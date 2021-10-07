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
  return ethers.utils.parseUnits(number, units || 18);
}

const formatUnits = function (number, units) {
  return ethers.utils.formatUnits(number, units || 18);
}

function sleep(ms) {
  return new Promise(resolve => setTimeout(resolve, ms));
}

const products = {
  localhost: [
    {
      id: 1, // ETH-USD
      feed: '0x0000000000000000000000000000000000000000',
      leverage: 50,
      fee: 0.15,
      symbol: 'ETH-USD'
    },
    {
      id: 2, // BTC-USD
      feed: '0x0000000000000000000000000000000000000000',
      leverage: 100,
      fee: 0.15,
      symbol: 'BTC-USD'
    }
  ],
  rinkeby: [
  ],
  arbitrum: [
  ]
};

async function main() {
  // Hardhat always runs the compile task when running scripts with its command
  // line interface.
  //
  // If this script is run directly using `node` you may want to call compile
  // manually to make sure everything is compiled
  // await hre.run('compile');

  const provider = hre.ethers.provider;
  const signer = await provider.getSigner();

  /*
  await hre.ethers.provider.send('hardhat_setNonce', [
    "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266",
    "0x3b"
  ]);
  return;
  */

  const account = await signer.getAddress();
  console.log('account', account);
  console.log('Account balance', formatUnits(await provider.getBalance(account)));

  const Trading = await hre.ethers.getContractFactory("Trading");
  const trading = await Trading.deploy();
  await trading.deployed();
  console.log("Trading deployed to:", trading.address);

  const Oracle = await hre.ethers.getContractFactory("Oracle");
  const oracle = await Oracle.deploy();
  await oracle.deployed();
  console.log("Oracle deployed to:", oracle.address);

  const Treasury = await hre.ethers.getContractFactory("Treasury");
  const treasury = await Treasury.deploy();
  await treasury.deployed();
  console.log("Treasury deployed to:", treasury.address);

  const network = hre.network.name;
  console.log('network', network);

  // Trading setup

  // Set contract dependencies

  await trading.setOracle(oracle.address);
  await trading.setTreasury(treasury.address);

  // Add products
  
  for (const p of products[network]) {
    await trading.addProduct(p.id, [
      p.feed,
      parseUnits(""+p.leverage, 8),
      p.fee * 100,
      1200,
      true,
      parseUnits("1000", 8),
      0,
      0,
      250, 
      0
    ]);
    console.log('Added product ' + p.symbol);
  }

  // Oracle setup

  //await oracle.setOracle('0x14dc79964da2c08b23698b3d3cc7ca32193d9955'); // account 7 on local node
  await oracle.setOracle('0x1192AAE2aB5Bad7c555f45b102Ea68D7A07689A4'); // v2-oracle
  await oracle.setTrading(trading.address);
  await oracle.setTreasury(treasury.address);

  // Treasury setup

  await treasury.setTrading(trading.address);
  await treasury.setOracle(oracle.address);

  await treasury.creditVault({value: parseUnits("20")});

  return;







  // Below are method tests

  //const randomWallet = await hre.ethers.Wallet.createRandom();
  //console.log('Created random wallet', randomWallet);

  // Stake in vault
  await trading.stake({value: parseUnits("100")});
  console.log('Staked 100 ETH');

  // submit order
  await trading.openPosition(1, true, parseUnits("50"), {value: parseUnits("10")});
  console.log('Submitted order long 10 ETH at 100x');

  let positions = await trading.getUserPositions(account);

  console.log('Positions', positions);
  console.log('Info', formatUnits(positions[0].price, 8), formatUnits(positions[0].margin));


  console.log('Account balance', formatUnits(await provider.getBalance(account)));

  // settle open position
  let settlingIds = await trading.checkPositionsToSettle();  
  console.log('Settling Ids', settlingIds);

  await trading.settlePositions(settlingIds);
  console.log('Settling position open (perform)');

  positions = await trading.getUserPositions(account);

  console.log('Positions', positions);
  console.log('Info', formatUnits(positions[0].price, 8), formatUnits(positions[0].margin));

  settlingIds = await trading.checkPositionsToSettle();  
  console.log('Settling Ids (2)', settlingIds);

  // add margin
  await trading.addMargin(1, {value: parseUnits("5")});
  console.log('Added 5 ETH margin');

  positions = await trading.getUserPositions(account);

  console.log('Positions', positions);
  console.log('Info', formatUnits(positions[0].price, 8), formatUnits(positions[0].margin));

  console.log('Account balance', formatUnits(await provider.getBalance(account)));

  // close position partial (2)
  await trading.closePosition(1, parseUnits("2"), false);
  console.log('Closed 2 ETH partially');

  positions = await trading.getUserPositions(account);

  console.log('Positions', positions);
  console.log('Info', formatUnits(positions[0].price, 8), formatUnits(positions[0].margin));

  console.log('Account balance', formatUnits(await provider.getBalance(account)));
  console.log('Vault balance', formatUnits(await provider.getBalance(trading.address)));

  // close remainder (13)
  await trading.closePosition(1, parseUnits("13"), false);
  console.log('Closed fully');

  positions = await trading.getUserPositions(account);

  console.log('Positions', positions);
  //console.log('Info', formatUnits(positions[0].price, 8), formatUnits(positions[0].margin));

  console.log('Account balance', formatUnits(await provider.getBalance(account)));
  console.log('Vault balance', formatUnits(await provider.getBalance(trading.address)));

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
