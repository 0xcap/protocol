// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "hardhat/console.sol";

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/Address.sol";

import "./interfaces/ITreasury.sol";
import "./interfaces/ITrading.sol";

contract Treasury is ITreasury {

	using SafeERC20 for IERC20; 
    using Address for address payable;

	// Contract dependencies
	address public owner;
	address public trading;
	address public oracle;
	address public pool;
	address public staking;
	address public weth;

	address[] stakingTokens;

	mapping(address => uint256) stakingTokenShare; // how much of total bps should go to CLP, CAP, vCAP stakers
	mapping(address => mapping(address => address)) stakingContracts; // stakingToken => rewardToken => contract
	uint256 public stakingRewardsBps = 9500; // = 95% of treasury income goes to rewards

	mapping(address => uint256) lastBalances; // per token

	constructor() {
		owner = msg.sender;
	}

	// Send pending rewards to staking contract
	function sendPendingRewards(address stakingToken, address token) external onlyStaking(stakingToken, token) returns(uint256) {
		IERC20(token).safeTransfer(msg.sender, pendingRewards[stakingToken][token]);
		pendingRewards[stakingToken][token] = 0;
	}

	function getPendingRewards(address stakingToken, address token) external view returns(uint256) {
		return pendingRewards[stakingToken][token];
	}

	function notifyFeeReceived(address token, uint256 amount) external onlyTrading {

		for (uint256 i = 0; i < stakingTokens.length; i++) {
			address stakingToken = stakingTokens[i];
			uint256 share = stakingTokenShare[stakingToken]; // in bps out of total stakingRewardsBps
			pendingRewards[stakingToken][token] += amount * stakingRewardsBps * share / 10**8;
		}

	}

	// Can be used right after sending a token to fund treasury without increasing pending rewards
	function updateLastBalance(address token) external onlyOwner {
		lastBalances[token] = IERC20(token).balanceOf(address(this));
	}

	function fundOracle(
		address destination, 
		uint256 amount
	) external override onlyOracle {
		IWETH(weth).withdraw(amount);
		payable(destination).sendValue(amount);
	}

	function sendToken(
		address token, 
		address destination, 
		uint256 amount
	) external onlyOwner {
		IERC20(token).transfer(destination, amount);
	}

	// Owner methods

	function setParams(
		uint256 _vaultThreshold
	) external onlyOwner {
		vaultThreshold = _vaultThreshold;
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