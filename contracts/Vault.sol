+// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "hardhat/console.sol";

// ETH Vault
import "./interfaces/IVault.sol";

contract Vault is IVault {

	// vault struct with params

	struct Vault {
		// 32 bytes
		uint96 cap; // Maximum capacity. 12 bytes
		uint96 balance; // Deposits + return. 12 bytes
		uint64 deposits; // Total deposits by users. 8 bytes
		// 32 bytes
		uint80 lastCheckpointBalance; // Used for max drawdown. 10 bytes
		uint80 lastCheckpointTime; // Used for max drawdown. 10 bytes
		uint32 maxDailyDrawdown; // In basis points (bps) 1000 = 10%. 4 bytes
	}


	// deposit

	// withdraw

	// owner method to update vault

}