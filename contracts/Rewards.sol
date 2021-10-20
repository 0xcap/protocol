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

	address stakingToken;
	address rewardToken;

	mapping(address => mapping(address => uint256)) private balances;
	mapping(address => uint256) private totalSupply; // stakingToken => amount staked

	uint256 public cumulativeRewardPerTokenStored;

	mapping(address => uint256) private claimableReward;
	mapping(address => uint256) private previousRewardPerToken;

	constructor() {
		owner = msg.sender;
	}

	function updateRewards(address account) external {

		uint256 rewardAmount = ITreasury(treasury).sendPendingRewards(stakingToken, rewardToken);

		uint256 supply = IStaking(staking).getStakedSupply(stakingToken);

		if (supply == 0) return;

		cumulativeRewardPerTokenStored += rewardAmount / supply;

		if (cumulativeRewardPerTokenStored == 0) return; // no rewards yet

		uint256 accountStakedBalance = IStaking(staking).getStakedBalance(stakingToken, account);

		claimableReward[account] += accountStakedBalance * (cumulativeRewardPerTokenStored - previousRewardPerToken[account]) / 10**18;

		previousRewardPerToken[account] = cumulativeRewardPerTokenStored;

	}

	function sendReward(address account) external onlyStaking {

		uint256 rewardToSend = claimableReward[account];
		claimableReward[account] = 0;

		if (rewardToSend > 0) {
			IERC20(rewardToken).safeTransfer(account, rewardToSend);
			emit ClaimedReward(account, stakingToken, rewardToken, rewardToSend);
		}

	}

	function getClaimableReward(address account) external view returns(uint256) {

		uint256 currentClaimableReward = claimableReward[account];

		uint256 pendingRewardAmount = ITreasury(treasury).getPendingRewards(stakingToken, rewardToken);

		uint256 supply = IStaking(staking).getStakedSupply(stakingToken);

		if (supply == 0) return 0;

		uint256 _rewardPerTokenStored = cumulativeRewardPerTokenStored + pendingRewardAmount / supply;

		if (_rewardPerTokenStored == 0) return 0; // no rewards yet

		uint256 accountStakedBalance = IStaking(staking).getStakedBalance(stakingToken, account);

		return currentClaimableReward + accountStakedBalance * (_rewardPerTokenStored - previousRewardPerToken[account]) / 10**18;
		
	}


}