// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "hardhat/console.sol";

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/Address.sol";

import "./libraries/Price.sol";

import "./interfaces/IPool.sol";
import "./interfaces/ITrading.sol";

// TODO: utlization ratio

contract Pool is IPool {

	using SafeERC20 for IERC20; 
    using Address for address payable;

	address public owner;
	address public trading;
	address public clp;
	address public staking;

	uint256 public withdrawFee = 15; // 0.15%

    address public currency;

    uint256 public maxDailyDrawdown = 3000; // 30%
    uint256 public checkpointBalance;
    uint256 public checkpointTimestamp;

	constructor() {
		owner = msg.sender;
	}

	function creditUserProfit(address destination, uint256 amount) external onlyTrading {
		
		uint256 currentBalance = IERC20(currency).balanceOf(address(this));

		// Check max drawdown

		if (checkpointBalance == 0) {
			checkpointBalance = currentBalance;
			checkpointTimestamp = block.timestamp;
		}
		if (block.timestamp >= checkpointTimestamp + 1 days) {
			checkpointTimestamp = block.timestamp;
		}
		if (currentBalance < checkpointBalance * (10**4 - maxDailyDrawdown) / 10**4) {
			revert("!drawdown");
		}

		IERC20(currency).safeTransfer(destination, amount);

	}

	function mintAndStakeCLP(uint256 amount) external returns(uint256) {

		address clp = IStaking(staking).clp();
		uint256 clpSupply = IERC20().totalSupply();
		uint256 currentBalance = IERC20(currency).balanceOf(address(this));

		// Pool needs approval to spend from sender
        IERC20(currency).safeTransferFrom(msg.sender, address(this), amount);

        uint256 CLPAmountToMint = currentBalance == 0 ? amount : amount * clpSupply / currentBalance;

        // mint directly to the CLP staking contract
        IMintableToken(clp).mint(staking, CLPAmountToMint);

        IStaking(staking).stake(msg.sender, CLPAmountToMint);

        return CLPAmountToMint;

	}

	function unstakeAndBurnCLP(uint256 amount) external returns(uint256) {

		require(amount > 0, "!amount");

		// Unstakes CLP and keeps them in the staking contract
		IStaking(staking).unstake(msg.sender, amount);

		uint256 currentBalance = IERC20(currency).balanceOf(address(this));
		uint256 clpSupply = IERC20(clp).totalSupply();

		// Amount of currency (weth, usdc, etc) to send user
		uint256 amountToSend = amount * currentBalance / clpSupply;
        uint256 amountAfterFee = amountToSend * (10**4 - withdrawFee);

		// burn directly in the staking contract. Pool can do this as minter role
		IMintableToken(clp).burn(staking, amount);

		// transfer token out
		IERC20(currency).safeTransfer(msg.sender, amountAfterFee);

		return amountAfterFee;
		
	}

}