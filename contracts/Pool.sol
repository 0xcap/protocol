// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "hardhat/console.sol";

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/Address.sol";

import "./libraries/Price.sol";

import "./interfaces/IPool.sol";
import "./interfaces/ITrading.sol";

contract Pool is IPool {

	using SafeERC20 for IERC20; 
    using Address for address payable;

	address public owner;
	address public trading;
	address public clp;

	uint256 public withdrawFee = 15; // 0.15%

    address public currency;

    uint256 public utilizationMultiplier; // in bps

    uint256 public maxDailyDrawdown = 3000; // 30%
    uint256 public checkpointBalance;
    uint256 public checkpointTimestamp;

    // Staking

    address public rewards; // contract

    mapping(address => uint256) private balances; // account => amount staked
    uint256 public clpSupply;

    mapping(address => uint256) lastStaked;
    uint256 public minStakingTime;

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

	function getUtlization() public view returns(uint256) {
		uint256 activeMargin = ITrading(trading).getActiveMargin(currency);
		uint256 currentBalance = IERC20(currency).balanceOf(address(this));
		return activeMargin * utilizationMultiplier / currentBalance; // in bps
	}

	function mintAndStakeCLP(uint256 amount) external returns(uint256) {

		uint256 currentBalance = IERC20(currency).balanceOf(address(this));

		// Pool needs approval to spend from sender
        IERC20(currency).safeTransferFrom(msg.sender, address(this), amount);

        uint256 CLPAmountToMint = currentBalance == 0 ? amount : amount * clpSupply / currentBalance;

        // mint CLP
        IMintableToken(clp).mint(address(this), CLPAmountToMint);
        _stake(CLPAmountToMint);

        return CLPAmountToMint;

	}

	function unstakeAndBurnCLP(uint256 amount) external returns(uint256) {

		require(amount > 0, "!amount");

		_unstake(amount);

		uint256 currentBalance = IERC20(currency).balanceOf(address(this));
		uint256 utlization = getUtlization();
		require(utlization < 10**4, "!utilization");
		
		uint256 availableBalance = currentBalance * (10**4 - utlization);

		// Amount of currency (weth, usdc, etc) to send user
		uint256 amountToSend = amount * currentBalance / clpSupply;
        uint256 amountAfterFee = amountToSend * (10**4 - withdrawFee);

        require(amountAfterFee <= availableBalance, "!balance");

		// burn CLP
		IMintableToken(clp).burn(address(this), amount);

		// transfer token out
		IERC20(currency).safeTransfer(msg.sender, amountAfterFee);

		return amountAfterFee;
		
	}

	function _stake(uint256 amount) internal {
		
		// just minted CLP with amount = amount and sent to this contract
		require(amount > 0, "!amount");
		lastStaked[msg.sender] = block.timestamp;

		IRewards(rewards).updateRewards(msg.sender);

		clpSupply += amount;
		balances[msg.sender] += amount;

	}

	function _unstake(uint256 amount) internal {

		require(lastStaked[msg.sender] > block.timestamp + minStakingTime, "!cooldown");
		require(amount > 0, "!amount");

		IRewards(rewards).updateRewards(msg.sender);

		require(amount <= balances[msg.sender], "!balance");

		clpSupply -= amount;
		balances[msg.sender] -= amount;

	}

	function getStakedSupply() external {
		return clpSupply;
	}

	function getStakedBalance(address account) external {
		return balances[account];
	}

}