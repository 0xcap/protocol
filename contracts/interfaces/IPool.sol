// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

interface IPool {
    function creditUserProfit(address destination, uint256 amount) external;
}