// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import {SafeCast} from "@valantis-core/lib/openzeppelin-contracts/contracts/utils/math/SafeCast.sol";
import {IERC20} from "@valantis-core/lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@valantis-core/lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {IUniversalPool} from "@valantis-core/src/pools/interfaces/IUniversalPool.sol";
import {ISovereignPool} from "@valantis-core/src/pools/interfaces/ISovereignPool.sol";
import {
    SovereignPoolSwapContextData,
    SovereignPoolSwapParams
} from "@valantis-core/src/pools/structs/SovereignPoolStructs.sol";
import {SwapParams} from "@valantis-core/src/pools/structs/UniversalPoolStructs.sol";
import {ReentrancyGuard} from "@valantis-core/src/utils/ReentrancyGuard.sol";

import {EIP712} from "./EIP712.sol";
import {SignatureVerification} from "./libraries/SignatureVerification.sol";
import {IWETH9} from "./interfaces/IWETH9.sol";
import {IProtocolFactory} from "../../lib/valantis-core/src/protocol-factory/interfaces/IProtocolFactory.sol";
import {IAllowanceTransfer} from "./interfaces/IAllowanceTransfer.sol";
import {IValantisSwapRouter} from "./interfaces/IValantisSwapRouter.sol";
import {GaslessSwapIntentHash} from "./libraries/GaslessSwapIntentHash.sol";
import {GaslessSwap} from "./libraries/GaslessSwap.sol";
import {DirectSwap} from "./libraries/DirectSwap.sol";
import {NonceBitmap} from "./libraries/NonceBitmap.sol";
import {
    GaslessSwapParams,
    GaslessSwapIntent,
    DirectSwapParams,
    ExecuteSwapParams,
    UniversalPoolSwapPayload,
    SovereignPoolSwapPayload
} from "./structs/ValantisSwapRouterStructs.sol";

contract ValantisSwapRouter is IValantisSwapRouter, EIP712, ReentrancyGuard {
    using GaslessSwapIntentHash for GaslessSwapIntent;
    using GaslessSwap for GaslessSwapParams;
    using DirectSwap for DirectSwapParams;
    using NonceBitmap for mapping(uint256 => uint256);
    using SafeCast for uint256;
    using SafeERC20 for IERC20;
    using SignatureVerification for bytes;

    /**
     *
     *  CUSTOM ERRORS
     *
     */
    error ValantisSwapRouter__batchGaslessSwaps_invalidArrayLengths();
    error ValantisSwapRouter__receive_onlyWeth();
    error ValantisSwapRouter__sovereignPoolSwapCallback_invalidTokenIn();
    error ValantisSwapRouter__sovereignPoolSwapCallback_poolNotAllowed();
    error ValantisSwapRouter__swap_invalidNativeTokenSwap();
    error ValantisSwapRouter__swap_insufficientAmountOut();
    error ValantisSwapRouter__swap_tokenOutNotWeth();
    error ValantisSwapRouter__sweep_invalidRecipient();
    error ValantisSwapRouter__sweep_invalidTokenAddress();
    error ValantisSwapRouter__sweep_invalidTokensArrayLength();
    error ValantisSwapRouter__universalPoolSwapCallback_invalidTokenIn();
    error ValantisSwapRouter__universalPoolSwapCallback_poolNotAllowed();
    error ValantisSwapRouter___executeSwaps_invalidAmountSpecifiedFirstSwap();
    error ValantisSwapRouter___executeSingleSwapSovereignPool_invalidSovereignPool();
    error ValantisSwapRouter___executeSingleSwapUniversalPool_invalidUniversalPool();
    error ValantisSwapRouter___executeGaslessSwap_excessiveFee();
    error ValantisSwapRouter___gaslessSwap_insufficientAmountOut();
    error ValantisSwapRouter___gaslessSwap_tokenOutNotWeth();
    error ValantisSwapRouter___sendNativeToken_ethTransferFailed();

    /**
     *
     *  IMMUTABLES
     *
     */

    /**
     * @notice Address of wrapped Native token.
     */
    // solhint-disable-next-line var-name-mixedcase
    address public immutable WETH9;

    /**
     * @notice Permit2 deployment.
     */
    IAllowanceTransfer private immutable _permit2;

    /**
     * @notice Valantis Protocol Factory.
     */
    IProtocolFactory private immutable _protocolFactory;

    /**
     *
     *  STORAGE
     *
     */

    /**
     * @notice Nonce bitmap for each signer and word.
     */
    mapping(address => mapping(uint256 => uint256)) public nonceBitmap;

    /**
     * @notice For each swap, only one Universal Pool is allowed to call `universalPoolSwapCallback`.
     */
    address public allowedUniversalPool;

    /**
     * @notice For each swap, only one Sovereign Pool is allowed to call `sovereignPoolSwapCallback`.
     */
    address public allowedSovereignPool;

    /**
     *
     *  CONSTRUCTOR
     *
     */
    constructor(address protocolFactory_, address _weth9, address permit2_) {
        _protocolFactory = IProtocolFactory(protocolFactory_);
        WETH9 = _weth9;
        _permit2 = IAllowanceTransfer(permit2_);

        allowedUniversalPool = address(1);
        allowedSovereignPool = address(1);
    }

    /**
     *
     *  VIEW FUNCTIONS
     *
     */

    /**
     * @notice Address of Permit2 deployment.
     */
    function permit2() external view override returns (address) {
        return address(_permit2);
    }

    /**
     * @notice Address of Valantis Protocol Factory.
     */
    function protocolFactory() external view override returns (address) {
        return address(_protocolFactory);
    }

    /**
     * @notice Exposes the status of reentrancy lock.
     * @dev Mainly useful for read-only reentrancy protection.
     */
    function isLocked() external view override returns (bool) {
        return _status == _ENTERED;
    }

    /**
     *
     *  EXTERNAL FUNCTIONS
     *
     */

    /**
     * @dev Required for swaps where tokenOut is ETH.
     * @dev Only callable by `WETH9`.
     */
    receive() external payable {
        if (msg.sender != WETH9) revert ValantisSwapRouter__receive_onlyWeth();
    }

    /**
     * @notice Callback function that Universal Pools can use to claim input token during a swap.
     * @dev Callable only by `allowedUniversalPool` at swap time.
     * @param _tokenIn Address of input token.
     * @param _amountInUsed Amount of input token used.
     * @param _swapCallbackContext Bytes encoded data required to execute the callback.
     */
    function universalPoolSwapCallback(address _tokenIn, uint256 _amountInUsed, bytes calldata _swapCallbackContext)
        external
        override
    {
        if (msg.sender != allowedUniversalPool) {
            revert ValantisSwapRouter__universalPoolSwapCallback_poolNotAllowed();
        }

        (address tokenIn, address payer) = abi.decode(_swapCallbackContext, (address, address));

        if (payer != address(this) && tokenIn != _tokenIn) {
            revert ValantisSwapRouter__universalPoolSwapCallback_invalidTokenIn();
        }

        _executeTransfer(_tokenIn, payer, msg.sender, _amountInUsed);
    }

    /**
     * @notice Callback function that Sovereign Pools can use to claim input token during a swap.
     * @dev Callable only by `allowedSovereignPool` at swap time.
     * @param _tokenIn Address of input token.
     * @param _amountInUsed Amount of input token used.
     * @param _swapCallbackContext Bytes encoded data required to execute the callback.
     */
    function sovereignPoolSwapCallback(address _tokenIn, uint256 _amountInUsed, bytes calldata _swapCallbackContext)
        external
        override
    {
        if (msg.sender != allowedSovereignPool) {
            revert ValantisSwapRouter__sovereignPoolSwapCallback_poolNotAllowed();
        }

        (address tokenIn, address payer) = abi.decode(_swapCallbackContext, (address, address));

        if (payer != address(this) && tokenIn != _tokenIn) {
            revert ValantisSwapRouter__sovereignPoolSwapCallback_invalidTokenIn();
        }

        // Sovereign Pools can have a custom recipient address for swaps
        address recipient = ISovereignPool(msg.sender).sovereignVault();
        _executeTransfer(_tokenIn, payer, recipient, _amountInUsed);
    }

    /**
     * @notice Swaps against Valantis liquidity pools using intents.
     * @dev Fee token payments, if any, are pulled from owner via Permit2.
     * @param _gaslessSwapParams Struct containing all intent parameters to be signed.
     * @param _ownerSignature EIP-712 signature of intent struct from owner.
     * @param _fee Fee to be charged for this transaction in feeToken.
     * @dev `_fee` must not exceed maxFee.
     */
    function gaslessSwap(GaslessSwapParams calldata _gaslessSwapParams, bytes calldata _ownerSignature, uint128 _fee)
        external
        override
        nonReentrant
        returns (uint256 amountOut)
    {
        amountOut = _gaslessSwap(_gaslessSwapParams, _ownerSignature, _fee);
    }

    /**
     * @notice Allows caller to execute batched swaps against Valantis liquidity pools.
     * @dev Each swap is expressed as an intent.
     * @param _gaslessSwapParamsArray Array containing struct parameters for each swap.
     * @param _ownerSignaturesArray Array containing intent signature from each owner.
     * @param _feeArray Array of fees that caller charges on each swap.
     * @return amountOutArray Array containing output token amount from each swap.
     */
    function batchGaslessSwaps(
        GaslessSwapParams[] calldata _gaslessSwapParamsArray,
        bytes[] calldata _ownerSignaturesArray,
        uint128[] calldata _feeArray
    ) external override nonReentrant returns (uint256[] memory amountOutArray) {
        // Array length consistency
        if (
            _gaslessSwapParamsArray.length != _ownerSignaturesArray.length
                || _ownerSignaturesArray.length != _feeArray.length
        ) {
            revert ValantisSwapRouter__batchGaslessSwaps_invalidArrayLengths();
        }

        uint256 length = _gaslessSwapParamsArray.length;
        amountOutArray = new uint256[](length);
        for (uint256 i; i < length;) {
            amountOutArray[i] = _gaslessSwap(_gaslessSwapParamsArray[i], _ownerSignaturesArray[i], _feeArray[i]);

            unchecked {
                ++i;
            }
        }
    }

    /**
     * @notice Allows msg.sender to swap against Valantis liquidity pools.
     * @param _directSwapParams Struct containing all relevant parameters to execute the swap(s).
     * @return amountOut Amount of output token.
     */
    function swap(DirectSwapParams calldata _directSwapParams)
        external
        payable
        override
        nonReentrant
        returns (uint256 amountOut)
    {
        // WETH related checks
        if (msg.value > 0 && _directSwapParams.tokenIn != WETH9) {
            revert ValantisSwapRouter__swap_invalidNativeTokenSwap();
        }

        if (_directSwapParams.isTokenOutEth && _directSwapParams.tokenOut != WETH9) {
            revert ValantisSwapRouter__swap_tokenOutNotWeth();
        }

        // Input params checks
        _directSwapParams.checkDirectSwapParams(msg.value);

        // Execute swap(s)
        uint256 tokenOutPreBalance = IERC20(_directSwapParams.tokenOut).balanceOf(
            _directSwapParams.isTokenOutEth ? address(this) : _directSwapParams.recipient
        );
        (uint256 amountInTotal, uint256 amountOutTotal) = _executeSwaps(
            ExecuteSwapParams({
                isUniversalPool: _directSwapParams.isUniversalPool,
                pools: _directSwapParams.pools,
                amountInSpecified: _directSwapParams.amountInSpecified,
                payloads: _directSwapParams.payloads,
                tokenIn: _directSwapParams.tokenIn,
                tokenOut: _directSwapParams.tokenOut,
                owner: msg.sender,
                deadline: _directSwapParams.deadline
            })
        );

        amountOut = IERC20(_directSwapParams.tokenOut).balanceOf(
            _directSwapParams.isTokenOutEth ? address(this) : _directSwapParams.recipient
        ) - tokenOutPreBalance;

        if (amountOut < _directSwapParams.amountOutMin || amountOutTotal < _directSwapParams.amountOutMin) {
            revert ValantisSwapRouter__swap_insufficientAmountOut();
        }

        if (msg.value > 0) {
            // Refund unspent ETH to recipient
            _sendNativeToken(_directSwapParams.recipient, address(this).balance);
        } else if (_directSwapParams.isTokenOutEth) {
            // Convert WETH into ETH and transfer to recipient
            IWETH9(WETH9).withdraw(amountOut);
            _sendNativeToken(_directSwapParams.recipient, amountOut);
        }

        emit DirectSwapLog(
            msg.sender,
            _directSwapParams.recipient,
            _directSwapParams.tokenIn,
            _directSwapParams.tokenOut,
            amountInTotal,
            amountOut,
            msg.value > 0,
            _directSwapParams.isTokenOutEth,
            _directSwapParams.code
        );
    }

    /**
     * @notice Sweep token balances which have been locked into this contract.
     * @dev Anyone can call this to sweep tokens.
     * @param _tokens Array of token address to claim balances for.
     * @param _recipient Recipient of incoming token balances.
     */
    function sweep(address[] memory _tokens, address _recipient) external nonReentrant {
        if (_tokens.length == 0) revert ValantisSwapRouter__sweep_invalidTokensArrayLength();

        if (_recipient == address(0)) revert ValantisSwapRouter__sweep_invalidRecipient();

        for (uint256 i; i < _tokens.length; i++) {
            IERC20 token = IERC20(_tokens[i]);
            if (address(token) == address(0)) revert ValantisSwapRouter__sweep_invalidTokenAddress();

            uint256 balance = token.balanceOf(address(this));
            if (balance > 0) token.safeTransfer(_recipient, balance);
        }
    }

    /**
     *
     *  PRIVATE FUNCTIONS
     *
     */
    function _gaslessSwap(GaslessSwapParams calldata gaslessSwapParams, bytes calldata ownerSignature, uint128 fee)
        private
        returns (uint256 amountOut)
    {
        if (gaslessSwapParams.intent.isTokenOutEth && gaslessSwapParams.intent.tokenOut != WETH9) {
            revert ValantisSwapRouter___gaslessSwap_tokenOutNotWeth();
        }

        uint256 amountInTotal;
        uint256 amountOutTotal;
        {
            uint256 tokenOutPreBalance = IERC20(gaslessSwapParams.intent.tokenOut).balanceOf(
                gaslessSwapParams.intent.isTokenOutEth ? address(this) : gaslessSwapParams.intent.recipient
            );

            (amountInTotal, amountOutTotal) = _executeGaslessSwap(gaslessSwapParams, ownerSignature, fee);

            amountOut = IERC20(gaslessSwapParams.intent.tokenOut).balanceOf(
                gaslessSwapParams.intent.isTokenOutEth ? address(this) : gaslessSwapParams.intent.recipient
            ) - tokenOutPreBalance;

            if (
                amountOut < gaslessSwapParams.intent.amountOutMin
                    || amountOutTotal < gaslessSwapParams.intent.amountOutMin
            ) {
                revert ValantisSwapRouter___gaslessSwap_insufficientAmountOut();
            }
        }

        if (gaslessSwapParams.intent.isTokenOutEth) {
            // Convert WETH into ETH and transfer to recipient
            IWETH9(WETH9).withdraw(amountOut);
            _sendNativeToken(gaslessSwapParams.intent.recipient, amountOut);
        }

        emit GaslessSwapLog(
            gaslessSwapParams.intent.owner,
            gaslessSwapParams.intent.authorizedSender,
            gaslessSwapParams.intent.recipient,
            gaslessSwapParams.intent.tokenIn,
            gaslessSwapParams.intent.tokenOut,
            amountInTotal,
            amountOut,
            gaslessSwapParams.intent.isTokenOutEth,
            gaslessSwapParams.code
        );
    }

    function _executeGaslessSwap(
        GaslessSwapParams calldata gaslessSwapParams,
        bytes calldata ownerSignature,
        uint128 fee
    ) private returns (uint256 amountInTotal, uint256 amountOutTotal) {
        // Input params checks
        gaslessSwapParams.checkGaslessSwapParams();

        if (fee > gaslessSwapParams.intent.maxFee) revert ValantisSwapRouter___executeGaslessSwap_excessiveFee();

        // Consume nonce
        nonceBitmap[gaslessSwapParams.intent.owner].consumeNonce(gaslessSwapParams.intent.nonce);

        // Verify owner signature
        ownerSignature.verify(_hashTypedDataV4(gaslessSwapParams.intent.hashStruct()), gaslessSwapParams.intent.owner);

        // Execute swap(s)
        (amountInTotal, amountOutTotal) = _executeSwaps(
            ExecuteSwapParams({
                isUniversalPool: gaslessSwapParams.isUniversalPool,
                pools: gaslessSwapParams.pools,
                amountInSpecified: gaslessSwapParams.amountInSpecified,
                payloads: gaslessSwapParams.payloads,
                tokenIn: gaslessSwapParams.intent.tokenIn,
                tokenOut: gaslessSwapParams.intent.tokenOut,
                owner: gaslessSwapParams.intent.owner,
                deadline: gaslessSwapParams.intent.deadline
            })
        );

        // Pay fee in feeToken
        if (fee > 0) {
            _permit2.transferFrom(
                gaslessSwapParams.intent.owner,
                gaslessSwapParams.intent.authorizedSender,
                uint160(fee),
                gaslessSwapParams.intent.feeToken
            );
        }
    }

    function _executeSwaps(ExecuteSwapParams memory params)
        private
        returns (uint256 amountInTotal, uint256 amountOutTotal)
    {
        uint256 amountOutSwap;

        // First swap's amountIn must be specified by owner
        if (params.amountInSpecified[0] == 0) {
            revert ValantisSwapRouter___executeSwaps_invalidAmountSpecifiedFirstSwap();
        }

        for (uint256 i; i < params.pools.length;) {
            uint256 amountInUsed;
            address tokenOutSwap;
            (amountInUsed, tokenOutSwap, amountOutSwap) = params.isUniversalPool[i]
                ? _executeSingleSwapUniversalPool(
                    params.amountInSpecified[i] > 0 ? params.amountInSpecified[i] : amountOutSwap,
                    params.deadline,
                    params.pools[i],
                    abi.encode(params.tokenIn, params.amountInSpecified[i] > 0 ? params.owner : address(this)),
                    params.payloads[i]
                )
                : _executeSingleSwapSovereignPool(
                    params.amountInSpecified[i] > 0 ? params.amountInSpecified[i] : amountOutSwap,
                    params.deadline,
                    params.pools[i],
                    abi.encode(params.tokenIn, params.amountInSpecified[i] > 0 ? params.owner : address(this)),
                    params.payloads[i]
                );

            // Equivalent to user's tokenIn being the input token of this swap
            if (params.amountInSpecified[i] > 0) {
                amountInTotal += amountInUsed;
            }

            if (tokenOutSwap == params.tokenOut) {
                amountOutTotal += amountOutSwap;
            }

            unchecked {
                ++i;
            }
        }
    }

    function _executeSingleSwapUniversalPool(
        uint256 amountIn,
        uint256 deadline,
        address pool,
        bytes memory swapCallbackContext,
        bytes memory payload
    ) private returns (uint256 amountInUsed, address tokenOut, uint256 amountOut) {
        if (!_protocolFactory.isValidUniversalPool(pool)) {
            revert ValantisSwapRouter___executeSingleSwapUniversalPool_invalidUniversalPool();
        }

        UniversalPoolSwapPayload memory payloadStruct = abi.decode(payload, (UniversalPoolSwapPayload));

        allowedUniversalPool = pool;

        (amountInUsed, amountOut) = IUniversalPool(pool).swap(
            SwapParams({
                isZeroToOne: payloadStruct.isZeroToOne,
                isSwapCallback: true,
                limitPriceTick: payloadStruct.limitPriceTick,
                recipient: payloadStruct.recipient,
                amountIn: amountIn,
                amountOutMin: payloadStruct.amountOutMin,
                deadline: deadline,
                swapCallbackContext: swapCallbackContext,
                swapFeeModuleContext: payloadStruct.swapFeeModuleContext,
                almOrdering: payloadStruct.almOrdering,
                externalContext: payloadStruct.externalContext
            })
        );

        tokenOut = payloadStruct.isZeroToOne ? IUniversalPool(pool).token1() : IUniversalPool(pool).token0();

        allowedUniversalPool = address(1);
    }

    function _executeSingleSwapSovereignPool(
        uint256 amountIn,
        uint256 deadline,
        address pool,
        bytes memory swapCallbackContext,
        bytes memory payload
    ) private returns (uint256 amountInUsed, address tokenOut, uint256 amountOut) {
        if (!_protocolFactory.isValidSovereignPool(pool)) {
            revert ValantisSwapRouter___executeSingleSwapSovereignPool_invalidSovereignPool();
        }

        SovereignPoolSwapPayload memory payloadStruct = abi.decode(payload, (SovereignPoolSwapPayload));

        allowedSovereignPool = pool;

        (amountInUsed, amountOut) = ISovereignPool(pool).swap(
            SovereignPoolSwapParams({
                isSwapCallback: true,
                isZeroToOne: payloadStruct.isZeroToOne,
                amountIn: amountIn,
                amountOutMin: payloadStruct.amountOutMin,
                deadline: deadline,
                recipient: payloadStruct.recipient,
                swapTokenOut: payloadStruct.swapTokenOut,
                swapContext: SovereignPoolSwapContextData(
                    payloadStruct.externalContext,
                    payloadStruct.verificationContext,
                    swapCallbackContext,
                    payloadStruct.swapFeeModuleContext
                )
            })
        );
        tokenOut = payloadStruct.swapTokenOut;

        allowedSovereignPool = address(1);
    }

    function _executeTransfer(address token, address payer, address recipient, uint256 amount) private {
        if (token == WETH9 && address(this).balance >= amount) {
            IWETH9(WETH9).deposit{value: amount}();
            IWETH9(WETH9).transfer(recipient, amount);
        } else if (payer == address(this)) {
            IERC20(token).safeTransfer(recipient, amount);
        } else {
            _permit2.transferFrom(payer, recipient, amount.toUint160(), token);
        }
    }

    function _sendNativeToken(address recipient, uint256 amount) private {
        if (amount > 0) {
            (bool success,) = payable(recipient).call{value: amount}("");
            if (!success) {
                revert ValantisSwapRouter___sendNativeToken_ethTransferFailed();
            }
        }
    }
}
