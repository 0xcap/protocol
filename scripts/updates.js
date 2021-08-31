// We require the Hardhat Runtime Environment explicitly here. This is optional
// but useful for running the script in a standalone fashion through `node <script>`.
//
// When running the script with `npx hardhat run <script>` you'll find the Hardhat
// Runtime Environment's members available in the global scope.
const hre = require("hardhat");
const { ethers } = require('hardhat');

async function main() {
  // Hardhat always runs the compile task when running scripts with its command
  // line interface.
  //
  // If this script is run directly using `node` you may want to call compile
  // manually to make sure everything is compiled
  // await hre.run('compile');

  const signer = await hre.ethers.provider.getSigner();

  console.log('signer', await signer.getAddress());

  const address = '0xEde8C3f9fb1d7F0C63Eb284547c35a45c8D7632c';

  const abi = [
    "function updateVault(uint8 vaultId, tuple(address base, uint256 cap, uint256 maxOpenInterest, uint256 maxDailyDrawdown, uint256 stakingPeriod, uint256 redemptionPeriod, uint256 protocolFee, uint256 openInterest, uint256 balance, uint256 totalStaked, uint256 lastCheckpointBalance, uint256 lastCheckpointTime, uint256 frMinStaked, uint256 frMaxStaked, uint16 frMinRebate, uint16 frMaxRebate, bool isActive))"
  ];
  const trading = new hre.ethers.Contract(address, abi, signer);

  console.log("Trading address:", trading.address);

  const USDC_address = '0x0A1A33aEb6d69966973a568653b6465642E4aD59';

  await trading.updateVault(1, [USDC_address, 4000000 * 10**6, 8000000000 * 10**6, 25 * 100, 30 * 24 * 3600, 8 * 3600, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, true]);
  console.log('updated usdc vault');
  
}

// We recommend this pattern to be able to use async/await everywhere
// and properly handle errors.
main();
