// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "hardhat/console.sol";

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/Address.sol";

import "./interfaces/IPool.sol";
import "./interfaces/ITrading.sol";

// Not needed

contract Router is IRouter {

	using SafeERC20 for IERC20; 
    using Address for address payable;

	address public owner;
	address public trading;
	address public clp;
	address public staking;

	constructor() {
		owner = msg.sender;
	}

	function creditProfit(address destination, address token, uint256 amount) {
		IERC20(token).safeTransfer(destination, amount);
	}

	function mintAndStakeCLP(address token, uint256 amount) external returns(uint256) {
		uint256 CLPAmountToMint = IPool(pool).mintCLPForAccount(msg.sender, token, amount);
		IStaking(staking).stakeForAccount(msg.sender, clp, CLPAmountToMint);
	}

	function unstakeAndBurnCLP() {
		// sends back user collateral and burns associated CLP, including staked
	}

	function stakeCAP() {

	}

	function unstakeCAP() {
		
	}

	// these are automatically done from trading contract
	function mintAndStakeVCAP() {}
	function unstakeAndBurnVCAP() {}



	function collectRewards(address stakingToken) {

	}

	function compoundRewards() {}



	function submitNewOrder() {}

	function submitCloseOrder() {}

	function addMargin() {}
	
	function removeMargin() {}

	function swap() {}

}