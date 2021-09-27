+// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "hardhat/console.sol";

// CAP Vault
import "./interfaces/IRewards.sol";

contract Rewards is IRewards {

	// pool of rewards sent from Trading that can be claimed weekly by any CAP holder with over 10 CAP. Like a dividend basically. Can be claimed for 24 hours after week is over, else return to the vault.

	uint256 public redemptionPeriod = 1 days; // in seconds

	address public owner; // Contract owner
	address public trading; // Trading contract
	address public cap; // CAP token contract
	address public vault; // Vault

	uint256 public MIN_CAP = 10**19; // 10 CAP

	mapping(uint256 => uint256) weeklyRewards; // week id => accumulated ETH
	mapping(uint256 => mapping(address => bool)) claimedRewards; // week id => user => claimed or not

	mapping(address => uint256) locked; // locked CAP per user

	uint256 totalLocked;

	constructor() {
		owner = msg.sender;
	}

	// receive
	function receive() external payable onlyTrading {
		// Get week id
		uint256 weekId = block.timestamp / 7 days;
		weeklyRewards[weekId] += msg.value;
	}

	function lockCAP(uint256 amount) external {
		IERC20(cap).transferFrom(msg.sender, address(this), amount);
		locked[msg.sender] += amount;
		totalLocked += amount;
	}

	function unlockCAP(uint256 amount) external {
		// require not to be in a redemption period to unlock CAP
		require(block.timestamp % 7 days > redemptionPeriod, "!redemption");
		IERC20(cap).transfer(msg.sender, amount);
		locked[msg.sender] -= amount;
		totalLocked -= amount;
	}

	// collect ETH rewards based on your share of CAP locked
	function claim() external {

		address user = msg.sender;

		uint256 previousWeekId = block.timestamp / 7 days - 1;

		require(!claimed[previousWeekId][user], "!claimed");

		require(block.timestamp < ((previousWeekId + 1) * 7 days) + redemptionPeriod, "!period");
		
		require(locked[user] >= MIN_CAP, "!min-locked");

		uint256 share = 10000 * locked[user] / totalLocked;

		uint256 weiRewards = share * weeklyRewards[previousWeekId] / 10000;

		claimed[previousWeekId][user] = true;

		payable(user).transfer(weiRewards);

	}

	// send unclaimed rewards back to vault
	function backToVault(uint256 weekId) {

		uint256 previousWeekId = block.timestamp / 7 days - 1;
		require(weekId < previousWeekId, "!weekid");

		uint256 amount = weeklyRewards[weekId];

		if (amount > 0) {
			IVault(vault).receive{amount}();
		}

	}

	// owner method to update vault params

	modifier onlyTrading() {
		require(msg.sender == trading, "!trading");
		_;
	}

}