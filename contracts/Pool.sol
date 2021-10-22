// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "hardhat/console.sol";

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/Address.sol";

import "./libraries/Price.sol";

import "./interfaces/IPool.sol";
import "./interfaces/ITrading.sol";

// TODO: set a maxDaily drawdown for pool. This protects from drainage in black swan scenarios like wrong price feeds, insider manipulation, even from chainlink. Max exposure per product have been removed.
// TODO: utlization ratio

contract Pool is IPool {

	using SafeERC20 for IERC20; 
    using Address for address payable;

	address public owner;
	address public trading;
	address public clp;
	address public staking;

	uint256 public standardFee = 15; // 0.15%
    uint256 public maxFee = 500; // 5%

    address[] currencyList; // list of currencies supported by the pool: weth, usdc, etc.
	mapping(address => address) currencyFeeds; // currency => chainlink feed

	mapping(address => uint256) targetWeights; // in bps

	constructor() {
		owner = msg.sender;
	}

	function creditProfit(address destination, address currency, uint256 amount) external onlyTrading {
		IERC20(currency).safeTransfer(destination, amount);
	}

	function mintAndStakeCLP(address currency, uint256 amount) external returns(uint256) {

		require(isCurrencySupported(currency), "!currency");

		address clp = IStaking(staking).clp();

		uint256 totalAssetsInUSD = _getAUMInUSD();
		uint256 clpSupply = IERC20().totalSupply();

		// Pool needs approval to spend from sender
        IERC20(currency).safeTransferFrom(msg.sender, address(this), amount);

        uint256 fee = _calculateFee(currency, amount, true);
        uint256 amountAfterFee = amount - fee;

        // Send fee to treasury
		IERC20(currency).safeTransfer(treasury, fee);
		ITreasury(treasury).notifyFeeReceived(currency, fee);

		uint256 price = getCurrencyPrice(currency);
        uint256 amountInUsd = amountAfterFee * price / 10**8;

        uint256 CLPAmountToMint = totalAssetsInUSD == 0 ? amountInUsd : amountInUsd * clpSupply / totalAssetsInUSD;

        // mint directly to the staking contract
        IMintableToken(clp).mint(staking, CLPAmountToMint);

        IStaking(staking).stakeCLP(msg.sender, CLPAmountToMint);

        return CLPAmountToMint;

	}

	function unstakeAndBurnCLP(address currency, uint256 amount) external returns(uint256) {

		require(amount > 0, "!amount");

		// Unstakes CLP and keeps them in the staking contract
		IStaking(staking).unstakeCLP(msg.sender, amount);

		uint256 totalAssetsInUSD = _getAUMInUSD();
		uint256 clpSupply = IERC20(clp).totalSupply();

		// Amount of currency (weth, usdc, etc) to send user in USD
		uint256 amountInUSD = amount * totalAssetsInUSD / clpSupply;

		uint256 price = getCurrencyPrice(currency);

		uint256 currencyAmount = amountInUSD / price;

		uint256 fee = _calculateFee(currency, currencyAmount, false);
        uint256 amountAfterFee = currencyAmount - fee;

        // Send fee to treasury
		IERC20(currency).safeTransfer(treasury, fee);
		ITreasury(treasury).notifyFeeReceived(currency, fee);

		// burn directly in the staking contract. Pool can do this as minter role
		IMintableToken(clp).burn(staking, amount);

		// transfer token out
		IERC20(currency).safeTransfer(msg.sender, amountAfterFee);

		return amountAfterFee;
		
	}

	// Is swap needed? Why not simply disallow CLP minting from overweight tokens and tell users to deposit other assets to get CLP instead?

	// Used by anyone to rebalance pool assets without slippage or fees
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

	// Utils

	// Get total value of pool assets in USD
	function _getAUMInUSD() internal view returns(uint256) {

		uint256 aum;
		uint256 length = currencyList.length;
		for (uint256 i = 0; i < length; i++) {
			address currency = currencyList[i];
			uint256 price = getCurrencyPrice(currency);
			uint256 balance = IERC20(currency).balanceOf(address(this));
			aum += balance * price / 10**8;
		}

		return aum;

	}

	function _calculateFee(address currency, uint256 amount, bool isTransferIn) public view returns(uint256) {
		// increases supply of token in pool
		uint256 tokenBalance = IERC20(token).balanceOf(address(this));
		
		uint256 tokenWeight;
		if (isTransferIn) {
			tokenWeight = (tokenBalance + amount) * tokenPriceInUSD / totalAssetsInUSDWithAmount;
		} else {
			tokenWeight = (tokenBalance - amount) * tokenPriceInUSD / totalAssetsInUSDWithAmount;
		}

		uint256 targetWeight = targetWeights[token];

		if (tokenWeight >= targetWeight) {
			// fee applies. doubling = maxfee
			// TODO: review formula
			return amount * maxFee * (tokenWeight / targetWeight) / 2*10**4;
		} else {
			return 0;
		}
	}

	function isCurrencySupported(address currency) public view returns(bool) {
		return currencyFeeds[currency] != address(0);
	}

	// Getters

	function getCurrencyPrice(address currency) public view returns(uint256) {
		return Price.get(currencyFeeds[currency]);
	}

}