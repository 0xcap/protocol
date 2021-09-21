+// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "hardhat/console.sol";

// CAP Vault
import "./interfaces/IStaking.sol";

contract Staking is IStaking {

	// params: a stake's cap balances, stake's stc balances, weekly ETH balance, weekly supply snapshots

	uint256 public maxMultiplier = 4;
	uint256 public maxStakePeriod = 4 years; // in seconds
	uint256 public minStakePeriod = 90 days; // in seconds

	uint256 public stcSupply;
	uint256 public stcMaxSupply;

	uint256 currentWeekId;

	address public owner; // Contract owner
	address public trading; // Trading contract
	address public cap; // CAP token contract

	uint256 public MIN_STAKE = 100000; //0.001 CAP
	uint256 public MAX_WEEK_LOOKBACK = 12;

	struct Stake {
		address owner;
		uint256 amount; // in CAP
		uint256 balance; // in "STC"
		uint256 period;
		uint256 timestamp;
	}

	uint256 public nextStakeId;

	mapping(uint256 => Stake) stakes; // stake id => Stake

	mapping(uint256 => uint256) weeklyRewards; // week id => accumulated ETH
	mapping(uint256 => uint256) supplySnapshots; // week id => total STC supply
	mapping(uint256 => mapping(uint256 => bool)) claimedRewards; // week id => stakeId => claimed or not

	constructor() {
		owner = msg.sender;
	}

	// receive
	function receive() external payable onlyTrading {
		// TODO: may result in "dust" ETH that will need to be collected?
		// Get week id
		uint256 weekId = block.timestamp / 7 days;
		if (weekId != currentWeekId) {
			snapshotStcSupply(weekId);
			currentWeekId = weekId;
		}
		weeklyRewards[weekId] += msg.value;
	}

	// stake
	function stake(uint256 amount, uint256 period) external {

		require(amount > MIN_STAKE, "!amount");
		require(period >= minStakePeriod, "!min-period");
		require(period <= maxStakePeriod, "!max-period");

		uint256 multiplier = 10000 + 10000 * (maxMultiplier - 1) * (period - minStakePeriod) / (maxStakePeriod - minStakePeriod); // in bps

		uint256 mintedSTC = amount * multiplier / 10000;
		stcSupply += mintedSTC;

		require(stcSupply <= stcMaxSupply, "!cap");

		address user = msg.sender;

		nextStakeId++;
		stakes[nextStakeId] = Stake({
			owner: user,
			amount: amount,
			balance: mintedSTC,
			period: period,
			timestamp: block.timestamp
		});

		IERC20(cap).transferFrom(user, address(this), amount);

		emit Staked(
			nextStakeId,
			user,
			amount,
			period,
			mintedSTC
		);

	}

	// collect ETH rewards
	function collect(uint256 stakeId) external {
		
		uint256 weiRewards = calculateRewards(stakeId);

		if (weiRewards > 0) {

			for (uint256 i = currentWeekId - 1; i > currentWeekId - MAX_WEEK_LOOKBACK - 1; i--) {
				claimedRewards[i][stakeId] = true;
			}

			payable(msg.sender).transfer(weiRewards);

			emit Collected(
				stakeId,
				msg.sender,
				weiRewards
			);

		}

	}

	// redeem CAP
	function redeem(uint256 stakeId) external {
		
		Stake memory stake = stakes[stakeId];

		require(stake.amount > 0, "!stake");
		require(block.timestamp > stake.timestamp + period, "!period");

		address user = msg.sender;

		IERC20(cap).transfer(user, stake.amount);

		stcSupply -= stake.balance;

		emit Redeemed(
			stakeId,
			user,
			stake.amount
		)

		delete stakes[stakeId];
		
	}

	function snapshotStcSupply(uint256 weekId) internal {
		supplySnapshots[weekId] = stcSupply;
	}

	function calculateRewards(uint256 stakeId) public returns(uint256) {
		Stake memory stake = stakes[stakeId];

		// Check last 12 weeks
		if (currentWeekId == 0) return 0;

		uint256 totalRewards;
		for (uint256 i = currentWeekId - 1; i > currentWeekId - MAX_WEEK_LOOKBACK - 1; i--) {
			if (claimedRewards[i][stakeId]) continue;
			uint256 weekRewards = weeklyRewards[i];
			uint256 weekSupplySnapshot = supplySnapshots[i];
			if (weekRewards == 0 || weekSupplySnapshot == 0) continue;
			// Check stake week
			uint256 stakeWeekId = stake.timestamp / 7 days;
			if (stakeWeekId > i) continue;
			if (stake.balance > weekSupplySnapshot) continue;
			totalRewards += weekRewards * stake.balance / weekSupplySnapshot;
		}

		return totalRewards;
	}

	// TODO: send rewards older than 12 weeks to vault

	// owner method to update vault params

	modifier onlyTrading() {
		require(msg.sender == trading, "!trading");
		_;
	}

}