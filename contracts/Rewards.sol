// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "hardhat/console.sol";

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/Address.sol";

import "./interfaces/IRouter.sol";
import "./interfaces/IPool.sol";
import "./interfaces/ITrading.sol";
import "./interfaces/IRewards.sol";
import "./interfaces/IStaking.sol";

contract Rewards {

	using SafeERC20 for IERC20; 
    using Address for address payable;

    address public owner;
	address public router;
	address public treasury;

	address public staking; // staking contract associated with these rewards
	address public currency; // rewards paid in this

	uint256 public cumulativeRewardPerTokenStored;
	uint256 public pendingReward;

	mapping(address => uint256) private claimableReward;
	mapping(address => uint256) private previousRewardPerToken;

	event CollectedReward(
		address user,
		address stakingContract,
		address currency,
		uint256 amount
	);

	constructor(address _staking, address _currency) {
		owner = msg.sender;
		staking = _staking;
		currency = _currency;
	}

	// Governance methods

	function setOwner(address newOwner) external onlyOwner {
		owner = newOwner;
	}

	function setRouter(address _router) external onlyOwner {
		router = _router;
		treasury = IRouter(router).treasury();
	}

	// Methods

	function notifyRewardReceived(uint256 amount) external onlyTreasury {
		pendingReward += amount;
	}

	function updateRewards(address account) public {

		uint256 supply = IStaking(staking).getStakedSupply();

		if (supply == 0) return;

		cumulativeRewardPerTokenStored += pendingReward * 10**18 / supply;

		if (cumulativeRewardPerTokenStored == 0) return; // no rewards yet

		uint256 accountStakedBalance = IStaking(staking).getStakedBalance(account);

		claimableReward[account] += accountStakedBalance * (cumulativeRewardPerTokenStored - previousRewardPerToken[account]) / 10**18;

		previousRewardPerToken[account] = cumulativeRewardPerTokenStored;

		pendingReward = 0;

	}

	function collectReward() external {

		updateRewards(msg.sender);

		uint256 rewardToSend = claimableReward[msg.sender];
		claimableReward[msg.sender] = 0;

		if (rewardToSend > 0) {
			IERC20(currency).safeTransfer(msg.sender, rewardToSend);
			emit CollectedReward(msg.sender, staking, currency, rewardToSend);
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

	modifier onlyOwner() {
		require(msg.sender == owner, "!owner");
		_;
	}

	modifier onlyTreasury() {
		require(msg.sender == treasury, "!treasury");
		_;
	}

}