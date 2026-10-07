// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {PoolSwapTest} from "test/vendor/v4-core/src/test/PoolSwapTest.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "v4-core/src/libraries/CustomRevert.sol";
import {SwarmlingsHook} from "src/SwarmlingsHook.sol";
import {ReentrancyGuard} from "src/ReentrancyGuard.sol";
import {DN404} from "dn404/src/DN404.sol";
import {CoreFixture, CoreSwapOracle} from "./helpers/CoreFixture.sol";
import {SwarmMerkleFixture} from "./helpers/SwarmMerkleFixture.sol";

contract DistributionCallbackProbe {
    SwarmlingsHook immutable hook;
    bool public reject = true;
    bytes4 public reentryError;

    constructor(SwarmlingsHook h) {
        hook = h;
    }

    function accept() external {
        reject = false;
    }

    function notifyReward() external payable {
        (bool ok, bytes memory reason) = address(hook).call(abi.encodeCall(hook.distribute, ()));
        require(!ok, "distribution reentered");
        reentryError = bytes4(reason);
        require(!reject, "reward recipient rejected ETH");
    }
}

contract IndependentV4Test is CoreFixture {
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;

    function setUp() public {
        _deploy();
    }

    function _trade(uint8 mode, uint256 amount) internal returns (BalanceDelta delta, uint256 fee) {
        uint256 beforeETH = trader.balance;
        uint256 beforeLING = token.balanceOf(trader);
        uint256 beforeFees = manager.balanceOf(address(hook), 0);
        vm.recordLogs();
        vm.prank(trader);
        delta = swapRouter.swap{value: mode < 2 ? 100 ether : 0}(
            key, CoreSwapOracle.params(mode, amount), PoolSwapTest.TestSettings(false, false), ""
        );
        (int128 raw0, int128 raw1, uint24 lpFee) = CoreSwapOracle.rawSwap(vm.getRecordedLogs(), address(manager));
        fee = CoreSwapOracle.fee(mode, amount, raw0);
        assertEq(lpFee, 12500, "hook must retain the launch LP fee");
        assertEq(int256(delta.amount0()), int256(raw0) - int256(fee), "only ETH hook fee");
        assertEq(delta.amount1(), raw1, "no LING hook fee");
        assertEq(int256(trader.balance) - int256(beforeETH), delta.amount0(), "router refunds unused ETH");
        assertEq(int256(token.balanceOf(trader)) - int256(beforeLING), delta.amount1());
        if (mode == 0) assertEq(delta.amount0(), -int256(amount));
        if (mode == 1) assertEq(delta.amount1(), int256(amount));
        if (mode == 2) assertEq(delta.amount1(), -int256(amount));
        if (mode == 3) assertEq(delta.amount0(), int256(amount));
        assertEq(manager.balanceOf(address(hook), 0) - beforeFees, fee);
        assertEq(manager.balanceOf(address(hook), uint160(address(token))), 0);
        assertEq(hook.totalFees(), hook.distributed() + manager.balanceOf(address(hook), 0));
        assertEq(manager.getNonzeroDeltaCount(), 0, "unlock fully settled");
        assertFalse(manager.isUnlocked());
        assertEq(address(swapRouter).balance, 0);
        assertEq(address(hook).balance, 0);
    }

    function test_coreRoutersAllFourModesThenPermissionlessDistribution() public {
        _seed(false);
        token.transfer(trader, 4 * UNIT);
        uint256 expected;
        for (uint8 mode; mode < 4; ++mode) {
            (, uint256 fee) = _trade(mode, mode == 0 || mode == 3 ? 1 ether : UNIT);
            expected += fee;
        }
        assertEq(hook.totalFees(), expected);
        assertEq(address(token).balance, 0, "no notification during swap");
        vm.prank(makeAddr("permissionless keeper"));
        hook.distribute();
        assertEq(hook.distributed(), expected);
        assertEq(manager.balanceOf(address(hook), 0), 0);
        uint256[] memory ids = token.ownedIds(trader, 0, 3333);
        assertLe(expected - token.pending(trader, ids), 1, "only accumulator dust retained");
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_realRouterFourModes(uint96 amountSeed, uint8 modeSeed) public {
        _seed(false);
        token.transfer(trader, 4 * UNIT);
        uint8 mode = modeSeed % 4;
        uint256 amount = mode == 0 || mode == 3 ? bound(amountSeed, 80, 1 ether) : bound(amountSeed, 1 ether, 2 * UNIT);
        _trade(mode, amount);
    }

    function test_firstBuyExactInOnTokenOnlyManager() public {
        _seed(true);
        assertEq(address(manager).balance, 0);
        _trade(0, 1 ether);
        assertEq(address(manager).balance, 1 ether);
        assertGt(mirror.balanceOf(trader), 0);
        hook.distribute();
        assertEq(hook.distributed(), 0.0125 ether);
    }

    function test_firstBuyExactOutOnTokenOnlyManager() public {
        _seed(true);
        assertEq(address(manager).balance, 0);
        _trade(1, UNIT);
        assertGt(address(manager).balance, 0);
        assertEq(mirror.balanceOf(trader), 1);
    }

    function test_exactOutputBuysCrossBoundaryAndExactInputSellBurns() public {
        _seed(false);
        _trade(1, 299_999.99 ether);
        assertEq(mirror.balanceOf(trader), 0);
        _trade(1, 0.01 ether);
        assertEq(token.balanceOf(trader), UNIT);
        assertEq(mirror.balanceOf(trader), 1);
        token.notifyReward{value: 1 ether}();
        _trade(2, 0.01 ether);
        assertEq(token.balanceOf(trader), 299_999.99 ether);
        assertEq(mirror.balanceOf(trader), 0);
        assertEq(token.owed(trader), 1 ether);
        assertEq(mirror.balanceOf(address(manager)), 0);
    }

    function test_whaleExactOutputBuyCrossesOneHundredUnitsGasMeasured() public {
        _seed(false);
        vm.prank(trader);
        uint256 startGas = gasleft();
        BalanceDelta delta = swapRouter.swap{value: 100 ether}(
            key, CoreSwapOracle.params(1, 100 * UNIT), PoolSwapTest.TestSettings(false, false), ""
        );
        uint256 used = startGas - gasleft();
        emit log_named_uint("100 NFT whale buy gas (router + settlement + mint)", used);
        assertEq(delta.amount1(), int256(100 * UNIT));
        assertEq(mirror.balanceOf(trader), 100);
        assertEq(token.balanceOf(trader), 100 * UNIT);
        assertEq(token.activeNFTs(), 100);
        // A concrete test budget, not a claim about the launch chain's gas limit.
        assertLt(used, 10_000_000);
    }

    function test_poolDistributorAndRoutersAccrueNoRewards() public {
        _seed(false);
        SwarmMerkleFixture distributor = new SwarmMerkleFixture(token, bytes32(0));
        token.transfer(address(distributor), token.totalSupply() / 10);
        token.transfer(address(hook), UNIT);
        _trade(0, 1 ether);
        hook.distribute();
        address[5] memory excluded = [
            address(manager), address(distributor), address(hook), address(swapRouter), address(modifyLiquidityRouter)
        ];
        for (uint256 i; i < excluded.length; ++i) {
            assertEq(mirror.balanceOf(excluded[i]), 0);
            assertEq(token.owed(excluded[i]), 0);
            assertEq(token.pending(excluded[i], new uint256[](0)), 0);
        }
        assertEq(token.owed(token.TREASURY()), 0);
        assertLe(hook.distributed() - token.pending(trader, token.ownedIds(trader, 0, 3333)), 1);
    }

    function test_emptyDistributionAndZeroSwapRejectWithoutChangingLedger() public {
        _seed(false);
        vm.expectRevert(SwarmlingsHook.BelowMinimum.selector);
        hook.distribute();
        vm.expectRevert(IPoolManager.SwapAmountCannotBeZero.selector);
        swapRouter.swap(key, CoreSwapOracle.params(1, 0), PoolSwapTest.TestSettings(false, false), "");
        assertEq(hook.totalFees(), 0);
        assertEq(hook.distributed(), 0);
        assertEq(address(token).balance, 0);
    }

    function test_unfundedRouterFailureRollsBackSwapNFTsAndClaims() public {
        _seed(false);
        (uint160 beforePrice,,,) = manager.getSlot0(key.toId());
        vm.prank(trader);
        vm.expectRevert(); // router owes native input, but was sent no ETH
        swapRouter.swap(key, CoreSwapOracle.params(1, UNIT), PoolSwapTest.TestSettings(false, false), "");
        (uint160 afterPrice,,,) = manager.getSlot0(key.toId());
        assertEq(afterPrice, beforePrice);
        assertEq(hook.totalFees(), 0);
        assertEq(token.balanceOf(trader), 0);
        assertEq(token.activeNFTs(), 0);
        assertEq(manager.getNonzeroDeltaCount(), 0);
    }

    function test_sellingWithoutApprovalRollsBackRewardsAndNFTBurn() public {
        _seed(false);
        token.transfer(trader, UNIT);
        token.notifyReward{value: 1 ether}();
        vm.prank(trader);
        token.approve(address(swapRouter), 0);
        vm.prank(trader);
        vm.expectRevert(DN404.InsufficientAllowance.selector);
        swapRouter.swap(key, CoreSwapOracle.params(2, UNIT), PoolSwapTest.TestSettings(false, false), "");
        assertEq(mirror.balanceOf(trader), 1);
        assertEq(token.pending(trader, token.ownedIds(trader, 0, 1)), 1 ether);
        assertEq(token.owed(trader), 0);
        assertEq(hook.totalFees(), 0);
    }

    function test_distributeReentryAndRecipientFailureRestoreRedeemableClaims() public {
        DistributionCallbackProbe receiver = new DistributionCallbackProbe(hook);
        key.currency1 = Currency.wrap(address(receiver));
        manager.initialize(key, TickMath.getSqrtPriceAtTick(INITIAL_TICK));
        claimsRouter.deposit{value: 1 ether}(Currency.wrap(address(0)), address(hook), 1 ether);
        vm.expectRevert("reward recipient rejected ETH");
        hook.distribute();
        assertEq(hook.distributed(), 0);
        assertEq(manager.balanceOf(address(hook), 0), 1 ether);
        assertEq(address(manager).balance, 1 ether);
        assertEq(address(hook).balance, 0);
        assertEq(address(receiver).balance, 0);
        assertFalse(manager.isUnlocked());
        receiver.accept();
        hook.distribute();
        assertEq(receiver.reentryError(), ReentrancyGuard.ReentrantCall.selector);
        assertEq(hook.distributed(), 1 ether);
        assertEq(hook.totalFees(), 1 ether);
        assertEq(hook.pendingFees(), 0);
        assertEq(address(receiver).balance, 1 ether);
        assertEq(address(manager).balance, 0);
        vm.expectRevert(SwarmlingsHook.BelowMinimum.selector);
        hook.distribute();
    }

    function test_specifiedETHPartialFillsRevertWithExactHookErrorAndRollback() public {
        _seed(false);
        token.transfer(trader, 100 * UNIT);
        for (uint8 mode; mode <= 3; mode += 3) {
            SwapParams memory p = CoreSwapOracle.params(mode, 100 ether);
            p.sqrtPriceLimitX96 = TickMath.getSqrtPriceAtTick(INITIAL_TICK + (mode == 0 ? int24(-1) : int24(1)));
            vm.prank(trader);
            vm.expectRevert(
                abi.encodeWithSelector(
                    CustomRevert.WrappedError.selector,
                    address(hook),
                    IHooks.afterSwap.selector,
                    abi.encodeWithSelector(SwarmlingsHook.PartialFill.selector),
                    abi.encodeWithSelector(Hooks.HookCallFailed.selector)
                )
            );
            swapRouter.swap{value: mode == 0 ? 100 ether : 0}(key, p, PoolSwapTest.TestSettings(false, false), "");
            (uint160 price,,,) = manager.getSlot0(key.toId());
            assertEq(price, TickMath.getSqrtPriceAtTick(INITIAL_TICK));
            assertEq(hook.totalFees(), 0);
            assertEq(token.balanceOf(trader), 100 * UNIT);
            assertEq(mirror.balanceOf(trader), 100);
        }
    }

    function test_unspecifiedETHPartialFillsChargeActualCoreDeltaOnly() public {
        _seed(false);
        token.transfer(trader, 100 * UNIT);
        uint256 expected;
        for (uint8 mode = 1; mode <= 2; ++mode) {
            SwapParams memory p = CoreSwapOracle.params(mode, 100 * UNIT);
            p.sqrtPriceLimitX96 = TickMath.getSqrtPriceAtTick(INITIAL_TICK + (mode == 1 ? int24(-1) : int24(1)));
            vm.recordLogs();
            vm.prank(trader);
            BalanceDelta d =
                swapRouter.swap{value: mode == 1 ? 100 ether : 0}(key, p, PoolSwapTest.TestSettings(false, false), "");
            (int128 raw0, int128 raw1,) = CoreSwapOracle.rawSwap(vm.getRecordedLogs(), address(manager));
            uint256 fee = CoreSwapOracle.fee(mode, 100 * UNIT, raw0);
            expected += fee;
            assertGt(fee, 0);
            assertEq(int256(d.amount0()), int256(raw0) - int256(fee));
            assertEq(d.amount1(), raw1);
            assertLt(uint256(raw1 < 0 ? -int256(raw1) : int256(raw1)), 100 * UNIT);
            assertEq(hook.totalFees(), expected);
        }
    }
}
