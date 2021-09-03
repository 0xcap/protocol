// We require the Hardhat Runtime Environment explicitly here. This is optional
// but useful for running the script in a standalone fashion through `node <script>`.
//
// When running the script with `npx hardhat run <script>` you'll find the Hardhat
// Runtime Environment's members available in the global scope.
const hre = require("hardhat");
const { ethers } = require('hardhat');

const toBytes32 = function (string) {
  return ethers.utils.formatBytes32String(string);
}
const fromBytes32 = function (string) {
  return ethers.utils.parseBytes32String(string);
}

const parseUnits = function (number, units) {
  return ethers.utils.parseUnits(number, units || 8);
}

const formatUnits = function (number, units) {
  return ethers.utils.formatUnits(number, units || 18);
}

function sleep(ms) {
  return new Promise(resolve => setTimeout(resolve, ms));
}

const chainlink_feeds = { 
  localhost: [,'0x5f4ec3df9cbd43714fe2740f5e3616155c5b8419', '0xF4030086522a5bEEa4988F8cA5B36dbC97BeE88c', '0x214eD9Da11D2fbe465a6fc601a91E62EbEc1a0D6', '0xb49f677943BC038e9857d61E7d053CaA2C1734C1'], // same as mainnet because forked from it. // ETH-USD, BTC-USD, Gold, EUR/USD
  mainnet: [,'0x5f4ec3df9cbd43714fe2740f5e3616155c5b8419', '0xF4030086522a5bEEa4988F8cA5B36dbC97BeE88c'],
  rinkeby: [,'0x8A753747A1Fa494EC906cE90E9f37563A8AF630e', '0xECe365B379E1dD183B20fc5f022230C044d51404', '0x81570059A0cb83888f1459Ec66Aad1Ac16730243', '0x78F9e60608bF48a1155b4B2A5e31F32318a1d85F'],// ETH-USD, BTC-USD, Gold, EUR/USD
  arbitrum_rinkeby: [,'0x0c9973e7a27d00e656B9f153348dA46CaD70d03d', '0x5f0423B1a6935dc5596e7A24d98532b67A0AeFd8'],// ETH-USD, BTC-USD
  arbitrum: [, '0x639Fe6ab55C921f74e7fac1ee960C0B6293ba612', '0x6ce185860a4963106506C203335A2910413708e9', null, '0xA14d53bC1F1c0F31B4aA3BD109344E5009051a84']// ETH-USD, BTC-USD, , EUR/USD
}

async function main() {
  // Hardhat always runs the compile task when running scripts with its command
  // line interface.
  //
  // If this script is run directly using `node` you may want to call compile
  // manually to make sure everything is compiled
  // await hre.run('compile');

  const provider = hre.ethers.provider;

  //const signer = new hre.ethers.Wallet('0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d', provider);

  const signer = await provider.getSigner();

  //signer.connect(provider);

  const account = await signer.getAddress();
  console.log('account', account);
  console.log('Account balance', formatUnits(await provider.getBalance(account)));

  const Trading = await hre.ethers.getContractFactory("Trading");
  const trading = await Trading.deploy();
  await trading.deployed();
  console.log("Cap Trading deployed to:", trading.address);

  await trading.updateVault([
    parseUnits("1000"), 
    0,
    0,
    0,
    0,
    30 * 24 * 3600, 
    8 * 3600,
    25 * 100
  ]);
  console.log('Updated vault');

  await trading.addProduct(1, [
    chainlink_feeds[hre.network.name][1],
    parseUnits("50"),
    0.05 * 100, 
    true,
    parseUnits("50000"),
    0,
    0,
    5 * 100, 
    1 * 60, 
    0 * 60, 
    80 * 100, 
    5 * 100
  ]);
  console.log('Added product ETH/USD');

  // Stake in vault
  const tx1 = await trading.stake({value: parseUnits("10", 18)});
  const receipt1 = await provider.getTransactionReceipt(tx1.hash);
  console.log('Staked 10 ETH', (receipt1.gasUsed).toNumber());

  console.log('Account balance', formatUnits(await provider.getBalance(account)));

  // submit order
  const tx2 = await trading.openPosition(1, true, parseUnits("50"), {value: parseUnits("10", 18)});
  const receipt2 = await provider.getTransactionReceipt(tx2.hash);
  console.log('Submitted order long 10 ETH margin at 50x', (receipt2.gasUsed).toNumber());

  console.log('Account balance', formatUnits(await provider.getBalance(account)));

  const tx4 = await trading.settlePositions([1]);
  const receipt4 = await provider.getTransactionReceipt(tx4.hash);
  console.log('Settling position open (perform)', (receipt4.gasUsed).toNumber());

  // add margin
  const tx3 = await trading.addMargin(1, {value: parseUnits("5", 18)});
  const receipt3 = await provider.getTransactionReceipt(tx3.hash);
  console.log('Added 5 ETH margin',  (receipt3.gasUsed).toNumber());

  console.log('Account balance', formatUnits(await provider.getBalance(account)));

  const position = await trading.getPosition(1);

  console.log('Position', position);
  console.log('Info', formatUnits(position.price, 8), formatUnits(position.margin, 8));

  // close position partial (2)
  const tx5 = await trading.closePosition(1, parseUnits("2"), false);
  const receipt5 = await provider.getTransactionReceipt(tx5.hash);
  console.log('Closed 2 ETH partially', (receipt5.gasUsed).toNumber());

  console.log('Account balance', formatUnits(await provider.getBalance(account)));

  /*
  // close remainder (13)
  const tx6 = await trading.closePosition(1, parseUnits("13"), false);
  const receipt6 = await provider.getTransactionReceipt(tx6.hash);
  console.log('Closed fully', (receipt6.gasUsed).toNumber());

  const position2 = await trading.getPosition(1);

  console.log('Position2', position2);
  console.log('Info', formatUnits(position2.price, 8), formatUnits(position2.margin, 8));

  console.log('Account balance', formatUnits(await provider.getBalance(account)));
  */

  // liquidate position
  const tx7 = await trading.liquidatePosition(1);
  const receipt7 = await provider.getTransactionReceipt(tx7.hash);
  console.log('Liquidated', (receipt7.gasUsed).toNumber());

  console.log('Account balance', formatUnits(await provider.getBalance(account)));

  /*
  // Redeem partial
  await trading.unstake(1, 2000 * 10**6);
  console.log('Unstake partial');

  console.log('Account balance', formatUnits((await usdc.balanceOf(account)).toNumber()));
  console.log('Vault balance', formatUnits((await trading.getBalance(1)).toNumber()));

  // Redeem remainder
  await trading.unstake(1, 8000 * 10**6);
  console.log('Unstake remaining');

  console.log('Account balance', formatUnits((await usdc.balanceOf(account)).toNumber()));
  console.log('Vault balance', formatUnits((await trading.getBalance(1)).toNumber()));
  */

}

// We recommend this pattern to be able to use async/await everywhere
// and properly handle errors.
main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
