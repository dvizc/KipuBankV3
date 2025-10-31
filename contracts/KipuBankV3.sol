// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * KipuBankV3
 * - Basado en KipuBankV2 (proporcionado por la usuaria)
 * - Añade: Universal Router (interfaz genérica), IPermit2, swap de tokens a USDC dentro del contrato,
 *   depositArbitraryToken, y preserva la lógica de bankCapUSD y oráculos Chainlink.
 *
 * NOTA: El "Universal Router" real de Uniswap V4 requiere construir un array/stream de "commands"
 * y "inputs" binarios (acciones). Aquí se expone una interfaz genérica ISwapRouterV4 para la
 * demostración y testing local. En integración final debes reemplazar / implementar la llamada
 * exacta al UniversalRouter con la codificación correctamente construida (ver README).
 */

import "https://raw.githubusercontent.com/OpenZeppelin/openzeppelin-contracts/v4.9.3/contracts/access/AccessControl.sol";
import "https://raw.githubusercontent.com/OpenZeppelin/openzeppelin-contracts/v4.9.3/contracts/security/ReentrancyGuard.sol";
import "https://raw.githubusercontent.com/OpenZeppelin/openzeppelin-contracts/v4.9.3/contracts/token/ERC20/utils/SafeERC20.sol";
import "https://raw.githubusercontent.com/OpenZeppelin/openzeppelin-contracts/v4.9.3/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/// @notice Minimal Chainlink AggregatorV3 interface
interface AggregatorV3Interface {
    function decimals() external view returns (uint8);
    function latestRoundData()
        external
        view
        returns (
            uint80,
            int256,
            uint256,
            uint256,
            uint80
        );
}

/*========================================================================
  Minimal external interfaces for Uniswap/permit helpers (placeholders)
  Replace / adapt them to the real UniswapV4 UniversalRouter / Permit2
  when integrating on testnet/mainnet.
  ========================================================================*/

interface IPermit2 {
    // Minimal placeholder interface. Real IPermit2 is more elaborate.
    function permit(address owner, bytes calldata permitData) external;
}

interface ISwapRouterV4 {
    /**
     * Placeholder simplified function representing a swap entrypoint.
     * In Uniswap V4 you will usually "execute" a series of Commands/Actions
     * with a UniversalRouter. Replace this call with the correct `execute(...)`
     * or `multicall(...)` and encoded actions.
     *
     * Implementations used for local tests / sample networks may expose a
     * convenience function like this — otherwise prepare the bytes payload.
     */
    function swapExactInputSingle(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        address recipient
    ) external payable returns (uint256 amountOut);
}

contract KipuBankV3 is AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                              ROLES
    //////////////////////////////////////////////////////////////*/

    bytes32 public constant MANAGER_ROLE = keccak256("MANAGER_ROLE");

    /*//////////////////////////////////////////////////////////////
                         CONSTANTS & IMMUTABLES
    //////////////////////////////////////////////////////////////*/

    /// @notice Internal accounting uses 6 decimals (like USDC)
    uint8 public constant INTERNAL_DECIMALS = 6;

    /// @notice Max total USD value allowed in the vault
    uint256 public immutable bankCapUSD;

    /// @notice Max USD withdrawal allowed per transaction
    uint256 public immutable maxWithdrawUSD;

    /*//////////////////////////////////////////////////////////////
                              STRUCTS
    //////////////////////////////////////////////////////////////*/

    struct TokenInfo {
        bool supported;
        address feed; // Chainlink feed returning USD price
        uint8 decimalsOverride; // 0 = use token.decimals()
    }

    /*//////////////////////////////////////////////////////////////
                              STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @notice user balances by token: balances[token][user]
    mapping(address => mapping(address => uint256)) private balances;

    /// @notice registered tokens and feeds
    mapping(address => TokenInfo) public tokenInfo;

    /// @notice Chainlink ETH/USD feed
    AggregatorV3Interface public priceFeedETH;

    /// @notice Staleness threshold (seconds)
    uint256 public priceStalenessThreshold;

    /// @notice Internal total in USD (6 decimals)
    uint256 private totalDepositedUSD;

    /// @notice operation counters
    uint256 public depositCount;
    uint256 public withdrawCount;

    /*//////////////////////////////////////////////////////////////
                     Uniswap / Helpers / Tokens
    //////////////////////////////////////////////////////////////*/

    /// @notice Address of USDC token (must be set by constructor or manager)
    address public immutable USDC;

    /// @notice Swap router (Universal Router / or a wrapper)
    ISwapRouterV4 public immutable swapRouter;

    /// @notice Optional Permit2 address (can be zero)
    IPermit2 public permit2;

    /*//////////////////////////////////////////////////////////////
                              EVENTS
    //////////////////////////////////////////////////////////////*/

    event Deposited(address indexed user, address indexed token, uint256 tokenAmount, uint256 usdValue);
    event Withdrawn(address indexed user, address indexed token, uint256 tokenAmount, uint256 usdValue);
    event TokenSupported(address indexed token, address indexed feed, uint8 decimalsOverride);
    event TokenUnsupported(address indexed token);
    event PriceFeedETHSet(address indexed feed);
    event PriceStalenessThresholdSet(uint256 secondsThreshold);
    event Rescue(address indexed to, address indexed token, uint256 amount);
    event Permit2Set(address indexed permit2);
    event SwapExecuted(address indexed user, address tokenIn, uint256 amountIn, uint256 amountOutUSDC);

    /*//////////////////////////////////////////////////////////////
                              ERRORS
    //////////////////////////////////////////////////////////////*/

    error ZeroAmount();
    error ExceedsBankCap(uint256 attemptedUSD, uint256 bankCapUSD);
    error InsufficientBalance(address user, address token, uint256 balance, uint256 requested);
    error NoPriceFeed(address token);
    error PriceFeedStale(address token, uint256 updatedAt, uint256 threshold);
    error ExceedsMaxWithdraw(uint256 attemptedUSD, uint256 maxWithdrawUSD);
    error TransferFailed();
    error TokenNotSupported(address token);
    error InvalidAddress();
    error SwapFailed();
    error NoUSDCContract();

    /*//////////////////////////////////////////////////////////////
                              MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier onlyManager() {
        require(hasRole(MANAGER_ROLE, msg.sender), "Manager role required");
        _; 
    }

    modifier nonZero(uint256 amount) {
        if (amount == 0) revert ZeroAmount();
        _;
    }

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /**
     * @param _bankCapUSD Max USD capacity (6 decimals)
     * @param _maxWithdrawUSD Max withdraw per tx (6 decimals)
     * @param _ethUsdFeed Chainlink ETH/USD feed
     * @param _usdc Address of USDC token (6 decimals expected)
     * @param _swapRouter Address of the swap router / universal router wrapper
     */
    constructor(
        uint256 _bankCapUSD,
        uint256 _maxWithdrawUSD,
        address _ethUsdFeed,
        address _usdc,
        address _swapRouter
    ) {
        if (_ethUsdFeed == address(0) || _usdc == address(0) || _swapRouter == address(0)) revert InvalidAddress();

        bankCapUSD = _bankCapUSD;
        maxWithdrawUSD = _maxWithdrawUSD;
        priceFeedETH = AggregatorV3Interface(_ethUsdFeed);
        USDC = _usdc;
        swapRouter = ISwapRouterV4(_swapRouter);

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(MANAGER_ROLE, msg.sender);

        emit PriceFeedETHSet(_ethUsdFeed);
    }

    /*//////////////////////////////////////////////////////////////
                        MANAGER / ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function supportToken(address token, address feed, uint8 decimalsOverride) external onlyManager {
        if (token == address(0) || feed == address(0)) revert InvalidAddress();
        tokenInfo[token] = TokenInfo(true, feed, decimalsOverride);
        emit TokenSupported(token, feed, decimalsOverride);
    }

    function unsupportToken(address token) external onlyManager {
        if (!tokenInfo[token].supported) revert TokenNotSupported(token);
        delete tokenInfo[token];
        emit TokenUnsupported(token);
    }

    function setETHPriceFeed(address feed) external onlyManager {
        if (feed == address(0)) revert InvalidAddress();
        priceFeedETH = AggregatorV3Interface(feed);
        emit PriceFeedETHSet(feed);
    }

    function setPriceStalenessThreshold(uint256 secondsThreshold) external onlyManager {
        priceStalenessThreshold = secondsThreshold;
        emit PriceStalenessThresholdSet(secondsThreshold);
    }

    function setPermit2(address _permit2) external onlyManager {
        permit2 = IPermit2(_permit2);
        emit Permit2Set(_permit2);
    }

    function rescueERC20(address token, address to, uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant {
        if (to == address(0)) revert InvalidAddress();
        IERC20(token).safeTransfer(to, amount);
        emit Rescue(to, token, amount);
    }

    function rescueETH(address payable to, uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant {
        if (to == address(0)) revert InvalidAddress();
        _safeTransferETH(to, amount);
        emit Rescue(to, address(0), amount);
    }

    /*//////////////////////////////////////////////////////////////
                              DEPOSITS
    //////////////////////////////////////////////////////////////*/

    function depositETH() public payable nonReentrant nonZero(msg.value) {
        uint256 usdValue = _convertETHToUSD(msg.value);
        if (totalDepositedUSD + usdValue > bankCapUSD) revert ExceedsBankCap(totalDepositedUSD + usdValue, bankCapUSD);

        balances[address(0)][msg.sender] += msg.value;
        totalDepositedUSD += usdValue;
        depositCount++;

        emit Deposited(msg.sender, address(0), msg.value, usdValue);
    }

    function depositERC20(address token, uint256 amount) public nonReentrant nonZero(amount) {
        TokenInfo memory info = tokenInfo[token];
        if (!info.supported) revert TokenNotSupported(token);

        uint256 usdValue = _convertTokenToUSD(token, amount);
        if (totalDepositedUSD + usdValue > bankCapUSD) revert ExceedsBankCap(totalDepositedUSD + usdValue, bankCapUSD);

        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        balances[token][msg.sender] += amount;
        totalDepositedUSD += usdValue;
        depositCount++;

        emit Deposited(msg.sender, token, amount, usdValue);
    }

    /**
     * @notice depositArbitraryToken:
     * - If token == USDC: store directly (USDC expected to have 6 decimals -> INTERNAL_DECIMALS)
     * - If token == native (msg.value > 0 or token == address(0)) -> depositETH (already converts using oracle)
     * - Otherwise: Transfer token in, swap to USDC (via swapRouter), compute USDC delta, check bank cap,
     *              credit user's USDC balance with the USDC received.
     */
    function depositArbitraryToken(address token, uint256 amount) external payable nonReentrant {
        // Case: ETH sent in msg.value -> route to depositETH
        if (msg.value > 0) {
            // ensure no additional 'amount' passed
            if (amount != 0) revert InvalidAddress();
            depositETH();
            return;
        }

        if (token == address(0)) {
            revert InvalidAddress(); // ETH should use msg.value path
        }

        // USDC direct deposit
        if (token == USDC) {
            // amount must be > 0
            if (amount == 0) revert ZeroAmount();

            // transfer USDC from user
            IERC20(USDC).safeTransferFrom(msg.sender, address(this), amount);

            // amount is already in USDC units (6 decimals expected)
            uint256 usdValue = amount; // internal decimals same as USDC (6)
            if (totalDepositedUSD + usdValue > bankCapUSD) revert ExceedsBankCap(totalDepositedUSD + usdValue, bankCapUSD);

            balances[USDC][msg.sender] += amount;
            totalDepositedUSD += usdValue;
            depositCount++;

            emit Deposited(msg.sender, USDC, amount, usdValue);
            return;
        }

        // Other ERC20 token -> swap to USDC
        if (amount == 0) revert ZeroAmount();

        // token must be supported (optional: for swaps we could allow arbitrary tokens, but keep safety)
        // We'll allow swap for tokens not explicitly supported by Chainlink (but note: _convertTokenToUSD would fail)
        // For depositArbitraryToken we don't rely on _convertTokenToUSD pre-swap; we will measure post-swap USDC delta
        // Transfer token to contract
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);

        // Record prior USDC balance to compute delta
        uint256 priorUSDC = IERC20(USDC).balanceOf(address(this));

        // Approve router to pull token. Use safeApprove pattern.
        IERC20(token).safeIncreaseAllowance(address(swapRouter), amount);

        // Execute swap: token -> USDC
        uint256 amountOutUSDC;
        try swapRouter.swapExactInputSingle(token, USDC, amount, 1, address(this)) returns (uint256 amtOut) {
            amountOutUSDC = amtOut;
        } catch {
            // revert approval then revert
            // reset approval to 0 for safety
            IERC20(token).safeApprove(address(swapRouter), 0);
            revert SwapFailed();
        }

        // Reset approval (security)
        IERC20(token).safeApprove(address(swapRouter), 0);

        // Compute actual USDC delta (in case router had pre-existing balance)
        uint256 postUSDC = IERC20(USDC).balanceOf(address(this));
        uint256 deltaUSDC;
        unchecked {
            if (postUSDC > priorUSDC) deltaUSDC = postUSDC - priorUSDC;
            else deltaUSDC = 0;
        }

        if (deltaUSDC == 0) revert SwapFailed();

        // Check bank cap using USDC (6 decimals)
        uint256 usdValue = deltaUSDC; // USDC is 6 decimals -> matches INTERNAL_DECIMALS

        if (totalDepositedUSD + usdValue > bankCapUSD) {
            // Revert entire tx to undo swap and token transfer
            revert ExceedsBankCap(totalDeposUSD + usdValue, bankCapUSD);
        }

        // Credit user's USDC balance with received USDC
        balances[USDC][msg.sender] += deltaUSDC;
        totalDepositedUSD += usdValue;
        depositCount++;

        emit Deposited(msg.sender, USDC, deltaUSDC, usdValue);
        emit SwapExecuted(msg.sender, token, amount, deltaUSDC);
    }

    /*//////////////////////////////////////////////////////////////
                              WITHDRAWALS
    //////////////////////////////////////////////////////////////*/

    function withdrawETH(uint256 amount) external nonReentrant nonZero(amount) {
        uint256 userBalance = balances[address(0)][msg.sender];
        if (userBalance < amount) revert InsufficientBalance(msg.sender, address(0), userBalance, amount);

        uint256 usdValue = _convertETHToUSD(amount);
        if (usdValue > maxWithdrawUSD) revert ExceedsMaxWithdraw(usdValue, maxWithdrawUSD);

        balances[address(0)][msg.sender] = userBalance - amount;
        totalDepositedUSD = _safeSubUSD(totalDeposUSD, usdValue);
        withdrawCount++;

        _safeTransferETH(payable(msg.sender), amount);
        emit Withdrawn(msg.sender, address(0), amount, usdValue);
    }

    function withdrawERC20(address token, uint256 amount) external nonReentrant nonZero(amount) {
        TokenInfo memory info = tokenInfo[token];
        if (!info.supported && token != USDC) revert TokenNotSupported(token);

        uint256 userBalance = balances[token][msg.sender];
        if (userBalance < amount) revert InsufficientBalance(msg.sender, token, userBalance, amount);

        uint256 usdValue;
        if (token == USDC) {
            // USDC 6 decimals
            usdValue = amount;
        } else {
            usdValue = _convertTokenToUSD(token, amount);
            if (usdValue > maxWithdrawUSD) revert ExceedsMaxWithdraw(usdValue, maxWithdrawUSD);
        }

        balances[token][msg.sender] = userBalance - amount;
        totalDepositedUSD = _safeSubUSD(totalDepositedUSD, usdValue);
        withdrawCount++;

        IERC20(token).safeTransfer(msg.sender, amount);
        emit Withdrawn(msg.sender, token, amount, usdValue);
    }

    /*//////////////////////////////////////////////////////////////
                              VIEWS
    //////////////////////////////////////////////////////////////*/

    function balanceOf(address token, address user) external view returns (uint256) {
        return balances[token][user];
    }

    function contractBalance(address token) external view returns (uint256) {
        return token == address(0) ? address(this).balance : IERC20(token).balanceOf(address(this));
    }

    function totalDeposited() external view returns (uint256) {
        return totalDepositedUSD;
    }

    /*//////////////////////////////////////////////////////////////
                          INTERNAL HELPERS
    //////////////////////////////////////////////////////////////*/

    function _convertETHToUSD(uint256 weiAmount) internal view returns (uint256) {
        ( , int256 price, , uint256 updatedAt, ) = priceFeedETH.latestRoundData();
        if (price <= 0) revert NoPriceFeed(address(0));
        if (priceStalenessThreshold > 0 && block.timestamp > updatedAt + priceStalenessThreshold) {
            revert PriceFeedStale(address(0), updatedAt, priceStalenessThreshold);
        }

        uint256 priceDecimals = priceFeedETH.decimals();
        uint256 numerator = weiAmount * uint256(price) * (10 ** INTERNAL_DECIMALS);
        uint256 denominator = (10 ** 18) * (10 ** priceDecimals);
        return numerator / denominator;
    }

    function _convertTokenToUSD(address token, uint256 amount) internal view returns (uint256) {
        TokenInfo memory info = tokenInfo[token];
        if (!info.supported) revert TokenNotSupported(token);

        AggregatorV3Interface feed = AggregatorV3Interface(info.feed);
        ( , int256 price, , uint256 updatedAt, ) = feed.latestRoundData();
        if (price <= 0) revert NoPriceFeed(token);
        if (priceStalenessThreshold > 0 && block.timestamp > updatedAt + priceStalenessThreshold) {
            revert PriceFeedStale(token, updatedAt, priceStalenessThreshold);
        }

        uint8 tokenDecimals = info.decimalsOverride == 0
            ? IERC20Metadata(token).decimals()
            : info.decimalsOverride;

        uint256 numerator = amount * uint256(price) * (10 ** INTERNAL_DECIMALS);
        uint256 denominator = (10 ** tokenDecimals) * (10 ** feed.decimals());
        return numerator / denominator;
    }

    function _safeSubUSD(uint256 a, uint256 b) internal pure returns (uint256) {
        return b >= a ? 0 : a - b;
    }

    function _safeTransferETH(address payable to, uint256 amount) internal {
        (bool success, ) = to.call{value: amount}("");
        if (!success) revert TransferFailed();
    }

    /*//////////////////////////////////////////////////////////////
                              FALLBACKS
    //////////////////////////////////////////////////////////////*/

    receive() external payable {
        revert("Use depositETH()");
    }

    fallback() external payable {
        revert("Use depositETH()");
    }
}
