// We require the Hardhat Runtime Environment explicitly here. This is optional
// but useful for running the script in a standalone fashion through `node <script>`.
//
// When running the script with `npx hardhat run <script>` you'll find the Hardhat
// Runtime Environment's members available in the global scope.
const hre = require("hardhat");
const { ethers } = require('hardhat');

const parseUnits = function (number, units) {
  return ethers.utils.parseUnits(number, units || 8);
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

  const signer = await hre.ethers.provider.getSigner();

  console.log('signer', await signer.getAddress());

  const address = '0x9BC357bc5b312AaCD41a84F3C687F031B8786853';

  const products = {
    arbitrum: [
      {
        id: 1, // ETH-USD
        feed: '0x639Fe6ab55C921f74e7fac1ee960C0B6293ba612',
        leverage: 50,
        fee: 0.15,
        symbol: 'ETH-USD'
      },
      {
        id: 2, // BTC-USD
        feed: '0x6ce185860a4963106506C203335A2910413708e9',
        leverage: 100,
        fee: 0.15,
        symbol: 'BTC-USD'
      },
      {
        id: 3, // LINK-USD
        feed: '0x86E53CF1B870786351Da77A57575e79CB55812CB',
        leverage: 20,
        fee: 0.25,
        symbol: 'LINK-USD'
      },
      {
        id: 16,
        feed: '0xaD1d5344AaDE45F43E596773Bcc4c423EAbdD034',
        leverage: 20,
        fee: 0.25,
        symbol: 'AAVE-USD'
      },
      {
        id: 17,
        feed: '0xb2A8BA74cbca38508BA1632761b56C897060147C',
        leverage: 20,
        fee: 0.25,
        symbol: 'SUSHI-USD'
      },
      {
        id: 18,
        feed: '0x9C917083fDb403ab5ADbEC26Ee294f6EcAda2720',
        leverage: 20,
        fee: 0.25,
        symbol: 'UNI-USD'
      },
      {
        id: 19,
        feed: '0x745Ab5b69E01E2BE1104Ca84937Bb71f96f5fB21',
        leverage: 10,
        fee: 0.25,
        symbol: 'YFI-USD'
      },
    ]
  };

  const deactivateProducts = {
    arbitrum: [
      {
        id: 8, // EUR-USD
        feed: '0xA14d53bC1F1c0F31B4aA3BD109344E5009051a84',
        leverage: 200,
        fee: 0.05,
        symbol: 'EUR-USD',
        longSettle: true
      },
      {
        id: 12, // AUD-USD
        feed: '0x9854e9a850e7C354c1de177eA953a6b1fba8Fc22',
        leverage: 100,
        fee: 0.1,
        symbol: 'AUD-USD',
        longSettle: true
      },
      {
        id: 13, // KRW-USD
        feed: '0x85bb02E0Ae286600d1c68Bb6Ce22Cc998d411916',
        leverage: 50,
        fee: 0.1,
        symbol: 'KRW-USD',
        longSettle: true
      },
      {
        id: 14, // PHP-USD
        feed: '0xfF82AAF635645fD0bcc7b619C3F28004cDb58574',
        leverage: 50,
        fee: 0.1,
        symbol: 'PHP-USD',
        longSettle: true
      },
    ]
  }

  const abi = [
    "function addProduct(uint256 productId, tuple(address feed, uint72 maxLeverage, uint16 fee, bool isActive, uint64 maxExposure, uint48 openInterestLong, uint48 openInterestShort, uint16 interest, uint32 settlementTime, uint16 minTradeDuration, uint16 liquidationThreshold, uint16 liquidationBounty))",
    "function updateProduct(uint256 productId, tuple(address feed, uint72 maxLeverage, uint16 fee, bool isActive, uint64 maxExposure, uint48 openInterestLong, uint48 openInterestShort, uint16 interest, uint32 settlementTime, uint16 minTradeDuration, uint16 liquidationThreshold, uint16 liquidationBounty))"
  ];
  const trading = new hre.ethers.Contract(address, abi, signer);

  console.log("Trading address:", trading.address);

  /*
  for (const p of products[hre.network.name]) {
    await trading.addProduct(p.id, [
      p.feed,
      parseUnits(""+p.leverage),
      p.fee * 100, 
      true,
      parseUnits("200"),
      0,
      0,
      12 * 100, 
      p.longSettle ? 72 * 3600 : 2 * 60, 
      2 * 60, 
      80 * 100, 
      5 * 100
    ]);
    console.log('Added product ' + p.symbol);
  }
  */

  for (const p of products[hre.network.name]) {
    await trading.updateProduct(p.id, [
      p.feed,
      parseUnits(""+p.leverage),
      p.fee * 100, 
      true,
      parseUnits("300"),
      0,
      0,
      8 * 100, 
      p.longSettle ? 72 * 3600 : 2 * 60, 
      0, 
      80 * 100, 
      5 * 100
    ]);
    console.log('Updated product ' + p.symbol);
  }

  /*
  for (const p of deactivateProducts[hre.network.name]) {
    await trading.updateProduct(p.id, [
      p.feed,
      parseUnits(""+p.leverage),
      p.fee * 100, 
      false,
      parseUnits("1000"),
      0,
      0,
      12 * 100, 
      p.longSettle ? 72 * 3600 : 2 * 60, 
      2 * 60, 
      80 * 100, 
      5 * 100
    ]);
    console.log('Updated product ' + p.symbol);
  }
  */

}

// We recommend this pattern to be able to use async/await everywhere
// and properly handle errors.
main();
