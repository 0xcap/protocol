// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/Address.sol";

import "./interfaces/IRouter.sol";
import "./interfaces/ITreasury.sol";
import "./interfaces/ITrading.sol";

import "./interfaces/IRewards.sol";
import "./interfaces/IRebates.sol";
import "./interfaces/IReferrals.sol";
import "./interfaces/IWETH.sol";

// This contract should be relatively upgradeable = no important state

contract Treasury {

	using SafeERC20 for IERC20; 
    using Address for address payable;

	// Contract dependencies
	address public owner;
	address public router;
	address public trading;
	address public oracle;
	address public weth;

	mapping(address => uint256) private poolShare; // currency (eth, usdc, etc.) => bps
	mapping(address => uint256) private capShare; // currency (eth, usdc, etc.) => bps
	mapping(address => uint256) private rebateShare; // currency => bps
	mapping(address => uint256) private referrerShare; // currency => bps
	mapping(address => uint256) private referredShare; // currency => bps

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
		oracle = IRouter(router).oracleContract();
		trading = IRouter(router).tradingContract();
		weth = IRouter(router).wethContract();
	}

	function setPoolShare(address currency, uint256 share) external onlyOwner {
		poolShare[currency] = share;
	}
	function setCapShare(address currency, uint256 share) external onlyOwner {
		capShare[currency] = share;
	}
	function setRebateShare(address currency, uint256 share) external onlyOwner {
		rebateShare[currency] = share;
	}
	function setReferrerShare(address currency, uint256 share) external onlyOwner {
		referrerShare[currency] = share;
	}
	function setReferredShare(address currency, uint256 share) external onlyOwner {
		referredShare[currency] = share;
	}

	// Methods

	function notifyFeeReceived(
		address user,
		address currency, 
		uint256 amount
	) external onlyTrading {

		// Contracts from Router
		address poolRewardsContract = IRouter(router).getPoolRewardsContract(currency);
		address capRewardsContract = IRouter(router).getCapRewardsContract(currency);
		address rebatesContract = IRouter(router).rebatesContract();
		address referralsContract = IRouter(router).referralsContract();

		// Send poolShare[currency] * amount to pool-currency rewards contract
		uint256 poolReward = poolShare[currency] * amount / 10**4;
		IERC20(currency).safeTransfer(poolRewardsContract, poolReward);
		IRewards(poolRewardsContract).notifyRewardReceived(poolReward);

		// Send capShare[currency] * amount to cap-currency rewards contract
		uint256 capReward = capShare[currency] * amount / 10**4;
		IERC20(currency).safeTransfer(capRewardsContract, capReward);
		IRewards(capRewardsContract).notifyRewardReceived(capReward);

		// Send rebateShare to rebates contract
		uint256 rebate = rebateShare[currency] * amount / 10**4;
		IERC20(currency).safeTransfer(rebatesContract, rebate);
		IRebates(rebatesContract).notifyRebateReceived(user, currency, rebate);

		// Send referrerShare, referredShare to referrals contract
		address referredBy = IReferrals(referralsContract).getReferrerOf(user);
		if (referredBy != address(0)) {
			uint256 referrerReward = referrerShare[currency] * amount / 10**4;
			uint256 referredReward = referredShare[currency] * amount / 10**4;
			IERC20(currency).safeTransfer(referralsContract, referrerReward + referredReward);
			IReferrals(referralsContract).notifyRewardReceived(user, currency, referredReward, referrerReward);
		}

	}

	function fundOracle(
		address destination, 
		uint256 amount
	) external onlyOracle {
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