// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "hardhat/console.sol";

import "./libraries/SafeERC20.sol";
import "./libraries/Address.sol";

import "./interfaces/IRouter.sol";
import "./interfaces/IPool.sol";
import "./interfaces/IRewards.sol";
import "./interfaces/ITrading.sol";
import "./interfaces/IWETH.sol";

contract Pool {

	using SafeERC20 for IERC20; 
    using Address for address payable;

    // Contracts
	address public owner;
	address public router;
	address public weth;
	address public trading;

	uint256 public withdrawFee = 15; // 0.15%

    address public currency;

    uint256 public utilizationMultiplier; // in bps

    uint256 public maxDailyDrawdown = 5000; // 50%
    uint256 public checkpointBalance;
    uint256 public checkpointTimestamp;

    address public rewards; // contract

    uint256 public maxCap = 10**7 * 10**18;

    mapping(address => uint256) private balances; // account => amount staked
    uint256 public totalSupply;

    mapping(address => uint256) lastDeposited;
    uint256 public minDepositTime = 1 hours;

    uint256 public openInterest;

    // Events
    event Deposit(
    	address indexed user, 
    	address indexed currency,
    	uint256 amount, 
    	uint256 clpAmount
    );
    event Withdraw(
    	address indexed user, 
    	address indexed currency,
    	uint256 amount, 
    	uint256 clpAmount
    );

	constructor(address _currency) {
		owner = msg.sender;
		currency = _currency;
	}

	// Governance methods

	function setOwner(address newOwner) external onlyOwner {
		owner = newOwner;
	}

	function setRouter(address _router) external onlyOwner {
		router = _router;
		trading = IRouter(router).trading();
		weth = IRouter(router).weth();
		rewards = IRouter(router).getPoolRewards(currency);
	}

	function setParams(
		uint256 _maxDailyDrawdown,
		uint256 _minDepositTime,
		uint256 _utilizationMultiplier,
		uint256 _maxCap
	) external onlyOwner {
		maxDailyDrawdown = _maxDailyDrawdown;
		minDepositTime = _minDepositTime;
		utilizationMultiplier = _utilizationMultiplier;
		maxCap = _maxCap;
	}

	// Open interest
	function updateOpenInterest(uint256 amount, bool isDecrease) external onlyTrading {
		if (isDecrease) {
			if (openInterest <= amount) {
				openInterest = 0;
			} else {
				openInterest -= amount;
			}
		} else {
			openInterest += amount;
		}
	}

	// Methods

	// clp is virtual

	function deposit(uint256 amount) external payable returns(uint256) {

		uint256 currentBalance = IERC20(currency).balanceOf(address(this));

		if (currency == weth) { // User is sending ETH
			require(msg.value > 0, "!amount");
			amount = msg.value;
			IWETH(currency).deposit{value: msg.value}();
		} else {
			_transferIn(currency, amount);
		}

		require(amount > 0, "!amount");

		require(amount + currentBalance <= maxCap, "!max-cap");

		// So this doesn't return 0 when totalSupply = 0, which can happen with currentBalance > 0 e.g. trader closes losing position before pool is funded, || totalSupply == 0 is added
        uint256 clpAmountToMint = currentBalance == 0 || totalSupply == 0 ? amount : amount * totalSupply / currentBalance;

        require(clpAmountToMint > 0, "!amount");

        lastDeposited[msg.sender] = block.timestamp;

        IRewards(rewards).updateRewards(msg.sender);

        totalSupply += clpAmountToMint;
        balances[msg.sender] += clpAmountToMint;

        emit Deposit(
        	msg.sender,
        	currency,
        	amount,
        	clpAmountToMint
        );

        return clpAmountToMint;

	}

	function withdraw(uint256 currencyAmount) external returns(uint256) {

		require(currencyAmount > 0, "!amount");
		require(block.timestamp > lastDeposited[msg.sender] + minDepositTime, "!cooldown");

		IRewards(rewards).updateRewards(msg.sender);

		// Determine corresponding CLP amount

		uint256 currentBalance = IERC20(currency).balanceOf(address(this));
		require(currentBalance > 0 && totalSupply > 0, "!empty");

		uint256 utlization = getUtlization();
		require(utlization < 10**4, "!utilization");
		
		uint256 availableBalance = currentBalance * (10**4 - utlization) / 10**4;

		uint256 currencyAmountAfterFee = currencyAmount * (10**4 - withdrawFee) / 10**4;
		require(currencyAmountAfterFee <= availableBalance, "!available-balance");

		// CLP amount
		uint256 amount = currencyAmount * totalSupply / currentBalance;

		require(amount <= balances[msg.sender], "!clp-balance");

		totalSupply -= amount;
		balances[msg.sender] -= amount;

		// transfer token or ETH out
		if (currency == weth) { // WETH
			// Unwrap and send
			IWETH(currency).withdraw(currencyAmountAfterFee);
			payable(msg.sender).sendValue(currencyAmountAfterFee);
		} else {
			_transferOut(currency, msg.sender, currencyAmountAfterFee);
		}

		emit Withdraw(
			msg.sender,
			currency,
			currencyAmountAfterFee,
			amount
		);

		return currencyAmountAfterFee;
		
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

		if (currency == weth) {
			// Unwrap and send
			IWETH(currency).withdraw(amount);
			payable(destination).sendValue(amount);
		} else {
			_transferOut(currency, destination, amount);
		}

	}

	// To receive ETH from WETH
	fallback() external payable {}
	receive() external payable {}

	// Utils

	function _transferIn(address _currency, uint256 _amount) internal {
		// adjust decimals
		uint256 decimals = IERC20(_currency).decimals();
		if (decimals != 18) {
			_amount = _amount * (10**decimals) / (10**18);
		}
		IERC20(_currency).safeTransferFrom(msg.sender, address(this), _amount);
	}

	function _transferOut(address _currency, address to, uint256 _amount) internal {
		// adjust decimals
		uint256 decimals = IERC20(_currency).decimals();
		if (decimals != 18) {
			_amount = _amount * (10**decimals) / (10**18);
		}
		IERC20(_currency).safeTransfer(to, _amount);
	}

	// Getters

	function getUtlization() public view returns(uint256) {
		uint256 currentBalance = IERC20(currency).balanceOf(address(this));
		return openInterest * utilizationMultiplier / currentBalance; // in bps
	}

	function getCurrencyBalance(address account) external view returns(uint256) {
		if (totalSupply == 0) return 0;
		uint256 currentBalance = IERC20(currency).balanceOf(address(this));
		return balances[account] * currentBalance / totalSupply;
	}

	// In Clp
	function getBalance(address account) external view returns(uint256) {
		return balances[account];
	}

	// Modifier

	modifier onlyOwner() {
		require(msg.sender == owner, "!owner");
		_;
	}

	modifier onlyTrading() {
		require(msg.sender == trading, "!trading");
		_;
	}

}