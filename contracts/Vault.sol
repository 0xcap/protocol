+// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "hardhat/console.sol";

// ETH Vault
import "./interfaces/IVault.sol";
import "./interfaces/IERC20.sol";

contract Vault is IVault {

	// All amounts in 8 decimals

	// staking and redemption periods, tracking balances by stake not user, max clp supply (cap)

	struct Vault {
		// TODO: revisit bytes distribution
		// 32 bytes
		uint96 maxSupply; // Maximum capacity in CLP. 12 bytes
		uint96 balance; // Deposits + return. 12 bytes
		// 32 bytes
		uint80 lastCheckpointBalance; // Used for max drawdown. 10 bytes
		uint80 lastCheckpointTime; // Used for max drawdown. 10 bytes
		uint32 maxDailyDrawdown; // In basis points (bps) 1000 = 10%. 4 bytes
		uint stakingPeriod;
		uint redemptionPeriod;
	}

	address public owner; // Contract owner
	address public trading; // Trading contract
	address public darkOracle; // DO

	uint256 public clpSupply;

	uint256 public MIN_DEPOSIT = 100000; //0.001 ETH

	int256 dailyPnl; // for max drawdown

	struct Stake {
		address owner;
		uint256 amount; // in CAP
		uint256 balance; // in "CLP"
		uint256 timestamp;
	}

	uint256 public nextStakeId;

	mapping(uint256 => Stake) stakes; // stake id => Stake

	Vault private vault;

	constructor() {
		owner = msg.sender;
		vault = Vault({
			maxSupply: 0,
			balance: 0,
			lastCheckpointBalance: 0,
			lastCheckpointTime: uint80(block.timestamp),
			maxDailyDrawdown: 0,
			redemptionFee: 1000, // 10%
			stakingPeriod: uint32(30 * 24 * 3600),
			redemptionPeriod: uint32(8 * 3600)
		});
	}

	// receive
	function receive() external payable onlyTrading {
		// TODO: may result in "dust" ETH that will need to be collected?
		vault.balance += uint96(msg.value / 10**10); // truncate to 8 decimals
		dailyPnl += msg.value / 10**10;
	}

	// pay
	function pay(address user, uint256 amount, bool skipDrawdown) external onlyTradingOrOracle {

		require(uint256(vault.balance) >= amount, "!vault-insufficient");

		dailyPnl -= int256(amount);

		if (!skipDrawdown) {
			require(
				int256(vault.lastCheckpointBalance) + dailyPnl >= uint256(vault.lastCheckpointBalance) * (10**4 - uint256(vault.maxDailyDrawdown)) / 10**4
			, "!max-drawdown");
		}

		vault.balance -= uint96(amount);

		payable(user).transfer(amount * 10**10);

	}

	// checkpoint
	function checkpoint() external onlyTrading {
		if (uint256(vault.lastCheckpointTime) < block.timestamp - 24 hours) {
			vault.lastCheckpointTime = uint80(block.timestamp);
			vault.lastCheckpointBalance = uint80(vault.balance);
			dailyPnl = 0;
		}
	}

	// Stakes msg.value in the vault and "mint" CLP
	function stake() external payable {

		uint256 amount = msg.value / 10**10; // truncate to 8 decimals
		require(amount >= MIN_DEPOSIT, "!minimum");

		uint256 clpAmountToMint = vault.balance == 0 ? amount : amount * clpSupply / vault.balance;

		require(clpSupply + clpAmountToMint <= uint256(vault.maxSupply), "!cap");

		address user = msg.sender;

		clpSupply += clpAmountToMint;

		vault.balance += uint96(amount);

		nextStakeId++;
		stakes[nextStakeId] = Stake({
			owner: user,
			balance: clpAmountToMint,
			amount: uint64(amount),
			timestamp: uint32(block.timestamp)
		});

		emit Staked(
			nextStakeId, 
			user, 
			amount
		);

	}

	// Redeems amount from Stake with id = stakeId, "burn" CLP
	function redeem(
		uint256 stakeId, 
		uint256 amount
	) external {

		require(amount <= uint256(vault.staked), "!staked");

		address user = msg.sender;

		Stake storage _stake = stakes[stakeId];
		require(_stake.owner == user, "!owner");

		uint256 amount = uint256(_stake.amount);

		if (user != owner) {
			uint256 timeDiff = block.timestamp - uint256(_stake.timestamp);
			require(
				(timeDiff > uint256(vault.stakingPeriod)) &&
				(timeDiff % uint256(vault.stakingPeriod)) < uint256(vault.redemptionPeriod)
			, "!period");
		}

		uint256 weiToRedeem = amount * vault.balance / clpSupply;

		vault.balance -= uint96(weiToRedeem);
		clpSupply -= amount;

		payable(user).transfer(weiToRedeem);

		emit Redeemed(
			stakeId, 
			user, 
			weiToRedeem
		);

		delete stakes[stakeId];

	}

	// TODO: owner method to update vault params

	modifier onlyTrading() {
		require(msg.sender == trading, "!trading");
		_;
	}

	modifier onlyTradingOrOracle() {
		require(msg.sender == trading || msg.sender == darkOracle, "!unauthorized");
		_;
	}

}