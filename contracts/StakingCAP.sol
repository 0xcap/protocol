// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "hardhat/console.sol";

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/Address.sol";

import "./interfaces/IPool.sol";
import "./interfaces/ITrading.sol";


contract StakingCAP is IStaking {

	using SafeERC20 for IERC20; 
    using Address for address payable;

	address public owner;
	address public trading;

	address public cap; // CAP address

	address[] rewardsContracts; // supported reward contracts

	mapping(address => uint256) private balances; // account => amount staked
	uint256 public totalSupply;

	constructor() {
		owner = msg.sender;
	}

	function stake(uint256 amount) internal {

		require(amount > 0, "!amount");

		_updateRewards();

		totalSupply += amount;
		balances[msg.sender] += amount;

		// Owner needs to approve this contract to spend their CLP
		IERC20(cap).safeTransferFrom(msg.sender, address(this), amount);

	}

	function unstake(uint256 amount) internal {
		
		require(amount > 0, "!amount");

		_updateRewards();

		require(amount <= balances[msg.sender], "!balance");

		totalSupply -= amount;
		balances[msg.sender] -= amount;

		IERC20(cap).safeTransfer(msg.sender, amount);

	}

	function getStakedSupply() external {
		return totalSupply;
	}

	function getStakedBalance(address account) external {
		return balances[msg.sender];
	}

	function _updateRewards(address stakingToken) internal {
		for (uint256 i = 0; i < rewardsContracts.length; i++) {
			IRewards(rewardsContracts[i]).updateRewards(msg.sender);
		}
	}

}