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

  const address = '0x91e434e892381D30bd01E008F539fe8b76217973';

  const products = {
    rinkeby: [
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
      }
    ]
  };

  const abi = [
    "function addProduct(uint16 productId, tuple(address feed, uint64 maxLeverage, uint16 fee, bool isActive, uint64 maxExposure, uint48 openInterestLong, uint48 openInterestShort, uint16 interest, uint32 settlementTime, uint16 minTradeDuration, uint16 liquidationThreshold, uint16 liquidationBounty))"
  ];
  const trading = new hre.ethers.Contract(address, abi, signer);

  console.log("Trading address:", trading.address);

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
    ], {gasLimit: 100000});
    console.log('Added product ' + p.symbol);
  }

}

// We recommend this pattern to be able to use async/await everywhere
// and properly handle errors.
main();
