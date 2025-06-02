// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.19;

import "forge-std/Test.sol";
import "forge-std/console.sol";

import {ERC20PresetFixedSupply} from
    "@valantis-core/lib/openzeppelin-contracts/contracts/token/ERC20/presets/ERC20PresetFixedSupply.sol";
import {WETH} from "@solmate/src/tokens/WETH.sol";
import {DeployPermit2} from "@permit2/test/utils/DeployPermit2.sol";

import {ALMLiquidityQuote} from "@valantis-core/src/ALM/structs/UniversalALMStructs.sol";
import {MockSovereignALM} from "@valantis-core/src/mocks/MockSovereignALM.sol";
import {MockSovereignALMFactory} from "@valantis-core/src/mocks/MockSovereignALMFactory.sol";
import {SovereignPool} from "@valantis-core/src/pools/SovereignPool.sol";
import {SovereignPoolFactory} from "@valantis-core/src/pools/factories/SovereignPoolFactory.sol";
import {SovereignPoolConstructorArgs} from "@valantis-core/src/pools/structs/SovereignPoolStructs.sol";
import {MockUniversalALM} from "@valantis-core/src/mocks/MockUniversalALM.sol";
import {MockUniversalALMFactory} from "@valantis-core/src/mocks/MockUniversalALMFactory.sol";
import {UniversalPool, PoolState} from "@valantis-core/src/pools/UniversalPool.sol";
import {ALMReserves} from "@valantis-core/src/ALM/structs/UniversalALMStructs.sol";
import {UniversalPoolFactory} from "@valantis-core/src/pools/factories/UniversalPoolFactory.sol";
import {ProtocolFactory} from "@valantis-core/src/protocol-factory/ProtocolFactory.sol";
import {PriceTickMath} from "@valantis-core/src/libraries/PriceTickMath.sol";

import {ValantisSwapRouter} from "../src/swap-router/ValantisSwapRouter.sol";
import {
    DirectSwapParams,
    UniversalPoolSwapPayload,
    SovereignPoolSwapPayload,
    GaslessSwapParams,
    GaslessSwapIntent
} from "../src/swap-router/structs/ValantisSwapRouterStructs.sol";
import {DirectSwap} from "../src/swap-router/libraries/DirectSwap.sol";
import {SignatureVerification} from "../src/swap-router/libraries/SignatureVerification.sol";
import {IAllowanceTransfer} from "../src/swap-router/interfaces/IAllowanceTransfer.sol";

contract SwapRouterTest is Test, DeployPermit2 {
    error SwapRouterTest__receive_revertOnReceive();

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

    IAllowanceTransfer public permit2;

    ERC20PresetFixedSupply public token0;
    ERC20PresetFixedSupply public token1;
    ERC20PresetFixedSupply public token2;
    ERC20PresetFixedSupply public token3;

    MockSovereignALM public firstSovereignALM;
    MockSovereignALM public secondSovereignALM;
    MockSovereignALM public thirdSovereignALM;
    MockSovereignALM public fourthSovereignALM;

    MockUniversalALM public firstUniversalALM;
    MockUniversalALM public secondUniversalALM;
    MockUniversalALM public thirdUniversalALM;
    MockUniversalALM public fourthUniversalALM;

    ProtocolFactory public protocolFactory;

    WETH public weth;

    ValantisSwapRouter public swapRouter;

    SovereignPool public firstSovereignPool;
    SovereignPool public secondSovereignPool;
    SovereignPool public thirdSovereignPool;
    SovereignPool public fourthSovereignPool;
    SovereignPool public invalidSovereignPool;

    UniversalPool public firstUniversalPool;
    UniversalPool public secondUniversalPool;
    UniversalPool public thirdUniversalPool;
    UniversalPool public fourthUniversalPool;
    UniversalPool public invalidUniversalPool;

    bool public revertOnReceive;

    address public constant MOCK_RECIPIENT = address(123);
    uint256 public constant TOKEN_SUPPLY = 1000e18;
    uint32 public constant BLOCK_TIME = 12;
    bytes32 public constant GASLESS_SWAP_INTENT_TYPEHASH = keccak256(
        // solhint-disable-next-line max-line-length
        "GaslessSwapIntent(bool isTokenOutEth,address tokenIn,address tokenOut,address owner,address recipient,address authorizedSender,address feeToken,uint256 amountIn,uint256 amountOutMin,uint128 maxFee,uint256 nonce,uint256 deadline)"
    );
    bytes32 public constant EMPTY_CODE = keccak256("");

    address _owner;
    uint256 private constant _ownerPrivateKey = 0x12345;

    function setUp() public {
        _owner = vm.addr(_ownerPrivateKey);

        permit2 = IAllowanceTransfer(deployPermit2());

        token0 = new ERC20PresetFixedSupply("token0", "0", TOKEN_SUPPLY, address(this));
        token1 = new ERC20PresetFixedSupply("token1", "1", TOKEN_SUPPLY, address(this));
        token2 = new ERC20PresetFixedSupply("token2", "2", TOKEN_SUPPLY, address(this));
        token3 = new ERC20PresetFixedSupply("token3", "3", TOKEN_SUPPLY, address(this));
        weth = new WETH();

        vm.deal(address(this), TOKEN_SUPPLY);
        assertEq(address(this).balance, TOKEN_SUPPLY);

        address protocolDeployer = address(this);
        protocolFactory = new ProtocolFactory(protocolDeployer);

        SovereignPoolFactory sovereignPoolFactory = new SovereignPoolFactory();
        protocolFactory.setSovereignPoolFactory(address(sovereignPoolFactory));

        UniversalPoolFactory universalPoolFactory = new UniversalPoolFactory();
        protocolFactory.setUniversalPoolFactory(address(universalPoolFactory));

        address sovereignALMFactory = address(new MockSovereignALMFactory(address(protocolFactory)));
        protocolFactory.addSovereignALMFactory(sovereignALMFactory);

        address universalALMFactory = address(new MockUniversalALMFactory(address(protocolFactory)));
        protocolFactory.addUniversalALMFactory(universalALMFactory);

        // Deploy Sovereign Pools
        firstSovereignPool = SovereignPool(
            protocolFactory.deploySovereignPool(
                SovereignPoolConstructorArgs({
                    token0: address(token0),
                    token1: address(token1),
                    protocolFactory: address(0),
                    poolManager: address(this),
                    sovereignVault: address(0),
                    verifierModule: address(0),
                    isToken0Rebase: false,
                    isToken1Rebase: false,
                    token0AbsErrorTolerance: 0,
                    token1AbsErrorTolerance: 0,
                    defaultSwapFeeBips: 0
                })
            )
        );

        secondSovereignPool = SovereignPool(
            protocolFactory.deploySovereignPool(
                SovereignPoolConstructorArgs({
                    token0: address(token1),
                    token1: address(token2),
                    protocolFactory: address(0),
                    poolManager: address(this),
                    sovereignVault: address(0),
                    verifierModule: address(0),
                    isToken0Rebase: false,
                    isToken1Rebase: false,
                    token0AbsErrorTolerance: 0,
                    token1AbsErrorTolerance: 0,
                    defaultSwapFeeBips: 0
                })
            )
        );

        thirdSovereignPool = SovereignPool(
            protocolFactory.deploySovereignPool(
                SovereignPoolConstructorArgs({
                    token0: address(token2),
                    token1: address(token3),
                    protocolFactory: address(0),
                    poolManager: address(this),
                    sovereignVault: address(0),
                    verifierModule: address(0),
                    isToken0Rebase: false,
                    isToken1Rebase: false,
                    token0AbsErrorTolerance: 0,
                    token1AbsErrorTolerance: 0,
                    defaultSwapFeeBips: 0
                })
            )
        );

        fourthSovereignPool = SovereignPool(
            protocolFactory.deploySovereignPool(
                SovereignPoolConstructorArgs({
                    token0: address(token3),
                    token1: address(weth),
                    protocolFactory: address(0),
                    poolManager: address(this),
                    sovereignVault: address(0),
                    verifierModule: address(0),
                    isToken0Rebase: false,
                    isToken1Rebase: false,
                    token0AbsErrorTolerance: 0,
                    token1AbsErrorTolerance: 0,
                    defaultSwapFeeBips: 0
                })
            )
        );

        // Sovereign Pool not whitelisted in ProtocolFactory
        invalidSovereignPool = SovereignPool(
            sovereignPoolFactory.deploy(
                bytes32(0),
                abi.encode(
                    SovereignPoolConstructorArgs({
                        token0: address(token0),
                        token1: address(token1),
                        protocolFactory: address(protocolFactory),
                        poolManager: address(this),
                        sovereignVault: address(0),
                        verifierModule: address(0),
                        isToken0Rebase: false,
                        isToken1Rebase: false,
                        token0AbsErrorTolerance: 0,
                        token1AbsErrorTolerance: 0,
                        defaultSwapFeeBips: 0
                    })
                )
            )
        );

        // Deploy Universal Pools
        firstUniversalPool =
            UniversalPool(protocolFactory.deployUniversalPool(address(token0), address(token1), address(this), 0));
        firstUniversalPool.initializeTick(0);

        secondUniversalPool =
            UniversalPool(protocolFactory.deployUniversalPool(address(token1), address(token2), address(this), 0));
        secondUniversalPool.initializeTick(0);

        thirdUniversalPool =
            UniversalPool(protocolFactory.deployUniversalPool(address(token2), address(token3), address(this), 0));
        thirdUniversalPool.initializeTick(0);

        fourthUniversalPool =
            UniversalPool(protocolFactory.deployUniversalPool(address(token3), address(weth), address(this), 0));
        fourthUniversalPool.initializeTick(0);

        invalidUniversalPool = UniversalPool(
            universalPoolFactory.deploy(
                bytes32(0), abi.encode(address(token0), address(token1), address(protocolFactory), address(this), 0)
            )
        );
        invalidUniversalPool.initializeTick(0);

        // Deploy Mock Sovereign ALMs
        firstSovereignALM = MockSovereignALM(
            protocolFactory.deployALMPositionForSovereignPool(
                address(firstSovereignPool), sovereignALMFactory, abi.encode(address(firstSovereignPool))
            )
        );
        firstSovereignPool.setALM(address(firstSovereignALM));
        firstSovereignALM.setSovereignVault();

        secondSovereignALM = MockSovereignALM(
            protocolFactory.deployALMPositionForSovereignPool(
                address(secondSovereignPool), sovereignALMFactory, abi.encode(address(secondSovereignPool))
            )
        );
        secondSovereignPool.setALM(address(secondSovereignALM));
        secondSovereignALM.setSovereignVault();

        thirdSovereignALM = MockSovereignALM(
            protocolFactory.deployALMPositionForSovereignPool(
                address(thirdSovereignPool), sovereignALMFactory, abi.encode(address(thirdSovereignPool))
            )
        );
        thirdSovereignPool.setALM(address(thirdSovereignALM));
        thirdSovereignALM.setSovereignVault();

        fourthSovereignALM = MockSovereignALM(
            protocolFactory.deployALMPositionForSovereignPool(
                address(fourthSovereignPool), sovereignALMFactory, abi.encode(address(fourthSovereignPool))
            )
        );
        fourthSovereignPool.setALM(address(fourthSovereignALM));
        fourthSovereignALM.setSovereignVault();

        // Deploy Mock Universal ALMs
        firstUniversalALM = MockUniversalALM(
            protocolFactory.deployALMPositionForUniversalPool(
                address(firstUniversalPool), universalALMFactory, abi.encode(address(firstUniversalPool), false)
            )
        );
        firstUniversalPool.addALMPosition(false, false, false, 0, address(firstUniversalALM));

        secondUniversalALM = MockUniversalALM(
            protocolFactory.deployALMPositionForUniversalPool(
                address(secondUniversalPool), universalALMFactory, abi.encode(address(secondUniversalPool), false)
            )
        );
        secondUniversalPool.addALMPosition(false, false, false, 0, address(secondUniversalALM));

        thirdUniversalALM = MockUniversalALM(
            protocolFactory.deployALMPositionForUniversalPool(
                address(thirdUniversalPool), universalALMFactory, abi.encode(address(thirdUniversalPool), false)
            )
        );
        thirdUniversalPool.addALMPosition(false, false, false, 0, address(thirdUniversalALM));

        fourthUniversalALM = MockUniversalALM(
            protocolFactory.deployALMPositionForUniversalPool(
                address(fourthUniversalPool), universalALMFactory, abi.encode(address(fourthUniversalPool), false)
            )
        );
        fourthUniversalPool.addALMPosition(false, false, false, 0, address(fourthUniversalALM));

        // Deploy swap router
        swapRouter = new ValantisSwapRouter(address(protocolFactory), address(weth), address(permit2));

        // Token approvals
        token0.approve(address(firstSovereignALM), TOKEN_SUPPLY);
        token0.approve(address(firstUniversalALM), TOKEN_SUPPLY);
        token0.approve(address(permit2), TOKEN_SUPPLY);

        token1.approve(address(firstSovereignALM), TOKEN_SUPPLY);
        token1.approve(address(firstUniversalALM), TOKEN_SUPPLY);
        token1.approve(address(secondSovereignALM), TOKEN_SUPPLY);
        token1.approve(address(secondUniversalALM), TOKEN_SUPPLY);
        token1.approve(address(permit2), TOKEN_SUPPLY);

        token2.approve(address(secondSovereignALM), TOKEN_SUPPLY);
        token2.approve(address(secondUniversalALM), TOKEN_SUPPLY);
        token2.approve(address(thirdSovereignALM), TOKEN_SUPPLY);
        token2.approve(address(thirdUniversalALM), TOKEN_SUPPLY);
        token1.approve(address(permit2), TOKEN_SUPPLY);

        token3.approve(address(thirdSovereignALM), TOKEN_SUPPLY);
        token3.approve(address(thirdUniversalALM), TOKEN_SUPPLY);
        token3.approve(address(fourthSovereignALM), TOKEN_SUPPLY);
        token3.approve(address(fourthUniversalALM), TOKEN_SUPPLY);
        token3.approve(address(permit2), TOKEN_SUPPLY);

        weth.approve(address(fourthSovereignALM), TOKEN_SUPPLY);
        weth.approve(address(fourthUniversalALM), TOKEN_SUPPLY);
        weth.approve(address(permit2), TOKEN_SUPPLY);

        // Permit2 approvals
        permit2.approve(address(token0), address(swapRouter), uint160(TOKEN_SUPPLY), uint48(block.timestamp + 1e8));
        permit2.approve(address(token1), address(swapRouter), uint160(TOKEN_SUPPLY), uint48(block.timestamp + 1e8));
        permit2.approve(address(token2), address(swapRouter), uint160(TOKEN_SUPPLY), uint48(block.timestamp + 1e8));
        permit2.approve(address(token3), address(swapRouter), uint160(TOKEN_SUPPLY), uint48(block.timestamp + 1e8));
        permit2.approve(address(weth), address(swapRouter), uint160(TOKEN_SUPPLY), uint48(block.timestamp + 1e8));

        // token transfers to owner + owner Permit2 approvals
        token0.transfer(_owner, 100e18);
        token1.transfer(_owner, 100e18);
        token2.transfer(_owner, 100e18);
        token3.transfer(_owner, 100e18);
        weth.deposit{value: 100e18}();
        weth.transfer(_owner, 100e18);

        vm.prank(_owner);
        token0.approve(address(permit2), 100e18);
        vm.prank(_owner);
        permit2.approve(address(token0), address(swapRouter), 100e18, uint48(block.timestamp + 1e8));
        vm.prank(_owner);
        token1.approve(address(permit2), 100e18);
        vm.prank(_owner);
        permit2.approve(address(token1), address(swapRouter), 100e18, uint48(block.timestamp + 1e8));
        vm.prank(_owner);
        token2.approve(address(permit2), 100e18);
        vm.prank(_owner);
        permit2.approve(address(token2), address(swapRouter), 100e18, uint48(block.timestamp + 1e8));
        vm.prank(_owner);
        token3.approve(address(permit2), 100e18);
        vm.prank(_owner);
        permit2.approve(address(token3), address(swapRouter), 100e18, uint48(block.timestamp + 1e8));
        vm.prank(_owner);
        weth.approve(address(permit2), 100e18);
        vm.prank(_owner);
        permit2.approve(address(weth), address(swapRouter), 100e18, uint48(block.timestamp + 1e8));

        (uint160 allowanceToken0,,) = permit2.allowance(_owner, address(token0), address(swapRouter));
        (uint160 allowanceToken1,,) = permit2.allowance(_owner, address(token1), address(swapRouter));
        (uint160 allowanceToken2,,) = permit2.allowance(_owner, address(token2), address(swapRouter));
        (uint160 allowanceToken3,,) = permit2.allowance(_owner, address(token3), address(swapRouter));
        (uint160 allowanceWeth,,) = permit2.allowance(_owner, address(weth), address(swapRouter));

        assertEq(allowanceToken0, 100e18);
        assertEq(allowanceToken1, 100e18);
        assertEq(allowanceToken2, 100e18);
        assertEq(allowanceToken3, 100e18);
        assertEq(allowanceWeth, 100e18);
    }

    receive() external payable {
        if (revertOnReceive) {
            revert SwapRouterTest__receive_revertOnReceive();
        }
    }

    function testDeploySwapRouter() public {
        ValantisSwapRouter swapRouterDeployment =
            new ValantisSwapRouter(address(protocolFactory), address(weth), address(permit2));

        assertEq(swapRouterDeployment.protocolFactory(), address(protocolFactory));
        assertEq(swapRouterDeployment.permit2(), address(permit2));
        assertEq(swapRouterDeployment.WETH9(), address(weth));
    }

    function testViewFunctions() public view {
        assertEq(swapRouter.permit2(), address(permit2));
        assertEq(swapRouter.protocolFactory(), address(protocolFactory));
        assertEq(swapRouter.isLocked(), false);
    }

    function testReceive() public {
        // Only WETH contract can directly send ETH to swapRouter
        vm.expectRevert(ValantisSwapRouter.ValantisSwapRouter__receive_onlyWeth.selector);
        (bool success,) = address(swapRouter).call{value: 1 ether}("");

        vm.prank(swapRouter.WETH9());

        (success, /* bytes memory data */ ) = address(swapRouter).call{value: 1 ether}("");
        assertTrue(success);
        assertEq(address(swapRouter).balance, 1 ether);
    }

    function testUniversalPoolSwapCallback() public {
        assertEq(swapRouter.allowedUniversalPool(), address(1));
        vm.expectRevert(ValantisSwapRouter.ValantisSwapRouter__universalPoolSwapCallback_poolNotAllowed.selector);
        swapRouter.universalPoolSwapCallback(address(token0), 1e18, abi.encode(address(token0), address(this)));

        vm.prank(address(1));
        vm.expectRevert(ValantisSwapRouter.ValantisSwapRouter__universalPoolSwapCallback_invalidTokenIn.selector);
        swapRouter.universalPoolSwapCallback(address(token0), 1e18, abi.encode(address(token1), address(this)));
    }

    function testSovereignPoolSwapCallback() public {
        assertEq(swapRouter.allowedSovereignPool(), address(1));
        vm.expectRevert(ValantisSwapRouter.ValantisSwapRouter__sovereignPoolSwapCallback_poolNotAllowed.selector);
        swapRouter.sovereignPoolSwapCallback(address(token0), 1e18, abi.encode(address(token0), address(this)));

        vm.prank(address(1));
        vm.expectRevert(ValantisSwapRouter.ValantisSwapRouter__sovereignPoolSwapCallback_invalidTokenIn.selector);
        swapRouter.sovereignPoolSwapCallback(address(token0), 1e18, abi.encode(address(token1), address(this)));
    }

    /**
     * @notice Test swap router over one Sovereign Pool.
     */
    function testSovereignPoolSwapSingle() public {
        _prepareSovereignPools();

        address tokenIn = address(token0);
        address tokenOut = address(token1);

        address recipient = MOCK_RECIPIENT;
        uint256 amountIn = 1e18;
        uint256 amountOutMin = 1e17;
        uint32 deadline = uint32(block.timestamp);

        bool[] memory isUniversalPool = new bool[](1);
        isUniversalPool[0] = false;

        address[] memory pools = new address[](1);
        pools[0] = address(firstSovereignPool);

        uint256[] memory amountInSpecified = new uint256[](1);
        amountInSpecified[0] = amountIn;

        bytes[] memory payloads = new bytes[](1);
        payloads[0] = abi.encode(
            SovereignPoolSwapPayload(true, recipient, address(token1), 0, new bytes(0), new bytes(0), new bytes(0))
        );

        DirectSwapParams memory swapParams = DirectSwapParams(
            isUniversalPool,
            pools,
            amountInSpecified,
            payloads,
            false,
            tokenIn,
            tokenOut,
            recipient,
            amountOutMin,
            deadline,
            EMPTY_CODE
        );

        token0.approve(address(swapRouter), amountIn);

        // Should revert if tokenOut amount is insufficient
        swapParams.amountOutMin = 100e18;
        vm.expectRevert(ValantisSwapRouter.ValantisSwapRouter__swap_insufficientAmountOut.selector);
        swapRouter.swap(swapParams);
        swapParams.amountOutMin = amountOutMin;

        // Should revert if deadline has expired
        swapParams.deadline = uint32(block.timestamp - 1);
        vm.expectRevert(DirectSwap.DirectSwap__checkDirectSwapParams_invalidDeadline.selector);
        swapRouter.swap(swapParams);
        swapParams.deadline = uint32(block.timestamp);

        // Should revert if isUniversalPool has zero length
        swapParams.isUniversalPool = new bool[](0);
        vm.expectRevert(DirectSwap.DirectSwap__checkDirectSwapParams_invalidArrayLength.selector);
        swapRouter.swap(swapParams);
        swapParams.isUniversalPool = isUniversalPool;

        // Should revert if any of the arrays has different length
        swapParams.pools = new address[](0);
        vm.expectRevert(DirectSwap.DirectSwap__checkDirectSwapParams_arrayLengthMismatch.selector);
        swapRouter.swap(swapParams);
        swapParams.pools = pools;

        // Should revert if tokenIn == tokenOut
        swapParams.tokenOut = swapParams.tokenIn;
        vm.expectRevert(DirectSwap.DirectSwap__checkDirectSwapParams_equalTokenInAndTokenOut.selector);
        swapRouter.swap(swapParams);
        swapParams.tokenOut = tokenOut;

        swapParams.amountInSpecified = new uint256[](0);
        vm.expectRevert(DirectSwap.DirectSwap__checkDirectSwapParams_arrayLengthMismatch.selector);
        swapRouter.swap(swapParams);
        swapParams.amountInSpecified = amountInSpecified;

        swapParams.payloads = new bytes[](2);
        vm.expectRevert(DirectSwap.DirectSwap__checkDirectSwapParams_arrayLengthMismatch.selector);
        swapRouter.swap(swapParams);
        swapParams.payloads = payloads;

        // Should revert if Sovereign pool is invalid (not whitelisted in ProtocolFactory)
        swapParams.pools[0] = address(invalidSovereignPool);
        vm.expectRevert(
            ValantisSwapRouter.ValantisSwapRouter___executeSingleSwapSovereignPool_invalidSovereignPool.selector
        );
        swapRouter.swap(swapParams);
        swapParams.pools[0] = address(firstSovereignPool);

        uint256 userPreBalance = token0.balanceOf(address(this));
        assertEq(token1.balanceOf(recipient), 0);
        uint256 amountOut = swapRouter.swap(swapParams);
        assert(amountOut >= amountOutMin);
        assertEq(token1.balanceOf(recipient), amountOut);
        assertEq(userPreBalance - token0.balanceOf(address(this)), amountIn);
    }

    /**
     * @notice Test swap router over one Sovereign Pool, starting from ETH.
     */
    function testSovereignPoolSwapSingleFromETH() public {
        _prepareSovereignPools();

        address tokenIn = address(weth);
        address tokenOut = address(token3);
        address recipient = MOCK_RECIPIENT;
        uint256 amountIn = 100e18;
        uint256 amountOutMin = 1e17;
        uint32 deadline = uint32(block.timestamp);

        bool[] memory isUniversalPool = new bool[](1);
        isUniversalPool[0] = false;

        address[] memory pools = new address[](1);
        pools[0] = address(fourthSovereignPool);

        uint256[] memory amountInSpecified = new uint256[](1);
        amountInSpecified[0] = amountIn;

        bytes[] memory payloads = new bytes[](1);
        payloads[0] = abi.encode(
            SovereignPoolSwapPayload(false, recipient, tokenOut, 0, new bytes(0), new bytes(0), new bytes(0))
        );

        DirectSwapParams memory swapParams = DirectSwapParams(
            isUniversalPool,
            pools,
            amountInSpecified,
            payloads,
            false,
            tokenIn,
            tokenOut,
            recipient,
            amountOutMin,
            deadline,
            EMPTY_CODE
        );

        // Should revert if swapParams.tokenIn is not WETH
        swapParams.tokenIn = address(1);
        vm.expectRevert(ValantisSwapRouter.ValantisSwapRouter__swap_invalidNativeTokenSwap.selector);
        swapRouter.swap{value: amountIn}(swapParams);
        swapParams.tokenIn = tokenIn;

        // Should revert if msg.value does not match total sum of amountInSpecified
        vm.expectRevert(DirectSwap.DirectSwap__checkDirectSwapParams_incorrectNativeTokenAmountIn.selector);
        swapRouter.swap{value: amountIn - 1}(swapParams);

        uint256 snapshot1 = vm.snapshot();
        uint256 snapshot2 = vm.snapshot();

        uint256 userPreBalance = address(this).balance;
        assertEq(token3.balanceOf(recipient), 0);
        uint256 amountOut = swapRouter.swap{value: amountIn}(swapParams);
        assertTrue(amountOut >= amountOutMin);
        assertEq(token3.balanceOf(recipient), amountOut);
        assertEq(userPreBalance - address(this).balance, amountIn);

        // Should revert if ETH refund call is not successful
        vm.revertTo(snapshot2);

        swapParams.recipient = address(this);
        swapParams.amountOutMin = 1;
        swapParams.payloads[0] = abi.encode(
            SovereignPoolSwapPayload(false, swapParams.recipient, tokenOut, 0, new bytes(0), new bytes(0), new bytes(0))
        );

        revertOnReceive = true;
        fourthSovereignALM.setQuotePartialFill(true);
        vm.expectRevert(ValantisSwapRouter.ValantisSwapRouter___sendNativeToken_ethTransferFailed.selector);
        amountOut = swapRouter.swap{value: amountIn}(swapParams);

        revertOnReceive = false;

        // Should refund left-over ETH to recipient in case of partial fill
        vm.revertTo(snapshot1);

        fourthSovereignALM.setQuotePartialFill(true);
        amountOut = swapRouter.swap{value: amountIn}(swapParams);
        assertTrue(amountOut >= amountOutMin);
        assertEq(address(swapRouter).balance, 0);
    }

    /**
     * @notice Test swap router over one Sovereign Pool, starting from WETH.
     */
    function testSovereignPoolSwapSingleFromWETH() public {
        _prepareSovereignPools();

        address tokenIn = address(weth);
        address tokenOut = address(token3);
        address recipient = MOCK_RECIPIENT;
        uint256 amountIn = 1e18;
        uint256 amountOutMin = 1e17;
        uint32 deadline = uint32(block.timestamp);

        bool[] memory isUniversalPool = new bool[](1);
        isUniversalPool[0] = false;

        address[] memory pools = new address[](1);
        pools[0] = address(fourthSovereignPool);

        uint256[] memory amountInSpecified = new uint256[](1);
        amountInSpecified[0] = amountIn;

        bytes[] memory payloads = new bytes[](1);
        payloads[0] = abi.encode(
            SovereignPoolSwapPayload(false, recipient, address(token3), 0, new bytes(0), new bytes(0), new bytes(0))
        );

        DirectSwapParams memory swapParams = DirectSwapParams(
            isUniversalPool,
            pools,
            amountInSpecified,
            payloads,
            false,
            tokenIn,
            tokenOut,
            recipient,
            amountOutMin,
            deadline,
            EMPTY_CODE
        );

        weth.deposit{value: amountIn}();
        assertEq(weth.balanceOf(address(this)), amountIn);

        weth.approve(address(swapRouter), amountIn);

        uint256 userPreBalance = weth.balanceOf(address(this));
        assertEq(token3.balanceOf(recipient), 0);
        uint256 amountOut = swapRouter.swap(swapParams);
        assert(amountOut >= amountOutMin);
        assertEq(token3.balanceOf(recipient), amountOut);
        assertEq(userPreBalance - weth.balanceOf(address(this)), amountIn);
    }

    /**
     * @notice Test swap router over one Sovereign Pool, ETH as output token.
     */
    function testSovereignPoolSwapSingleToETH() public {
        _prepareSovereignPools();

        address tokenIn = address(token3);
        address tokenOut = address(weth);
        address recipient = MOCK_RECIPIENT;
        uint256 amountIn = 1e18;
        uint256 amountOutMin = 1e17;
        uint32 deadline = uint32(block.timestamp);
        bool isTokenOutEth = true;

        bool[] memory isUniversalPool = new bool[](1);
        isUniversalPool[0] = false;

        address[] memory pools = new address[](1);
        pools[0] = address(fourthSovereignPool);

        uint256[] memory amountInSpecified = new uint256[](1);
        amountInSpecified[0] = amountIn;

        bytes[] memory payloads = new bytes[](1);
        payloads[0] = abi.encode(
            SovereignPoolSwapPayload(
                true,
                address(swapRouter), // WETH amount from swap first goes into swapRouter
                address(weth),
                amountOutMin,
                new bytes(0),
                new bytes(0),
                new bytes(0)
            )
        );

        DirectSwapParams memory swapParams = DirectSwapParams(
            isUniversalPool,
            pools,
            amountInSpecified,
            payloads,
            isTokenOutEth,
            tokenIn,
            tokenOut,
            recipient,
            amountOutMin,
            deadline,
            EMPTY_CODE
        );

        swapParams.tokenOut = tokenIn;
        // If recipient wants ETH, tokenOut must be specified as WETH
        vm.expectRevert(ValantisSwapRouter.ValantisSwapRouter__swap_tokenOutNotWeth.selector);
        swapRouter.swap(swapParams);

        swapParams.tokenOut = tokenOut;

        payloads[0] = abi.encode(
            SovereignPoolSwapPayload(
                true, recipient, address(weth), amountOutMin, new bytes(0), new bytes(0), new bytes(0)
            )
        );
        // WETH amount cannot go directly from pool to recipient
        vm.expectRevert(ValantisSwapRouter.ValantisSwapRouter__swap_insufficientAmountOut.selector);
        swapRouter.swap(swapParams);

        payloads[0] = abi.encode(
            SovereignPoolSwapPayload(
                true, address(swapRouter), address(weth), amountOutMin, new bytes(0), new bytes(0), new bytes(0)
            )
        );

        uint256 amountOut = swapRouter.swap(swapParams);
        assert(amountOut >= amountOutMin);
        assertEq(recipient.balance, amountOut);
    }

    /**
     * @notice Test swap router over multiple Sovereign pools.
     */
    function testSovereignPoolMultiSwap() public {
        _prepareSovereignPools();

        address tokenIn = address(token0);
        address tokenOut = address(token3);
        address recipient = MOCK_RECIPIENT;
        uint256 amountIn = 1e18;
        uint256 amountOutMin = 1e17;
        uint32 deadline = uint32(block.timestamp);

        bool[] memory isUniversalPool = new bool[](3);
        isUniversalPool[0] = false;
        isUniversalPool[1] = false;
        isUniversalPool[2] = false;

        address[] memory pools = new address[](3);
        pools[0] = address(firstSovereignPool);
        pools[1] = address(secondSovereignPool);
        pools[2] = address(thirdSovereignPool);

        uint256[] memory amountInSpecified = new uint256[](3);
        amountInSpecified[0] = amountIn;

        bytes[] memory payloads = new bytes[](3);
        payloads[0] = abi.encode(
            SovereignPoolSwapPayload(
                true, address(swapRouter), address(token1), 0, new bytes(0), new bytes(0), new bytes(0)
            )
        );
        payloads[1] = abi.encode(
            SovereignPoolSwapPayload(
                true, address(swapRouter), address(token2), 0, new bytes(0), new bytes(0), new bytes(0)
            )
        );
        payloads[2] = abi.encode(
            SovereignPoolSwapPayload(true, recipient, address(token3), 0, new bytes(0), new bytes(0), new bytes(0))
        );

        DirectSwapParams memory swapParams = DirectSwapParams(
            isUniversalPool,
            pools,
            amountInSpecified,
            payloads,
            false,
            tokenIn,
            tokenOut,
            recipient,
            amountOutMin,
            deadline,
            EMPTY_CODE
        );

        token0.approve(address(swapRouter), amountIn);

        // Should revert if amountIn of first swap is 0
        swapParams.amountInSpecified[0] = 0;
        vm.expectRevert(ValantisSwapRouter.ValantisSwapRouter___executeSwaps_invalidAmountSpecifiedFirstSwap.selector);
        swapRouter.swap(swapParams);
        swapParams.amountInSpecified[0] = amountIn;

        uint256 userPreBalance = token0.balanceOf(address(this));
        assertEq(token3.balanceOf(recipient), 0);
        uint256 amountOut = swapRouter.swap(swapParams);
        assertTrue(amountOut >= amountOutMin);
        assertEq(token3.balanceOf(recipient), amountOut);
        assertEq(userPreBalance - token0.balanceOf(address(this)), amountIn);
    }

    /**
     * @notice Test swap router over multiple Sovereign pools, starting from ETH.
     */
    function testSovereignPoolMultiSwapFromETH() public {
        _prepareSovereignPools();

        address tokenIn = address(weth);
        address tokenOut = address(token0);
        address recipient = MOCK_RECIPIENT;
        uint256 amountIn = 1e18;
        uint256 amountOutMin = 1e17;
        uint32 deadline = uint32(block.timestamp);

        bool[] memory isUniversalPool = new bool[](4);
        isUniversalPool[0] = false;
        isUniversalPool[1] = false;
        isUniversalPool[2] = false;
        isUniversalPool[3] = false;

        address[] memory pools = new address[](4);
        pools[0] = address(fourthSovereignPool);
        pools[1] = address(thirdSovereignPool);
        pools[2] = address(secondSovereignPool);
        pools[3] = address(firstSovereignPool);

        uint256[] memory amountInSpecified = new uint256[](4);
        amountInSpecified[0] = amountIn;

        bytes[] memory payloads = new bytes[](4);
        payloads[0] = abi.encode(
            SovereignPoolSwapPayload(
                false, address(swapRouter), address(token3), 0, new bytes(0), new bytes(0), new bytes(0)
            )
        );
        payloads[1] = abi.encode(
            SovereignPoolSwapPayload(
                false, address(swapRouter), address(token2), 0, new bytes(0), new bytes(0), new bytes(0)
            )
        );
        payloads[2] = abi.encode(
            SovereignPoolSwapPayload(
                false, address(swapRouter), address(token1), 0, new bytes(0), new bytes(0), new bytes(0)
            )
        );
        payloads[3] = abi.encode(
            SovereignPoolSwapPayload(false, recipient, address(token0), 0, new bytes(0), new bytes(0), new bytes(0))
        );

        DirectSwapParams memory swapParams = DirectSwapParams(
            isUniversalPool,
            pools,
            amountInSpecified,
            payloads,
            false,
            tokenIn,
            tokenOut,
            recipient,
            amountOutMin,
            deadline,
            EMPTY_CODE
        );

        uint256 userPreBalance = address(this).balance;
        assertEq(token0.balanceOf(recipient), 0);
        uint256 amountOut = swapRouter.swap{value: amountIn}(swapParams);
        assert(amountOut >= amountOutMin);
        assertEq(token0.balanceOf(recipient), amountOut);
        assertEq(userPreBalance - address(this).balance, amountIn);
    }

    /**
     * @notice Test swap router over multiple Sovereign pools, starting from WETH.
     */
    function testSovereignPoolMultiSwapFromWETH() public {
        _prepareSovereignPools();

        address tokenIn = address(weth);
        address tokenOut = address(token0);
        address recipient = MOCK_RECIPIENT;
        uint256 amountIn = 1e18;
        uint256 amountOutMin = 1e17;
        uint32 deadline = uint32(block.timestamp);

        bool[] memory isUniversalPool = new bool[](4);
        isUniversalPool[0] = false;
        isUniversalPool[1] = false;
        isUniversalPool[2] = false;
        isUniversalPool[3] = false;

        address[] memory pools = new address[](4);
        pools[0] = address(fourthSovereignPool);
        pools[1] = address(thirdSovereignPool);
        pools[2] = address(secondSovereignPool);
        pools[3] = address(firstSovereignPool);

        uint256[] memory amountInSpecified = new uint256[](4);
        amountInSpecified[0] = amountIn;

        bytes[] memory payloads = new bytes[](4);
        payloads[0] = abi.encode(
            SovereignPoolSwapPayload(
                false, address(swapRouter), address(token3), 0, new bytes(0), new bytes(0), new bytes(0)
            )
        );
        payloads[1] = abi.encode(
            SovereignPoolSwapPayload(
                false, address(swapRouter), address(token2), 0, new bytes(0), new bytes(0), new bytes(0)
            )
        );
        payloads[2] = abi.encode(
            SovereignPoolSwapPayload(
                false, address(swapRouter), address(token1), 0, new bytes(0), new bytes(0), new bytes(0)
            )
        );
        payloads[3] = abi.encode(
            SovereignPoolSwapPayload(false, recipient, address(token0), 0, new bytes(0), new bytes(0), new bytes(0))
        );

        DirectSwapParams memory swapParams = DirectSwapParams(
            isUniversalPool,
            pools,
            amountInSpecified,
            payloads,
            false,
            tokenIn,
            tokenOut,
            recipient,
            amountOutMin,
            deadline,
            EMPTY_CODE
        );

        weth.deposit{value: amountIn}();
        assertEq(weth.balanceOf(address(this)), amountIn);

        weth.approve(address(swapRouter), amountIn);

        uint256 userPreBalance = weth.balanceOf(address(this));
        assertEq(token0.balanceOf(recipient), 0);
        uint256 amountOut = swapRouter.swap(swapParams);
        assert(amountOut >= amountOutMin);
        assertEq(token0.balanceOf(recipient), amountOut);
        assertEq(userPreBalance - weth.balanceOf(address(this)), amountIn);
    }

    /**
     * @notice Test swap router over a single Universal Pool.
     */
    function testUniversalPoolSwapSingle() public {
        bool isZeroToOne = true;

        _prepareUniversalPools(isZeroToOne);

        address tokenIn = address(token0);
        address tokenOut = address(token1);
        address recipient = MOCK_RECIPIENT;
        uint256 amountIn = 1e18;
        uint256 amountOutMin = 1e17;
        uint32 deadline = uint32(block.timestamp);

        bool[] memory isUniversalPool = new bool[](1);
        isUniversalPool[0] = true;

        address[] memory pools = new address[](1);
        pools[0] = address(firstUniversalPool);

        uint256[] memory amountInSpecified = new uint256[](1);
        amountInSpecified[0] = amountIn;

        bytes[] memory payloads = new bytes[](1);
        payloads[0] = abi.encode(
            UniversalPoolSwapPayload(
                isZeroToOne,
                recipient,
                isZeroToOne ? PriceTickMath.MIN_PRICE_TICK : PriceTickMath.MAX_PRICE_TICK,
                0,
                new uint8[](1),
                _getUniversalPoolDefaultSwapData(isZeroToOne, amountIn),
                new bytes(0)
            )
        );

        DirectSwapParams memory swapParams = DirectSwapParams(
            isUniversalPool,
            pools,
            amountInSpecified,
            payloads,
            false,
            tokenIn,
            tokenOut,
            recipient,
            amountOutMin,
            deadline,
            EMPTY_CODE
        );

        token0.approve(address(swapRouter), amountIn);

        uint256 userPreBalance = token0.balanceOf(address(this));
        assertEq(token1.balanceOf(recipient), 0);

        // Should revert if Universal pool is invalid (not whitelisted in ProtocolFactory)
        swapParams.pools[0] = address(invalidUniversalPool);
        vm.expectRevert(
            ValantisSwapRouter.ValantisSwapRouter___executeSingleSwapUniversalPool_invalidUniversalPool.selector
        );
        swapRouter.swap(swapParams);
        swapParams.pools[0] = address(firstUniversalPool);

        uint256 amountOut = swapRouter.swap(swapParams);
        assert(amountOut >= amountOutMin);
        assertEq(token1.balanceOf(recipient), amountOut);
        assertEq(userPreBalance - token0.balanceOf(address(this)), amountIn);
    }

    /**
     * @notice Test swap router over multiple Universal pools.
     */
    function testUniversalPoolMultiSwap() public {
        bool isZeroToOne = true;

        _prepareUniversalPools(isZeroToOne);

        address tokenIn = address(token0);
        address tokenOut = address(token3);
        address recipient = MOCK_RECIPIENT;
        uint256 amountIn = 1e18;
        uint256 amountOutMin = 1e17;
        uint32 deadline = uint32(block.timestamp);

        bool[] memory isUniversalPool = new bool[](3);
        isUniversalPool[0] = true;
        isUniversalPool[1] = true;
        isUniversalPool[2] = true;

        address[] memory pools = new address[](3);
        pools[0] = address(firstUniversalPool);
        pools[1] = address(secondUniversalPool);
        pools[2] = address(thirdUniversalPool);

        uint256[] memory amountInSpecified = new uint256[](3);
        amountInSpecified[0] = amountIn;

        bytes[] memory payloads = new bytes[](3);
        payloads[0] = abi.encode(
            UniversalPoolSwapPayload(
                isZeroToOne,
                address(swapRouter),
                isZeroToOne ? PriceTickMath.MIN_PRICE_TICK : PriceTickMath.MAX_PRICE_TICK,
                0,
                new uint8[](1),
                _getUniversalPoolDefaultSwapData(isZeroToOne, amountIn),
                new bytes(0)
            )
        );
        payloads[1] = abi.encode(
            UniversalPoolSwapPayload(
                isZeroToOne,
                address(swapRouter),
                isZeroToOne ? PriceTickMath.MIN_PRICE_TICK : PriceTickMath.MAX_PRICE_TICK,
                0,
                new uint8[](1),
                _getUniversalPoolDefaultSwapData(isZeroToOne, amountIn),
                new bytes(0)
            )
        );
        payloads[2] = abi.encode(
            UniversalPoolSwapPayload(
                isZeroToOne,
                recipient,
                isZeroToOne ? PriceTickMath.MIN_PRICE_TICK : PriceTickMath.MAX_PRICE_TICK,
                0,
                new uint8[](1),
                _getUniversalPoolDefaultSwapData(isZeroToOne, amountIn),
                new bytes(0)
            )
        );

        DirectSwapParams memory swapParams = DirectSwapParams(
            isUniversalPool,
            pools,
            amountInSpecified,
            payloads,
            false,
            tokenIn,
            tokenOut,
            recipient,
            amountOutMin,
            deadline,
            EMPTY_CODE
        );

        // Should revert if amountIn of first swap is 0
        swapParams.amountInSpecified[0] = 0;
        vm.expectRevert(ValantisSwapRouter.ValantisSwapRouter___executeSwaps_invalidAmountSpecifiedFirstSwap.selector);
        swapRouter.swap(swapParams);
        swapParams.amountInSpecified[0] = amountIn;

        uint256 userPreBalance = token0.balanceOf(address(this));
        assertEq(token3.balanceOf(recipient), 0);
        uint256 amountOut = swapRouter.swap(swapParams);
        assert(amountOut >= amountOutMin);
        assertEq(token3.balanceOf(recipient), amountOut);
        assertEq(userPreBalance - token0.balanceOf(address(this)), amountIn);
    }

    /**
     * @notice Test swap router over multiple Universal pools, starting from ETH.
     */
    function testUniversalPoolMultiSwapFromETH() public {
        bool isZeroToOne = false;

        _prepareUniversalPools(isZeroToOne);

        address tokenIn = address(weth);
        address tokenOut = address(token0);
        address recipient = MOCK_RECIPIENT;
        uint256 amountIn = 1e18;
        uint256 amountOutMin = 1e17;
        uint32 deadline = uint32(block.timestamp);

        bool[] memory isUniversalPool = new bool[](4);
        isUniversalPool[0] = true;
        isUniversalPool[1] = true;
        isUniversalPool[2] = true;
        isUniversalPool[3] = true;

        address[] memory pools = new address[](4);
        pools[0] = address(fourthUniversalPool);
        pools[1] = address(thirdUniversalPool);
        pools[2] = address(secondUniversalPool);
        pools[3] = address(firstUniversalPool);

        uint256[] memory amountInSpecified = new uint256[](4);
        amountInSpecified[0] = amountIn;

        bytes[] memory payloads = new bytes[](4);
        payloads[0] = abi.encode(
            UniversalPoolSwapPayload(
                isZeroToOne,
                address(swapRouter),
                isZeroToOne ? PriceTickMath.MIN_PRICE_TICK : PriceTickMath.MAX_PRICE_TICK,
                0,
                new uint8[](1),
                _getUniversalPoolDefaultSwapData(isZeroToOne, amountIn),
                new bytes(0)
            )
        );
        payloads[1] = abi.encode(
            UniversalPoolSwapPayload(
                isZeroToOne,
                address(swapRouter),
                isZeroToOne ? PriceTickMath.MIN_PRICE_TICK : PriceTickMath.MAX_PRICE_TICK,
                0,
                new uint8[](1),
                _getUniversalPoolDefaultSwapData(isZeroToOne, amountIn),
                new bytes(0)
            )
        );
        payloads[2] = abi.encode(
            UniversalPoolSwapPayload(
                isZeroToOne,
                address(swapRouter),
                isZeroToOne ? PriceTickMath.MIN_PRICE_TICK : PriceTickMath.MAX_PRICE_TICK,
                0,
                new uint8[](1),
                _getUniversalPoolDefaultSwapData(isZeroToOne, amountIn),
                new bytes(0)
            )
        );
        payloads[3] = abi.encode(
            UniversalPoolSwapPayload(
                isZeroToOne,
                recipient,
                isZeroToOne ? PriceTickMath.MIN_PRICE_TICK : PriceTickMath.MAX_PRICE_TICK,
                0,
                new uint8[](1),
                _getUniversalPoolDefaultSwapData(isZeroToOne, amountIn),
                new bytes(0)
            )
        );

        DirectSwapParams memory swapParams = DirectSwapParams(
            isUniversalPool,
            pools,
            amountInSpecified,
            payloads,
            false,
            tokenIn,
            tokenOut,
            recipient,
            amountOutMin,
            deadline,
            EMPTY_CODE
        );

        uint256 userPreBalance = address(this).balance;
        assertEq(token0.balanceOf(recipient), 0);
        uint256 amountOut = swapRouter.swap{value: amountIn}(swapParams);
        assert(amountOut >= amountOutMin);
        assertEq(token0.balanceOf(recipient), amountOut);
        assertEq(userPreBalance - address(this).balance, amountIn);
    }

    /**
     * @notice Test swap router over multiple Universal pools, starting from WETH.
     */
    function testUniversalPoolMultiSwapFromWETH() public {
        bool isZeroToOne = false;

        _prepareUniversalPools(isZeroToOne);

        address tokenIn = address(weth);
        address tokenOut = address(token0);
        address recipient = MOCK_RECIPIENT;
        uint256 amountIn = 1e18;
        uint256 amountOutMin = 1e17;
        uint32 deadline = uint32(block.timestamp);

        bool[] memory isUniversalPool = new bool[](4);
        isUniversalPool[0] = true;
        isUniversalPool[1] = true;
        isUniversalPool[2] = true;
        isUniversalPool[3] = true;

        address[] memory pools = new address[](4);
        pools[0] = address(fourthUniversalPool);
        pools[1] = address(thirdUniversalPool);
        pools[2] = address(secondUniversalPool);
        pools[3] = address(firstUniversalPool);

        uint256[] memory amountInSpecified = new uint256[](4);
        amountInSpecified[0] = amountIn;

        bytes[] memory payloads = new bytes[](4);
        payloads[0] = abi.encode(
            UniversalPoolSwapPayload(
                isZeroToOne,
                address(swapRouter),
                isZeroToOne ? PriceTickMath.MIN_PRICE_TICK : PriceTickMath.MAX_PRICE_TICK,
                0,
                new uint8[](1),
                _getUniversalPoolDefaultSwapData(isZeroToOne, amountIn),
                new bytes(0)
            )
        );
        payloads[1] = abi.encode(
            UniversalPoolSwapPayload(
                isZeroToOne,
                address(swapRouter),
                isZeroToOne ? PriceTickMath.MIN_PRICE_TICK : PriceTickMath.MAX_PRICE_TICK,
                0,
                new uint8[](1),
                _getUniversalPoolDefaultSwapData(isZeroToOne, amountIn),
                new bytes(0)
            )
        );
        payloads[2] = abi.encode(
            UniversalPoolSwapPayload(
                isZeroToOne,
                address(swapRouter),
                isZeroToOne ? PriceTickMath.MIN_PRICE_TICK : PriceTickMath.MAX_PRICE_TICK,
                0,
                new uint8[](1),
                _getUniversalPoolDefaultSwapData(isZeroToOne, amountIn),
                new bytes(0)
            )
        );
        payloads[3] = abi.encode(
            UniversalPoolSwapPayload(
                isZeroToOne,
                recipient,
                isZeroToOne ? PriceTickMath.MIN_PRICE_TICK : PriceTickMath.MAX_PRICE_TICK,
                0,
                new uint8[](1),
                _getUniversalPoolDefaultSwapData(isZeroToOne, amountIn),
                new bytes(0)
            )
        );

        DirectSwapParams memory swapParams = DirectSwapParams(
            isUniversalPool,
            pools,
            amountInSpecified,
            payloads,
            false,
            tokenIn,
            tokenOut,
            recipient,
            amountOutMin,
            deadline,
            EMPTY_CODE
        );

        weth.deposit{value: amountIn}();
        assertEq(weth.balanceOf(address(this)), amountIn);

        weth.approve(address(swapRouter), amountIn);

        uint256 userPreBalance = weth.balanceOf(address(this));
        assertEq(token0.balanceOf(recipient), 0);
        uint256 amountOut = swapRouter.swap(swapParams);
        assert(amountOut >= amountOutMin);
        assertEq(token0.balanceOf(recipient), amountOut);
        assertEq(userPreBalance - weth.balanceOf(address(this)), amountIn);
    }

    /**
     * @notice Test swap router over both Universal and Sovereign pools for the same pairs.
     */
    function testUniversalAndSovereignPoolMultiSwap() public {
        bool isZeroToOne = true;

        _prepareUniversalPools(isZeroToOne);
        _prepareSovereignPools();

        address tokenIn = address(token0);
        address tokenOut = address(token3);
        address recipient = MOCK_RECIPIENT;
        uint256 amountIn = 1e18;
        uint256 amountOutMin = 1e17;
        uint32 deadline = uint32(block.timestamp);

        bool[] memory isUniversalPool = new bool[](6);
        isUniversalPool[0] = true;
        isUniversalPool[1] = true;
        isUniversalPool[2] = true;

        address[] memory pools = new address[](6);
        pools[0] = address(firstUniversalPool);
        pools[1] = address(secondUniversalPool);
        pools[2] = address(thirdUniversalPool);
        pools[3] = address(firstSovereignPool);
        pools[4] = address(secondSovereignPool);
        pools[5] = address(thirdSovereignPool);

        uint256[] memory amountInSpecified = new uint256[](6);
        amountInSpecified[0] = amountIn / 2;
        amountInSpecified[3] = amountIn - amountInSpecified[0];

        bytes[] memory payloads = new bytes[](6);
        payloads[0] = abi.encode(
            UniversalPoolSwapPayload(
                isZeroToOne,
                address(swapRouter),
                isZeroToOne ? PriceTickMath.MIN_PRICE_TICK : PriceTickMath.MAX_PRICE_TICK,
                0,
                new uint8[](1),
                _getUniversalPoolDefaultSwapData(isZeroToOne, amountInSpecified[0]),
                new bytes(0)
            )
        );
        payloads[1] = abi.encode(
            UniversalPoolSwapPayload(
                isZeroToOne,
                address(swapRouter),
                isZeroToOne ? PriceTickMath.MIN_PRICE_TICK : PriceTickMath.MAX_PRICE_TICK,
                0,
                new uint8[](1),
                _getUniversalPoolDefaultSwapData(isZeroToOne, amountInSpecified[0]),
                new bytes(0)
            )
        );
        payloads[2] = abi.encode(
            UniversalPoolSwapPayload(
                isZeroToOne,
                recipient,
                isZeroToOne ? PriceTickMath.MIN_PRICE_TICK : PriceTickMath.MAX_PRICE_TICK,
                0,
                new uint8[](1),
                _getUniversalPoolDefaultSwapData(isZeroToOne, amountInSpecified[0]),
                new bytes(0)
            )
        );
        payloads[3] = abi.encode(
            SovereignPoolSwapPayload(
                isZeroToOne, address(swapRouter), address(token1), 0, new bytes(0), new bytes(0), new bytes(0)
            )
        );
        payloads[4] = abi.encode(
            SovereignPoolSwapPayload(
                isZeroToOne, address(swapRouter), address(token2), 0, new bytes(0), new bytes(0), new bytes(0)
            )
        );
        payloads[5] = abi.encode(
            SovereignPoolSwapPayload(
                isZeroToOne, recipient, address(token3), 0, new bytes(0), new bytes(0), new bytes(0)
            )
        );

        DirectSwapParams memory swapParams = DirectSwapParams(
            isUniversalPool,
            pools,
            amountInSpecified,
            payloads,
            false,
            tokenIn,
            tokenOut,
            recipient,
            amountOutMin,
            deadline,
            EMPTY_CODE
        );

        token0.approve(address(swapRouter), amountIn);

        uint256 amountOut;
        {
            uint256 snapshot = vm.snapshot();
            amountOut = swapRouter.swap(swapParams);
            vm.revertTo(snapshot);
        }

        {
            uint256 userPreBalance = token0.balanceOf(address(this));
            assertEq(token3.balanceOf(recipient), 0);

            vm.expectEmit(false, false, false, true);
            emit DirectSwapLog(
                address(this), recipient, tokenIn, tokenOut, amountIn, amountOut, false, false, EMPTY_CODE
            );
            amountOut = swapRouter.swap(swapParams);
            assert(amountOut >= amountOutMin);
            assertEq(token3.balanceOf(recipient), amountOut);
            assertEq(userPreBalance - token0.balanceOf(address(this)), amountIn);
        }
    }

    /**
     * @notice Test gasless swap over multiple Universal and Sovereign pools.
     */
    function testGaslessSwapUniversalAndSovereignPoolMultiSwap() public {
        bool isZeroToOne = true;

        _prepareUniversalPools(isZeroToOne);
        _prepareSovereignPools();

        address recipient = MOCK_RECIPIENT;
        uint256 amountIn = 1e18;
        uint256 amountOutMin = 1e17;

        bool[] memory isUniversalPool = new bool[](6);
        isUniversalPool[0] = true;
        isUniversalPool[1] = true;
        isUniversalPool[2] = true;

        address[] memory pools = new address[](6);
        pools[0] = address(firstUniversalPool);
        pools[1] = address(secondUniversalPool);
        pools[2] = address(thirdUniversalPool);
        pools[3] = address(firstSovereignPool);
        pools[4] = address(secondSovereignPool);
        pools[5] = address(thirdSovereignPool);

        uint256[] memory amountInSpecified = new uint256[](6);
        amountInSpecified[0] = amountIn / 2;
        amountInSpecified[3] = amountIn - amountInSpecified[0];

        bytes[] memory payloads = new bytes[](6);
        payloads[0] = abi.encode(
            UniversalPoolSwapPayload(
                isZeroToOne,
                address(swapRouter),
                isZeroToOne ? PriceTickMath.MIN_PRICE_TICK : PriceTickMath.MAX_PRICE_TICK,
                0,
                new uint8[](1),
                _getUniversalPoolDefaultSwapData(isZeroToOne, amountInSpecified[0]),
                new bytes(0)
            )
        );
        payloads[1] = abi.encode(
            UniversalPoolSwapPayload(
                isZeroToOne,
                address(swapRouter),
                isZeroToOne ? PriceTickMath.MIN_PRICE_TICK : PriceTickMath.MAX_PRICE_TICK,
                0,
                new uint8[](1),
                _getUniversalPoolDefaultSwapData(isZeroToOne, amountInSpecified[0]),
                new bytes(0)
            )
        );
        payloads[2] = abi.encode(
            UniversalPoolSwapPayload(
                isZeroToOne,
                recipient,
                isZeroToOne ? PriceTickMath.MIN_PRICE_TICK : PriceTickMath.MAX_PRICE_TICK,
                0,
                new uint8[](1),
                _getUniversalPoolDefaultSwapData(isZeroToOne, amountInSpecified[0]),
                new bytes(0)
            )
        );
        payloads[3] = abi.encode(
            SovereignPoolSwapPayload(
                isZeroToOne, address(swapRouter), address(token1), 0, new bytes(0), new bytes(0), new bytes(0)
            )
        );
        payloads[4] = abi.encode(
            SovereignPoolSwapPayload(
                isZeroToOne, address(swapRouter), address(token2), 0, new bytes(0), new bytes(0), new bytes(0)
            )
        );
        payloads[5] = abi.encode(
            SovereignPoolSwapPayload(
                isZeroToOne, recipient, address(token3), 0, new bytes(0), new bytes(0), new bytes(0)
            )
        );

        // Should revert on insufficient tokenOut amount received
        GaslessSwapIntent memory gaslessSwapIntent = GaslessSwapIntent(
            false,
            address(token0),
            address(token3),
            _owner,
            recipient,
            address(this),
            address(token0),
            amountIn,
            100e18,
            1e15,
            0,
            block.timestamp
        );

        (bytes memory ownerSignature,) = _getIntentsSignatureAndHash(_ownerPrivateKey, gaslessSwapIntent);

        GaslessSwapParams memory swapParams =
            GaslessSwapParams(isUniversalPool, pools, amountInSpecified, payloads, gaslessSwapIntent, EMPTY_CODE);

        vm.expectRevert(ValantisSwapRouter.ValantisSwapRouter___gaslessSwap_insufficientAmountOut.selector);
        swapRouter.gaslessSwap(swapParams, ownerSignature, gaslessSwapIntent.maxFee);

        // Should revert if chain id changes after signing
        uint256 chainId = block.chainid;

        gaslessSwapIntent = GaslessSwapIntent(
            false,
            address(token0),
            address(token3),
            _owner,
            recipient,
            address(this),
            address(token0),
            amountIn,
            amountOutMin,
            1e15,
            0,
            block.timestamp
        );

        (ownerSignature,) = _getIntentsSignatureAndHash(_ownerPrivateKey, gaslessSwapIntent);

        swapParams =
            GaslessSwapParams(isUniversalPool, pools, amountInSpecified, payloads, gaslessSwapIntent, EMPTY_CODE);

        vm.chainId(123);

        vm.expectRevert(SignatureVerification.InvalidSigner.selector);
        swapRouter.gaslessSwap(swapParams, ownerSignature, gaslessSwapIntent.maxFee);

        vm.chainId(chainId);

        uint256 amountOut;
        {
            uint256 snapshot = vm.snapshot();
            amountOut = swapRouter.gaslessSwap(swapParams, ownerSignature, gaslessSwapIntent.maxFee);
            vm.revertTo(snapshot);
        }

        {
            uint256 senderPreBalance = token0.balanceOf(address(this));
            assertEq(token3.balanceOf(recipient), 0);
            vm.expectEmit(false, false, false, true);
            emit GaslessSwapLog(
                swapParams.intent.owner,
                address(this),
                swapParams.intent.recipient,
                swapParams.intent.tokenIn,
                swapParams.intent.tokenOut,
                swapParams.intent.amountIn,
                amountOut,
                false,
                EMPTY_CODE
            );
            amountOut = swapRouter.gaslessSwap(swapParams, ownerSignature, gaslessSwapIntent.maxFee);
            assertEq(token3.balanceOf(recipient), amountOut);
            assertEq(token0.balanceOf(address(this)) - senderPreBalance, 1e15);
        }
    }

    /**
     * @notice Test gasless swap over multiple Universal and Sovereign pools, into ETH.
     */
    function testGaslessSwapUniversalAndSovereignPoolMultiSwapIntoETH() public {
        bool isZeroToOne = true;

        _prepareUniversalPools(isZeroToOne);
        _prepareSovereignPools();

        address recipient = MOCK_RECIPIENT;
        uint256 amountIn = 1e18;
        uint256 amountOutMin = 1e16;
        bool isEthTokenOut = true;

        bool[] memory isUniversalPool = new bool[](6);
        isUniversalPool[0] = true;
        isUniversalPool[1] = true;
        isUniversalPool[2] = true;

        address[] memory pools = new address[](6);
        pools[0] = address(secondUniversalPool);
        pools[1] = address(thirdUniversalPool);
        pools[2] = address(fourthUniversalPool);
        pools[3] = address(secondSovereignPool);
        pools[4] = address(thirdSovereignPool);
        pools[5] = address(fourthSovereignPool);

        uint256[] memory amountInSpecified = new uint256[](6);
        amountInSpecified[0] = amountIn / 2;
        amountInSpecified[3] = amountIn - amountInSpecified[0];

        bytes[] memory payloads = new bytes[](6);
        payloads[0] = abi.encode(
            UniversalPoolSwapPayload(
                isZeroToOne,
                address(swapRouter),
                isZeroToOne ? PriceTickMath.MIN_PRICE_TICK : PriceTickMath.MAX_PRICE_TICK,
                0,
                new uint8[](1),
                _getUniversalPoolDefaultSwapData(isZeroToOne, amountInSpecified[0]),
                new bytes(0)
            )
        );
        payloads[1] = abi.encode(
            UniversalPoolSwapPayload(
                isZeroToOne,
                address(swapRouter),
                isZeroToOne ? PriceTickMath.MIN_PRICE_TICK : PriceTickMath.MAX_PRICE_TICK,
                0,
                new uint8[](1),
                _getUniversalPoolDefaultSwapData(isZeroToOne, amountInSpecified[0]),
                new bytes(0)
            )
        );
        payloads[2] = abi.encode(
            UniversalPoolSwapPayload(
                isZeroToOne,
                address(swapRouter), // tokenOut is ETH, hence swapRouter must receive WETH to unwrap
                isZeroToOne ? PriceTickMath.MIN_PRICE_TICK : PriceTickMath.MAX_PRICE_TICK,
                0,
                new uint8[](1),
                _getUniversalPoolDefaultSwapData(isZeroToOne, amountInSpecified[0]),
                new bytes(0)
            )
        );
        payloads[3] = abi.encode(
            SovereignPoolSwapPayload(
                isZeroToOne, address(swapRouter), address(token2), 0, new bytes(0), new bytes(0), new bytes(0)
            )
        );
        payloads[4] = abi.encode(
            SovereignPoolSwapPayload(
                isZeroToOne, address(swapRouter), address(token3), 0, new bytes(0), new bytes(0), new bytes(0)
            )
        );
        payloads[5] = abi.encode(
            SovereignPoolSwapPayload(
                isZeroToOne,
                address(swapRouter), // tokenOut is ETH, hence swapRouter must receive WETH to unwrap
                address(weth),
                0,
                new bytes(0),
                new bytes(0),
                new bytes(0)
            )
        );

        // Should revert on insufficient tokenOut amount received
        GaslessSwapIntent memory gaslessSwapIntent = GaslessSwapIntent(
            isEthTokenOut,
            address(token1),
            address(weth),
            _owner,
            recipient,
            address(this),
            address(token0),
            amountIn,
            amountOutMin,
            1e15,
            0,
            block.timestamp
        );

        (bytes memory ownerSignature,) = _getIntentsSignatureAndHash(_ownerPrivateKey, gaslessSwapIntent);

        GaslessSwapParams memory swapParams =
            GaslessSwapParams(isUniversalPool, pools, amountInSpecified, payloads, gaslessSwapIntent, EMPTY_CODE);

        swapParams.intent.tokenOut = address(token2);
        // Should revert if tokenOut is not WETH
        vm.expectRevert(ValantisSwapRouter.ValantisSwapRouter___gaslessSwap_tokenOutNotWeth.selector);
        swapRouter.gaslessSwap(swapParams, ownerSignature, gaslessSwapIntent.maxFee);

        swapParams.intent.tokenOut = address(weth);

        // Should revert if chain id changes after signing
        uint256 chainId = block.chainid;

        (ownerSignature,) = _getIntentsSignatureAndHash(_ownerPrivateKey, gaslessSwapIntent);

        vm.chainId(123);

        vm.expectRevert(SignatureVerification.InvalidSigner.selector);
        swapRouter.gaslessSwap(swapParams, ownerSignature, gaslessSwapIntent.maxFee);

        vm.chainId(chainId);

        uint256 amountOut;
        {
            uint256 snapshot = vm.snapshot();
            amountOut = swapRouter.gaslessSwap(swapParams, ownerSignature, gaslessSwapIntent.maxFee);
            vm.revertTo(snapshot);
        }

        vm.expectEmit(false, false, false, true);
        emit GaslessSwapLog(
            swapParams.intent.owner,
            address(this),
            swapParams.intent.recipient,
            swapParams.intent.tokenIn,
            swapParams.intent.tokenOut,
            swapParams.intent.amountIn,
            amountOut,
            true,
            EMPTY_CODE
        );
        amountOut = swapRouter.gaslessSwap(swapParams, ownerSignature, gaslessSwapIntent.maxFee);
        // Recipient must receive amountOut of ETH
        assertEq(recipient.balance, amountOut);
    }

    function testBatchGaslessSwaps() public {
        bool isZeroToOne = true;

        _prepareUniversalPools(isZeroToOne);

        address recipient = MOCK_RECIPIENT;
        uint256 amountIn = 1e18;
        uint256 amountOutMin = 1e17;

        bool[] memory isUniversalPool = new bool[](1);
        isUniversalPool[0] = true;

        address[] memory pools = new address[](1);
        pools[0] = address(firstUniversalPool);

        uint256[] memory amountInSpecified = new uint256[](1);
        amountInSpecified[0] = amountIn;

        bytes[] memory payloads = new bytes[](1);
        payloads[0] = abi.encode(
            UniversalPoolSwapPayload(
                isZeroToOne,
                recipient,
                isZeroToOne ? PriceTickMath.MIN_PRICE_TICK : PriceTickMath.MAX_PRICE_TICK,
                0,
                new uint8[](1),
                _getUniversalPoolDefaultSwapData(isZeroToOne, amountIn),
                new bytes(0)
            )
        );

        // First user's swap intent
        GaslessSwapIntent memory firstGaslessSwapIntent = GaslessSwapIntent(
            false,
            address(token0),
            address(token1),
            _owner,
            recipient,
            address(this),
            address(token0),
            amountIn,
            100e18,
            1e15,
            0,
            block.timestamp
        );

        (bytes memory firstSignature,) = _getIntentsSignatureAndHash(_ownerPrivateKey, firstGaslessSwapIntent);

        // Second user's swap intent
        GaslessSwapIntent memory secondGaslessSwapIntent = GaslessSwapIntent(
            false,
            address(token0),
            address(token1),
            _owner,
            recipient,
            address(this),
            address(token0),
            amountIn,
            amountOutMin,
            1e15,
            1,
            block.timestamp
        );

        (bytes memory secondSignature,) = _getIntentsSignatureAndHash(_ownerPrivateKey, secondGaslessSwapIntent);

        GaslessSwapParams[] memory params = new GaslessSwapParams[](2);
        bytes[] memory signatures = new bytes[](2);
        uint128[] memory fees = new uint128[](2);

        params[0] =
            GaslessSwapParams(isUniversalPool, pools, amountInSpecified, payloads, firstGaslessSwapIntent, EMPTY_CODE);
        params[1] =
            GaslessSwapParams(isUniversalPool, pools, amountInSpecified, payloads, secondGaslessSwapIntent, EMPTY_CODE);

        signatures[0] = firstSignature;
        signatures[1] = secondSignature;

        // Should revert if input arrays do not have the same length
        params = new GaslessSwapParams[](0);
        vm.expectRevert(ValantisSwapRouter.ValantisSwapRouter__batchGaslessSwaps_invalidArrayLengths.selector);
        swapRouter.batchGaslessSwaps(params, signatures, fees);

        // Should revert if one of the swaps does not get enough tokenOut
        params = new GaslessSwapParams[](2);
        signatures = new bytes[](2);
        fees = new uint128[](2);

        params[0] =
            GaslessSwapParams(isUniversalPool, pools, amountInSpecified, payloads, firstGaslessSwapIntent, EMPTY_CODE);
        params[1] =
            GaslessSwapParams(isUniversalPool, pools, amountInSpecified, payloads, secondGaslessSwapIntent, EMPTY_CODE);

        signatures[0] = firstSignature;
        signatures[1] = secondSignature;

        vm.expectRevert(ValantisSwapRouter.ValantisSwapRouter___gaslessSwap_insufficientAmountOut.selector);
        swapRouter.batchGaslessSwaps(params, signatures, fees);

        firstGaslessSwapIntent.amountOutMin = amountOutMin;
        params[0] =
            GaslessSwapParams(isUniversalPool, pools, amountInSpecified, payloads, firstGaslessSwapIntent, EMPTY_CODE);

        (firstSignature,) = _getIntentsSignatureAndHash(_ownerPrivateKey, firstGaslessSwapIntent);
        signatures[0] = firstSignature;

        swapRouter.batchGaslessSwaps(params, signatures, fees);
    }

    function testSweep() public {
        address[] memory mockTokens = new address[](4);
        mockTokens[0] = address(token0);
        mockTokens[1] = address(token1);
        mockTokens[2] = address(token2);
        mockTokens[3] = address(token3);

        // Tokens array cannot have zero length
        vm.expectRevert(ValantisSwapRouter.ValantisSwapRouter__sweep_invalidTokensArrayLength.selector);
        swapRouter.sweep(new address[](0), MOCK_RECIPIENT);

        // Recipient cannot be zero address
        vm.expectRevert(ValantisSwapRouter.ValantisSwapRouter__sweep_invalidRecipient.selector);
        swapRouter.sweep(mockTokens, address(0));

        mockTokens[3] = address(0);
        // None of the tokens can be zero address
        vm.expectRevert(ValantisSwapRouter.ValantisSwapRouter__sweep_invalidTokenAddress.selector);
        swapRouter.sweep(mockTokens, MOCK_RECIPIENT);
        mockTokens[3] = address(token3);

        // Claim of tokens should be successful,
        // transferring all balance of token2 and token3 to MOCK_RECIPIENT
        token2.transfer(address(swapRouter), 2e18);
        token3.transfer(address(swapRouter), 3e18);
        assertEq(token2.balanceOf(address(swapRouter)), 2e18);
        assertEq(token3.balanceOf(address(swapRouter)), 3e18);

        swapRouter.sweep(mockTokens, MOCK_RECIPIENT);

        assertEq(token0.balanceOf(MOCK_RECIPIENT), 0);
        assertEq(token1.balanceOf(MOCK_RECIPIENT), 0);
        assertEq(token2.balanceOf(MOCK_RECIPIENT), 2e18);
        assertEq(token3.balanceOf(MOCK_RECIPIENT), 3e18);
        assertEq(token2.balanceOf(address(swapRouter)), 0);
        assertEq(token3.balanceOf(address(swapRouter)), 0);
    }

    function _prepareSovereignPools() private {
        firstSovereignALM.depositLiquidity(10e18, 10e18, new bytes(0));
        {
            (uint256 reserve0, uint256 reserve1) = firstSovereignPool.getReserves();
            assertEq(reserve0, 10e18);
            assertEq(reserve1, 10e18);
        }

        secondSovereignALM.depositLiquidity(10e18, 10e18, new bytes(0));
        {
            (uint256 reserve0, uint256 reserve1) = secondSovereignPool.getReserves();
            assertEq(reserve0, 10e18);
            assertEq(reserve1, 10e18);
        }

        thirdSovereignALM.depositLiquidity(10e18, 10e18, new bytes(0));
        {
            (uint256 reserve0, uint256 reserve1) = thirdSovereignPool.getReserves();
            assertEq(reserve0, 10e18);
            assertEq(reserve1, 10e18);
        }

        weth.deposit{value: 10e18}();
        assertEq(weth.balanceOf(address(this)), 10e18);
        fourthSovereignALM.depositLiquidity(10e18, 10e18, new bytes(0));
        {
            (uint256 reserve0, uint256 reserve1) = fourthSovereignPool.getReserves();
            assertEq(reserve0, 10e18);
            assertEq(reserve1, 10e18);
        }
    }

    function _prepareUniversalPools(bool isZeroToOne) private {
        firstUniversalALM.depositLiquidity(10e18, 10e18);
        ALMReserves memory almReserves;
        {
            almReserves = firstUniversalPool.getALMReserves(address(firstUniversalALM), isZeroToOne);
            assertEq(almReserves.tokenInReserves, 10e18);
            assertEq(almReserves.tokenOutReserves, 10e18);
        }

        secondUniversalALM.depositLiquidity(10e18, 10e18);
        {
            almReserves = secondUniversalPool.getALMReserves(address(secondUniversalALM), isZeroToOne);
            assertEq(almReserves.tokenInReserves, 10e18);
            assertEq(almReserves.tokenOutReserves, 10e18);
        }

        thirdUniversalALM.depositLiquidity(10e18, 10e18);
        {
            almReserves = thirdUniversalPool.getALMReserves(address(thirdUniversalALM), isZeroToOne);
            assertEq(almReserves.tokenInReserves, 10e18);
            assertEq(almReserves.tokenOutReserves, 10e18);
        }

        weth.deposit{value: 10e18}();
        assertEq(weth.balanceOf(address(this)), 10e18);
        fourthUniversalALM.depositLiquidity(10e18, 10e18);
        assertEq(weth.balanceOf(address(this)), 0);

        {
            almReserves = fourthUniversalPool.getALMReserves(address(fourthUniversalALM), isZeroToOne);
            assertEq(almReserves.tokenInReserves, 10e18);
            assertEq(almReserves.tokenOutReserves, 10e18);
        }
    }

    function _getUniversalPoolDefaultSwapData(bool isZeroToOne, uint256 amountOut)
        private
        pure
        returns (bytes[] memory externalContext)
    {
        externalContext = new bytes[](1);

        externalContext[0] = abi.encode(
            true, false, 0, 0, ALMLiquidityQuote(amountOut, isZeroToOne ? int24(-1) : int24(1), new bytes(0))
        );
    }

    function _getIntentsSignatureAndHash(uint256 privateKey, GaslessSwapIntent memory swapIntent)
        private
        view
        returns (bytes memory signature, bytes32 eip712IntentHash)
    {
        bytes32 intentHash = keccak256(abi.encode(GASLESS_SWAP_INTENT_TYPEHASH, swapIntent));
        eip712IntentHash = keccak256(abi.encodePacked("\x19\x01", swapRouter.DOMAIN_SEPARATOR(), intentHash));

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, eip712IntentHash);

        signature = bytes.concat(r, s, bytes1(v));
    }
}
