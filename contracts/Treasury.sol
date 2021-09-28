// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "hardhat/console.sol";

import '@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol';
import '@uniswap/v3-periphery/contracts/libraries/TransferHelper.sol';

import "./interfaces/ITreasury.sol";
import "./interfaces/ITrading.sol";

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

	// Treasury can sell assets, hedge, support Cap ecosystem, etc.

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

	function receiveETH() external payable {
	}

	function fundVault(uint256 amount) external onlyOwner {
		ITrading(trading).fundVault{value: amount}();
	}

	function fundOracle(
		address oracle, 
		uint256 amount
	) external onlyDarkFeed {
		if (amount > address(this).balance) return;
		payable(oracle).transfer(amount);
	}

	function sendETH(
		address destination, 
		uint256 amount
	) external onlyOwner {
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

	function setOwner(address newOwner) external onlyOwner {
		owner = newOwner;
	}

	function setTrading(address _trading) external onlyOwner {
		trading = _trading;
	}

	function setDarkFeed(address _darkFeed) external onlyOwner {
		darkFeed = _darkFeed;
	}

	// Modifiers

	modifier onlyOwner() {
		require(msg.sender == owner, "!owner");
		_;
	}

	modifier onlyDarkFeed() {
		require(msg.sender == darkFeed, "!darkFeed");
		_;
	}

}