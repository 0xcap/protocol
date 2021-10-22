// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/Address.sol";

import "./interfaces/ITreasury.sol";
import "./interfaces/ITrading.sol";

// Sends user queries to various contracts: staking, rewards, etc. Upgradeable

contract Router is IRouter {

	using SafeERC20 for IERC20; 
    using Address for address payable;

	// Contract dependencies
	address public owner;
	address public trading;
	address public oracle;
	address public pool;
	address public staking;
	address public weth;

	mapping(address => address) poolContracts; // currency => contract
	mapping(address => address) clpStakingContracts; // currency => contract
	mapping(address => address) clpRewardsContracts; // currency => contract
	mapping(address => address) capRewardsContracts; // currency => contract
	
	address public tradingContract;
	address public capStakingContract;
	address public rebatesContract;
	address public referralsContract;

	constructor() {
		owner = msg.sender;
	}

	function isSupportedCurrency(address currency) external view returns(bool) {
		return currency != address(0) && poolContracts[currency] != address(0);
	}

	/*
	List of actions
	user
	- submit new order
	- add margin
	- close position
	- stake currency for CLP (mint)
	- unstake CLP for currency (burn)
	- collect rewards for CLP-currency
	- collect rewards for CAP-currency
	- stake CAP
	- unstake CAP

	internal
	- getters for the contract addresses
	*/

	// Owner methods

	function setOwner(address newOwner) external onlyOwner {
		owner = newOwner;
	}

	function setTrading(address _trading) external onlyOwner {
		trading = _trading;
	}

	function setOracle(address _oracle) external onlyOwner {
		oracle = _oracle;
	}

	// Modifiers

	modifier onlyOwner() {
		require(msg.sender == owner, "!owner");
		_;
	}

	modifier onlyTrading() {
		require(msg.sender == trading, "!trading");
		_;
	}

	modifier onlyOracle() {
		require(msg.sender == oracle, "!oracle");
		_;
	}

}