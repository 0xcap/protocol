// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

interface IRebates {
    function notifyRebateReceived(address user, address currency, uint256 amount) external;
}