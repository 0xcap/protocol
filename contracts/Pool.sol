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

	mapping(address => uint256) lastMinted;

	uint256 public cooldownPeriod; // min staking time

	constructor() {
		owner = msg.sender;
	}

	function creditProfit(address destination, address token, uint256 amount) {
		IERC20(token).safeTransfer(destination, amount);
	}

	function mintCLPForAccount(address account, address token, uint256 amount) external onlyRouter {
		_mintCLP(account, token, amount);
	}

	// TODO: weights for each collateral token, swap method, fees for minting/burning CLP based on weights

	function mintAndStakeCLP(address account, address token, uint256 amount) external returns(uint256) {

		require(supportedToken[token], "!token");

		uint256 totalAssetsInUSD = ; // of total assets in the pool
		uint256 clpSupply = IERC20(clp).totalSupply();

		// !! Pool needs approval to spend from account
        IERC20(token).safeTransferFrom(account, address(this), amount);

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
		IStaking(staking).unstakeForAccount(account, clp, amount, address(this));

		// Token is the token user will get back (weth, usdc, etc)

		uint256 totalAssetsInUSD = ; // of total assets in the pool
		uint256 clpSupply = IERC20(clp).totalSupply();

		// Amount of tokens to send user in USD
		uint256 amountInUSD = amount * totalAssetsInUSD / clpSupply;

		uint256 tokenAmount = amountInUSD / tokenPriceInUSD; // get price with chainlink

		// burn directly in the staking contract. Pool can do this as minter role
		IMintableToken(clp).burn(staking, CLPAmountToBurn);

		// transfer token out
		IERC20(token).safeTransfer(account, tokenAmount);

		return tokenAmount;
		
	}

}