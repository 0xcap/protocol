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

const formatUnits = function (number, units) {
  if (!units) units = 6; // usdc
  return ethers.utils.formatUnits(number, units);
}

function sleep(ms) {
  return new Promise(resolve => setTimeout(resolve, ms));
}

const chainlink_feeds = { 
  localhost: [,'0x5f4ec3df9cbd43714fe2740f5e3616155c5b8419', '0xF4030086522a5bEEa4988F8cA5B36dbC97BeE88c', '0x214eD9Da11D2fbe465a6fc601a91E62EbEc1a0D6', '0xb49f677943BC038e9857d61E7d053CaA2C1734C1'], // same as mainnet because forked from it. // ETH-USD, BTC-USD, Gold, EUR/USD
  mainnet: [,'0x5f4ec3df9cbd43714fe2740f5e3616155c5b8419', '0xF4030086522a5bEEa4988F8cA5B36dbC97BeE88c'],
  rinkeby: [,'0x8A753747A1Fa494EC906cE90E9f37563A8AF630e', '0xECe365B379E1dD183B20fc5f022230C044d51404', '0x81570059A0cb83888f1459Ec66Aad1Ac16730243', '0x78F9e60608bF48a1155b4B2A5e31F32318a1d85F'],// ETH-USD, BTC-USD, Gold, EUR/USD
  arbitrum: []
}

async function main() {
  // Hardhat always runs the compile task when running scripts with its command
  // line interface.
  //
  // If this script is run directly using `node` you may want to call compile
  // manually to make sure everything is compiled
  // await hre.run('compile');

  const signer = await hre.ethers.provider.getSigner();

  /*
  await hre.ethers.provider.send('hardhat_setNonce', [
    "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266",
    "0x3b"
  ]);
  return;
  */

  const account = await signer.getAddress();
  console.log('account', account);

  // Mint USDC Mock
  const USDC = await hre.ethers.getContractFactory("USDCMock");
  const usdc = await USDC.deploy();
  await usdc.deployed();
  console.log("USDC deployed to:", usdc.address);

  // USDC address
  const base = usdc.address;

  const Trading = await hre.ethers.getContractFactory("Trading");
  const trading = await Trading.deploy();
  await trading.deployed();
  console.log("Cap Trading deployed to:", trading.address);

  await trading.addVault(1, [base, 4000000 * 10**6, 8000000 * 10**6, 25 * 100, 30 * 24 * 3600, 8 * 3600, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, true]);
  console.log('Added vault USDC');

  await trading.addProduct(1, [50 * 10**6, 0.05 * 100, 5 * 100, chainlink_feeds[hre.network.name][1], 1 * 60, 0 * 60, 80 * 100, 5 * 100, true]);
  console.log('Added product ETH/USD');

  await trading.addProduct(2, [100 * 10**6, 0.05 * 100, 5 * 100, chainlink_feeds[hre.network.name][2], 1 * 60, 0 * 60, 80 * 100, 5 * 100, true]);
  console.log('Added product BTC/USD');

  await trading.addProduct(3, [50 * 10**6, 0.02 * 100, 5 * 100, chainlink_feeds[hre.network.name][3], 1 * 60, 0 * 60, 80 * 100, 5 * 100, true]);
  console.log('Added product Gold');

  await trading.addProduct(4, [200 * 10**6, 0.01 * 100, 5 * 100, chainlink_feeds[hre.network.name][4], 1 * 60, 0 * 60, 80 * 100, 5 * 100, true]);
  console.log('Added product EUR/USD');


  //const randomWallet = await hre.ethers.Wallet.createRandom();
  //console.log('Created random wallet', randomWallet);

  await usdc.mint(account, 10000000 * 10**6);
  console.log('Minted USDC to', account, (await usdc.balanceOf(account)).toNumber());

  //await usdc.approve(trading.address, 10000000 * 10**6);
  //console.log('Approved Trading contract to spend USDC');

  // Stake in vault
  //await trading.stake(1, 10000 * 10**6);
  //console.log('Staked', 10000);

  console.log('Account balance', formatUnits((await usdc.balanceOf(account)).toNumber()));

  return;
  // below this are local tests, not needing for client interaction

  //await usdc.transfer(randomWallet.address, 2000 * 10**6);
  //console.log((await usdc.balanceOf(randomWallet.address)).toNumber());

  // deposit
  /*
  console.log('h');
  await trading.deposit(base, 1000 * 10**6);
  console.log('g');
  console.log('Deposited 1000 USDC. Balance:', formatUnits(await mu.balances(account, base)));
  console.log('y');

  // withdraw
  await mu.withdraw(base, 300 * 10**6);
  console.log('Withdrew 300 USDC. Balance:', formatUnits(await mu.balances(account, base)));
  */

  // submit order
  await trading.submitOrder(1, 1, true, 0, 100 * 10**6, 10 * 10**6, false);
  console.log('Submitted order');

  let positions = await trading.getUserPositions(account, 1);

  console.log('Positions', positions);
  console.log('Info', formatUnits(positions[0].price, 8), formatUnits(positions[0].margin));

  console.log('Account balance', formatUnits((await usdc.balanceOf(account)).toNumber()));

  // settle open position
  let settlingIds = await trading.checkSettlement();  
  console.log('Settling Ids', settlingIds);

  await trading.performSettlement(settlingIds);
  console.log('Settling position open (perform)');

  positions = await trading.getUserPositions(account, 1);

  console.log('Positions', positions);
  console.log('Info', formatUnits(positions[0].price, 8), formatUnits(positions[0].margin));

  settlingIds = await trading.checkSettlement();  
  console.log('Settling Ids (2)', settlingIds);

  // add margin
  await trading.submitOrder(1, 1, true, 1, 50 * 10**6, 1, false);
  console.log('Added margin');

  positions = await trading.getUserPositions(account, 1);

  console.log('Positions', positions);
  console.log('Info', formatUnits(positions[0].price, 8), formatUnits(positions[0].margin));

  console.log('Account balance', formatUnits((await usdc.balanceOf(account)).toNumber()));

  // close position partial (25)
  await trading.submitOrder(1, 1, false, 1, 25 * 10**6, 1, false);
  console.log('Closed partially');

  positions = await trading.getUserPositions(account, 1);

  console.log('Positions', positions);
  console.log('Info', formatUnits(positions[0].price, 8), formatUnits(positions[0].margin));

  console.log('Account balance', formatUnits((await usdc.balanceOf(account)).toNumber()));
  console.log('Vault balance', formatUnits((await trading.getBalance(1)).toNumber()));

  // close remainder (125)
  await trading.submitOrder(1, 1, false, 1, 125 * 10**6, 1, false);

  console.log('Closed fully');

  positions = await trading.getUserPositions(account, 1);

  console.log('Positions', positions);
  //console.log('Info', formatUnits(positions[0].price, 8), formatUnits(positions[0].margin));

  console.log('Account balance', formatUnits((await usdc.balanceOf(account)).toNumber()));
  console.log('Vault balance', formatUnits((await trading.getBalance(1)).toNumber()));

  /*
  // liquidate position
  await trading.liquidatePosition(1);
  console.log('liquidating');

  positions = await trading.getUserPositions(account, 1);
  console.log('Positions', positions);

  console.log('Account balance', formatUnits((await usdc.balanceOf(account)).toNumber()));
  console.log('Vault balance', formatUnits((await trading.getBalance(1)).toNumber()));
  */

  /*
  // Unstake partial
  await trading.unstake(1, 2000 * 10**6);
  console.log('Unstake partial');

  console.log('Account balance', formatUnits((await usdc.balanceOf(account)).toNumber()));
  console.log('Vault balance', formatUnits((await trading.getBalance(1)).toNumber()));

  // Unstake remainder
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
