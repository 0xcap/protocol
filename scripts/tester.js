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

  if (!p || !p.margin || p.margin.toString() * 1 == 0) return;

  return {
    closeOrderId: p.closeOrderId.toString(),
    productId: p.productId.toString(),
    size: p.size.toString(),
    price: p.price.toString(),
    margin: p.margin.toString(),
    fee: p.fee.toString(),
    owner: p.owner,
    currency: p.currency,
    timestamp: p.timestamp.toString(),
    isLong: p.isLong
  };

}

const formatOrder = (o) => {

  if (!o || !o.margin || o.margin.toString() * 1 == 0) return;

  return {
    positionId: o.positionId.toString(),
    productId: o.productId.toString(),
    margin: o.margin.toString(),
    fee: o.fee.toString(),
    timestamp: o.timestamp.toString(),
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
  const [owner, user, user2, user3] = await ethers.getSigners();

  console.log('owner', owner.address);
  console.log('user', user.address);

  // Other contract addresses can be obtained through router
  const routerAddress = '0x193521C8934bCF3473453AF4321911E7A89E0E12';
  const router = await (await ethers.getContractFactory("Router")).attach(routerAddress);

  const wethAddress = await router.weth();
  const weth = await (await ethers.getContractFactory("WETH")).attach(wethAddress);

  const trading = await (await ethers.getContractFactory("Trading")).attach(await router.trading());
  const oracle = await (await ethers.getContractFactory("Oracle")).attach(await router.oracle());
  const treasury = await (await ethers.getContractFactory("Treasury")).attach(await router.treasury());
  
  const usdcAddress = '0x547382C0D1b23f707918D3c83A77317B71Aa8470';
  const usdc = await (await ethers.getContractFactory("MockToken")).attach(usdcAddress);

  const capAddress = '0x22a9B82A6c3D2BFB68F324B2e8367f346Dd6f32a';
  const cap = await (await ethers.getContractFactory("MockToken")).attach(capAddress);

  const poolWETH = await (await ethers.getContractFactory("Pool")).attach(await router.getPool(wethAddress));
  const poolUSDC = await (await ethers.getContractFactory("Pool")).attach(await router.getPool(usdcAddress));

  const poolRewardsWETH = await (await ethers.getContractFactory("Rewards")).attach(await router.getPoolRewards(wethAddress));
  const poolRewardsUSDC = await (await ethers.getContractFactory("Rewards")).attach(await router.getPoolRewards(usdcAddress));

  const capPool = await (await ethers.getContractFactory("PoolCAP")).attach(await router.capPool());

  const capRewardsWETH = await (await ethers.getContractFactory("Rewards")).attach(await router.getCapRewards(usdcAddress));
  const capRewardsUSDC = await (await ethers.getContractFactory("Rewards")).attach(await router.getCapRewards(usdcAddress));
  
  console.log('Contracts set', router.address);

  // // Mint some CAP, USDC
  // await usdc.connect(user2).mint(parseUnits("100000", 6));
  // await cap.connect(user2).mint(parseUnits("1000"));

  let tx, receipt;

  // // get product
  // console.log('BTC-USD');
  // const product = await trading.getProduct(2);
  // console.log('product', product);
  
  // // Update product
  // await trading.updateProduct(2, [
  //   product[0],
  //   parseUnits("50"),
  //   product[2],
  //   8000,
  //   1500,
  //   1600
  // ]);
  // console.log('Updated BTC/USD');
  
  // // submit order (ETH)
  // tx = await trading.connect(user).submitNewPosition(
  //   wethAddress, // currency
  //   1, // productId
  //   0, // margin is sent as value for WETH
  //   parseUnits("5"), // size
  //   true, // isLong
  //   {value: parseUnits("1")} // margin
  // );
  // console.log('Submitted order long 1 ETH margin at 20x (WETH, ETH-USD)');
  // receipt = await provider.getTransactionReceipt(tx.hash);
  // console.log('Gas used:', (receipt.gasUsed).toNumber()); // 279690

  // // Router dark oracle address
  // console.log('ro', await router.darkOracle());
  // console.log('oo', await oracle.darkOracle());

  // Check weth balance
  // console.log('WETH ETH balance', formatUnits(await provider.getBalance(weth.address)));
  // console.log('Trading contract balance (WETH)', formatUnits(await weth.balanceOf(trading.address)));

  // const posId = await trading.nextPositionId();
  // console.log('Position', posId.toString(), formatPosition((await trading.getPositions([posId]))[0]));
  
  // // submit partial close order
  // tx = await trading.connect(user).submitCloseOrder(
  //   posId, // position id
  //   parseUnits("1"), // size to close
  //   {value: parseUnits("0.0016")} // fee - to be calculated correctly. can be anything above the expected amount
  // );
  // console.log('Submitted close order for 1 ETH on position ', posId);
  // receipt = await provider.getTransactionReceipt(tx.hash);
  // console.log('Gas used:', (receipt.gasUsed).toNumber()); // 235604

  // const closeId = await trading.nextCloseOrderId();
  // console.log('Close Order', closeId.toString(), formatOrder((await trading.getCloseOrders([closeId]))[0]));

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


  // // Treasury balance
  // console.log('Treasury weth balance', formatUnits(await weth.balanceOf(treasury.address)));
  // console.log('Pool weth balance', formatUnits(await weth.balanceOf(poolWETH.address)));

  // // Pool: stake, unstake, claim rewards

  // console.log('weth', await poolWETH.weth());
  // console.log('balance', formatUnits(await weth.balanceOf(poolWETH.address)));

  // // stake ETH

  // console.log('Depositing 1 ETH in WETH pool');
  
  // await poolWETH.connect(user).deposit(
  //   0, 
  //   {value: parseUnits("1")}
  // );
  // console.log('Deposited', formatUnits(await poolWETH.getBalance(user.address)), formatUnits(await poolWETH.totalSupply()));

  // // stake ETH (owner)

  // console.log('Depositing 2 ETH from another user in WETH pool');
  
  // await poolWETH.deposit(
  //   0, 
  //   {value: parseUnits("2")}
  // );
  // console.log('Deposited', formatUnits(await poolWETH.getBalance(owner.address)), formatUnits(await poolWETH.totalSupply()));

  // // stake USDC

  // await usdc.connect(user).mint(parseUnits("100000"));
  // await usdc.connect(user).approve(poolUSDC.address, parseUnits("1000000000000"));

  // console.log('Staking 1000 USDC in USDC pool');
  // console.log('currency', await poolUSDC.currency());
  
  // await poolUSDC.connect(user).mintAndStakeCLP(parseUnits("1000"));
  // console.log('Staked', formatUnits(await poolUSDC.getStakedBalance(user.address)), formatUnits(await poolUSDC.getStakedSupply()));

  // console.log('supply', formatUnits(await poolUSDC.clpSupply()));
  // console.log('balance', formatUnits(await usdc.balanceOf(user.address)));

  // // withdraw ETH

  // console.log('Pool weth address', poolWETH.address);

  // await poolWETH.setParams(3000, 0, 0, "10000000000000000000000000");
  
  // console.log('Pool weth balance', formatUnits(await weth.balanceOf(poolWETH.address)));
  // console.log('Pool usdc balance', formatUnits(await usdc.balanceOf(poolUSDC.address)));

  // console.log('User staked CLP-ETH balance', formatUnits(await poolWETH.getBalance(user.address)));
  // console.log('User staked CLP-USDC balance', formatUnits(await poolUSDC.getBalance(user.address)));

  // console.log('Owner staked CLP-ETH balance', formatUnits(await poolWETH.getBalance(owner.address)));
  // console.log('Owner staked CLP-USDC balance', formatUnits(await poolUSDC.getBalance(owner.address)));

  // console.log('Withdrawing 0.4 ETH pool');

  // await poolWETH.connect(user).withdraw(parseUnits("0.4"));
  
  // console.log('Pool WETH', formatUnits(await poolWETH.getBalance(user2.address)), formatUnits(await poolRewardsWETH.pendingReward()), formatUnits(await poolWETH.totalSupply()));

  // // claim rewards

  // console.log('router weth rewards contract', await router.getPoolRewards(wethAddress));
  // console.log('actual weth rewards contract', poolRewardsWETH.address);
  // console.log('staking contract associated', await poolRewardsWETH.pool());
  // console.log('staked supply', formatUnits(await poolWETH.totalSupply()));

  // console.log('update rewards weth');
  // await poolRewardsWETH.updateRewards(user.address);
  
  // console.log('rewards contract weth', formatUnits(await weth.balanceOf(poolRewardsWETH.address)));
  // console.log('pendingReward weth', formatUnits(await poolRewardsWETH.pendingReward()));
  // console.log('cumulativeRewardPerTokenStored weth', formatUnits(await poolRewardsWETH.cumulativeRewardPerTokenStored()));
  // console.log('claimable reward weth', formatUnits(await poolRewardsWETH.getClaimableReward()));
  // console.log('claimable reward usdc', formatUnits(await poolRewardsUSDC.connect(user3).getClaimableReward()));

  // // CAP: stake, unstake, claim rewards

  // console.log('treasury weth', formatUnits(await weth.balanceOf(treasury.address)));
  // console.log('treasury usdc', formatUnits(await usdc.balanceOf(treasury.address), 6));

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

  // Owner methods

  // await poolWETH.setParams(
  //   4000,
  //   180,
  //   100,
  //   parseUnits("100"),
  //   20
  // );

  // console.log('pool WETH params', (await poolWETH.maxDailyDrawdown()).toString(), (await poolWETH.minDepositTime()).toString(), (await poolWETH.utilizationMultiplier()).toString(), (await poolWETH.maxCap()).toString(), (await poolWETH.withdrawFee()).toString());

  // console.log('pool WETH utilization', formatUnits(await poolWETH.openInterest()), (await poolWETH.getUtilization()).toString());
  console.log('pool WETH rewards balance', formatUnits(await weth.balanceOf(poolRewardsWETH.address)), formatUnits(await provider.getBalance(poolRewardsWETH.address)));

  // await poolUSDC.setParams(
  //   4000,
  //   180,
  //   100,
  //   parseUnits("100"),
  //   20
  // );

  // console.log('poolUSDC params', (await poolUSDC.maxDailyDrawdown()).toString(), (await poolUSDC.minDepositTime()).toString(), (await poolUSDC.utilizationMultiplier()).toString(), (await poolUSDC.maxCap()).toString(), (await poolUSDC.withdrawFee()).toString());

  // console.log('poolUSDC utilization', formatUnits(await poolUSDC.openInterest()), (await poolUSDC.getUtilization()).toString());


}

// We recommend this pattern to be able to use async/await everywhere
// and properly handle errors.
main();
