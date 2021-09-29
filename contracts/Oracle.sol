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

	event SettlementError(
		uint256 indexed orderId,
		string reason,
		bool isClose
	);

	constructor() {
		owner = msg.sender;
	}

	function getPendingOrderIds() external view onlyOracle returns(
		uint256[] memory,
		uint256[] memory,
		uint256[] memory, 
		uint256[] memory
	) {
		return ITrading(trading).getPendingOrderIds();
	}

	function openPosition(
		uint256 positionId,
		uint256 price
	) external onlyOracle {
		try ITrading(trading).openPosition(positionId, price) {

		} catch Error(string memory reason) {
			ITrading(trading).deletePendingPosition(positionId);
			emit SettlementError(
				positionId,
				reason,
				false
			);
		}
		_checkRequests();
	}

	function closePosition(
		uint256 orderId,
		uint256 price
	) external onlyOracle {
		try ITrading(trading).closePosition(orderId, price) {

		} catch Error(string memory reason) {
			ITrading(trading).deletePendingOrder(orderId);
			emit SettlementError(
				orderId,
				reason,
				true
			);
		}
		_checkRequests();
	}

	function _checkRequests() internal {
		requestsSinceFunding++;
		if (requestsSinceFunding >= requestsPerFunding) {
			requestsSinceFunding = 0;
			ITreasury(treasury).fundOracle(oracle, costPerRequest * requestsPerFunding);
		}
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