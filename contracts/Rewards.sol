// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "hardhat/console.sol";

import "./libraries/SafeERC20.sol";
import "./libraries/Address.sol";

import "./interfaces/IRouter.sol";
import "./interfaces/IPool.sol";
import "./interfaces/ITrading.sol";
import "./interfaces/IRewards.sol";
import "./interfaces/IPool.sol";
import "./interfaces/IWETH.sol";

contract Rewards {

	using SafeERC20 for IERC20; 
    using Address for address payable;

    address public owner;
	address public router;
	address public treasury;

	address public pool; // pool contract associated with these rewards
	address public currency; // rewards paid in this
	address public weth;

	uint256 public cumulativeRewardPerTokenStored;
	uint256 public pendingReward;

	mapping(address => uint256) private claimableReward;
	mapping(address => uint256) private previousRewardPerToken;

	event CollectedReward(
		address user,
		address poolContract,
		address currency,
		uint256 amount
	);

	constructor(address _pool, address _currency) {
		owner = msg.sender;
		pool = _pool;
		currency = _currency;
	}

	// Governance methods

	function setOwner(address newOwner) external onlyOwner {
		owner = newOwner;
	}

	function setRouter(address _router) external onlyOwner {
		router = _router;
		treasury = IRouter(router).treasury();
		weth = IRouter(router).weth();
	}

	// Methods

	function notifyRewardReceived(uint256 amount) external onlyTreasury {
		pendingReward += amount;
	}

	function updateRewards(address account) public {

		uint256 supply = IPool(pool).totalSupply();

		if (supply == 0) return;

		cumulativeRewardPerTokenStored += pendingReward * 10**18 / supply;

		if (cumulativeRewardPerTokenStored == 0) return; // no rewards yet

		uint256 accountStakedBalance = IPool(pool).getBalance(account);

		claimableReward[account] += accountStakedBalance * (cumulativeRewardPerTokenStored - previousRewardPerToken[account]) / 10**18;

		previousRewardPerToken[account] = cumulativeRewardPerTokenStored;

		pendingReward = 0;

	}

	function collectReward() external {

		updateRewards(msg.sender);

		uint256 rewardToSend = claimableReward[msg.sender];
		claimableReward[msg.sender] = 0;

		if (rewardToSend > 0) {

			if (currency == weth) { // WETH
				// Unwrap and send
				IWETH(weth).withdraw(rewardToSend);
				payable(msg.sender).sendValue(rewardToSend);
			} else {
				_transferOut(currency, msg.sender, rewardToSend);
			}

			emit CollectedReward(msg.sender, pool, currency, rewardToSend);
		}

	}

	function getClaimableReward() external view returns(uint256) {

		uint256 currentClaimableReward = claimableReward[msg.sender];

		uint256 supply = IPool(pool).totalSupply();

		if (supply == 0) return 0;

		uint256 _rewardPerTokenStored = cumulativeRewardPerTokenStored + pendingReward / supply;

		if (_rewardPerTokenStored == 0) return 0; // no rewards yet

		uint256 accountStakedBalance = IPool(pool).getBalance(msg.sender);

		return currentClaimableReward + accountStakedBalance * (_rewardPerTokenStored - previousRewardPerToken[msg.sender]) / 10**18;
		
	}

	// Utils

	function _transferOut(address _currency, address to, uint256 _amount) internal {
		// adjust decimals
		uint256 decimals = IERC20(_currency).decimals();
		if (decimals != 18) {
			_amount = _amount * (10**decimals) / (10**18);
		}
		IERC20(_currency).safeTransfer(to, _amount);
	}

	modifier onlyOwner() {
		require(msg.sender == owner, "!owner");
		_;
	}

	modifier onlyTreasury() {
		require(msg.sender == treasury, "!treasury");
		_;
	}

}