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

  const tradingAddress = '0x0Dd99d9f56A14E9D53b2DdC62D9f0bAbe806647A';
  const oracleAddress = '0xeAd789bd8Ce8b9E94F5D0FCa99F8787c7e758817';
  const treasuryAddress = '0x95775fD3Afb1F4072794CA4ddA27F2444BCf8Ac3';

  console.log('Trading balance', formatUnits(await provider.getBalance(tradingAddress)));
  console.log('Oracle balance', formatUnits(await provider.getBalance(oracleAddress)));
  console.log('Treasury balance', formatUnits(await provider.getBalance(treasuryAddress)));

  const trading = await (await ethers.getContractFactory("Trading")).attach(tradingAddress);
  const oracle = await (await ethers.getContractFactory("Oracle")).attach(oracleAddress);
  const treasury = await (await ethers.getContractFactory("Treasury")).attach(treasuryAddress);

  let tx, receipt;

  
  // submit order
  // tx = await trading.connect(user).submitNewPosition(1, true, parseUnits("50", 8), {value: parseUnits("1")});
  // console.log('Submitted order long 1 ETH at 50x');
  // receipt = await provider.getTransactionReceipt(tx.hash);
  // console.log('Gas used:', (receipt.gasUsed).toNumber()); // 77291
  

  // const posId = await trading.nextPositionId();
  // console.log('Position', posId, await trading.getPositions([posId]));
  
  // // submit partial close order
  // tx = await trading.connect(user).submitCloseOrder(posId, parseUnits("0.3", 8), false);
  // console.log('Submitted close order for 0.3 ETH on position ', posId);
  // receipt = await provider.getTransactionReceipt(tx.hash);
  // console.log('Gas used:', (receipt.gasUsed).toNumber()); // 62222

  // // submit rest of close order (full)
  // tx = await trading.connect(user).submitCloseOrder(posId, parseUnits("0.7", 8), false);
  // console.log('Submitted close order for 0.7 ETH on position ', posId);
  // receipt = await provider.getTransactionReceipt(tx.hash);
  // console.log('Gas used:', (receipt.gasUsed).toNumber()); // 62222

  // // cancel close order
  // tx = await trading.connect(user).cancelOrder(3);
  // console.log('Cancelled close order', 3);
  // receipt = await provider.getTransactionReceipt(tx.hash);
  // console.log('Gas used:', (receipt.gasUsed).toNumber()); // 28987


  // Treasury

  // Fund vault
  // await treasury.fundVault(parseUnits("1"));
  // console.log('Trading balance', formatUnits(await provider.getBalance(tradingAddress)));
  // console.log('Treasury balance', formatUnits(await provider.getBalance(treasuryAddress)));

  // Send ETH
  // console.log('Owner balance pre', formatUnits(await provider.getBalance(owner.address)));
  // await treasury.sendETH(owner.address, parseUnits("1.221"));
  // console.log('Owner balance', formatUnits(await provider.getBalance(owner.address)));
  // console.log('Treasury balance', formatUnits(await provider.getBalance(treasuryAddress)));

  // Transfer from owner to treasury
  // console.log('Owner balance pre', formatUnits(await provider.getBalance(owner.address)));
  // await owner.sendTransaction({to: treasuryAddress, value: parseUnits("1.454")});
  // console.log('Treasury balance', formatUnits(await provider.getBalance(treasuryAddress)));

}

// We recommend this pattern to be able to use async/await everywhere
// and properly handle errors.
main();
