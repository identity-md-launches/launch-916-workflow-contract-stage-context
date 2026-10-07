// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface IRewardReceiver {
    function notifyReward() external payable;
}
