// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

/**
 * @notice Swap params passed by solvers and executed on behalf of due owner.
 */
struct GaslessSwapParams {
    bool[] isUniversalPool;
    address[] pools;
    uint256[] amountInSpecified;
    bytes[] payloads;
    GaslessSwapIntent intent;
    bytes32 code;
}

/**
 * @notice Intent struct, to be EIP-712 signed by `owner`.
 */
struct GaslessSwapIntent {
    bool isTokenOutEth;
    address tokenIn;
    address tokenOut;
    address owner;
    address recipient;
    address authorizedSender;
    address feeToken;
    uint256 amountIn;
    uint256 amountOutMin;
    uint128 maxFee;
    uint256 nonce;
    uint256 deadline;
}

/**
 * @notice Struct containing params for direct swap.
 */
struct DirectSwapParams {
    bool[] isUniversalPool;
    address[] pools;
    uint256[] amountInSpecified;
    bytes[] payloads;
    bool isTokenOutEth;
    address tokenIn;
    address tokenOut;
    address recipient;
    uint256 amountOutMin;
    uint256 deadline;
    bytes32 code;
}

/**
 * @notice Auxiliary struct containing parameters for `_executeSwaps`.
 *     @dev Required in order to bypass stack-too-deep errors.
 */
struct ExecuteSwapParams {
    bool[] isUniversalPool;
    address[] pools;
    uint256[] amountInSpecified;
    bytes[] payloads;
    address tokenIn;
    address tokenOut;
    address owner;
    uint256 deadline;
}

/**
 * @notice Internal struct used for single swap payloads in Universal pools.
 */
struct UniversalPoolSwapPayload {
    bool isZeroToOne;
    address recipient;
    int24 limitPriceTick;
    uint256 amountOutMin;
    uint8[] almOrdering;
    bytes[] externalContext;
    bytes swapFeeModuleContext;
}

/**
 * @notice Internal struct used for single swap payloads in Sovereign pools.
 */
struct SovereignPoolSwapPayload {
    bool isZeroToOne;
    address recipient;
    address swapTokenOut;
    uint256 amountOutMin;
    bytes externalContext;
    bytes verificationContext;
    bytes swapFeeModuleContext;
}
