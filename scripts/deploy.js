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

  const darkOracleAddress = '0x1192AAE2aB5Bad7c555f45b102Ea68D7A07689A4';

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

  // Rebates
  const Rebates = await hre.ethers.getContractFactory("Rebates");
  const rebates = await Rebates.deploy();
  await rebates.deployed();
  console.log("Rebates deployed to:", rebates.address);

  // Referrals
  const Referrals = await hre.ethers.getContractFactory("Referrals");
  const referrals = await Referrals.deploy();
  await referrals.deployed();
  console.log("Referrals deployed to:", referrals.address);

  // WETH, CAP, USDC mock tokens (local only)
  const WETH = await hre.ethers.getContractFactory("WETH");
  const weth = await WETH.deploy();
  await weth.deployed();
  console.log("weth deployed to:", weth.address);

  const MockToken = await hre.ethers.getContractFactory("MockToken");
  const cap = await MockToken.deploy("Cap", "CAP");
  await cap.deployed();
  console.log("cap deployed to:", cap.address);

  const usdc = await MockToken.deploy("USDC", "USDC");
  await usdc.deployed();
  console.log("usdc deployed to:", usdc.address);

  // Staking (for CAP)
  const Staking = await hre.ethers.getContractFactory("Staking");
  const staking = await Staking.deploy(cap.address);
  await staking.deployed();
  console.log("Staking deployed to:", staking.address);

  // Pools (WETH, USDC)
  const Pool = await hre.ethers.getContractFactory("Pool");
  
  const poolWETH = await Pool.deploy(weth.address);
  await poolWETH.deployed();
  console.log("poolWETH deployed to:", poolWETH.address);

  const poolUSDC = await Pool.deploy(usdc.address);
  await poolUSDC.deployed();
  console.log("poolUSDC deployed to:", poolUSDC.address);

  // CLPs
  const MintableToken = await hre.ethers.getContractFactory("MintableToken");

  const clpWeth = await MintableToken.deploy("CLP-WETH", "CLP-WETH");
  await clpWeth.deployed();
  console.log("clpWeth deployed to:", clpWeth.address);
  // Set pool as minter
  await clpWeth.setMinter(poolWETH.address);

  const clpUsdc = await MintableToken.deploy("CLP-USDC", "CLP-USDC");
  await clpUsdc.deployed();
  console.log("clpUsdc deployed to:", clpUsdc.address);
  await clpUsdc.setMinter(poolUSDC.address);
  
  // Rewards

  const Rewards = await hre.ethers.getContractFactory("Rewards");

  // Rewards for Pools
  const poolRewardsWETH = await Rewards.deploy(poolWETH.address, weth.address);
  await poolRewardsWETH.deployed();
  console.log("poolRewardsWETH deployed to:", poolRewardsWETH.address);

  const poolRewardsUSDC = await Rewards.deploy(poolUSDC.address, usdc.address);
  await poolRewardsUSDC.deployed();
  console.log("poolRewardsUSDC deployed to:", poolRewardsUSDC.address);

  // Rewards for Cap staking
  const capRewardsWETH = await Rewards.deploy(staking.address, weth.address);
  await capRewardsWETH.deployed();
  console.log("capRewardsWETH deployed to:", capRewardsWETH.address);

  const capRewardsUSDC = await Rewards.deploy(staking.address, usdc.address);
  await capRewardsUSDC.deployed();
  console.log("capRewardsUSDC deployed to:", capRewardsUSDC.address);


  // Treasury fee share setup
  await treasury.setPoolShare(weth.address, 3000);
  await treasury.setPoolShare(usdc.address, 3000);
  console.log("set pool shares for treasury");

  await treasury.setCapShare(weth.address, 2000);
  await treasury.setCapShare(usdc.address, 2000);
  console.log("set Cap shares for treasury");

  await treasury.setRebateShare(weth.address, 1000);
  await treasury.setRebateShare(usdc.address, 1000);
  console.log("set rebate shares for treasury");

  await treasury.setReferrerShare(weth.address, 1000);
  await treasury.setReferrerShare(usdc.address, 1000);
  console.log("set referrer shares for treasury");

  await treasury.setReferredShare(weth.address, 1000);
  await treasury.setReferredShare(usdc.address, 1000);
  console.log("set referred shares for treasury");


  // Router setup
  await router.setContracts(
    trading.address,
    staking.address,
    rebates.address,
    referrals.address,
    oracle.address,
    weth.address,
    treasury.address,
    darkOracleAddress
  );

  await router.setPoolContract(weth.address, poolWETH.address);
  await router.setPoolContract(usdc.address, poolUSDC.address);

  await router.setClpAddress(weth.address, clpWeth.address);
  await router.setClpAddress(usdc.address, clpUsdc.address);

  await router.setPoolRewardsContract(weth.address, poolRewardsWETH.address);
  await router.setPoolRewardsContract(usdc.address, poolRewardsUSDC.address);

  await router.setCapRewardsContract(weth.address, capRewardsWETH.address);
  await router.setCapRewardsContract(usdc.address, capRewardsUSDC.address);
  
  console.log("Setup router contracts");

  await router.setCurrencies([weth.address, usdc.address]);
  console.log("Setup router currencies");

  // Link contracts with Router, which also sets their dependent contract addresses
  await trading.setRouter(router.address);
  await treasury.setRouter(router.address);
  await staking.setRouter(router.address);
  await rebates.setRouter(router.address);
  await referrals.setRouter(router.address);
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
      parseInt(p.maxLeverage),
      parseInt(p.oracleMaxDeviation * 100),
      parseInt(p.fee * 10000),
      parseInt(p.interest * 100),
      parseInt(p.liquidationThreshold * 100)
    ]);
    console.log('Added product ' + p.symbol);
  }

  // Mint some CAP, USDC
  await usdc.mint(parseUnits("100000"));
  await cap.mint(parseUnits("1000"));


  // // Below are method tests

  // //const randomWallet = await hre.ethers.Wallet.createRandom();
  // //console.log('Created random wallet', randomWallet);

  // // Stake in vault
  // await trading.stake({value: parseUnits("100")});
  // console.log('Staked 100 ETH');

  // // submit order
  // await trading.openPosition(1, true, parseUnits("50"), {value: parseUnits("10")});
  // console.log('Submitted order long 10 ETH at 100x');

  // let positions = await trading.getUserPositions(account);

  // console.log('Positions', positions);
  // console.log('Info', formatUnits(positions[0].price, 8), formatUnits(positions[0].margin));


  // console.log('Account balance', formatUnits(await provider.getBalance(account)));

  // // settle open position
  // let settlingIds = await trading.checkPositionsToSettle();  
  // console.log('Settling Ids', settlingIds);

  // await trading.settlePositions(settlingIds);
  // console.log('Settling position open (perform)');

  // positions = await trading.getUserPositions(account);

  // console.log('Positions', positions);
  // console.log('Info', formatUnits(positions[0].price, 8), formatUnits(positions[0].margin));

  // settlingIds = await trading.checkPositionsToSettle();  
  // console.log('Settling Ids (2)', settlingIds);

  // // add margin
  // await trading.addMargin(1, {value: parseUnits("5")});
  // console.log('Added 5 ETH margin');

  // positions = await trading.getUserPositions(account);

  // console.log('Positions', positions);
  // console.log('Info', formatUnits(positions[0].price, 8), formatUnits(positions[0].margin));

  // console.log('Account balance', formatUnits(await provider.getBalance(account)));

  // // close position partial (2)
  // await trading.closePosition(1, parseUnits("2"), false);
  // console.log('Closed 2 ETH partially');

  // positions = await trading.getUserPositions(account);

  // console.log('Positions', positions);
  // console.log('Info', formatUnits(positions[0].price, 8), formatUnits(positions[0].margin));

  // console.log('Account balance', formatUnits(await provider.getBalance(account)));
  // console.log('Vault balance', formatUnits(await provider.getBalance(trading.address)));

  // // close remainder (13)
  // await trading.closePosition(1, parseUnits("13"), false);
  // console.log('Closed fully');

  // positions = await trading.getUserPositions(account);

  // console.log('Positions', positions);
  // //console.log('Info', formatUnits(positions[0].price, 8), formatUnits(positions[0].margin));

  // console.log('Account balance', formatUnits(await provider.getBalance(account)));
  // console.log('Vault balance', formatUnits(await provider.getBalance(trading.address)));

  // /*
  // // liquidate position
  // await trading.liquidatePosition(1);
  // console.log('liquidating');

  // positions = await trading.getUserPositions(account, 1);
  // console.log('Positions', positions);

  // console.log('Account balance', formatUnits((await usdc.balanceOf(account)).toNumber()));
  // console.log('Vault balance', formatUnits((await trading.getBalance(1)).toNumber()));
  // */

  // /*
  // // Unstake partial
  // await trading.unstake(1, 2000 * 10**6);
  // console.log('Unstake partial');

  // console.log('Account balance', formatUnits((await usdc.balanceOf(account)).toNumber()));
  // console.log('Vault balance', formatUnits((await trading.getBalance(1)).toNumber()));

  // // Unstake remainder
  // await trading.unstake(1, 8000 * 10**6);
  // console.log('Unstake remaining');

  // console.log('Account balance', formatUnits((await usdc.balanceOf(account)).toNumber()));
  // console.log('Vault balance', formatUnits((await trading.getBalance(1)).toNumber()));
  // */

}

// We recommend this pattern to be able to use async/await everywhere
// and properly handle errors.
main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
