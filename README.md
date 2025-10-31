# KipuBankV3

Repositorio: `KipuBankV3`  
Contrato principal: `KipuBankV3.sol`

## Objetivo
Actualizar KipuBankV2 para aceptar cualquier token soportado en Uniswap V4, convertirlo a USDC dentro del contrato y acreditar el resultado en el saldo del usuario, respetando el `bankCapUSD`. Mantener la lógica de V2: depósitos, retiros, roles, oráculos Chainlink, y protección contra reentradas.

## Componentes añadidos
- `USDC` (address) configurado en constructor.
- `swapRouter` (ISwapRouterV4) configurado en constructor — wrapper o acceso al UniversalRouter.
- `permit2` (IPermit2) opcional (setter).
- `depositArbitraryToken(address token, uint256 amount)`: función pública que:
  - Si `msg.value > 0` -> `depositETH()`.
  - Si `token == USDC` -> transferir y almacenar directamente.
  - Si otro ERC20 -> transferir token, aprobar router, ejecutar swap(token -> USDC),
    medir delta de USDC en el contrato y, si no excede `bankCapUSD`, acreditar al usuario.
- `_swapExactInputSingle(...)`: helper que llama al `swapRouter`. En esta entrega el router expone
  `swapExactInputSingle(...)` para simplificar pruebas. Para integración real con Uniswap V4,
  reemplazar la llamada por `UniversalRouter.execute(...)` con la codificación de acciones.

## Decisiones de diseño / trade-offs
- **Medición post-swap**: en vez de usar un "quoter" para estimar antes del swap, se mide exactamente el
  `deltaUSDC` después del swap y, si excede el `bankCapUSD`, se revierte la transacción. Esto garantiza
  que el banco nunca supere su límite aunque el slippage varíe.
- **Interfaz del Router**: para simplicidad y claridad en la entrega, se creó una interfaz `ISwapRouterV4`
  con un método `swapExactInputSingle(...)`. En producción debes:
  - Construir los `commands` y `inputs` del UniversalRouter (Uniswap V4),
  - o usar un wrapper que traduzca parámetros legibles (tokenIn, tokenOut, fee, recipient) a los `commands`.
- **Seguridad**:
  - `nonReentrant` en funciones de estado que manipulan fondos.
  - Uso de `SafeERC20` para transferencias y allowances.
  - Reset de allowance a 0 tras el swap.
  - Requiere revert si swap falla.
- **Oráculos**: se reutiliza la lógica de Chainlink para convertir ETH o tokens con feed conocido a USD.
  Para tokens convertidos por swap, tomamos el USDC recibido (6 decimales) como USD internal.

## Pasos para desplegar (pruebas / testnet)
1. Actualiza las direcciones en constructor:
   - `_ethUsdFeed`: Chainlink ETH/USD feed en la testnet elegida.
   - `_usdc`: dirección del contrato USDC (testnet).
   - `_swapRouter`: dirección del router compatible o un wrapper de pruebas.
2. Compila: `npx hardhat compile`
3. Despliega en testnet (ej. Goerli, Sepolia, o la testnet que uses) con `npx hardhat run --network <network> scripts/deploy.ts`
4. Verifica en explorer y sube la fuente (flatten o verify) para que se muestre el código verificado.
5. Prueba casos:
   - depositArbitraryToken con USDC
   - depositArbitraryToken con otro token ERC20 (requiere que el router tenga un pool para token->USDC)
   - depositETH (msg.value)
   - verificar que `bankCapUSD` no es excedido

## Qué debes reemplazar para integración completa con Uniswap V4
- Implementar la codificación exacta de `commands`/`actions` y llamar al `UniversalRouter`:
  - Construye la secuencia `Actions` (por ejemplo: permit2 (si usas permit), swap, etc.) y pásala al `execute` del router.
  - Si usas `Permit2`, implementa la lógica para usar `permit` y evitar `approve` on-chain.
- Considerar el uso de `Quoter` si quieres estimaciones previas al swap para mejorar UX (opcional).
- Verificar gas y ajustar `minAmountOut` / slippage guard.

## Notas finales
- El contrato preserva la lógica y estructura de KipuBankV2.
- Para la entrega final del curso, sustituye el wrapper `ISwapRouterV4` por la llamada al `UniversalRouter` y adjunta pruebas unitarias y scripts de despliegue.
