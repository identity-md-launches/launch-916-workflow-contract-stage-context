// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @dev Local storage guard; each inheriting contract has its own lock.
abstract contract ReentrancyGuard {
    error ReentrantCall();

    bool private _entered;

    modifier nonReentrant() {
        if (_entered) revert ReentrantCall();
        _entered = true;
        _;
        _entered = false;
    }
}
