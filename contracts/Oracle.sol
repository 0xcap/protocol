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
		try ITrading(trading).settleNewPosition(positionId, price) {

		} catch Error(string memory reason) {
			ITrading(trading).cancelPosition(positionId);
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
		try ITrading(trading).settleCloseOrder(orderId, price) {

		} catch Error(string memory reason) {
			ITrading(trading).cancelOrder(orderId);
			emit SettlementError(
				orderId,
				reason,
				true
			);
		}
		_checkRequests();
	}

	function liquidatePositions(
		uint256[] calldata positionIds,
		uint256[] calldata _prices
	) external onlyOracle {
		ITrading(trading).liquidatePositions(positionIds, _prices);
	}

	function _checkRequests() internal {
		requestsSinceFunding++;
		if (requestsSinceFunding >= requestsPerFunding) {
			requestsSinceFunding = 0;
			ITreasury(treasury).fundOracle(oracle, costPerRequest * requestsPerFunding);
		}
	}

	function getChainlinkPrice(uint256 productId) external view returns(uint256) {
		return ITrading(trading).getChainlinkPrice(productId);
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