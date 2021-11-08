// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "./libraries/SafeERC20.sol";
import "./libraries/Address.sol";

import "./interfaces/IRouter.sol";
import "./interfaces/IRewards.sol";
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
	mapping(address => uint256) private capPoolShare; // currency => bps

	uint256 public constant UNIT = 10**18;

	constructor() {
		owner = msg.sender;
	}

	// Governance methods

	function setOwner(address newOwner) external onlyOwner {
		owner = newOwner;
	}

	function setRouter(address _router) external onlyOwner {
		router = _router;
		oracle = IRouter(router).oracle();
		trading = IRouter(router).trading();
		weth = IRouter(router).weth();
	}

	function setPoolShare(address currency, uint256 share) external onlyOwner {
		poolShare[currency] = share;
	}
	function setCapPoolShare(address currency, uint256 share) external onlyOwner {
		capPoolShare[currency] = share;
	}

	// Methods

	function notifyFeeReceived(
		address currency, 
		uint256 amount
	) external onlyTrading {

		// Contracts from Router
		address poolRewards = IRouter(router).getPoolRewards(currency);
		address capRewards = IRouter(router).getCapRewards(currency);

		// Send poolShare to pool-currency rewards contract
		uint256 poolReward = poolShare[currency] * amount / 10**4;
		_transferOut(currency, poolRewards, poolReward, false);
		IRewards(poolRewards).notifyRewardReceived(poolReward);

		// Send capPoolShare to cap-currency rewards contract
		uint256 capReward = capPoolShare[currency] * amount / 10**4;
		_transferOut(currency, capRewards, capReward, false);
		IRewards(capRewards).notifyRewardReceived(capReward);

	}

	function fundOracle(
		address destination, 
		uint256 amount
	) external onlyOracle {
		uint256 wethBalance = IERC20(weth).balanceOf(address(this));
		if (amount > wethBalance) return;
		IWETH(weth).withdraw(amount);
		payable(destination).sendValue(amount);
	}

	function sendToken(
		address token, 
		address destination, 
		uint256 amount
	) external onlyOwner {
		_transferOut(token, destination, amount, true);
	}

	// To receive ETH from WETH
	fallback() external payable {}
	receive() external payable {}

	// Utils

	function _transferOut(address currency, address to, uint256 amount, bool sendETH) internal {
		if (amount == 0 || currency == address(0) || to == address(0)) return;
		// adjust decimals
		uint256 decimals = IRouter(router).getDecimals(currency);
		amount = amount * (10**decimals) / UNIT;
		if (currency == weth && sendETH) {
			IWETH(weth).withdraw(amount);
			payable(to).sendValue(amount);
		} else {
			IERC20(currency).safeTransfer(to, amount);
		}
	}

	// Getters

	function getPoolShare(address currency) external view returns(uint256) {
		return poolShare[currency];
	}
	function getCapShare(address currency) external view returns(uint256) {
		return capPoolShare[currency];
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