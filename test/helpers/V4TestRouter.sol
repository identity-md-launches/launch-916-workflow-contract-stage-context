// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IERC20Minimal} from "v4-core/src/interfaces/external/IERC20Minimal.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwarmlingsHook} from "../../src/SwarmlingsHook.sol";

/// @dev Test-only settlement router. Pre-funded native ETH avoids refund noise in assertions.
contract V4TestRouter is IUnlockCallback {
    IPoolManager public immutable manager;

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    function swap(PoolKey memory key, SwapParams memory params) external returns (BalanceDelta) {
        return abi.decode(manager.unlock(abi.encode(uint8(0), msg.sender, key, abi.encode(params))), (BalanceDelta));
    }

    function liquidity(PoolKey memory key, ModifyLiquidityParams memory params) external returns (BalanceDelta) {
        return abi.decode(manager.unlock(abi.encode(uint8(1), msg.sender, key, abi.encode(params))), (BalanceDelta));
    }

    function donateClaims(PoolKey memory key, address to, uint256 amount) external {
        manager.unlock(abi.encode(uint8(2), msg.sender, key, abi.encode(to, amount)));
    }

    function nestedDistribute(PoolKey memory key) external {
        manager.unlock(abi.encode(uint8(3), msg.sender, key, bytes("")));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager));
        (uint8 op, address payer, PoolKey memory key, bytes memory args) =
            abi.decode(data, (uint8, address, PoolKey, bytes));
        BalanceDelta delta;
        if (op == 0) {
            delta = manager.swap(key, abi.decode(args, (SwapParams)), "");
        } else if (op == 1) {
            (delta,) = manager.modifyLiquidity(key, abi.decode(args, (ModifyLiquidityParams)), "");
        } else if (op == 2) {
            (address to, uint256 amount) = abi.decode(args, (address, uint256));
            manager.mint(address(this), 0, amount);
            manager.sync(Currency.wrap(address(0)));
            manager.settle{value: amount}();
            manager.transfer(to, 0, amount);
            return "";
        } else {
            SwarmlingsHook(payable(address(key.hooks))).distribute();
            return "";
        }
        _settle(key.currency0, delta.amount0(), payer);
        _settle(key.currency1, delta.amount1(), payer);
        return abi.encode(delta);
    }

    function _settle(Currency currency, int128 delta, address payer) private {
        if (delta > 0) {
            manager.take(currency, payer, uint256(int256(delta)));
        } else if (delta < 0) {
            uint256 amount = uint256(-int256(delta));
            manager.sync(currency);
            if (Currency.unwrap(currency) == address(0)) {
                manager.settle{value: amount}();
            } else {
                require(IERC20Minimal(Currency.unwrap(currency)).transferFrom(payer, address(manager), amount));
                manager.settle();
            }
        }
    }

    receive() external payable {}
}
