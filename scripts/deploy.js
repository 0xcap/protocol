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

const products = {
  rinkeby: [
    {
      id: 1, // ETH-USD
      feed: '0x8A753747A1Fa494EC906cE90E9f37563A8AF630e',
      leverage: 50,
      fee: 0.05,
      symbol: 'ETH-USD'
    },
    {
      id: 2, // BTC-USD
      feed: '0xECe365B379E1dD183B20fc5f022230C044d51404',
      leverage: 100,
      fee: 0.05,
      symbol: 'BTC-USD'
    },
    {
      id: 3, // LINK-USD
      feed: '0xd8bD0a1cB028a31AA859A21A3758685a95dE4623',
      leverage: 30,
      fee: 0.05,
      symbol: 'LINK-USD'
    },
    {
      id: 4, // XRP-USD
      feed: '0xc3E76f41CAbA4aB38F00c7255d4df663DA02A024',
      leverage: 20,
      fee: 0.05,
      symbol: 'XRP-USD'
    },
    {
      id: 5, // XAU-USD
      feed: '0x81570059A0cb83888f1459Ec66Aad1Ac16730243',
      leverage: 50,
      fee: 0.02,
      symbol: 'XAU-USD',
      longSettle: true
    },
    {
      id: 6, // XAG-USD
      feed: '0x9c1946428f4f159dB4889aA6B218833f467e1BfD',
      leverage: 50,
      fee: 0.02,
      symbol: 'XAG-USD',
      longSettle: true
    },
    {
      id: 7, // Oil-USD
      feed: '0x6292aA9a6650aE14fbf974E5029f36F95a1848Fd',
      leverage: 50,
      fee: 0.03,
      symbol: 'Oil-USD',
      longSettle: true
    },
    {
      id: 8, // EUR-USD
      feed: '0x78F9e60608bF48a1155b4B2A5e31F32318a1d85F',
      leverage: 200,
      fee: 0.01,
      symbol: 'EUR-USD',
      longSettle: true
    },
    {
      id: 9, // GBP-USD
      feed: '0x7B17A813eEC55515Fb8F49F2ef51502bC54DD40F',
      leverage: 200,
      fee: 0.01,
      symbol: 'GBP-USD',
      longSettle: true
    },
    {
      id: 10, // JPY-USD
      feed: '0x3Ae2F46a2D84e3D5590ee6Ee5116B80caF77DeCA',
      leverage: 200,
      fee: 0.01,
      symbol: 'JPY-USD',
      longSettle: true
    },
    {
      id: 11, // CHF-USD
      feed: '0x5e601CF5EF284Bcd12decBDa189479413284E1d2',
      leverage: 200,
      fee: 0.01,
      symbol: 'CHF-USD',
      longSettle: true
    },
    {
      id: 12, // AUD-USD
      feed: '0x21c095d2aDa464A294956eA058077F14F66535af',
      leverage: 200,
      fee: 0.01,
      symbol: 'AUD-USD',
      longSettle: true
    }
  ]
};

/*
const chainlink_feeds = { 
  localhost: [,'0x5f4ec3df9cbd43714fe2740f5e3616155c5b8419', '0xF4030086522a5bEEa4988F8cA5B36dbC97BeE88c', '0x214eD9Da11D2fbe465a6fc601a91E62EbEc1a0D6', '0xb49f677943BC038e9857d61E7d053CaA2C1734C1'], // same as mainnet because forked from it. // ETH-USD, BTC-USD, Gold, EUR/USD
  mainnet: [,'0x5f4ec3df9cbd43714fe2740f5e3616155c5b8419', '0xF4030086522a5bEEa4988F8cA5B36dbC97BeE88c'],
  rinkeby: [,'0x8A753747A1Fa494EC906cE90E9f37563A8AF630e', '0xECe365B379E1dD183B20fc5f022230C044d51404', '0x81570059A0cb83888f1459Ec66Aad1Ac16730243', '0x78F9e60608bF48a1155b4B2A5e31F32318a1d85F'],// ETH-USD, BTC-USD, Gold, EUR/USD
  arbitrum_rinkeby: [,'0x0c9973e7a27d00e656B9f153348dA46CaD70d03d', '0x5f0423B1a6935dc5596e7A24d98532b67A0AeFd8'],// ETH-USD, BTC-USD
  arbitrum: [, '0x639Fe6ab55C921f74e7fac1ee960C0B6293ba612', '0x6ce185860a4963106506C203335A2910413708e9', null, '0xA14d53bC1F1c0F31B4aA3BD109344E5009051a84']// ETH-USD, BTC-USD, , EUR/USD
}
*/

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
  console.log("Cap Trading deployed to:", trading.address);

  await trading.updateVault([
    parseUnits("100"), 
    0,
    0,
    0,
    0,
    30 * 24 * 3600, 
    8 * 3600,
    25 * 100
  ]);
  console.log('Updated vault');

  for (const p of products[hre.network.name]) {
    await trading.addProduct(p.id, [
      p.feed,
      parseUnits(""+p.leverage),
      p.fee * 100, 
      true,
      parseUnits("50000"),
      0,
      0,
      5 * 100, 
      p.longSettle ? 72 * 3600 : 1 * 60, 
      0 * 60, 
      80 * 100, 
      5 * 100
    ]);
    console.log('Added product ' + p.symbol);
  }

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
