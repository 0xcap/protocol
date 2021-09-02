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

  const address = '0x5F2fFc7883BD12604e0adf0403f9436D40386Ef4';

  const abi = [
    "function updateVault(uint8 vaultId, tuple(address base, uint256 cap, uint256 maxOpenInterest, uint256 maxDailyDrawdown, uint256 stakingPeriod, uint256 redemptionPeriod, uint256 protocolFee, uint256 openInterest, uint256 balance, uint256 totalStaked, uint256 lastCheckpointBalance, uint256 lastCheckpointTime, uint256 frMinStaked, uint256 frMaxStaked, uint16 frMinRebate, uint16 frMaxRebate, bool isActive))",
    "function updateProduct(uint16 productId, tuple(uint256 leverage, uint256 fee, uint256 interest, address feed, uint256 settlementTime, uint256 minTradeDuration, uint256 liquidationThreshold, uint256 liquidationBounty, bool isActive))"
  ];
  const trading = new hre.ethers.Contract(address, abi, signer);

  console.log("Trading address:", trading.address);

  const USDC_address = '0xBbfacB66a6F3a73930a8b5483B37b05Be25Bf7fd';

  //await trading.updateVault(1, [USDC_address, 4000000 * 10**6, 8000000000 * 10**6, 25 * 100, 30 * 24 * 3600, 8 * 3600, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, true]);
  //console.log('updated usdc vault');

  await trading.updateProduct(1, [50 * 10**6, 0.05 * 100, 5 * 100, '0x639Fe6ab55C921f74e7fac1ee960C0B6293ba612', 1 * 60, 0 * 60, 80 * 100, 5 * 100, true], {gasPrice: 5000000000 ,gasLimit: 2000000});

  await trading.updateProduct(2, [100 * 10**6, 0.05 * 100, 5 * 100, '0x6ce185860a4963106506C203335A2910413708e9', 1 * 60, 0 * 60, 80 * 100, 5 * 100, true], {gasPrice: 5000000000 ,gasLimit: 2000000});
  
}

// We recommend this pattern to be able to use async/await everywhere
// and properly handle errors.
main();
