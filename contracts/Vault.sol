+// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "hardhat/console.sol";

// ETH Vault
import "./interfaces/IVault.sol";
import "./interfaces/IERC20.sol";

// need to hold min amount of CAP to participate or redeem from the vault. CAP as a utility token to access the vault

contract Vault is IVault {

	// All amounts in 8 decimals

	// vault struct with params

	struct Vault {
		// TODO: revisit bytes distribution
		// 32 bytes
		uint96 balance; // Deposits + return. 12 bytes
		// 32 bytes
		uint80 lastCheckpointBalance; // Used for max drawdown. 10 bytes
		uint80 lastCheckpointTime; // Used for max drawdown. 10 bytes
		uint32 maxDailyDrawdown; // In basis points (bps) 1000 = 10%. 4 bytes
		uint32 redemptionFee;
		uint64 minHoldingTime;
		uint256 minCAPBalanceDeposit; // can be increased to limit vault size
		uint256 minCAPBalanceWithdraw;
	}

	address public owner; // Contract owner
	address public trading; // Trading contract
	address public cap; // CAP contract

	uint256 public clpSupply;

	uint256 public MIN_DEPOSIT = 100000; //0.001 ETH

	Vault private vault;

	mapping(address => uint256) clpBalances;
	mapping(address => uint256) lastDepositTime;

	constructor() {
		owner = msg.sender;
		vault = Vault({
			maxSupply: 0,
			balance: 0,
			lastCheckpointBalance: 0,
			lastCheckpointTime: uint80(block.timestamp),
			maxDailyDrawdown: 0,
			redemptionFee: 1000 // 10%
		});
	}

	// receive
	function receive() external payable onlyTrading {
		// TODO: may result in "dust" ETH that will need to be collected?
		vault.balance += uint96(msg.value / 10**10); // truncate to 8 decimals
	}

	// pay
	function pay(address user, uint256 amount) external onlyTrading {

		require(uint256(vault.balance) >= amount, "!vault-insufficient");
		require(
			uint256(vault.balance) - amount >= uint256(vault.lastCheckpointBalance) * (10**4 - uint256(vault.maxDailyDrawdown)) / 10**4
		, "!max-drawdown");

		vault.balance -= uint96(amount);

		payable(user).transfer(amount * 10**10);

	}

	// checkpoint
	function checkpoint() external onlyTrading {
		if (uint256(vault.lastCheckpointTime) < block.timestamp - 24 hours) {
			vault.lastCheckpointTime = uint80(block.timestamp);
			vault.lastCheckpointBalance = uint80(vault.balance);
		}
	}

	// deposit amount in ETH and "mint" CLP
	function deposit() external payable {

		uint256 amount = msg.value / 10**10; // truncate to 8 decimals
		require(amount >= MIN_DEPOSIT, "!minimum");

		address user = msg.sender;
		uint256 capBalance = IERC20(cap).balanceOf(user);
		require(capBalance >= vault.minCAPBalanceDeposit, "!insufficient-cap");

		uint256 clpAmountToMint = vault.balance == 0 ? amount : amount * clpSupply / vault.balance;

		lastDepositTime[user] = block.timestamp;

		clpSupply += clpAmountToMint;
		clpBalances[user] += clpAmountToMint;

		vault.balance += uint96(amount);

		emit Deposit(
			user, 
			amount,
			clpAmountToMint
		);

	}

	// withdraw with redemption fee
	function withdraw(uint256 amount) external {

		address user = msg.sender;

		// amount of CLP, 8 decimals
		require(amount >= MIN_DEPOSIT, "!minimum");
		require(amount <= clpSupply, "!supply");
		require(amount <= clpBalances[user], "!maximum");

		uint256 capBalance = IERC20(cap).balanceOf(user);
		require(capBalance >= vault.minCAPBalanceWithdraw, "!insufficient-cap");

		require(lastDepositTime[user] < block.timestamp - vault.minHoldingTime, "!min-holding");

		uint256 weiToRedeem = (10**4 - vault.redemptionFee) * amount * vault.balance * 10**6 / clpSupply;

		vault.balance -= uint96(weiToRedeem / 10**10);

		clpSupply -= amount;
		clpBalances[user] -= amount;

		payable(user).transfer(weiToRedeem);

		emit Withdraw(
			user,
			amount,
			weiToRedeem
		);

	}

	// TODO: owner method to update vault params

	modifier onlyTrading() {
		require(msg.sender == trading, "!trading");
		_;
	}

}