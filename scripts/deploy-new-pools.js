// We require the Hardhat Runtime Environment explicitly here. This is optional
// but useful for running the script in a standalone fashion through `node <script>`.
//
// When running the script with `npx hardhat run <script>` you'll find the Hardhat
// Runtime Environment's members available in the global scope.
const hre = require("hardhat");
const { ethers } = require('hardhat');

const ADDRESS_ZERO = '0x0000000000000000000000000000000000000000';

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
  return ethers.utils.formatUnits(number, units || 8);
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

  const account = await signer.getAddress();
  console.log('account', account);
  console.log('Account balance', formatUnits(await provider.getBalance(account)));

  const routerAddress = '0x5ABFF8F8D5b13253dCAB1e427Fdb3305cA620119';
  const router = await (await ethers.getContractFactory("Router")).attach(routerAddress);

  const usdc = {address: '0xff970a61a04b1ca14834a43f5de4533ebddb5cc8'};
  console.log("usdc:", usdc.address);

  // // Pools (WETH, USDC)
  // const Pool = await hre.ethers.getContractFactory("Pool");
  
  // const poolETH = await Pool.deploy(ADDRESS_ZERO);
  // await poolETH.deployed();
  // console.log("poolETH deployed to:", poolETH.address);

  // const poolUSDC = await Pool.deploy(usdc.address);
  // await poolUSDC.deployed();
  // console.log("poolUSDC deployed to:", poolUSDC.address);

  // // Rewards

  // const Rewards = await hre.ethers.getContractFactory("Rewards");

  // // Rewards for Pools
  // const poolRewardsETH = await Rewards.deploy(poolETH.address, ADDRESS_ZERO);
  // await poolRewardsETH.deployed();
  // console.log("poolRewardsETH deployed to:", poolRewardsETH.address);

  // const poolRewardsUSDC = await Rewards.deploy(poolUSDC.address, usdc.address);
  // await poolRewardsUSDC.deployed();
  // console.log("poolRewardsUSDC deployed to:", poolRewardsUSDC.address);

  // Router

  const poolETH = await (await ethers.getContractFactory("Pool")).attach('0xE0cCd451BB57851c1B2172c07d8b4A7c6952a54e');
  const poolUSDC = await (await ethers.getContractFactory("Pool")).attach('0x958cc92297e6F087f41A86125BA8E121F0FbEcF2');
  const poolRewardsETH = await (await ethers.getContractFactory("Rewards")).attach('0x29163356bBAF0a3bfeE9BA5a52a5C6463114Cb5f');
  const poolRewardsUSDC = await (await ethers.getContractFactory("Rewards")).attach('0x10f2f3B550d98b6E51461a83AD3FE27123391029');


  await router.setPool(ADDRESS_ZERO, '0xE0cCd451BB57851c1B2172c07d8b4A7c6952a54e');
  await router.setPool(usdc.address, '0x958cc92297e6F087f41A86125BA8E121F0FbEcF2');

  await router.setPoolRewards(ADDRESS_ZERO, '0x29163356bBAF0a3bfeE9BA5a52a5C6463114Cb5f');
  await router.setPoolRewards(usdc.address, '0x10f2f3B550d98b6E51461a83AD3FE27123391029');

  console.log("Setup router contracts");

  // Link contracts with Router, which also sets their dependent contract addresses
  await poolETH.setRouter(router.address);
  await poolUSDC.setRouter(router.address);
  await poolRewardsETH.setRouter(router.address);
  await poolRewardsUSDC.setRouter(router.address);

  console.log("Linked router with contracts");

  const network = hre.network.name;
  console.log('network', network);

}

// We recommend this pattern to be able to use async/await everywhere
// and properly handle errors.
main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
});