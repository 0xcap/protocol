// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

interface ITreasury {

	function receiveETH() external payable;

	function fundOracle(address oracle, uint256 amount) external;

}