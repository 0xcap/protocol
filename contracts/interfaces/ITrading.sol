// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

interface ITrading {

	function fundVault() external payable;

	function openPosition(
		uint256 positionId,
		uint256 price
	) external;

	function deletePendingPosition(uint256 positionId) external;

	function closePosition(
		uint256 positionId, 
		uint256 price
	) external;

	function deletePendingOrder(uint256 positionId) external;

	function getPendingOrderIds() external view returns(
		uint256[] memory openOrderIds,
		uint256[] memory openOrderProductIds,
		uint256[] memory closeOrderIds, 
		uint256[] memory closeOrderProductIds
	);

}