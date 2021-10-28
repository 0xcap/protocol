// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

interface IPool {
    function totalSupply() external view returns (uint256);
    function creditUserProfit(address destination, uint256 amount) external;
    function getBalance(address account) external view returns (uint256);
}