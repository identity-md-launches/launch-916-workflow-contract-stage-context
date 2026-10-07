// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta, toBalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {Swarmlings} from "../src/Swarmlings.sol";
import {SwarmlingsHook} from "../src/SwarmlingsHook.sol";
import {ReentrancyGuard} from "../src/ReentrancyGuard.sol";
import {HookDeployer} from "./helpers/HookDeployer.sol";
import {V4TestRouter} from "./helpers/V4TestRouter.sol";

contract BadRewardReceiver {
    SwarmlingsHook public hook;
    bool public reject = true;
    bool public reentryBlocked;

    function configure(SwarmlingsHook h, bool r) external {
        hook = h;
        reject = r;
    }

    function notifyReward() external payable {
        require(!reject, "reject reward");
        (bool ok, bytes memory reason) = address(hook).call(abi.encodeCall(hook.distribute, ()));
        reentryBlocked = !ok && bytes4(reason) == ReentrancyGuard.ReentrantCall.selector;
    }
}

contract SwarmlingsHookTest is Test, HookDeployer {
    PoolManager manager;
    Swarmlings token;
    SwarmlingsHook hook;
    V4TestRouter router;
    PoolKey key;
    uint160 constant PRICE = 79228162514264337593543950336;
    address alice = address(0xa11ce);

    function setUp() public {
        manager = new PoolManager(address(this));
        token = new Swarmlings();
        hook = deployHook(manager);
        router = new V4TestRouter(manager);
        key = PoolKey(Currency.wrap(address(0)), Currency.wrap(address(token)), 12500, 60, IHooks(address(hook)));
        vm.deal(address(router), 100_000 ether);
        vm.deal(address(this), 100 ether);
        token.approve(address(router), type(uint256).max);
    }

    function initializeAndSeed() internal {
        manager.initialize(key, PRICE);
        router.liquidity(key, ModifyLiquidityParams(-60000, 60000, 1000 ether, bytes32(0)));
    }

    function params(bool buy, bool exactIn, uint256 amount) internal pure returns (SwapParams memory) {
        return SwapParams(
            buy,
            exactIn ? -int256(amount) : int256(amount),
            buy ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        );
    }

    function assertLedger() internal view {
        assertEq(hook.totalFees(), hook.distributed() + manager.balanceOf(address(hook), 0));
        assertEq(hook.pendingFees(), manager.balanceOf(address(hook), 0));
        assertEq(manager.balanceOf(address(hook), uint160(address(token))), 0);
        assertEq(address(hook).balance, 0);
    }

    function test_permissionBitsAndBadDeploymentRefused() public {
        assertEq(uint160(address(hook)) & ((1 << 14) - 1), 0x10cc);
        Hooks.Permissions memory p = hook.getHookPermissions();
        assertFalse(p.beforeInitialize);
        assertTrue(
            p.afterInitialize && p.beforeSwap && p.afterSwap && p.beforeSwapReturnDelta && p.afterSwapReturnDelta
        );
        assertFalse(
            p.beforeAddLiquidity || p.afterAddLiquidity || p.beforeRemoveLiquidity || p.afterRemoveLiquidity
                || p.beforeDonate || p.afterDonate || p.afterAddLiquidityReturnDelta
                || p.afterRemoveLiquidityReturnDelta
        );
        vm.expectRevert();
        new SwarmlingsHook(manager);
    }

    function test_onlyManagerCanCallEveryCallbackAndReceive() public {
        SwapParams memory p = params(true, true, 1 ether);
        vm.expectRevert(SwarmlingsHook.OnlyPoolManager.selector);
        hook.afterInitialize(address(this), key, PRICE, 0);
        vm.expectRevert(SwarmlingsHook.OnlyPoolManager.selector);
        hook.beforeSwap(address(this), key, p, "");
        vm.expectRevert(SwarmlingsHook.OnlyPoolManager.selector);
        hook.afterSwap(address(this), key, p, BalanceDelta.wrap(0), "");
        vm.expectRevert(SwarmlingsHook.OnlyPoolManager.selector);
        hook.unlockCallback(abi.encode(1));
        vm.prank(address(manager));
        vm.expectRevert(SwarmlingsHook.UnexpectedUnlock.selector);
        hook.unlockCallback(abi.encode(1));
        (bool ok,) = address(hook).call{value: 1}("");
        assertFalse(ok);
    }

    function test_initializeAcceptsNonNativeThenBindsOnlyFirstNative() public {
        PoolKey memory other =
            PoolKey(Currency.wrap(address(10)), Currency.wrap(address(20)), 3000, 60, IHooks(address(hook)));
        manager.initialize(other, PRICE);
        assertFalse(hook.launchPoolSet());
        manager.initialize(key, PRICE);
        assertTrue(hook.launchPoolSet());
        assertEq(PoolId.unwrap(hook.launchPool()), PoolId.unwrap(key.toId()));
        assertEq(hook.LING(), address(token));
        other.currency0 = Currency.wrap(address(0));
        manager.initialize(other, PRICE);
        assertEq(PoolId.unwrap(hook.launchPool()), PoolId.unwrap(key.toId()));
        assertEq(hook.LING(), address(token));
        vm.prank(address(manager));
        (bytes4 selector, BeforeSwapDelta d, uint24 feeOverride) =
            hook.beforeSwap(address(this), other, params(true, true, 1 ether), "");
        assertEq(selector, IHooks.beforeSwap.selector);
        assertEq(BeforeSwapDelta.unwrap(d), 0);
        assertEq(feeOverride, 0);
        vm.prank(address(manager));
        (, int128 fee) =
            hook.afterSwap(address(this), other, params(false, true, 1 ether), toBalanceDelta(1 ether, -1 ether), "");
        assertEq(fee, 0);
    }

    function test_allFourFeeModesOnRealManager() public {
        initializeAndSeed();
        uint256 beforeFees;
        BalanceDelta d = router.swap(key, params(true, true, 1 ether));
        assertEq(d.amount0(), -1 ether);
        assertGt(d.amount1(), 0);
        assertEq(hook.totalFees(), 0.0125 ether);
        assertLedger();

        beforeFees = hook.totalFees();
        d = router.swap(key, params(false, false, 1 ether));
        assertEq(d.amount0(), 1 ether);
        assertLt(d.amount1(), 0);
        assertEq(hook.totalFees() - beforeFees, 0.0125 ether);
        assertLedger();

        beforeFees = hook.totalFees();
        d = router.swap(key, params(true, false, 1 ether));
        uint256 collected = hook.totalFees() - beforeFees;
        uint256 rawETHInput = uint256(-int256(d.amount0())) - collected;
        assertEq(d.amount1(), 1 ether);
        assertEq(collected, rawETHInput * 125 / 10000);
        assertGt(collected, 0);
        assertLedger();

        beforeFees = hook.totalFees();
        d = router.swap(key, params(false, true, 1 ether));
        collected = hook.totalFees() - beforeFees;
        uint256 rawETHOutput = uint256(int256(d.amount0())) + collected;
        assertEq(d.amount1(), -1 ether);
        assertEq(collected, rawETHOutput * 125 / 10000);
        assertGt(collected, 0);
        assertLedger();
    }

    function test_identicalBuyFillsHaveModeDependentFees() public {
        initializeAndSeed();
        uint256 snapshot = vm.snapshotState();
        BalanceDelta exactIn = router.swap(key, params(true, true, 1 ether));
        assertEq(hook.pendingFees(), 0.0125 ether);
        assertEq(exactIn.amount0(), -1 ether);
        uint256 output = uint256(int256(exactIn.amount1()));
        assertEq(output, 974206246689751447);
        assertTrue(vm.revertToState(snapshot));
        BalanceDelta exactOut = router.swap(key, params(true, false, output));
        assertEq(exactOut.amount1(), exactIn.amount1());
        assertEq(exactOut.amount0(), -0.99984375 ether);
        assertEq(hook.pendingFees(), 0.01234375 ether);
        assertLedger();
    }

    function test_pendingFeesAllocateAtNotificationAndNotAtSwap() public {
        initializeAndSeed();
        uint256 unit = token.UNIT();
        token.transfer(alice, unit);
        router.swap(key, params(true, true, 8 ether));
        assertEq(hook.pendingFees(), 0.1 ether);
        assertEq(token.activeNFTs(), 1);
        assertEq(token.pending(alice, token.ownedIds(alice, 0, 1)), 0);

        address laterHolder = address(0xb0b);
        token.transfer(laterHolder, 3 * unit);
        hook.distribute();
        assertEq(token.pending(alice, token.ownedIds(alice, 0, 1)), 0.025 ether);
        assertEq(token.pending(laterHolder, token.ownedIds(laterHolder, 0, 3)), 0.075 ether);
        vm.prank(laterHolder);
        token.transfer(address(this), 3 * unit);
        assertEq(token.owed(laterHolder), 0.075 ether);
        vm.prank(laterHolder);
        token.claim(new uint256[](0));
        assertEq(laterHolder.balance, 0.075 ether);
        assertLedger();
    }

    function test_firstBuyOnTokenOnlyLiquidityWithZeroManagerETH() public {
        manager.initialize(key, PRICE);
        router.liquidity(key, ModifyLiquidityParams(-600, 0, 1000 ether, bytes32(0)));
        assertEq(address(manager).balance, 0);
        assertEq(token.activeNFTs(), 0);
        BalanceDelta d = router.swap(key, params(true, true, 1 ether));
        assertEq(d.amount0(), -1 ether);
        assertGt(d.amount1(), 0);
        assertEq(address(manager).balance, 1 ether);
        assertEq(hook.pendingFees(), 0.0125 ether);
        assertEq(address(token).balance, 0);
        assertLedger();
    }

    function test_firstExactOutputBuyOnTokenOnlyLiquidity() public {
        manager.initialize(key, PRICE);
        router.liquidity(key, ModifyLiquidityParams(-600, 0, 1000 ether, bytes32(0)));
        assertEq(address(manager).balance, 0);
        BalanceDelta d = router.swap(key, params(true, false, 1 ether));
        assertEq(d.amount1(), 1 ether);
        assertGt(hook.pendingFees(), 0);
        assertLedger();
    }

    function test_onlyLaunchPoolPaysFees() public {
        initializeAndSeed();
        PoolKey memory other = key;
        other.fee = 3000;
        manager.initialize(other, PRICE);
        router.liquidity(other, ModifyLiquidityParams(-60000, 60000, 1000 ether, bytes32(0)));
        for (uint256 i; i < 4; ++i) {
            router.swap(other, params(i < 2, i % 2 == 0, 1 ether));
            assertEq(hook.totalFees(), 0);
        }
        router.swap(key, params(true, true, 1 ether));
        assertEq(hook.totalFees(), 0.0125 ether);
    }

    function test_partialFillsRevertSpecifiedModesAndRollbackClaims() public {
        initializeAndSeed();
        SwapParams memory p = SwapParams(true, -100 ether, TickMath.getSqrtPriceAtTick(-1));
        vm.expectRevert();
        router.swap(key, p);
        assertEq(hook.pendingFees(), 0);
        p = SwapParams(false, 100 ether, TickMath.getSqrtPriceAtTick(1));
        vm.expectRevert();
        router.swap(key, p);
        assertEq(hook.pendingFees(), 0);
        vm.prank(address(manager));
        vm.expectRevert(SwarmlingsHook.PartialFill.selector);
        hook.afterSwap(address(this), key, p, toBalanceDelta(1, -1), "");
        assertLedger();
    }

    function test_partialFillsInAfterModesOnlyChargeActualETH() public {
        initializeAndSeed();
        BalanceDelta d = router.swap(key, SwapParams(true, 100 ether, TickMath.getSqrtPriceAtTick(-1)));
        assertLt(d.amount1(), 100 ether);
        uint256 fee = hook.totalFees();
        assertEq(fee, (uint256(-int256(d.amount0())) - fee) * 125 / 10000);
        uint256 beforeFees = hook.totalFees();
        d = router.swap(key, SwapParams(false, -100 ether, TickMath.getSqrtPriceAtTick(1)));
        assertGt(d.amount1(), -100 ether);
        fee = hook.totalFees() - beforeFees;
        assertEq(fee, (uint256(int256(d.amount0())) + fee) * 125 / 10000);
        assertLedger();
    }

    function test_distributionToHoldersAndEmptyHolderFallback() public {
        initializeAndSeed();
        token.transfer(alice, token.UNIT());
        router.swap(key, params(true, true, 1 ether));
        vm.prank(alice);
        hook.distribute();
        assertEq(hook.distributed(), 0.0125 ether);
        assertEq(hook.pendingFees(), 0);
        uint256[] memory all = token.ownedIds(alice, 0, 10);
        assertEq(token.pending(alice, all), 0.0125 ether);
        vm.prank(alice);
        token.claim(all);
        assertEq(alice.balance, 0.0125 ether);
        uint256 unit = token.UNIT();
        vm.prank(alice);
        token.transfer(address(this), unit);
        router.swap(key, params(true, true, 1 ether));
        hook.distribute();
        assertEq(token.owed(token.TREASURY()), 0.0125 ether);
        assertEq(token.TREASURY().balance, 0);
        assertLedger();
    }

    function test_distributionThresholdExactBoundaryAndRepeatedCall() public {
        initializeAndSeed();
        vm.expectRevert(SwarmlingsHook.BelowMinimum.selector);
        hook.distribute();
        router.donateClaims(key, address(hook), hook.MIN_DISTRIBUTE() - 1);
        vm.expectRevert(SwarmlingsHook.BelowMinimum.selector);
        hook.distribute();
        router.donateClaims(key, address(hook), 1);
        assertLedger();
        hook.distribute();
        assertEq(hook.distributed(), 0.01 ether);
        assertEq(token.owed(token.TREASURY()), 0.01 ether);
        vm.expectRevert(SwarmlingsHook.BelowMinimum.selector);
        hook.distribute();
        assertLedger();
    }

    function test_distributionRequiresItsOwnUnlock() public {
        initializeAndSeed();
        router.swap(key, params(true, true, 1 ether));
        vm.expectRevert(IPoolManager.AlreadyUnlocked.selector);
        router.nestedDistribute(key);
        assertEq(hook.pendingFees(), 0.0125 ether);
        hook.distribute();
        assertLedger();
    }

    function test_distributionRevertRestoresClaimsAndReentryBlocked() public {
        BadRewardReceiver bad = new BadRewardReceiver();
        key.currency1 = Currency.wrap(address(bad));
        manager.initialize(key, PRICE);
        router.donateClaims(key, address(hook), 1 ether);
        vm.expectRevert("reject reward");
        hook.distribute();
        assertEq(hook.pendingFees(), 1 ether);
        assertEq(hook.distributed(), 0);
        assertEq(address(hook).balance, 0);
        bad.configure(hook, false);
        hook.distribute();
        assertTrue(bad.reentryBlocked());
        assertEq(address(bad).balance, 1 ether);
        assertLedger();
    }

    function test_tinyFeeRoundingAndOversizedSpecifiedAmount() public {
        manager.initialize(key, PRICE);
        vm.prank(address(manager));
        (, BeforeSwapDelta delta,) = hook.beforeSwap(address(this), key, params(true, true, 79), "");
        assertEq(BeforeSwapDelta.unwrap(delta), 0);
        vm.prank(address(manager));
        (, int128 afterFee) = hook.afterSwap(address(this), key, params(false, true, 100), toBalanceDelta(79, -100), "");
        assertEq(afterFee, 0);
        assertEq(hook.totalFees(), 0);
        SwapParams memory p = SwapParams(true, type(int256).min, TickMath.MIN_SQRT_PRICE + 1);
        vm.prank(address(manager));
        vm.expectRevert();
        hook.beforeSwap(address(this), key, p, "");
        assertEq(hook.totalFees(), 0);
    }

    function test_rewardReceiverIsNeverCalledInsideSwaps() public {
        initializeAndSeed();
        vm.mockCallRevert(address(token), abi.encodeWithSelector(token.notifyReward.selector), "blocked notify");
        for (uint256 i; i < 4; ++i) {
            router.swap(key, params(i < 2, i % 2 == 0, 1 ether));
        }
        uint256 fees = hook.pendingFees();
        assertGt(fees, 0);
        assertEq(address(token).balance, 0);
        vm.expectRevert();
        hook.distribute();
        assertEq(hook.pendingFees(), fees);
        assertLedger();
    }

    function testFuzz_fourModeFeeLedger(uint96 value, uint8 mode) public {
        initializeAndSeed();
        uint256 amount = bound(value, 1000, 2 ether);
        mode %= 4;
        BalanceDelta d = router.swap(key, params(mode < 2, mode % 2 == 0, amount));
        uint256 fee = hook.totalFees();
        uint256 gross;
        if (mode == 0 || mode == 3) gross = amount;
        else if (mode == 1) gross = uint256(-int256(d.amount0())) - fee;
        else gross = uint256(int256(d.amount0())) + fee;
        assertEq(fee, gross * 125 / 10000);
        assertLedger();
        if (fee >= hook.MIN_DISTRIBUTE()) {
            hook.distribute();
            assertEq(hook.distributed(), fee);
            assertEq(token.owed(token.TREASURY()), fee);
            assertLedger();
        }
    }

    receive() external payable {}
}
