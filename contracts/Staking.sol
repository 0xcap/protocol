// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "hardhat/console.sol";

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/Address.sol";

import "./interfaces/IPool.sol";
import "./interfaces/ITrading.sol";

// keeps track of staked balances for users (not rewards) across all staking tokens

contract Staking is IStaking {

	using SafeERC20 for IERC20; 
    using Address for address payable;

	address public owner;
	address public trading;
	address public clp;
	address public staking;

	mapping(address => bool) stakingTokens; // address => true
	mapping (address => address[]) rewardTokens; // staking token => supported reward tokens

	mapping(address => mapping(address => uint256)) private balances; // stakingToken => account => amount staked
	mapping(address => uint256) private totalSupply; // stakingToken => amount staked

	constructor() {
		owner = msg.sender;
	}

	function stake(address stakingToken, uint256 amount) external {
		_stake(msg.sender, stakingToken, amount, false);
	}

	function stakeForAccount(address account, address stakingToken, uint256 amount) external onlyPool {
		_stake(account, stakingToken, amount, false);
	}

	function stakeMinted(address account, address stakingToken, uint256 amount) external onlyPool {
		// just minted stakingToken with amount = amount and sent to this contract

		_stake(account, stakingToken, amount, true);
	}

	function _stake(address account, address stakingToken, uint256 amount, bool noTransfer) internal {

		require(amount > 0, "!amount");
		require(stakingTokens[stakingToken], "!stakingToken");

		_updateRewards(stakingToken);

		totalSupply[stakingToken] += amount;
		balances[stakingToken][account] += amount;

		if (!noTransfer) {
			// Owner needs to approve this contract to spend their CLP
			IERC20(stakingToken).safeTransferFrom(account, address(this), amount);
		}

	}

	function unstakeForAccount(address account, address stakingToken, uint256 amount, bool noTransfer) external onlyPool {
		_unstake(account, stakingToken, amount, noTransfer);
	}

	function _unstake(address account, address stakingToken, uint256 amount, bool noTransfer) internal {
		
		require(amount > 0, "!amount");
		require(stakingTokens[stakingToken], "!stakingToken");

		_updateRewards(stakingToken);

		require(amount <= balances[stakingToken][account], "!balance");

		totalSupply[stakingToken] -= amount;
		balances[stakingToken][account] -= amount;

		if (!noTransfer) {
			IERC20(stakingToken).safeTransfer(account, amount);
		}

	}

	function collectRewards(address stakingToken) external {

		require(stakingTokens[stakingToken], "!stakingToken");

		_updateRewards(stakingToken);

		for (uint256 i = 0; i < rewardTokens[stakingToken].length; i++) {
			address rewardsContract = rewardsContracts[stakingToken][token];
			IRewards(rewardsContract).sendReward(msg.sender);
		}

	}

	function getStakedSupply(address stakingToken) external {
		return totalSupply[stakingToken];
	}

	function getStakedBalance(address stakingToken, address account) external {
		return balances[stakingToken][msg.sender];
	}

	function getClaimableRewards(address stakingToken, address account) external view returns(uint256[] memory _rewards) {
		uint256 length = rewardTokens[stakingToken].length;
		_rewards = new uint256[](length);
		for (uint256 i = 0; i < length; i++) {
			address rewardsContract = rewardsContracts[stakingToken][token];
			_rewards[i] = IRewards(rewardsContract).getClaimableReward(msg.sender);
		}
		return _rewards; // array of reward amounts, 1 for each reward token for this staking token
	}

	function _updateRewards(address stakingToken) internal {
		for (uint256 i = 0; i < rewardTokens[stakingToken].length; i++) {
			address rewardsContract = rewardsContracts[stakingToken][token];
			IRewards(rewardsContract).updateRewards(msg.sender);
		}
	}

}