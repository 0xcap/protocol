// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

interface ITrading {

	function fundVault() external payable;

	function settleNewPosition(
		uint256 positionId,
		uint256 price
	) external;

	function cancelPosition(uint256 positionId) external;

	function settleCloseOrder(
		uint256 positionId, 
		uint256 price
	) external;

	function cancelOrder(uint256 positionId) external;

	function liquidatePositions(
		uint256[] calldata positionIds,
		uint256[] calldata prices
	) external;

	function getPendingOrderIds() external view returns(
		uint256[] memory openOrderIds,
		uint256[] memory openOrderProductIds,
		uint256[] memory closeOrderIds, 
		uint256[] memory closeOrderProductIds
	);

}