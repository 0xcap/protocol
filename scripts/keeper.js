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

  const address = '0x7bc06c482DEAd17c0e297aFbC32f6e63d3846650';
  const abi = [
    "function canSettlePositions(uint256[] calldata) view returns(uint256[] memory _positionIds)",
    "function settlePositions(uint256[] calldata)"
  ];
  const trading = new hre.ethers.Contract(address, abi, signer);

  console.log("Trading address:", trading.address);

  const idsToSettle = await trading.canSettlePositions([1]);
  console.log('idsToSettle', idsToSettle);

  //await trading.settlePositions([1]);
  //console.log('Settled ids');
  
}

// We recommend this pattern to be able to use async/await everywhere
// and properly handle errors.
main();
