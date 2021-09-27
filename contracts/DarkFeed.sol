+// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "hardhat/console.sol";

import "./interfaces/IDarkFeed.sol";
import "./interfaces/ITreasury.sol";

contract DarkFeed is IDarkFeed {

	// Contract dependencies
	address public owner;
	address public trading;
	address public oracle;
	address public treasury;

	// Variables
	uint256 public requestsPerFunding = 100;
	uint256 public costPerRequest = 6 * 10**14; // 0.0006 ETH
	uint256 public requestsSinceFunding;

	// Mappings
	mapping(address => uint256) prices;
	mapping(address => uint256) timestamps;

	constructor() {
		owner = msg.sender;
	}

	// Price methods

	function setLatestData(
		address[] calldata feeds, 
		uint256[] calldata _prices
	) external onlyOracle {

		require(feeds.length == _prices.length && feeds.length > 0, "!length");
		
		for (uint256 i = 0; i < feeds.length; i++) {
			if (_prices[i] == 0) continue;
			prices[feeds[i]] = _prices[i];
			timestamps[feeds[i]] = block.timestamp;
		}
		
		requestsSinceFunding++;
		
		if (requestsSinceFunding >= requestsPerFunding) {
			requestsSinceFunding = 0;
			ITreasury(treasury).sendETH(oracle, costPerRequest * requestsPerFunding);
		}

	}

	function getLatestData(address feed) external view returns (uint256, uint256) {
		return (prices[feed], timestamps[feed]);
	}

	// Owner methods

	function setParams(
		uint256 _requestsPerFunding, 
		uint256 _costPerRequest
	) external onlyOwner {
		requestsPerFunding = _requestsPerFunding;
		costPerRequest = _costPerRequest;
	}

	function setOwner(address newOwner) external onlyOwner {
		owner = newOwner;
	}

	function setTrading(address _trading) external onlyOwner {
		trading = _trading;
	}

	function setOracle(address _oracle) external onlyOwner {
		oracle = _oracle;
	}

	function setTreasury(address _treasury) external onlyOwner {
		treasury = _treasury;
	}

	// Modifiers

	modifier onlyOwner() {
		require(msg.sender == owner, "!owner");
		_;
	}

	modifier onlyOracle() {
		require(msg.sender == oracle, "!oracle");
		_;
	}

}