// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "hardhat/console.sol";

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/Address.sol";

import "./interfaces/IPool.sol";
import "./interfaces/ITrading.sol";

contract Pool is IPool {

	using SafeERC20 for IERC20; 
    using Address for address payable;

	address public owner;
	address public trading;
	address public clp;
	address public staking;

	uint256 public standardFee = 15; // 0.15%
    uint256 public maxFee = 500; // 5%

	mapping(address => uint256) targetWeights; // in bps

	mapping(address => uint256) lastMinted;

	uint256 public cooldownPeriod; // min staking time

	constructor() {
		owner = msg.sender;
	}

	function creditProfit(address destination, address token, uint256 amount) {
		IERC20(token).safeTransfer(destination, amount);
	}

	function swap(address tokenIn, uint256 amountIn, address tokenOut, address destination) external {

		// TODO: validate tokens

		require(amountIn > 0, "!amountIn");

		uint256 amountOut = amountIn * tokenInPrice / tokenOutPrice;

		// get token weights with +amountIn and -amountOut in the pool

		uint256 tokenInBalance = IERC20(tokenIn).balanceOf(address(this));
		uint256 tokenOutBalance = IERC20(tokenOut).balanceOf(address(this));

		require(amountOut <= tokenOutBalance, "!amountOut");

		uint256 totalAssetsInUSD = getAUMAfterSwap(tokenIn, amountIn, tokenOut, amountOut);

		uint256 tokenInWeight = tokenInBalance * tokenPriceInUSD / totalAssetsInUSD; // normalized in usd with amountIn
		uint256 tokenInWeightAfter = (tokenInBalance + amountIn) * tokenPriceInUSD / totalAssetsInUSD; // normalized in usd with amountIn
		
		uint256 tokenOutWeight = tokenOutBalance * tokenPriceInUSD / totalAssetsInUSD; // normalized in usd with amountIn
		uint256 tokenOutWeightAfter = (tokenOutBalance - amountOut) * tokenPriceInUSD / totalAssetsInUSD; // normalized in usd with amountIn

		uint256 targetInWeight = targetWeights[tokenIn];
		uint256 targetOutWeight = targetWeights[tokenOut];

		if (
			tokenInWeight <= targetInWeight && tokenInWeightAfter >= tokenInWeight && tokenInWeightAfter <= targetInWeight ||
			tokenInWeight >= targetInWeight && tokenInWeightAfter <= tokenInWeight && tokenInWeightAfter >= targetInWeight ||
			tokenOutWeight >= targetOutWeight && tokenOutWeightAfter <= tokenOutWeight && tokenOutWeightAfter >= targetOutWeight ||
			tokenOutWeight <= targetOutWeight && tokenOutWeightAfter >= tokenOutWeight && tokenOutWeightAfter <= targetOutWeight
		) {
			// Allow swap because it helps rebalance in the right direction
			IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
			IERC20(tokenOut).safeTransfer(msg.sender, amountOut);
		} else {
			revert("!swap");
		}

	}

	// TODO: calculate AUM in USD

	function getMintingFee(address token, uint256 amount) public view returns(uint256) {
		// increases supply of token in pool
		uint256 tokenBalance = IERC20(token).balanceOf(address(this));
		uint256 tokenWeight = (tokenBalance + amount) * tokenPriceInUSD / totalAssetsInUSDWithAmount; // normalized in usd, including addition of amount
		uint256 targetWeight = targetWeights[token];

		if (tokenWeight >= targetWeight) {
			// fee applies. doubling = maxfee
			// TODO: review formula
			return amount * maxFee * (tokenWeight / targetWeight) / 2*10**4;
		} else {
			return 0;
		}
	}

	function getBurningFee(address token, uint256 amount) public view returns(uint256) {
		// reduces supply of token in pool
		uint256 tokenBalance = IERC20(token).balanceOf(address(this));
		uint256 tokenWeight = (tokenBalance - amount) * tokenPriceInUSD / totalAssetsInUSDWithAmount; // normalized in usd, including addition of amount
		uint256 targetWeight = targetWeights[token];

		if (tokenWeight <= targetWeight) {
			// fee applies. doubling = maxfee
			// TODO: review formula
			return amount * maxFee * (tokenWeight / targetWeight) / 2*10**4;
		} else {
			return 0;
		}
	}

	function mintAndStakeCLP(address account, address token, uint256 amount) external returns(uint256) {

		require(supportedToken[token], "!token");

		uint256 totalAssetsInUSD = ; // of total assets in the pool
		uint256 clpSupply = IERC20(clp).totalSupply();

		// !! Pool needs approval to spend from account
        IERC20(token).safeTransferFrom(account, address(this), amount);

        uint256 amountAfterFees = amount - getMintingFee(token, amount);
        uint256 fees = amount - amountAfterFees;

        // Send fee to treasury
		IERC20(token).safeTransfer(treasury, fees);
		ITreasury(treasury).notifyFeeReceived(token, fees);

        uint256 amountInUsd = ; // of sent token

        uint256 CLPAmountToMint = totalAssetsInUSD == 0 ? amountInUsd : amountInUsd * clpSupply / totalAssetsInUSD;

        require(CLPAmountToMint >= minCLP, "!minCLP");

        // mint directly to the staking contract
        IMintableToken(clp).mint(staking, CLPAmountToMint);

        lastMinted[account] = block.timestamp;

        IStaking(staking).stakeMinted(msg.sender, clp, CLPAmountToMint);

        return CLPAmountToMint;

	}

	function unstakeAndBurnCLP(address account, address token, uint256 amount) external returns(uint256) {

		require(amount > 0, "!amount");
		require(lastMinted[account] > block.timestamp + cooldownPeriod, "!cooldown");

		// Unstakes CLP and keeps them in the staking contract
		IStaking(staking).unstakeForAccount(account, clp, amount, false);

		// Token is the token user will get back (weth, usdc, etc)

		uint256 totalAssetsInUSD = ; // of total assets in the pool
		uint256 clpSupply = IERC20(clp).totalSupply();

		// Amount of tokens to send user in USD
		uint256 amountInUSD = amount * totalAssetsInUSD / clpSupply;

		uint256 tokenAmount = amountInUSD / tokenPriceInUSD; // get price with chainlink

        uint256 amountAfterFees = tokenAmount - getBurningFee(token, tokenAmount);
        uint256 fees = tokenAmount - amountAfterFees;

        // Send fee to treasury
		IERC20(token).safeTransfer(treasury, fees);
		ITreasury(treasury).notifyFeeReceived(token, fees);

		// burn directly in the staking contract. Pool can do this as minter role
		IMintableToken(clp).burn(staking, amount);

		// transfer token out
		IERC20(token).safeTransfer(account, amountAfterFees);

		return amountAfterFees;
		
	}

}