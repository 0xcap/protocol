// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "hardhat/console.sol";

import "./interfaces/IOracle.sol";
import "./interfaces/ITreasury.sol";
import "./interfaces/ITrading.sol";

contract Oracle is IOracle {

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

	bool isActive = true;

	constructor() {
		owner = msg.sender;
	}

	// 
	function openPosition(
		uint256 positionId,
		uint256 price
	) external onlyOracle {

		try ITrading(trading).openPosition(positionId, price) {

		} catch {
			ITrading(trading).deletePosition(positionId);
		}
	}

	function closePosition(
		uint256 positionId,
		uint256 price
	) external onlyOracle {

		try ITrading(trading).closePosition(positionId, price) {

		} catch {
			ITrading(trading).deleteOrder(positionId);
		}
	}

	// Owner methods

	function setParams(
		uint256 _requestsPerFunding, 
		uint256 _costPerRequest,
		bool _isActive
	) external onlyOwner {
		requestsPerFunding = _requestsPerFunding;
		costPerRequest = _costPerRequest;
		isActive = _isActive;
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