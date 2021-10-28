// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "hardhat/console.sol";

import "./libraries/SafeERC20.sol";

import "./interfaces/IRouter.sol";
import "./interfaces/IPool.sol";
import "./interfaces/ITrading.sol";
import "./interfaces/IRewards.sol";

contract PoolCAP {

	using SafeERC20 for IERC20; 

	address public owner;
	address public router;

	address public cap; // CAP address

	mapping(address => uint256) private balances; // account => amount staked
	uint256 public totalSupply;

	// Events
    event Deposit(
    	address indexed user, 
    	uint256 amount
    );
    event Withdraw(
    	address indexed user,
    	uint256 amount
    );

	constructor(address _cap) {
		owner = msg.sender;
		cap = _cap;
	}

	// Governance methods

	function setOwner(address newOwner) external onlyOwner {
		owner = newOwner;
	}

	function setRouter(address _router) external onlyOwner {
		router = _router;
	}

	function deposit(uint256 amount) external {

		require(amount > 0, "!amount");

		_updateRewards();

		totalSupply += amount;
		balances[msg.sender] += amount;

		// Owner needs to approve this contract to spend their CAP
		IERC20(cap).safeTransferFrom(msg.sender, address(this), amount);

		emit Deposit(
			msg.sender,
			amount
		);

	}

	function withdraw(uint256 amount) external {
		
		require(amount > 0, "!amount");

		_updateRewards();

		require(amount <= balances[msg.sender], "!balance");

		totalSupply -= amount;
		balances[msg.sender] -= amount;

		IERC20(cap).safeTransfer(msg.sender, amount);

		emit Withdraw(
			msg.sender,
			amount
		);

	}

	function getBalance(address account) external view returns(uint256) {
		return balances[account];
	}

	function _updateRewards() internal {
		uint256 length = IRouter(router).currenciesLength();
		for (uint256 i = 0; i < length; i++) {
			address currency = IRouter(router).currencies(i);
			address rewardsContract = IRouter(router).getCapRewards(currency);
			IRewards(rewardsContract).updateRewards(msg.sender);
		}
	}

	modifier onlyOwner() {
		require(msg.sender == owner, "!owner");
		_;
	}

}