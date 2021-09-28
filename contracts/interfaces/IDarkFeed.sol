// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

interface IDarkFeed {

	function getLatestData(address feed) external view returns (uint256, uint256);

}