// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {SafeCast} from "v4-core/src/libraries/SafeCast.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {ReentrancyGuard} from "./ReentrancyGuard.sol";
import {IRewardReceiver} from "./interfaces/IRewardReceiver.sol";

/// @title SwarmlingsHook
/// @notice Fixed 1.25% ETH hook fee for NFT holders, on top of the IMD pool's 1.25% LP
/// fee (1% launch payer / 0.25% IMD): nominal 2.5% total. No admin can change anything.
/// The first native pool initialized binds LING permanently. Deploy and initialize atomically.
/// Swap callbacks only call PoolManager.mint; no payouts or third-party calls occur there.
contract SwarmlingsHook is IUnlockCallback, ReentrancyGuard {
    using PoolIdLibrary for PoolKey;
    using SafeCast for uint256;

    uint256 public constant BUY_FEE_BPS = 125;
    uint256 public constant SELL_FEE_BPS = 125;
    uint256 public constant MIN_DISTRIBUTE = 0.01 ether;

    IPoolManager public immutable poolManager;
    PoolId public launchPool;
    bool public launchPoolSet;
    address public LING;
    uint256 public distributed;
    bool private _expectingUnlock;

    error OnlyPoolManager();
    error UnexpectedUnlock();
    error PartialFill();
    error BelowMinimum();

    event LaunchPoolBound(PoolId indexed poolId, address indexed ling);
    event FeeCollected(uint256 amount);
    event Distributed(uint256 amount);

    constructor(IPoolManager manager) {
        poolManager = manager;
        Hooks.validateHookPermissions(IHooks(address(this)), getHookPermissions());
    }

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert OnlyPoolManager();
        _;
    }

    function getHookPermissions() public pure returns (Hooks.Permissions memory p) {
        p.afterInitialize = true;
        p.beforeSwap = true;
        p.afterSwap = true;
        p.beforeSwapReturnDelta = true;
        p.afterSwapReturnDelta = true;
    }

    /// @notice Authorized initialization never rejects any PoolKey or calls its currencies.
    function afterInitialize(address, PoolKey calldata key, uint160, int24) external onlyPoolManager returns (bytes4) {
        if (!launchPoolSet && Currency.unwrap(key.currency0) == address(0)) {
            launchPoolSet = true;
            launchPool = key.toId();
            LING = Currency.unwrap(key.currency1);
            emit LaunchPoolBound(launchPool, LING);
        }
        return IHooks.afterInitialize.selector;
    }

    function beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        if (_isLaunch(key) && _ethSpecified(params)) {
            uint256 fee = _specifiedFee(params);
            int128 feeDelta = fee.toInt128();
            _collect(fee);
            return (IHooks.beforeSwap.selector, toBeforeSwapDelta(feeDelta, 0), 0);
        }
        return (IHooks.beforeSwap.selector, BeforeSwapDelta.wrap(0), 0);
    }

    function afterSwap(address, PoolKey calldata key, SwapParams calldata params, BalanceDelta delta, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, int128)
    {
        if (!_isLaunch(key)) return (IHooks.afterSwap.selector, 0);
        if (_ethSpecified(params)) {
            // This is core's raw pool delta, before the hook fee is subtracted.
            if (int256(delta.amount0()) != params.amountSpecified + int256(_specifiedFee(params))) {
                revert PartialFill();
            }
            return (IHooks.afterSwap.selector, 0);
        }
        int256 ethDelta = int256(delta.amount0());
        uint256 gross = uint256(ethDelta < 0 ? -ethDelta : ethDelta);
        uint256 fee = gross * (params.zeroForOne ? BUY_FEE_BPS : SELL_FEE_BPS) / 10000;
        int128 feeDelta = fee.toInt128();
        _collect(fee);
        return (IHooks.afterSwap.selector, feeDelta);
    }

    /// @notice All outstanding native ETH claims, including unsolicited claim donations.
    function pendingFees() public view returns (uint256) {
        return poolManager.balanceOf(address(this), 0);
    }

    /// @notice Lifetime ETH claims received. Derived to keep the ledger exact even when
    /// another ERC6909 holder transfers claims here without a callback.
    function totalFees() public view returns (uint256) {
        return distributed + pendingFees();
    }

    /// @notice Permissionless redemption of ALL pending fees into LING's holder reward ledger.
    /// Must start its own manager unlock. Failure at any step restores claims and accounting.
    function distribute() external nonReentrant {
        uint256 amount = pendingFees();
        if (amount < MIN_DISTRIBUTE) revert BelowMinimum();
        _expectingUnlock = true;
        poolManager.unlock(abi.encode(amount));
        if (_expectingUnlock) revert UnexpectedUnlock();
        distributed += amount;
        IRewardReceiver(LING).notifyReward{value: amount}();
        emit Distributed(amount);
    }

    function unlockCallback(bytes calldata data) external onlyPoolManager returns (bytes memory) {
        if (!_expectingUnlock) revert UnexpectedUnlock();
        _expectingUnlock = false;
        uint256 amount = abi.decode(data, (uint256));
        poolManager.burn(address(this), 0, amount);
        poolManager.take(Currency.wrap(address(0)), address(this), amount);
        return "";
    }

    receive() external payable onlyPoolManager {}

    function _isLaunch(PoolKey calldata key) private view returns (bool) {
        return launchPoolSet && PoolId.unwrap(key.toId()) == PoolId.unwrap(launchPool);
    }

    function _ethSpecified(SwapParams calldata params) private pure returns (bool) {
        return params.zeroForOne == (params.amountSpecified < 0);
    }

    function _specifiedFee(SwapParams calldata params) private pure returns (uint256) {
        uint256 magnitude =
            params.amountSpecified < 0 ? uint256(-(params.amountSpecified + 1)) + 1 : uint256(params.amountSpecified);
        return FullMath.mulDiv(magnitude, params.zeroForOne ? BUY_FEE_BPS : SELL_FEE_BPS, 10000);
    }

    function _collect(uint256 fee) private {
        if (fee == 0) return;
        poolManager.mint(address(this), 0, fee);
        emit FeeCollected(fee);
    }
}
