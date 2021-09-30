// We require the Hardhat Runtime Environment explicitly here. This is optional
// but useful for running the script in a standalone fashion through `node <script>`.
//
// When running the script with `npx hardhat run <script>` you'll find the Hardhat
// Runtime Environment's members available in the global scope.
const hre = require("hardhat");
const { ethers } = require('hardhat');

const parseUnits = function (number, units) {
  return ethers.utils.parseUnits(number, units || 18);
}

const formatUnits = function (number, units) {
  return ethers.utils.formatUnits(number, units || 18);
}

async function main() {
  // Hardhat always runs the compile task when running scripts with its command
  // line interface.
  //
  // If this script is run directly using `node` you may want to call compile
  // manually to make sure everything is compiled
  // await hre.run('compile');

  const provider = hre.ethers.provider;
  const [owner, user] = await ethers.getSigners();

  console.log('owner', owner.address);
  console.log('user', user.address);

  const tradingAddress = '0x5081a39b8A5f0E35a8D959395a630b68B74Dd30f';
  const oracleAddress = '0x1fA02b2d6A771842690194Cf62D91bdd92BfE28d';
  const treasuryAddress = '0xdbC43Ba45381e02825b14322cDdd15eC4B3164E6';

  console.log('Trading balance', formatUnits(await provider.getBalance(tradingAddress)));
  console.log('Oracle balance', formatUnits(await provider.getBalance(oracleAddress)));
  console.log('Treasury balance', formatUnits(await provider.getBalance(treasuryAddress)));

  const trading = await (await ethers.getContractFactory("Trading")).attach(tradingAddress);
  const oracle = await (await ethers.getContractFactory("Oracle")).attach(oracleAddress);
  const treasury = await (await ethers.getContractFactory("Treasury")).attach(treasuryAddress);

  // submit order
  let tx = await trading.connect(user).submitNewPosition(1, true, parseUnits("50", 8), {value: parseUnits("1")});
  console.log('Submitted order long 1 ETH at 50x');
  let receipt = await provider.getTransactionReceipt(tx.hash);
  console.log('Gas used:', (receipt.gasUsed).toNumber());

  const posId = await trading.nextPositionId();
  console.log('Position', posId, await trading.getPositions([posId]));

}

// We recommend this pattern to be able to use async/await everywhere
// and properly handle errors.
main();
