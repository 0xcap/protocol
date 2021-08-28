//SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "hardhat/console.sol";

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import './interfaces/IStaking.sol';

contract Staking is IStaking {

	// CAP staking contract

	// Simply takes in CAP and locks them for a given period, in exchange for rewards

	function getUserStake(address user) external view override returns (uint256) {
		return 0;
	}

}