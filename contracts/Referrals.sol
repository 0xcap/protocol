// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/Address.sol";

import "./interfaces/ITreasury.sol";
import "./interfaces/ITrading.sol";

contract Referrals is IReferrals {

	using SafeERC20 for IERC20; 
    using Address for address payable;

	// Contract dependencies
	address public owner;
	address public trading;
	address public oracle;
	address public pool;
	address public staking;
	address public weth;

	mapping(address => address) private referredBy; // referred user => referred by

	mapping(address => mapping(address => uint256)) private balances; // user => currency => amount

	constructor() {
		owner = msg.sender;
	}

	function notifyRewardReceived(address referredUser, address currency, uint256 referredReward, uint256 referrerReward) external onlyTreasury {
		address referrer = referredBy[referredUser];
		balances[referredUser][currency] += referredReward;
		balances[referrer][currency] += referrerReward;	
	}

	function claimReward(address currency) external {
		uint256 amount = balances[msg.sender][currency];
		require(amount > 0, "!amount");
		balances[msg.sender][currency] = 0;
		IERC20(currency).safeTransfer(msg.sender, amount);
	}

	function setReferrer(address referredUser, address referrer) {
		if (referredBy[referredUser] == address(0)) {
			referredBy[referredUser] = referrer;
		}
	}
	
	function sendToken(
		address token, 
		address destination, 
		uint256 amount
	) external onlyOwner {
		IERC20(token).safeTransfer(destination, amount);
	}

	// Owner methods

	function setParams(
		uint256 _vaultThreshold
	) external onlyOwner {
		vaultThreshold = _vaultThreshold;
	}

	function setOwner(address newOwner) external onlyOwner {
		owner = newOwner;
	}

	function setTrading(address _trading) external onlyOwner {
		trading = _trading;
	}

	function setOracle(address _oracle) external onlyOwner {
		oracle = _oracle;
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

	modifier onlyOracle() {
		require(msg.sender == oracle, "!oracle");
		_;
	}

}