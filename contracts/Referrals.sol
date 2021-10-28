// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/Address.sol";

import "./interfaces/IRouter.sol";
import "./interfaces/ITreasury.sol";
import "./interfaces/ITrading.sol";
import "./interfaces/IReferrals.sol";

contract Referrals {

	using SafeERC20 for IERC20; 
    using Address for address payable;

	// Contract dependencies
	address public owner;
	address public router;
	address public treasury;
	address public trading;

	mapping(address => address) private referredBy; // referred user => referred by

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
		trading = IRouter(router).trading();
		treasury = IRouter(router).treasury();
	}

	// Methods

	function notifyRewardReceived(address referredUser, address currency, uint256 referrerReward) external onlyTreasury {
		address referrer = referredBy[referredUser];
		if (referrer != address(0)) {
			balances[referrer][currency] += referrerReward;	
		}
	}

	function claimReward(address currency) external {
		uint256 amount = balances[msg.sender][currency];
		require(amount > 0, "!amount");
		balances[msg.sender][currency] = 0;
		IERC20(currency).safeTransfer(msg.sender, amount);
	}

	// TODO: support calls from multiple trading contracts e.g. adding cross margin in the future
	function setReferrer(address referredUser, address referrer) external onlyTrading {
		if (referredBy[referredUser] == address(0)) {
			referredBy[referredUser] = referrer;
		}
	}
		
	function getReferrerOf(address user) external view returns(address) {
		return referredBy[user];
	}

	function sendToken(
		address token, 
		address destination, 
		uint256 amount
	) external onlyOwner {
		IERC20(token).safeTransfer(destination, amount);
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

	modifier onlyTrading() {
		require(msg.sender == trading, "!trading");
		_;
	}

}