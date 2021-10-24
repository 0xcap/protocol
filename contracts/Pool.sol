// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "hardhat/console.sol";

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/Address.sol";

import "./interfaces/IRouter.sol";
import "./interfaces/IPool.sol";
import "./interfaces/IRewards.sol";
import "./interfaces/ITrading.sol";
import "./interfaces/IWETH.sol";
import "./interfaces/IMintableToken.sol";

// TODO: max cap on pool

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

    uint256 public maxDailyDrawdown = 3000; // 30%
    uint256 public checkpointBalance;
    uint256 public checkpointTimestamp;

    // Staking

    address public rewards; // contract

    mapping(address => uint256) private balances; // account => amount staked
    uint256 public clpSupply;

    mapping(address => uint256) lastStaked;
    uint256 public minStakingTime = 1 hours;

    // Events
    event Staked(
    	address indexed user, 
    	address indexed currency,
    	uint256 amount, 
    	uint256 clpAmount
    );
    event Unstaked(
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
		trading = IRouter(router).tradingContract();
		weth = IRouter(router).wethContract();
		rewards = IRouter(router).getPoolRewardsContract(currency);
	}

	function setMinStakingTime(uint256 _minStakingTime) external onlyOwner {
		minStakingTime = _minStakingTime;
	}

	function setUtilizationMultiplier(uint256 _utilizationMultiplier) external onlyOwner {
		utilizationMultiplier = _utilizationMultiplier;
	}

	// Methods

	function mintAndStakeCLP(uint256 amount) external payable returns(uint256) {

		uint256 currentBalance = IERC20(currency).balanceOf(address(this));

		if (currency == weth) { // User is sending ETH
			require(msg.value > 0, "!amount");
			amount = msg.value;
			IWETH(currency).deposit{value: msg.value}();
		} else {
			IERC20(currency).safeTransferFrom(msg.sender, address(this), amount);
		}

		require(amount > 0, "!amount");

		// So this doesn't return 0 when clpsupply = 0, which can happen with currentBalance > 0 e.g. trader closes losing position before pool is funded, || clpSupply == 0 is added
        uint256 clpAmountToMint = currentBalance == 0 || clpSupply == 0 ? amount : amount * clpSupply / currentBalance;

        // mint CLP
        address clp = IRouter(router).getClpAddress(currency);
        IMintableToken(clp).mint(address(this), clpAmountToMint);
        _stake(clpAmountToMint);

        emit Staked(
        	msg.sender,
        	currency,
        	amount,
        	clpAmountToMint
        );

        return clpAmountToMint;

	}

	function unstakeAndBurnCLP(uint256 amount) external returns(uint256) {

		require(amount > 0, "!amount");

		_unstake(amount);

		uint256 currentBalance = IERC20(currency).balanceOf(address(this));
		uint256 utlization = getUtlization();
		require(utlization < 10**4, "!utilization");
		
		uint256 availableBalance = currentBalance * (10**4 - utlization) / 10**4;

		// Amount of currency (weth, usdc, etc) to send user
		uint256 currencyAmount = amount * currentBalance / clpSupply;
        uint256 currencyAmountAfterFee = currencyAmount * (10**4 - withdrawFee) / 10**4;

        require(currencyAmountAfterFee <= availableBalance, "!balance");

		// burn CLP
		address clp = IRouter(router).getClpAddress(currency);
		IMintableToken(clp).burn(address(this), amount);

		// transfer token or ETH out
		if (currency == weth) { // WETH
			// Unwrap and send
			IWETH(currency).withdraw(currencyAmountAfterFee);
			payable(msg.sender).sendValue(currencyAmountAfterFee);
		} else {
			IERC20(currency).safeTransfer(msg.sender, currencyAmountAfterFee);
		}

		emit Unstaked(
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

		IERC20(currency).safeTransfer(destination, amount);

	}

	// Internal

	function _stake(uint256 amount) internal {
		
		// just minted CLP with amount = amount and sent to this contract
		require(amount > 0, "!amount");
		lastStaked[msg.sender] = block.timestamp;

		IRewards(rewards).updateRewards(msg.sender);

		clpSupply += amount;
		balances[msg.sender] += amount;

	}

	function _unstake(uint256 amount) internal {

		require(block.timestamp > lastStaked[msg.sender] + minStakingTime, "!cooldown");
		require(amount > 0, "!amount");

		IRewards(rewards).updateRewards(msg.sender);

		require(amount <= balances[msg.sender], "!balance");

		clpSupply -= amount;
		balances[msg.sender] -= amount;

	}

	// To receive ETH from WETH
	fallback() external payable {}
	receive() external payable {}

	// Getters

	function getUtlization() public view returns(uint256) {
		uint256 activeMargin = ITrading(trading).getActiveMargin(currency);
		uint256 currentBalance = IERC20(currency).balanceOf(address(this));
		return activeMargin * utilizationMultiplier / currentBalance; // in bps
	}

	// Todo: NOT NEEDED
	function getStakedSupply() external view returns(uint256) {
		return clpSupply;
	}

	function getStakedBalance(address account) external view returns(uint256) {
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