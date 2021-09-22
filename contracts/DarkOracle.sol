+// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "hardhat/console.sol";

import "./interfaces/IDarkOracle.sol";

contract DarkOracle is IDarkOracle {

	address public owner; // Contract owner
	address public trading; // Trading contract
	address public vault; // vault contract
	address public oracle;

	uint256 public requestNumber;

	uint256 MAX_REQUESTS_BEFORE_FUNDING = 100;
	uint256 PER_REQUEST_COST = 0.0006 * 10**18; // in wei

	mapping(address => uint256) prices;
	mapping(address => uint256) timestamps;

	constructor() {
		owner = msg.sender;
	}

	function setLatestData(address[] calldata feeds, uint256[] calldata _prices) external onlyOracle {
		for (uint256 i = 0; i < feeds.length; i++) {
			prices[feeds[i]] = _prices[i];
			timestamps[feeds[i]] = block.timestamp;
		}
		requestNumber++;
		if (requestNumber == MAX_REQUESTS_BEFORE_FUNDING) {
			IVault(vault).pay(oracle, amount, true);
			requestNumber = 0;
		}
	}

	function getLatestData(address feed) external view returns (uint256, uint256) {
		return (prices[feed], timestamps[feed]);
	}

	// owner method to update params

	modifier onlyOwner() {
		require(msg.sender == owner, "!owner");
		_;
	}

	modifier onlyOracle() {
		require(msg.sender == oracle, "!oracle");
		_;
	}

}