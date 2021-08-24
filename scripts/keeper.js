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

  const address = '0x2bdCC0de6bE1f7D2ee689a0342D76F52E8EFABa3';
  const abi = [
    "function checkPositionsToSettle() view returns(uint256[] memory)",
    "function settlePositions(uint256[] calldata)"
  ];
  const trading = new hre.ethers.Contract(address, abi, signer);

  console.log("Trading address:", trading.address);

  setInterval(async () => {
    let settleTheseIds = await trading.checkSettlement();
    console.log('settleTheseIds:', settleTheseIds);

    if (settleTheseIds.length > 0) {
      await trading.settle(settleTheseIds);
      console.log('Settled ids');
    }
  }, 5000);
  
}

// We recommend this pattern to be able to use async/await everywhere
// and properly handle errors.
main();
