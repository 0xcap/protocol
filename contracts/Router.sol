// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "./interfaces/ITreasury.sol";
import "./interfaces/ITrading.sol";
import "./interfaces/IRouter.sol";

contract Router {

	// Contract dependencies
	address public owner;
	address public trading;
	address public oracle;
	address public capPool;
	address public treasury;
	address public darkOracle;

	// Native currency
	address public weth;

	address[] public currencies;

	mapping(address => address) pools; // currency => contract
	mapping(address => address) poolRewards; // currency => contract
	mapping(address => address) capRewards; // currency => contract

	constructor() {
		owner = msg.sender;
	}

	function isSupportedCurrency(address currency) external view returns(bool) {
		return currency != address(0) && pools[currency] != address(0);
	}

	function currenciesLength() external view returns(uint256) {
		return currencies.length;
	}

	function getPool(address currency) external view returns(address) {
		return pools[currency];
	}

	function getPoolRewards(address currency) external view returns(address) {
		return poolRewards[currency];
	}

	function getCapRewards(address currency) external view returns(address) {
		return capRewards[currency];
	}

	// Setters

	function setCurrencies(address[] calldata _currencies) external onlyOwner {
		currencies = _currencies;
	}

	function setContracts(
		address _treasury,
		address _trading,
		address _capPool,
		address _oracle,
		address _darkOracle,
		address _weth
	) external onlyOwner {
		trading = _trading;
		capPool = _capPool;
		oracle = _oracle;
		weth = _weth;
		treasury = _treasury;
		darkOracle = _darkOracle;
	}

	function setPool(address currency, address _contract) external onlyOwner {
		pools[currency] = _contract;
	}

	function setPoolRewards(address currency, address _contract) external onlyOwner {
		poolRewards[currency] = _contract;
	}

	function setCapRewards(address currency, address _contract) external onlyOwner {
		capRewards[currency] = _contract;
	}

	function setOwner(address newOwner) external onlyOwner {
		owner = newOwner;
	}

	// Modifiers

	modifier onlyOwner() {
		require(msg.sender == owner, "!owner");
		_;
	}

}