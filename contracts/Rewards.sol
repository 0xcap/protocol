// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "hardhat/console.sol";

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/Address.sol";

import "./interfaces/IPool.sol";
import "./interfaces/ITrading.sol";

// holds and pays out rewards for stakingToken in rewardToken

contract Rewards is IRewards {

	using SafeERC20 for IERC20; 
    using Address for address payable;

	address public staking;
	address public rewardToken;

	uint256 public cumulativeRewardPerTokenStored;
	uint256 public pendingReward;

	mapping(address => uint256) private claimableReward;
	mapping(address => uint256) private previousRewardPerToken;

	constructor() {
		owner = msg.sender;
	}

	function notifyRewardReceived(uint256 amount) external onlyTreasury {
		pendingReward += amount;
	}

	function updateRewards(address account) public {

		uint256 supply = IStaking(staking).getStakedSupply();

		if (supply == 0) return;

		cumulativeRewardPerTokenStored += pendingReward / supply;

		if (cumulativeRewardPerTokenStored == 0) return; // no rewards yet

		uint256 accountStakedBalance = IStaking(staking).getStakedBalance(account);

		claimableReward[account] += accountStakedBalance * (cumulativeRewardPerTokenStored - previousRewardPerToken[account]) / 10**18;

		previousRewardPerToken[account] = cumulativeRewardPerTokenStored;

		pendingReward = 0;

	}

	function collectRewards() external {

		updateRewards(msg.sender);

		uint256 rewardToSend = claimableReward[msg.sender];
		claimableReward[msg.sender] = 0;

		if (rewardToSend > 0) {
			IERC20(rewardToken).safeTransfer(msg.sender, rewardToSend);
			emit ClaimedReward(msg.sender, rewardToken, rewardToSend);
		}

	}

	function getClaimableReward() external view returns(uint256) {

		uint256 currentClaimableReward = claimableReward[msg.sender];

		uint256 supply = IStaking(staking).getStakedSupply();

		if (supply == 0) return 0;

		uint256 _rewardPerTokenStored = cumulativeRewardPerTokenStored + pendingReward / supply;

		if (_rewardPerTokenStored == 0) return 0; // no rewards yet

		uint256 accountStakedBalance = IStaking(staking).getStakedBalance(msg.sender);

		return currentClaimableReward + accountStakedBalance * (_rewardPerTokenStored - previousRewardPerToken[msg.sender]) / 10**18;
		
	}

}