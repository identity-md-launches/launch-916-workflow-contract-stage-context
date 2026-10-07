// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {Swarmlings} from "../src/Swarmlings.sol";
import {SwarmlingsHook} from "../src/SwarmlingsHook.sol";
import {DN404Mirror} from "dn404/src/DN404Mirror.sol";
import {HookDeployer} from "./helpers/HookDeployer.sol";
import {V4TestRouter} from "./helpers/V4TestRouter.sol";

/// @dev Reference ledger credits wallets by NFT counts at each notification. It never uses
/// rewardDebt, owed or pending to compute entitlements, and never moves rewards on transfers.
contract ConservationHandler is Test {
    Swarmlings public token;
    DN404Mirror public mirror;
    SwarmlingsHook public hook;
    V4TestRouter public router;
    PoolKey private key;
    address[3] public actors = [address(0x111), address(0x222), address(0x333)];
    mapping(address => uint256) public allocatedScaled;
    mapping(address => uint256) public paid;
    uint256 public notified;
    uint256 public ghostFees;
    uint256 public ghostDistributed;
    uint256 constant UNIT = 300_000e18;

    constructor(Swarmlings t, SwarmlingsHook h, V4TestRouter r, PoolKey memory k) {
        token = t;
        mirror = DN404Mirror(payable(t.mirrorERC721()));
        hook = h;
        router = r;
        key = k;
        token.approve(address(r), type(uint256).max);
    }

    function donate(uint96 seed) external {
        uint256 amount = bound(seed, 0, 1 ether);
        _allocate(amount);
        token.notifyReward{value: amount}();
    }

    function swapAndMaybeDistribute(uint96 seed, bool distributeNow) external {
        uint256 amount = bound(seed, 1000, 1 ether);
        router.swap(key, SwapParams(true, -int256(amount), TickMath.MIN_SQRT_PRICE + 1));
        ghostFees += amount * 125 / 10000;
        if (distributeNow && hook.pendingFees() >= hook.MIN_DISTRIBUTE()) {
            uint256 payout = ghostFees - ghostDistributed;
            _allocate(payout);
            ghostDistributed += payout;
            hook.distribute();
        }
    }

    function transferERC20(uint8 fromSeed, uint8 toSeed, uint96 amountSeed) external {
        address from = actors[fromSeed % 3];
        address to = toSeed % 4 == 3 ? address(this) : actors[toSeed % 3];
        uint256 amount = bound(amountSeed, 0, token.balanceOf(from));
        vm.prank(from);
        token.transfer(to, amount);
    }

    function receiveLING(uint8 actorSeed, uint96 amountSeed) external {
        token.transfer(actors[actorSeed % 3], bound(amountSeed, 0, 2 * UNIT));
    }

    function transferNFT(uint8 fromSeed, uint8 toSeed, uint256 idSeed) external {
        address from = actors[fromSeed % 3];
        address to = actors[toSeed % 3];
        uint256[] memory all = token.ownedIds(from, 0, 3333);
        if (all.length == 0) return;
        uint256 id = all[idSeed % all.length];
        vm.prank(from);
        mirror.transferFrom(from, to, id);
    }

    function skipNFT(uint8 actorSeed, bool skip) external {
        vm.prank(actors[actorSeed % 3]);
        token.setSkipNFT(skip);
    }

    function claim(uint8 actorSeed) external {
        address actor = actorSeed % 4 == 3 ? token.TREASURY() : actors[actorSeed % 3];
        uint256[] memory all = token.ownedIds(actor, 0, 3333);
        uint256 expected = allocatedScaled[actor] / 1e36 - paid[actor];
        uint256 balanceBefore = actor.balance;
        vm.prank(actor);
        token.claim(all);
        assertEq(actor.balance - balanceBefore, expected, "reference reward allocation");
        paid[actor] += expected;
    }

    function _allocate(uint256 amount) private {
        notified += amount;
        uint256 n = mirror.totalSupply();
        if (n == 0) {
            allocatedScaled[token.TREASURY()] += amount * 1e36;
        } else {
            uint256 perNFT = amount * 1e36 / n;
            for (uint256 i; i < 3; ++i) {
                allocatedScaled[actors[i]] += perNFT * mirror.balanceOf(actors[i]);
            }
        }
    }

    receive() external payable {}
}

contract ConservationInvariantTest is StdInvariant, Test, HookDeployer {
    Swarmlings token;
    DN404Mirror mirror;
    PoolManager manager;
    SwarmlingsHook hook;
    ConservationHandler handler;

    function setUp() public {
        token = new Swarmlings();
        mirror = DN404Mirror(payable(token.mirrorERC721()));
        manager = new PoolManager(address(this));
        hook = deployHook(manager);
        V4TestRouter router = new V4TestRouter(manager);
        PoolKey memory key =
            PoolKey(Currency.wrap(address(0)), Currency.wrap(address(token)), 12500, 60, IHooks(address(hook)));
        manager.initialize(key, 79228162514264337593543950336);
        vm.deal(address(router), 100_000 ether);
        token.approve(address(router), type(uint256).max);
        router.liquidity(key, ModifyLiquidityParams(-60000, 60000, 1000 ether, bytes32(0)));
        handler = new ConservationHandler(token, hook, router, key);
        for (uint256 i; i < 3; ++i) {
            token.transfer(handler.actors(i), 2 * token.UNIT());
        }
        token.transfer(address(handler), token.balanceOf(address(this)));
        vm.deal(address(handler), 1000 ether);
        bytes4[] memory selectors = new bytes4[](7);
        selectors[0] = handler.donate.selector;
        selectors[1] = handler.swapAndMaybeDistribute.selector;
        selectors[2] = handler.transferERC20.selector;
        selectors[3] = handler.receiveLING.selector;
        selectors[4] = handler.transferNFT.selector;
        selectors[5] = handler.skipNFT.selector;
        selectors[6] = handler.claim.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
        targetContract(address(handler));
    }

    function invariant_fixedSupplyAndNFTBacking() public view {
        uint256 total = token.balanceOf(address(handler)) + token.balanceOf(address(manager));
        uint256 nftTotal;
        for (uint256 i; i < 3; ++i) {
            address actor = handler.actors(i);
            total += token.balanceOf(actor);
            uint256 count = mirror.balanceOf(actor);
            assertLe(count * token.UNIT(), token.balanceOf(actor));
            nftTotal += count;
        }
        assertEq(total, 1e27);
        assertEq(token.totalSupply(), 1e27);
        assertEq(nftTotal, token.activeNFTs());
        assertLe(nftTotal, 3333);
    }

    function invariant_referenceRewardsAndETHConservation() public view {
        uint256 paid;
        for (uint256 i; i < 4; ++i) {
            address actor = i == 3 ? token.TREASURY() : handler.actors(i);
            uint256 payout = handler.paid(actor);
            paid += payout;
            assertEq(
                token.pending(actor, token.ownedIds(actor, 0, 3333)), handler.allocatedScaled(actor) / 1e36 - payout
            );
        }
        assertEq(address(token).balance + paid, handler.notified());
        assertEq(hook.totalFees(), handler.ghostFees());
        assertEq(hook.distributed(), handler.ghostDistributed());
        assertEq(hook.totalFees(), hook.distributed() + manager.balanceOf(address(hook), 0));
        assertEq(address(hook).balance, 0);
    }
}
