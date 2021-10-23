// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

interface IReferrals {
    function setReferrer(address referredUser, address referrer) external;
    function getReferrerOf(address user) external view returns(address);
    function notifyRewardReceived(address referredUser, address currency, uint256 referredReward, uint256 referrerReward) external;
}