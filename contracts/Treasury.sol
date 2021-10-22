// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/Address.sol";

import "./interfaces/ITreasury.sol";
import "./interfaces/ITrading.sol";

// This contract should be relatively upgradeable = no important state

contract Treasury is ITreasury {

	using SafeERC20 for IERC20; 
    using Address for address payable;

	// Contract dependencies
	address public owner;
	address public trading;
	address public oracle;
	address public pool;
	address public staking;
	address public weth;

	mapping(address => uint256) private clpShare; // currency (eth, usdc, etc.) => bps
	mapping(address => uint256) private capShare; // currency (eth, usdc, etc.) => bps
	mapping(address => uint256) private standardRebateShare; // currency => bps
	mapping(address => uint256) private referrerShare; // currency => bps
	mapping(address => uint256) private referredShare; // currency => bps

	mapping(address => address) private clpRewardsContracts; // currency (eth, usdc, etc.) => contract
	mapping(address => address) private capRewardsContracts; // currency (eth, usdc, etc.) => contract

	address public rebates; // contract
	address public referrals; // contract

	constructor() {
		owner = msg.sender;
	}

	function notifyFeeReceived(
		address user,
		address currency, 
		uint256 amount
	) external onlyTrading {

		// Send clpShare[currency] * amount to clp-currency rewards contract
		uint256 clpReward = clpShare[currency] * amount / 10**4;
		address clpRewardsContract = clpRewardsContracts[currency];
		IERC20(currency).safeTransfer(clpRewardsContract, clpReward);
		IRewards(clpRewardsContract).notifyRewardReceived(clpReward);

		// Send capShare[currency] * amount to cap-currency rewards contract
		uint256 capReward = capShare[currency] * amount / 10**4;
		address capRewardsContract = capRewardsContracts[currency];
		IERC20(currency).safeTransfer(capRewardsContract, capReward);
		IRewards(capRewardsContract).notifyRewardReceived(capReward);

		// Send standardRebateShare to rebates contract
		uint256 standardRebate = standardRebateShare[currency] * amount / 10**4;
		IERC20(currency).safeTransfer(rebates, standardRebate);
		IRebates(rebates).notifyRebateReceived(user, currency, standardRebate);

		// Send referrerShare, referredShare to referrals contract
		address referredBy = IReferrals(referrals).referrerOf(user);
		if (referredBy != address(0)) {
			uint256 referrerReward = referrerShare[currency] * amount / 10**4;
			uint256 referredReward = referredShare[currency] * amount / 10**4;
			IERC20(currency).safeTransfer(referrals, referrerReward + referredReward);
			IReferrals(referrals).notifyRewardReceived(user, currency, referredReward, referrerReward);
		}

	}

	function fundOracle(
		address destination, 
		uint256 amount
	) external override onlyOracle {
		IWETH(weth).withdraw(amount);
		payable(destination).sendValue(amount);
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