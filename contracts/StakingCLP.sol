// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "hardhat/console.sol";

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/Address.sol";

import "./interfaces/IPool.sol";
import "./interfaces/ITrading.sol";

contract StakingCLP is IStaking {

	using SafeERC20 for IERC20; 
    using Address for address payable;

	address public owner;
	address public pool;

	address public rewards; // contract

	mapping(address => uint256) private balances; // account => amount staked
	uint256 public totalSupply;

	mapping(address => uint256) lastStakedCLP;
	uint256 public minCLPStakingTime;


	constructor() {
		owner = msg.sender;
	}

	function stake(address account, uint256 amount) external onlyPool {
		
		// just minted CLP with amount = amount and sent to this contract
		require(amount > 0, "!amount");
		lastStakedCLP[account] = block.timestamp;

		IRewards(rewards).updateRewards(msg.sender);

		totalSupply += amount;
		balances[account] += amount;

	}

	function unstake(address account, uint256 amount) external onlyPool {

		require(lastStakedCLP[msg.sender] > block.timestamp + minStakingTime, "!cooldown");
		require(amount > 0, "!amount");

		IRewards(rewards).updateRewards(msg.sender);

		require(amount <= balances[account], "!balance");

		totalSupply -= amount;
		balances[account] -= amount;

	}

	function getStakedSupply() external {
		return totalSupply;
	}

	function getStakedBalance(address account) external {
		return balances[msg.sender];
	}

}