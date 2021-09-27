+// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "hardhat/console.sol";

import '@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol';
import '@uniswap/v3-periphery/contracts/libraries/TransferHelper.sol';

import "./interfaces/ITreasury.sol";

// Treasury with broad powers to use revenue to push the Cap ecosystem forward through buybacks, dividends, etc. This contract can be upgraded any time, simply point to the new one in the Trading contract

contract Treasury is ITreasury {

	ISwapRouter public immutable swapRouter = ISwapRouter(0xE592427A0AEce92De3Edee1F18E0157C05861564);;

	address public constant CAP = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
	address public constant WETH9 = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

	uint24 public constant poolFee = 3000;

	address public owner; // Contract owner
	address public oracle; // Trading contract

	constructor() {
		owner = msg.sender;
	}

	// receive
	function receive() external payable {

	}

	function sendETH(address destination, uint256 amount) external onlyOwner {
		require(msg.sender == owner || msg.sender == oracle, "!owner");
		payable(destination).transfer(amount);
	}

	function sendToken(address token, address destination, uint256 amount) external onlyOwner {
		require(msg.sender == owner || msg.sender == oracle, "!owner");
		IERC20(token).transfer(destination, amount);
	}

	function buyback(uint256 amount, uint256 amountOutMinimum) external onlyOwner {

		// CAP is precious. Buy back CAP at market from Uniswap sellers using part of trader losses. Can be called once per period. 

		// Amount up to 80% of treasury (configurable)

		uint256 weiBalance = address(this).balance;

		require(amount <= weiBalance * 80 / 100, "!amount");

		ISwapRouter.ExactInputSingleParams memory params =
	        ISwapRouter.ExactInputSingleParams({
	            tokenIn: WETH9,
	            tokenOut: CAP,
	            fee: poolFee,
	            recipient: msg.sender,
	            deadline: block.timestamp,
	            amountIn: amount,
	            amountOutMinimum: amountOutMinimum,
	            sqrtPriceLimitX96: 0
	        });

	    ISwapRouter.exactInputSingle{ value: amount }(params);

		// Bought back CAP can be burnt or sold OTC by governance, or later used for rewards, pay contributors, and other incentives.

	}

	modifier onlyOwner() {
		require(msg.sender == owner, "!owner");
		_;
	}


}