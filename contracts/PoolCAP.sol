// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "hardhat/console.sol";

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/Address.sol";

import "./interfaces/IRouter.sol";
import "./interfaces/IPool.sol";
import "./interfaces/ITrading.sol";
import "./interfaces/IRewards.sol";

contract PoolCAP {

	using SafeERC20 for IERC20; 
    using Address for address payable;

	address public owner;
	address public router;

	address public cap; // CAP address

	mapping(address => uint256) private balances; // account => amount staked
	uint256 public totalSupply;

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

	function stake(uint256 amount) external {

		require(amount > 0, "!amount");

		_updateRewards();

		totalSupply += amount;
		balances[msg.sender] += amount;

		// Owner needs to approve this contract to spend their CLP
		IERC20(cap).safeTransferFrom(msg.sender, address(this), amount);

	}

	function unstake(uint256 amount) external {
		
		require(amount > 0, "!amount");

		_updateRewards();

		require(amount <= balances[msg.sender], "!balance");

		totalSupply -= amount;
		balances[msg.sender] -= amount;

		IERC20(cap).safeTransfer(msg.sender, amount);

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