// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/Address.sol";

import "./interfaces/IRouter.sol";
import "./interfaces/ITreasury.sol";
import "./interfaces/ITrading.sol";
import "./interfaces/IRebates.sol";

contract Rebates {

	using SafeERC20 for IERC20; 
    using Address for address payable;

	// Contract dependencies
	address public owner;
	address public router;
	address public treasury;

	mapping(address => mapping(address => uint256)) private balances; // user => currency => amount

	constructor() {
		owner = msg.sender;
	}

	// Governance methods

	function setOwner(address newOwner) external onlyOwner {
		owner = newOwner;
	}

	function setRouter(address _router) external onlyOwner {
		router = _router;
	}

	function setContracts() external onlyOwner {
		treasury = IRouter(router).treasuryContract();
	}

	// Methods

	function notifyRebateReceived(address user, address currency, uint256 amount) external onlyTreasury {
		balances[user][currency] += amount;
	}

	function claimRebate(address currency) external {
		uint256 amount = balances[msg.sender][currency];
		require(amount > 0, "!amount");
		balances[msg.sender][currency] = 0;
		IERC20(currency).safeTransfer(msg.sender, amount);
	}

	// Modifiers

	modifier onlyOwner() {
		require(msg.sender == owner, "!owner");
		_;
	}

	modifier onlyTreasury() {
		require(msg.sender == treasury, "!treasury");
		_;
	}

}