+// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "hardhat/console.sol";

import '@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol';
import '@uniswap/v3-periphery/contracts/libraries/TransferHelper.sol';

import "./interfaces/ITreasury.sol";

// Treasury with broad powers to use revenue to push the Cap ecosystem forward through buybacks, dividends, etc. This contract can be upgraded any time, simply point to the new one in the Trading contract

contract Treasury is ITreasury {

	// Contract dependencies
	address public owner;
	address public trading;
	address public darkFeed;

	// Uniswap arbitrum addresses
	ISwapRouter public immutable swapRouter = ISwapRouter(0xE592427A0AEce92De3Edee1F18E0157C05861564);
	//address public constant CAP = 0x031d35296154279dc1984dcd93e392b1f946737b;

	// Arbitrum
	address public constant WETH9 = 0x82af49447d8a07e3bd95bd0d56f35241523fbab1;

	//uint256 public buybackPeriod = 7 days;
	//uint256 public maxBuybackShare = 8000;

	uint256 dailyOutflow;
	uint256 public maxDailyOutflow; // in bps
	uint256 public lastCheckpointTime;

	// TODO: use treasury directly as vault, no max drawdown, etc. Treasury can sell assets, hedge, support Cap ecosystem, etc.

	// Events

	event Swap(
		uint256 amount,
	    uint256 amountOut,
	    uint256 amountOutMinimum,
	    address tokenIn,
	    address tokenOut,
	    uint24 poolFee
	);

	constructor() {
		owner = msg.sender;
	}

	function receive() external payable {
	}

	function pay(
		address user, 
		uint256 amount
	) external onlyTrading {
		uint256 weiBalance = address(this).balance;
		require(amount <= weiBalance, "!vault-insufficient");
		dailyOutflow += amount;
		// Check maxDailyOutflow
		if (lastCheckpointTime < block.timestamp - 24 hours) {
			lastCheckpointTime = block.timestamp;
			dailyOutflow = 0;
		}
		require(dailyOutflow <= maxDailyOutflow * weiBalance / 10**4, "!outflow");
		payable(user).transfer(amount);
	}

	function sendETH(
		address destination, 
		uint256 amount
	) external onlyOwnerOrDarkFeed {
		uint256 weiBalance = address(this).balance;
		if (amount > weiBalance) {
			if (msg.sender == oracle) return;
			revert("!balance");
		}
		payable(destination).transfer(amount);
	}

	function sendToken(
		address token, 
		address destination, 
		uint256 amount
	) external onlyOwner {
		IERC20(token).transfer(destination, amount);
	}

	function swap(
		address tokenIn,
		address tokenOut,
		uint256 amountIn, 
		uint256 amountOutMinimum,
		uint24 poolFee
	) external onlyOwner {

        // Approve the router to spend tokenIn
        TransferHelper.safeApprove(tokenIn, address(swapRouter), amountIn);

		ISwapRouter.ExactInputSingleParams memory params =
	        ISwapRouter.ExactInputSingleParams({
	            tokenIn: tokenIn,
	            tokenOut: tokenOut,
	            fee: poolFee,
	            recipient: msg.sender,
	            deadline: block.timestamp,
	            amountIn: amountIn,
	            amountOutMinimum: amountOutMinimum,
	            sqrtPriceLimitX96: 0
	        });

	    uint256 amountOut;

	    if (tokenIn == WETH9) {
	    	amountOut = ISwapRouter.exactInputSingle{value: amount}(params);
	    } else {
	    	amountOut = ISwapRouter.exactInputSingle(params);
	    }

	    emit Swap(
	    	amountIn,
	    	amountOut,
	    	amountOutMinimum,
	    	tokenIn,
	    	tokenOut,
	    	poolFee
	    );

	}

	// Owner methods

	function setParams(uint256 _maxDailyOutflow) external onlyOwner {
		maxDailyOutflow = _maxDailyOutflow;
	}

	function setOwner(address newOwner) external onlyOwner {
		owner = newOwner;
	}

	function setDarkFeed(address _darkFeed) external onlyOwner {
		darkFeed = _darkFeed;
	}

	function setTrading(address _trading) external onlyOwner {
		trading = _trading;
	}

	// Modifiers

	modifier onlyOwner() {
		require(msg.sender == owner, "!owner");
		_;
	}

	modifier onlyTrading() {
		require(msg.sender == trading, "!trading");
		_;
	}

	modifier onlyOwnerOrDarkFeed() {
		require(msg.sender == owner || msg.sender == darkFeed, "!owner|darkFeed");
		_;
	}

}