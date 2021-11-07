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

  const darkOracleAddress = '0x14dc79964da2c08b23698b3d3cc7ca32193d9955';

  const account = await signer.getAddress();
  console.log('account', account);
  console.log('Account balance', formatUnits(await provider.getBalance(account)));

  // Router
  const Router = await hre.ethers.getContractFactory("Router");
  const router = await Router.deploy();
  await router.deployed();
  console.log("Router deployed to:", router.address);

  // Trading
  const Trading = await hre.ethers.getContractFactory("Trading");
  const trading = await Trading.deploy();
  await trading.deployed();
  console.log("Trading deployed to:", trading.address);

  // Oracle
  const Oracle = await hre.ethers.getContractFactory("Oracle");
  const oracle = await Oracle.deploy();
  await oracle.deployed();
  console.log("Oracle deployed to:", oracle.address);

  // Treasury
  const Treasury = await hre.ethers.getContractFactory("Treasury");
  const treasury = await Treasury.deploy();
  await treasury.deployed();
  console.log("Treasury deployed to:", treasury.address);

  // WETH, CAP, USDC mock tokens (local only)
  const WETH = await hre.ethers.getContractFactory("WETH");
  const weth = await WETH.deploy();
  await weth.deployed();
  console.log("weth deployed to:", weth.address);

  const MockToken = await hre.ethers.getContractFactory("MockToken");
  const cap = await MockToken.deploy("Cap", "CAP", 18);
  await cap.deployed();
  console.log("cap deployed to:", cap.address);

  const usdc = await MockToken.deploy("USDC", "USDC", 6);
  await usdc.deployed();
  console.log("usdc deployed to:", usdc.address);

  // PoolCAP
  const PoolCAP = await hre.ethers.getContractFactory("PoolCAP");
  const poolCAP = await PoolCAP.deploy(cap.address);
  await poolCAP.deployed();
  console.log("PoolCAP deployed to:", poolCAP.address);

  // Pools (WETH, USDC)
  const Pool = await hre.ethers.getContractFactory("Pool");
  
  const poolWETH = await Pool.deploy(weth.address);
  await poolWETH.deployed();
  console.log("poolWETH deployed to:", poolWETH.address);

  const poolUSDC = await Pool.deploy(usdc.address);
  await poolUSDC.deployed();
  console.log("poolUSDC deployed to:", poolUSDC.address);
  
  // Rewards

  const Rewards = await hre.ethers.getContractFactory("Rewards");

  // Rewards for Pools
  const poolRewardsWETH = await Rewards.deploy(poolWETH.address, weth.address);
  await poolRewardsWETH.deployed();
  console.log("poolRewardsWETH deployed to:", poolRewardsWETH.address);

  const poolRewardsUSDC = await Rewards.deploy(poolUSDC.address, usdc.address);
  await poolRewardsUSDC.deployed();
  console.log("poolRewardsUSDC deployed to:", poolRewardsUSDC.address);

  // Rewards for Cap
  const capRewardsWETH = await Rewards.deploy(poolCAP.address, weth.address);
  await capRewardsWETH.deployed();
  console.log("capRewardsWETH deployed to:", capRewardsWETH.address);

  const capRewardsUSDC = await Rewards.deploy(poolCAP.address, usdc.address);
  await capRewardsUSDC.deployed();
  console.log("capRewardsUSDC deployed to:", capRewardsUSDC.address);


  // Treasury fee share setup
  await treasury.setPoolShare(weth.address, 5000);
  await treasury.setPoolShare(usdc.address, 5000);
  console.log("set pool shares for treasury");

  await treasury.setCapPoolShare(weth.address, 1000);
  await treasury.setCapPoolShare(usdc.address, 1000);
  console.log("set Cap shares for treasury");

  // Router setup
  await router.setContracts(
    treasury.address,
    trading.address,
    poolCAP.address,
    oracle.address,
    darkOracleAddress,
    weth.address
  );

  await router.setPool(weth.address, poolWETH.address);
  await router.setPool(usdc.address, poolUSDC.address);

  await router.setPoolRewards(weth.address, poolRewardsWETH.address);
  await router.setPoolRewards(usdc.address, poolRewardsUSDC.address);

  await router.setCapRewards(weth.address, capRewardsWETH.address);
  await router.setCapRewards(usdc.address, capRewardsUSDC.address);
  
  console.log("Setup router contracts");

  await router.setCurrencies([weth.address, usdc.address]);
  console.log("Setup router currencies");

  // Link contracts with Router, which also sets their dependent contract addresses
  await trading.setRouter(router.address);
  await treasury.setRouter(router.address);
  await poolCAP.setRouter(router.address);
  await oracle.setRouter(router.address);
  await poolWETH.setRouter(router.address);
  await poolUSDC.setRouter(router.address);
  await poolRewardsWETH.setRouter(router.address);
  await poolRewardsUSDC.setRouter(router.address);
  await capRewardsWETH.setRouter(router.address);
  await capRewardsUSDC.setRouter(router.address);

  console.log("Linked router with contracts");

  const network = hre.network.name;
  console.log('network', network);

  // Add products

  const products = [
    {
      symbol: 'ETH-USD',
      id: 1,
      feed: '0x0000000000000000000000000000000000000000',
      maxLeverage: 50,
      oracleMaxDeviation: 2.5,
      fee: 0.15,
      interest: 16,
      liquidationThreshold: 80
    },
    {
      symbol: 'BTC-USD',
      id: 2,
      feed: '0x0000000000000000000000000000000000000000',
      maxLeverage: 100,
      oracleMaxDeviation: 2.5,
      fee: 0.15,
      interest: 16,
      liquidationThreshold: 80
    }
  ];

  for (const p of products) {
    await trading.addProduct(p.id, [
      p.feed,
      parseUnits(""+p.maxLeverage),
      parseInt(p.oracleMaxDeviation * 100),
      parseInt(p.liquidationThreshold * 100),
      parseInt(p.fee * 10000),
      parseInt(p.interest * 100),
    ]);
    console.log('Added product ' + p.symbol);
  }

  // Mint some CAP, USDC
  await usdc.mint(parseUnits("100000", 6));
  await cap.mint(parseUnits("1000"));

}

// We recommend this pattern to be able to use async/await everywhere
// and properly handle errors.
main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
