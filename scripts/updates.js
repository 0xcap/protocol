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
      //{
      //  id: 16,
      //  feed: '0xaD1d5344AaDE45F43E596773Bcc4c423EAbdD034',
      //  leverage: 20,
      //  fee: 0.25,
      //  symbol: 'AAVE-USD'
      //},
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

  const abi = [
    "function addProduct(uint256 productId, tuple(address feed, uint72 maxLeverage, uint16 fee, bool isActive, uint64 maxExposure, uint48 openInterestLong, uint48 openInterestShort, uint16 interest, uint32 settlementTime, uint16 minTradeDuration, uint16 liquidationThreshold, uint16 liquidationBounty))",
    "function updateProduct(uint256 productId, tuple(address feed, uint72 maxLeverage, uint16 fee, bool isActive, uint64 maxExposure, uint48 openInterestLong, uint48 openInterestShort, uint16 interest, uint32 settlementTime, uint16 minTradeDuration, uint16 liquidationThreshold, uint16 liquidationBounty))"
  ];
  const trading = new hre.ethers.Contract(address, abi, signer);

  console.log("Trading address:", trading.address);

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

  /*
  for (const p of products[hre.network.name]) {
    await trading.updateProduct(p.id, [
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
    console.log('Updated product ' + p.symbol);
  }
  */

}

// We recommend this pattern to be able to use async/await everywhere
// and properly handle errors.
main();
