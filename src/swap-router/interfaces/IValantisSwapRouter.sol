// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {ISovereignPoolSwapCallback} from "@valantis-core/src/pools/interfaces/ISovereignPoolSwapCallback.sol";
import {IUniversalPoolSwapCallback} from "@valantis-core/src/pools/interfaces/IUniversalPoolSwapCallback.sol";

import {GaslessSwapParams, DirectSwapParams} from "../structs/ValantisSwapRouterStructs.sol";

interface IValantisSwapRouter is ISovereignPoolSwapCallback, IUniversalPoolSwapCallback {
    event DirectSwapLog(
        address user,
        address recipient,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        bool isTokenInEth,
        bool isTokenOutEth,
        bytes32 code
    );

    event GaslessSwapLog(
        address user,
        address solver,
        address recipient,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        bool isTokenOutEth,
        bytes32 code
    );

    // solhint-disable-next-line func-name-mixedcase
    function WETH9() external view returns (address);

    function nonceBitmap(address _signer, uint256 _wordPosition) external view returns (uint256);

    function isLocked() external view returns (bool);

    function allowedUniversalPool() external view returns (address);

    function allowedSovereignPool() external view returns (address);

    function permit2() external view returns (address);

    function protocolFactory() external view returns (address);

    function gaslessSwap(GaslessSwapParams calldata _gaslessSwapParams, bytes calldata _ownerSignature, uint128 _fee)
        external
        returns (uint256 amountOut);

    function batchGaslessSwaps(
        GaslessSwapParams[] calldata _gaslessSwapParamsArray,
        bytes[] calldata _ownerSignaturesArray,
        uint128[] calldata _feeArray
    ) external returns (uint256[] memory amountOutArray);

    function swap(DirectSwapParams calldata _directSwapParams) external payable returns (uint256 amountOut);
}
