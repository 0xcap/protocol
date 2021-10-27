// We require the Hardhat Runtime Environment explicitly here. This is optional
// but useful for running the script in a standalone fashion through `node <script>`.
//
// When running the script with `npx hardhat run <script>` you'll find the Hardhat
// Runtime Environment's members available in the global scope.
const hre = require("hardhat");
const { ethers } = require('hardhat');

const ADDRESS_ZERO = '0x0000000000000000000000000000000000000000';

const parseUnits = function (number, units) {
  return ethers.utils.parseUnits(number, units || 18);
}

const formatUnits = function (number, units) {
  return ethers.utils.formatUnits(number, units || 18);
}

const formatPosition = (p) => {

  if (!p || !p.margin || p.margin.toNumber() == 0) return;

  return {
    productId: p.productId,
    leverage: p.leverage.toNumber(),
    price: p.price.toNumber(),
    margin: p.margin.toNumber(),
    fee: p.fee.toNumber(),
    owner: p.owner,
    currency: p.currency,
    timestamp: p.timestamp.toNumber(),
    isLong: p.isLong
  };

}

const formatOrder = (o) => {

  if (!o || !o.margin || o.margin.toNumber() == 0) return;

  return {
    positionId: o.positionId,
    productId: o.productId,
    margin: o.margin.toNumber(),
    fee: p.fee.toNumber(),
    timestamp: o.timestamp.toNumber(),
    isLong: o.isLong
  };

}

async function main() {
  // Hardhat always runs the compile task when running scripts with its command
  // line interface.
  //
  // If this script is run directly using `node` you may want to call compile
  // manually to make sure everything is compiled
  // await hre.run('compile');

  const provider = hre.ethers.provider;
  const [owner, user] = await ethers.getSigners();

  console.log('owner', owner.address);
  console.log('user', user.address);

  // Other contract addresses can be obtained through router
  const routerAddress = '0x0462Bc7390a33C8BB748d5c2ad76E93690A365c5';
  const router = await (await ethers.getContractFactory("Router")).attach(routerAddress);

  const wethAddress = await router.wethContract();
  const weth = await (await ethers.getContractFactory("WETH")).attach(wethAddress);

  const trading = await (await ethers.getContractFactory("Trading")).attach(await router.trading());
  const oracle = await (await ethers.getContractFactory("Oracle")).attach(await router.oracle());
  const treasury = await (await ethers.getContractFactory("Treasury")).attach(await router.treasury());
  
  const usdcAddress = '0xd2983525E903Ef198d5dD0777712EB66680463bc';
  const usdc = await (await ethers.getContractFactory("MockToken")).attach(usdcAddress);

  const poolWETH = await (await ethers.getContractFactory("Pool")).attach(await router.getPool(wethAddress));
  const poolUSDC = await (await ethers.getContractFactory("Pool")).attach(await router.getPool(usdcAddress));

  const clpWeth = await (await ethers.getContractFactory("MintableToken")).attach(await router.getClp(wethAddress));
  const clpUsdc = await (await ethers.getContractFactory("MintableToken")).attach(await router.getClp(usdcAddress));

  const poolRewardsWETH = await (await ethers.getContractFactory("Rewards")).attach(await router.getPoolRewards(wethAddress));
  const poolRewardsUSDC = await (await ethers.getContractFactory("Rewards")).attach(await router.getPoolRewards(usdcAddress));

  const capStaking = await (await ethers.getContractFactory("Staking")).attach(await router.capPool());

  const capRewardsWETH = await (await ethers.getContractFactory("Rewards")).attach(await router.getCapRewards(usdcAddress));
  const capRewardsUSDC = await (await ethers.getContractFactory("Rewards")).attach(await router.getCapRewards(usdcAddress));
  
  console.log('Contracts set', router.address);

  
  // console.log('Treasury balance1', formatUnits(await provider.getBalance(treasuryAddress)));
  // await treasury.creditVault({value: parseUnits("2")});
  // console.log('Treasury balance2', formatUnits(await provider.getBalance(treasuryAddress)));

  let tx, receipt;

  // get product
  //console.log('ETH-USD', await trading.getProduct(1));
  
  // // submit order (ETH)
  // tx = await trading.connect(user).submitNewPosition(
  //   wethAddress, // currency
  //   1, // productId
  //   0, // margin is sent as value for WETH
  //   parseInt(40 * 10**8), // leverage
  //   true, // isLong
  //   ADDRESS_ZERO, // referrer
  //   {value: parseUnits("1")} // margin
  // );
  // console.log('Submitted order long 1 ETH at 50x (WETH, ETH-USD)');
  // receipt = await provider.getTransactionReceipt(tx.hash);
  // console.log('Gas used:', (receipt.gasUsed).toNumber()); // 87109

  // Router dark oracle address
  // console.log('ro', await router.darkOracleAddress());
  // console.log('oo', await oracle.darkOracle());

  // Check weth balance
  // console.log('WETH ETH balance', formatUnits(await provider.getBalance(weth.address)));
  // console.log('Trading contract balance (WETH)', formatUnits(await weth.balanceOf(trading.address)));

  // const posId = await trading.nextPositionId();
  // console.log('Position', posId, formatPosition((await trading.getPositions([posId]))[0]));
  
  // // submit partial close order
  // tx = await trading.connect(user).submitCloseOrder(
  //   posId, // position id
  //   parseUnits("0.3", 8), // margin to close
  //   {value: parseUnits("0.03")} // fee - to be calculated correctly. can be anything above the expected amount
  // );
  // console.log('Submitted close order for 0.3 ETH on position ', posId);
  // receipt = await provider.getTransactionReceipt(tx.hash);
  // console.log('Gas used:', (receipt.gasUsed).toNumber()); // 65222

  // // submit rest of close order (full)
  // tx = await trading.connect(user).submitCloseOrder(posId, parseUnits("0.936", 8), {value: parseUnits("0.1")});
  // console.log('Submitted close order for 0.936 ETH on position ', posId);
  // receipt = await provider.getTransactionReceipt(tx.hash);
  // console.log('Gas used:', (receipt.gasUsed).toNumber()); // 65222

  // // cancel close order
  // tx = await trading.connect(user).cancelOrder(3);
  // console.log('Cancelled close order', 3);
  // receipt = await provider.getTransactionReceipt(tx.hash);
  // console.log('Gas used:', (receipt.gasUsed).toNumber()); // 28987


  // Treasury balance
  console.log('Treasury weth balance', formatUnits(await weth.balanceOf(treasury.address)));
  console.log('Pool weth balance', formatUnits(await weth.balanceOf(poolWETH.address)));

  // Pool: stake, unstake, claim rewards

  // console.log('weth', await poolWETH.weth());
  // console.log('balance', formatUnits(await weth.balanceOf(poolWETH.address)));

  // // stake ETH

  // console.log('Staking 1 ETH in WETH pool');
  
  // await poolWETH.connect(user).mintAndStakeCLP(
  //   0, 
  //   {value: parseUnits("1.5")}
  // );
  // console.log('Staked', formatUnits(await poolWETH.getStakedBalance(user.address)), formatUnits(await poolWETH.getStakedSupply()));

  // // stake ETH (owner)

  // console.log('Staking 2 ETH from another user in WETH pool');
  
  // await poolWETH.mintAndStakeCLP(
  //   0, 
  //   {value: parseUnits("2")}
  // );
  // console.log('Staked', formatUnits(await poolWETH.getStakedBalance(owner.address)), formatUnits(await poolWETH.getStakedSupply()));

  // // stake USDC

  // await usdc.connect(user).mint(parseUnits("100000"));
  // await usdc.connect(user).approve(poolUSDC.address, parseUnits("1000000000000"));

  // console.log('Staking 1000 USDC in USDC pool');
  // console.log('currency', await poolUSDC.currency());
  
  // await poolUSDC.connect(user).mintAndStakeCLP(parseUnits("1000"));
  // console.log('Staked', formatUnits(await poolUSDC.getStakedBalance(user.address)), formatUnits(await poolUSDC.getStakedSupply()));

  // console.log('supply', formatUnits(await poolUSDC.clpSupply()));
  // console.log('balance', formatUnits(await usdc.balanceOf(user.address)));

  // unstake ETH

  // console.log('Pool weth address', poolWETH.address);

  // await poolWETH.setMinStakingTime(0);
  
  // console.log('Pool weth balance', formatUnits(await weth.balanceOf(poolWETH.address)));
  // console.log('Pool usdc balance', formatUnits(await usdc.balanceOf(poolUSDC.address)));

  // console.log('Pool CLP-ETH balance', formatUnits(await clpWeth.balanceOf(poolWETH.address)));
  // console.log('Pool CLP-USDC balance', formatUnits(await clpUsdc.balanceOf(poolUSDC.address)));

  // console.log('User staked CLP-ETH balance', formatUnits(await poolWETH.getStakedBalance(user.address)));
  // console.log('User staked CLP-USDC balance', formatUnits(await poolUSDC.getStakedBalance(user.address)));

  // // console.log('Owner staked CLP-ETH balance', formatUnits(await poolWETH.getStakedBalance(owner.address)));
  // // console.log('Owner staked CLP-USDC balance', formatUnits(await poolUSDC.getStakedBalance(owner.address)));

  // console.log('Unstaking 1 CLP from WETH pool');

  // await poolWETH.connect(user).unstakeAndBurnCLP(parseUnits("1"));
  
  console.log('Staked', formatUnits(await poolWETH.getStakedBalance(user.address)), formatUnits(await poolWETH.getStakedSupply()));

  // // claim rewards

  // console.log('router weth rewards contract', await router.getPoolRewards(wethAddress));
  // console.log('actual weth rewards contract', poolRewardsWETH.address);
  // console.log('staking contract associated', await poolRewardsWETH.staking());
  // console.log('staked supply', formatUnits(await poolWETH.getStakedSupply()));

  // console.log('update rewards weth');
  // await poolRewardsWETH.updateRewards(user.address);
  
  // console.log('rewards contract weth', formatUnits(await weth.balanceOf(poolRewardsWETH.address)));
  // console.log('pendingReward weth', formatUnits(await poolRewardsWETH.pendingReward()));
  // console.log('cumulativeRewardPerTokenStored weth', formatUnits(await poolRewardsWETH.cumulativeRewardPerTokenStored()));
  // console.log('claimable reward weth', formatUnits(await poolRewardsWETH.getClaimableReward()));

  // CAP: stake, unstake, claim rewards


  // Treasury

  // Credit vault
  // console.log('Treasury vault balance 1', formatUnits(await treasury.vaultBalance()));
  // console.log('Treasury vault threshold 1', formatUnits(await treasury.vaultThreshold()));
  // await treasury.setParams(parseUnits("30"));
  // console.log('Treasury vault threshold 2', formatUnits(await treasury.vaultThreshold()));
  // await treasury.creditVault({value: parseUnits("5")});
  // console.log('Treasury balance', formatUnits(await provider.getBalance(treasuryAddress)));
  // console.log('Treasury vault balance 2', formatUnits(await treasury.vaultBalance()));

  // Fund vault internally
  // console.log('Treasury vault balance 1', formatUnits(await treasury.vaultBalance()));
  // await treasury.fundVault(parseUnits("3"));
  // console.log('Treasury balance', formatUnits(await provider.getBalance(treasuryAddress)));
  // console.log('Treasury vault balance 2', formatUnits(await treasury.vaultBalance()));

  // Send ETH
  // console.log('Owner balance pre', formatUnits(await provider.getBalance(owner.address)));
  // await treasury.sendETH(owner.address, parseUnits("2.5"));
  // console.log('Owner balance', formatUnits(await provider.getBalance(owner.address)));
  // console.log('Treasury balance', formatUnits(await provider.getBalance(treasuryAddress)));

  // Transfer from owner to treasury
  // console.log('Owner balance pre', formatUnits(await provider.getBalance(owner.address)));
  // await owner.sendTransaction({to: treasuryAddress, value: parseUnits("11")});
  // console.log('Treasury balance', formatUnits(await provider.getBalance(treasuryAddress)));

  // Release margin
  // tx = await trading.releaseMargin(posId);
  // console.log('Released margin');
  // receipt = await provider.getTransactionReceipt(tx.hash);
  // console.log('Gas used:', (receipt.gasUsed).toNumber()); // 44899
  // console.log('User balance', formatUnits(await provider.getBalance(user.address)));
  // console.log('Trading balance', formatUnits(await provider.getBalance(tradingAddress)));

}

// We recommend this pattern to be able to use async/await everywhere
// and properly handle errors.
main();
