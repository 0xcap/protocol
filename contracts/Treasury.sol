+// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "hardhat/console.sol";

import "./interfaces/ITreasury.sol";

contract Treasury is ITreasury {

	address public owner; // Contract owner
	address public trading; // Trading contract
	address public darkOracle; // Dark oracle contract

	constructor() {
		owner = msg.sender;
	}

	// receive
	function receive() external payable onlyTrading {

	}

	// send
	function withdraw(address to, uint256 amount) external onlyOwner {
		payable(to).transfer(amount);
	}

	function fundOracle(address oracle, uint26 amount) external onlyDarkOracle {
		if (address(this).balance < amount) {
			emit OracleFundingFailed(
				oracle,
				amount
			);
		} else {
			payable(oracle).transfer(amount);
		}
	}

	function() public payable {

	}

	// owner method to update params

	modifier onlyOwner() {
		require(msg.sender == owner, "!owner");
		_;
	}

	modifier onlyDarkOracle() {
		require(msg.sender == darkOracle, "!owner");
		_;
	}

	modifier onlyTrading() {
		require(msg.sender == trading, "!trading");
		_;
	}

}