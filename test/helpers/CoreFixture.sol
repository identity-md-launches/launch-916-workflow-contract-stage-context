// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {Deployers} from "test/vendor/v4-core/test/utils/Deployers.sol";
import {PoolSwapTest} from "test/vendor/v4-core/src/test/PoolSwapTest.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {Swarmlings} from "src/Swarmlings.sol";
import {SwarmlingsHook} from "src/SwarmlingsHook.sol";
import {DN404Mirror} from "dn404/src/DN404Mirror.sol";
import {HookDeployer} from "./HookDeployer.sol";

/// @dev Independent oracle reads the manager's RAW pool deltas, before hook fees.
/// It never infers a fee from the hook's totalFees/pendingFees implementation.
library CoreSwapOracle {
    bytes32 constant SWAP_EVENT = keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)");

    function rawSwap(Vm.Log[] memory logs, address manager)
        internal
        pure
        returns (int128 raw0, int128 raw1, uint24 lpFee)
    {
        uint256 found;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == manager && logs[i].topics[0] == SWAP_EVENT) {
                (raw0, raw1,,,, lpFee) = abi.decode(logs[i].data, (int128, int128, uint160, uint128, int24, uint24));
                ++found;
            }
        }
        require(found == 1, "expected one real core swap");
    }

    function fee(uint8 mode, uint256 specified, int128 raw0) internal pure returns (uint256) {
        uint256 basis = mode == 0 || mode == 3 ? specified : uint256(raw0 < 0 ? -int256(raw0) : int256(raw0));
        return basis / 80; // Exactly 125 / 10,000, rounded down.
    }

    function params(uint8 mode, uint256 amount) internal pure returns (SwapParams memory) {
        return SwapParams(
            mode < 2,
            mode % 2 == 0 ? -int256(amount) : int256(amount),
            mode < 2 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        );
    }
}

abstract contract CoreFixture is Deployers, HookDeployer {
    Swarmlings internal token;
    SwarmlingsHook internal hook;
    DN404Mirror internal mirror;
    address internal trader = makeAddr("core router trader");
    uint256 internal constant UNIT = 300_000e18;
    int24 internal constant INITIAL_TICK = 138180;

    function _deploy() internal {
        deployFreshManagerAndRouters();
        token = new Swarmlings();
        mirror = DN404Mirror(payable(token.mirrorERC721()));
        hook = deployHook(manager);
        key = PoolKey(Currency.wrap(address(0)), Currency.wrap(address(token)), 12500, 60, IHooks(address(hook)));
        token.approve(address(modifyLiquidityRouter), type(uint256).max);
        vm.prank(trader);
        token.approve(address(swapRouter), type(uint256).max);
        vm.deal(address(this), 100_000 ether);
        vm.deal(trader, 100_000 ether);
    }

    function _seed(bool tokenOnly) internal {
        manager.initialize(key, TickMath.getSqrtPriceAtTick(INITIAL_TICK));
        modifyLiquidityRouter.modifyLiquidity{value: tokenOnly ? 0 : 1000 ether}(
            key,
            ModifyLiquidityParams(
                INITIAL_TICK - 30000, tokenOnly ? INITIAL_TICK : INITIAL_TICK + 30000, 3e23, bytes32(0)
            ),
            ""
        );
        assertEq(mirror.balanceOf(address(manager)), 0);
    }
}
