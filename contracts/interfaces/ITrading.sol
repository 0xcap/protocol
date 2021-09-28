// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

interface ITrading {

	function fundVault() external payable;

	function openPosition(
		uint256 positionId,
		uint256 price
	) external;

	function deletePosition(uint256 positionId) external;

	function closePosition(
		uint256 positionId, 
		uint256 price
	) external;

	function deleteOrder(uint256 positionId) external;

}