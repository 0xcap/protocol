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

  const tradingAddress = '0x5302E909d1e93e30F05B5D6Eea766363D14F9892';
  const oracleAddress = '0x0ed64d01D0B4B655E410EF1441dD677B695639E7';
  const treasuryAddress = '0x4bf010f1b9beDA5450a8dD702ED602A104ff65EE';

  console.log('Trading balance', formatUnits(await provider.getBalance(tradingAddress)));
  console.log('Oracle balance', formatUnits(await provider.getBalance(oracleAddress)));
  console.log('Treasury balance', formatUnits(await provider.getBalance(treasuryAddress)));

  const trading = await (await ethers.getContractFactory("Trading")).attach(tradingAddress);
  const oracle = await (await ethers.getContractFactory("Oracle")).attach(oracleAddress);
  const treasury = await (await ethers.getContractFactory("Treasury")).attach(treasuryAddress);

  let tx, receipt;
  /*
  // submit order
  tx = await trading.connect(user).submitNewPosition(1, true, parseUnits("50", 8), {value: parseUnits("1")});
  console.log('Submitted order long 1 ETH at 50x');
  receipt = await provider.getTransactionReceipt(tx.hash);
  console.log('Gas used:', (receipt.gasUsed).toNumber()); // 77000

  */

  const posId = await trading.nextPositionId();
  console.log('Position', posId, await trading.getPositions([posId]));

  /*
  // cancel close order
  tx = await trading.connect(user).cancelOrder(1);
  console.log('Cancelled close order', 1);
  receipt = await provider.getTransactionReceipt(tx.hash);
  console.log('Gas used:', (receipt.gasUsed).toNumber()); // 28987
  */

  /*
  // submit close order
  tx = await trading.connect(user).submitCloseOrder(posId, parseUnits("0.3", 8), false);
  console.log('Submitted close order for 0.3 ETH on position ', posId);
  receipt = await provider.getTransactionReceipt(tx.hash);
  console.log('Gas used:', (receipt.gasUsed).toNumber()); // 62222
  */

}

// We recommend this pattern to be able to use async/await everywhere
// and properly handle errors.
main();
