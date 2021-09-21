+// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "hardhat/console.sol";

// ETH Vault
import "./interfaces/IVault.sol";
import "./interfaces/IERC20.sol";

contract Vault is IVault {

	// All amounts in 8 decimals

	// vault struct with params

	struct Vault {
		// TODO: revisit bytes distribution
		// 32 bytes
		uint96 maxSupply; // Maximum capacity in CLP. 12 bytes
		uint96 balance; // Deposits + return. 12 bytes
		// 32 bytes
		uint80 lastCheckpointBalance; // Used for max drawdown. 10 bytes
		uint80 lastCheckpointTime; // Used for max drawdown. 10 bytes
		uint32 maxDailyDrawdown; // In basis points (bps) 1000 = 10%. 4 bytes
	}

	address public owner; // Contract owner
	address public trading; // Trading contract
	address public clp; // CLP token

	uint256 public MIN_DEPOSIT = 100000; //0.001 ETH

	Vault private vault;

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

	// deposit amount in ETH and mint CLP
	function deposit() external payable {

		uint256 amount = msg.value / 10**10; // truncate to 8 decimals
		require(amount >= MIN_DEPOSIT, "!minimum");

		uint256 clpSupply = IERC20(clp).totalSupply();

		require(clpSupply + amount <= uint256(vault.maxSupply), "!cap");

		uint256 clpAmountToMint = vault.balance == 0 ? amount : amount * clpSupply / vault.balance;

		address user = msg.sender;

		IERC20(clp).mint(user, clpAmountToMint * 10**10);

		vault.balance += uint96(amount);

		emit Deposit(
			user, 
			amount,
			clpAmountToMint
		);

	}

	// withdraw (burn CLP) with redemption fee = 10%
	function withdraw(uint256 amount) external {

		// amount of CLP, 8 decimals
		require(amount >= MIN_DEPOSIT, "!minimum");

		uint256 clpSupply = IERC20(clp).totalSupply();

		require(amount * 10**10 <= clpSupply, "!supply");

		uint256 weiToRedeem = (10**4 - vault.redemptionFee) * amount * vault.balance * 10**16 / clpSupply;

		vault.balance -= uint96(weiToRedeem / 10**10);

		address user = msg.sender;

		IERC20(clp).burn(user, amount * 10**10);

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