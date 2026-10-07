// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {PoolSwapTest} from "test/vendor/v4-core/src/test/PoolSwapTest.sol";
import {PoolClaimsTest} from "test/vendor/v4-core/src/test/PoolClaimsTest.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {Swarmlings} from "src/Swarmlings.sol";
import {SwarmlingsHook} from "src/SwarmlingsHook.sol";
import {DN404Mirror} from "dn404/src/DN404Mirror.sol";
import {CoreFixture, CoreSwapOracle} from "./helpers/CoreFixture.sol";
import {SwarmMerkleFixture} from "./helpers/SwarmMerkleFixture.sol";

contract InvariantContractWallet {
    receive() external payable {}
}

/// @dev Reference entitlements are credited to wallets only at notification time,
/// using their NFT counts. Transferring/burning an NFT never moves this ledger.
/// Paid amounts come from recipient ETH balance changes, not token storage/events.
contract IndependentConservationHandler is Test {
    uint256 constant UNIT = 300_000e18;
    uint256 constant SCALE = 1e36;
    Swarmlings public immutable token;
    SwarmlingsHook public immutable hook;
    DN404Mirror public immutable mirror;
    PoolSwapTest public immutable router;
    PoolClaimsTest public immutable claimsRouter;
    IPoolManager public immutable manager;
    PoolKey private key;
    address[5] public actors;
    mapping(address => uint256) public entitledScaled;
    mapping(address => uint256) public paid;
    uint256 public notified;
    uint256 public divisionDustScaled;
    uint256 public totalPaid;
    uint256 public feesReceived;
    uint256 public distributions;
    uint256[4] public modeCalls;
    uint256 public zeroHolderNotifications;
    uint256 public successfulDistributions;
    uint256 public successfulClaims;
    uint256 public rejectedUnnotifiedPayments;

    constructor(Swarmlings t, SwarmlingsHook h, PoolSwapTest r, PoolClaimsTest c, IPoolManager m, PoolKey memory k) {
        token = t;
        hook = h;
        mirror = DN404Mirror(payable(t.mirrorERC721()));
        router = r;
        claimsRouter = c;
        manager = m;
        key = k;
        actors = [
            address(0x10001),
            address(0x10002),
            address(0x10003),
            address(0x10004),
            address(new InvariantContractWallet())
        ];
        for (uint256 i; i < actors.length; ++i) {
            vm.deal(actors[i], 1_000_000 ether);
            vm.prank(actors[i]);
            t.approve(address(r), type(uint256).max);
        }
    }

    function notify(uint96 seed) external {
        uint256 amount = bound(seed, 0, 2 ether);
        _allocate(amount);
        token.notifyReward{value: amount}();
    }

    function rejectUnnotifiedPayment(uint8 selectorSeed, uint96 amountSeed) external {
        // These inherited read selectors return from assembly. They must never
        // accept ETH before Swarmlings' reward-notification accounting runs.
        bytes[4] memory calls = [
            abi.encodeWithSignature("implementsDN404()"),
            abi.encodeWithSignature("totalNFTSupply()"),
            abi.encodeWithSignature("balanceOfNFT(address)", actors[0]),
            abi.encodeWithSignature("ownerAtNFT(uint256)", uint256(1))
        ];
        bytes memory data = calls[selectorSeed % 4];
        (bool readable,) = address(token).staticcall(data);
        assertTrue(readable, "selector must work without ETH");
        uint256 beforeBalance = address(token).balance;
        (bool ok, bytes memory reason) = address(token).call{value: bound(amountSeed, 1, 2 ether)}(data);
        assertFalse(ok, "fallback accepted ETH outside notifyReward");
        assertEq(reason, abi.encodeWithSelector(Swarmlings.UnexpectedETH.selector));
        assertEq(address(token).balance, beforeBalance, "rejected ETH must be refunded");
        ++rejectedUnnotifiedPayments;
    }

    function trade(uint8 actorSeed, uint8 modeSeed, uint96 amountSeed) external {
        address actor = actors[actorSeed % 5];
        uint8 mode = modeSeed % 4;
        // Keep each sale funded without unconstrained assume/discard or catch/revert.
        if (mode >= 2 && token.balanceOf(actor) < 2 * UNIT) token.transfer(actor, 2 * UNIT);
        uint256 amount = mode == 0
            ? bound(amountSeed, 0.01 ether, 1 ether)
            : mode == 3 ? bound(amountSeed, 0.001 ether, 0.1 ether) : bound(amountSeed, 1 ether, UNIT);
        vm.recordLogs();
        vm.prank(actor);
        BalanceDelta delta = router.swap{value: mode < 2 ? 10 ether : 0}(
            key, CoreSwapOracle.params(mode, amount), PoolSwapTest.TestSettings(false, false), ""
        );
        (int128 raw0, int128 raw1, uint24 lpFee) = CoreSwapOracle.rawSwap(vm.getRecordedLogs(), address(manager));
        uint256 expectedFee = CoreSwapOracle.fee(mode, amount, raw0);
        assertEq(int256(delta.amount0()), int256(raw0) - int256(expectedFee));
        assertEq(delta.amount1(), raw1);
        assertEq(lpFee, 12500);
        if (mode == 0) assertEq(delta.amount0(), -int256(amount));
        if (mode == 1) assertEq(delta.amount1(), int256(amount));
        if (mode == 2) assertEq(delta.amount1(), -int256(amount));
        if (mode == 3) assertEq(delta.amount0(), int256(amount));
        feesReceived += expectedFee;
        ++modeCalls[mode];
    }

    function donateClaims(uint96 seed) external {
        uint256 amount = bound(seed, 1, 0.02 ether);
        // Credit this account first, then transfer ERC-6909 claims to the hook.
        claimsRouter.deposit{value: amount}(Currency.wrap(address(0)), address(this), amount);
        manager.transfer(address(hook), 0, amount);
        feesReceived += amount;
    }

    function distribute() external {
        uint256 amount = feesReceived - distributions;
        if (amount < hook.MIN_DISTRIBUTE()) {
            vm.expectRevert(SwarmlingsHook.BelowMinimum.selector);
            hook.distribute();
            return;
        }
        _allocate(amount);
        hook.distribute();
        distributions += amount;
        ++successfulDistributions;
    }

    function receiveTokens(uint8 actorSeed, uint96 seed) external {
        token.transfer(actors[actorSeed % 5], bound(seed, 0, 3 * UNIT));
    }

    function transferTokens(uint8 fromSeed, uint8 toSeed, uint96 seed) external {
        address from = actors[fromSeed % 5];
        address to = toSeed % 6 == 5 ? address(this) : actors[toSeed % 5];
        uint256 amount = bound(seed, 0, token.balanceOf(from));
        vm.prank(from);
        token.transfer(to, amount);
    }

    function transferNFT(uint8 fromSeed, uint8 toSeed, uint256 idSeed) external {
        address from = actors[fromSeed % 5];
        address to = actors[toSeed % 5];
        uint256[] memory ids = token.ownedIds(from, 0, 3333);
        if (ids.length == 0) return;
        vm.prank(from);
        mirror.transferFrom(from, to, ids[idSeed % ids.length]);
    }

    function toggleSkip(uint8 actorSeed, bool skip) external {
        vm.prank(actors[actorSeed % 5]);
        token.setSkipNFT(skip);
    }

    function burnAll() external {
        for (uint256 i; i < 5; ++i) {
            address actor = actors[i];
            uint256 amount = token.balanceOf(actor);
            vm.prank(actor);
            token.transfer(address(this), amount);
        }
        assertEq(token.activeNFTs(), 0);
    }

    function claim(uint8 actorSeed, bool empty, bool duplicate) external {
        address actor = actorSeed % 6 == 5 ? token.TREASURY() : actors[actorSeed % 5];
        uint256[] memory ids = empty ? new uint256[](0) : token.ownedIds(actor, 0, 3333);
        if (duplicate && ids.length != 0) {
            uint256[] memory doubled = new uint256[](ids.length * 2);
            for (uint256 i; i < ids.length; ++i) {
                doubled[2 * i] = doubled[2 * i + 1] = ids[i];
            }
            ids = doubled;
        }
        uint256 beforeBalance = actor.balance;
        vm.prank(actor);
        token.claim(ids);
        uint256 payout = actor.balance - beforeBalance;
        paid[actor] += payout;
        totalPaid += payout;
        if (payout != 0) ++successfulClaims;
        assertLe(paid[actor] * SCALE, entitledScaled[actor], "cannot overclaim reference entitlement");
    }

    function _allocate(uint256 amount) private {
        notified += amount;
        uint256 count;
        for (uint256 i; i < 5; ++i) {
            count += mirror.balanceOf(actors[i]);
        }
        assertEq(count, token.activeNFTs(), "no untracked NFT holder");
        if (count == 0) {
            entitledScaled[token.TREASURY()] += amount * SCALE;
            ++zeroHolderNotifications;
        } else {
            uint256 perNFT = amount * SCALE / count;
            divisionDustScaled += amount * SCALE - perNFT * count;
            for (uint256 i; i < 5; ++i) {
                entitledScaled[actors[i]] += perNFT * mirror.balanceOf(actors[i]);
            }
        }
    }

    receive() external payable {}
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 96
/// forge-config: default.invariant.fail-on-revert = true
contract IndependentConservationInvariantTest is StdInvariant, CoreFixture {
    using TransientStateLibrary for IPoolManager;
    IndependentConservationHandler handler;
    SwarmMerkleFixture distributor;

    function setUp() public {
        _deploy();
        _seed(false);
        distributor = new SwarmMerkleFixture(token, bytes32(0));
        token.transfer(address(distributor), token.totalSupply() / 10);
        handler = new IndependentConservationHandler(token, hook, swapRouter, claimsRouter, manager, key);
        for (uint256 i; i < 5; ++i) {
            token.transfer(handler.actors(i), 2 * UNIT);
        }
        token.transfer(address(handler), token.balanceOf(address(this)));
        vm.deal(address(handler), 1_000_000 ether);
        bytes4[] memory selectors = new bytes4[](11);
        selectors[0] = handler.notify.selector;
        selectors[1] = handler.trade.selector;
        selectors[2] = handler.donateClaims.selector;
        selectors[3] = handler.distribute.selector;
        selectors[4] = handler.receiveTokens.selector;
        selectors[5] = handler.transferTokens.selector;
        selectors[6] = handler.transferNFT.selector;
        selectors[7] = handler.toggleSkip.selector;
        selectors[8] = handler.burnAll.selector;
        selectors[9] = handler.claim.selector;
        selectors[10] = handler.rejectUnnotifiedPayment.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    function invariant_claimedPlusOwedPlusHeldEqualsNotified() public view {
        uint256 owed;
        uint256 claimable;
        uint256 unpaidScaled;
        uint256 paid;
        for (uint256 i; i < 6; ++i) {
            address actor = i == 5 ? token.TREASURY() : handler.actors(i);
            uint256 allocated = handler.entitledScaled(actor);
            uint256 claimed = handler.paid(actor);
            uint256 pending = token.pending(actor, token.ownedIds(actor, 0, 3333));
            assertEq(pending, allocated / 1e36 - claimed, "wallet reference rewards");
            assertLe(token.owed(actor), pending);
            owed += token.owed(actor);
            claimable += pending;
            unpaidScaled += allocated - claimed * 1e36;
            paid += claimed;
        }
        assertEq(paid, handler.totalPaid());
        assertGe(address(token).balance, claimable, "all claims remain solvent");
        // Owed is already physically inside the token. Held denotes the remaining
        // uncheckpointed rewards and dust; adding raw balance to owed double-counts.
        uint256 held = address(token).balance - owed;
        assertEq(paid + owed + held, handler.notified());
        assertEq(address(token).balance * 1e36, unpaidScaled + handler.divisionDustScaled());
    }

    function invariant_hookFeesMatchIndependentSwapAndDonationLedger() public view {
        assertEq(hook.totalFees(), handler.feesReceived());
        assertEq(hook.distributed(), handler.distributions());
        assertEq(hook.totalFees(), hook.distributed() + manager.balanceOf(address(hook), 0));
        assertEq(hook.pendingFees(), handler.feesReceived() - handler.distributions());
        assertEq(manager.balanceOf(address(hook), uint160(address(token))), 0);
        assertEq(address(hook).balance, 0);
        assertEq(manager.getNonzeroDeltaCount(), 0);
        assertFalse(manager.isUnlocked());
    }

    function invariant_supplyNFTBackingAndExcludedRecipients() public view {
        uint256 supply = token.balanceOf(address(manager)) + token.balanceOf(address(handler))
            + token.balanceOf(address(distributor));
        uint256 nftCount;
        bool[3334] memory seen;
        for (uint256 i; i < 5; ++i) {
            (uint256 balance, uint256 count) = _checkActorNFTs(handler.actors(i), seen);
            supply += balance;
            nftCount += count;
        }
        assertEq(supply, 1e27);
        assertEq(token.totalSupply(), 1e27);
        assertEq(nftCount, token.activeNFTs());
        assertEq(nftCount, mirror.totalSupply());
        assertLe(nftCount, 3333);
        address[4] memory excluded = [address(manager), address(distributor), address(hook), address(handler)];
        for (uint256 i; i < excluded.length; ++i) {
            assertEq(mirror.balanceOf(excluded[i]), 0);
            assertEq(token.pending(excluded[i], new uint256[](0)), 0);
        }
    }

    function _checkActorNFTs(address actor, bool[3334] memory seen)
        private
        view
        returns (uint256 balance, uint256 count)
    {
        balance = token.balanceOf(actor);
        uint256[] memory ids = token.ownedIds(actor, 0, 3333);
        count = ids.length;
        assertEq(count, mirror.balanceOf(actor));
        assertLe(count * UNIT, balance);
        if (!token.getSkipNFT(actor)) assertEq(count, balance / UNIT);
        for (uint256 j; j < count; ++j) {
            uint256 id = ids[j];
            assertGt(id, 0);
            assertLe(id, 3333);
            assertFalse(seen[id], "NFT cannot have two owners");
            seen[id] = true;
            assertEq(mirror.ownerOf(id), actor);
        }
    }

    function afterInvariant() public {
        for (uint8 i; i < 6; ++i) {
            handler.claim(i, false, false);
        }
        invariant_claimedPlusOwedPlusHeldEqualsNotified();
        // Each of six tracked recipients can retain less than one wei of fraction,
        // plus less than one wei lost to accumulator division at this depth.
        assertLe(address(token).balance, 6, "all whole-wei liabilities are redeemable");
    }

    function test_handlerExercisesEveryFeeModeAndZeroHolderTransition() public {
        handler.burnAll();
        handler.notify(1 ether);
        assertEq(handler.zeroHolderNotifications(), 1);
        for (uint8 mode; mode < 4; ++mode) {
            handler.trade(0, mode, uint96(mode == 0 || mode == 3 ? 0.1 ether : UNIT));
            assertEq(handler.modeCalls(mode), 1);
        }
        handler.donateClaims(0.02 ether);
        handler.distribute();
        assertEq(handler.successfulDistributions(), 1);
        handler.claim(5, false, false);
        assertEq(handler.successfulClaims(), 1);
        invariant_claimedPlusOwedPlusHeldEqualsNotified();
        invariant_hookFeesMatchIndependentSwapAndDonationLedger();
        invariant_supplyNFTBackingAndExcludedRecipients();
    }

    function test_unnotifiedPaymentsCannotPolluteRewardsBeforeOrAfterLastBurn() public {
        handler.burnAll();
        handler.notify(1 ether);
        for (uint8 selector; selector < 4; ++selector) {
            handler.rejectUnnotifiedPayment(selector, 1);
        }
        handler.receiveTokens(0, uint96(UNIT));
        handler.notify(2 ether);
        for (uint8 selector; selector < 4; ++selector) {
            handler.rejectUnnotifiedPayment(selector, 1 ether);
        }
        handler.burnAll();
        assertEq(token.owed(handler.actors(0)), 2 ether);
        assertEq(token.owed(token.TREASURY()), 1 ether);
        for (uint8 selector; selector < 4; ++selector) {
            handler.rejectUnnotifiedPayment(selector, 2 ether);
        }
        assertEq(handler.rejectedUnnotifiedPayments(), 12);
        invariant_claimedPlusOwedPlusHeldEqualsNotified();
        handler.claim(0, true, false);
        handler.claim(5, true, false);
        assertEq(handler.totalPaid(), 3 ether);
        assertEq(address(token).balance, 0);
        invariant_claimedPlusOwedPlusHeldEqualsNotified();
        invariant_hookFeesMatchIndependentSwapAndDonationLedger();
        invariant_supplyNFTBackingAndExcludedRecipients();
    }
}
