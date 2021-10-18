// We require the Hardhat Runtime Environment explicitly here. This is optional
// but useful for running the script in a standalone fashion through `node <script>`.
//
// When running the script with `npx hardhat run <script>` you'll find the Hardhat
// Runtime Environment's members available in the global scope.
const hre = require("hardhat");
const { ethers } = require('hardhat');

const parseUnits = function (number, units) {
  return ethers.utils.parseUnits(number, units || 18);
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

  const provider = hre.ethers.provider;
  const [owner, user] = await ethers.getSigners();

  console.log('owner', owner.address);
  //console.log('user', user.address);

  const tradingAddress = '0xA55Eee92a46A50A4C65908F28A0BE966D3e71633';
  const oracleAddress = '0x08AAcc8FA22133b97324765B973704Ca286a6D76';
  const treasuryAddress = '0x1058AFe66BB5b79C295CCCE51016586949Bc4e8d';

  // console.log('Owner balance', formatUnits(await provider.getBalance(owner.address)));
  // //console.log('User balance', formatUnits(await provider.getBalance(user.address)));
  // console.log('Trading balance', formatUnits(await provider.getBalance(tradingAddress)));
  // console.log('Oracle balance', formatUnits(await provider.getBalance(oracleAddress)));
  // console.log('Treasury balance', formatUnits(await provider.getBalance(treasuryAddress)));

  const trading = await (await ethers.getContractFactory("Trading")).attach(tradingAddress);
  const oracle = await (await ethers.getContractFactory("Oracle")).attach(oracleAddress);
  const treasury = await (await ethers.getContractFactory("Treasury")).attach(treasuryAddress);

  //console.log('Oracle addrs', await oracle.owner(), await oracle.trading(), await oracle.treasury(), await oracle.oracle());
  //console.log('Treasury addrs', await oracle.owner(), await oracle.trading(), await oracle.oracle());
  //console.log('Products', await trading.getProduct(1), await trading.getProduct(2));

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
      }
    ]
  };

  // // Add products
  // const network = hre.network.name;
  // console.log('network', network);

  // for (const p of products[network]) {
  //   await trading.addProduct(p.id, [
  //     p.feed,
  //     parseUnits(""+p.leverage, 8),
  //     p.fee * 100,
  //     1200,
  //     true,
  //     parseUnits("1000", 8),
  //     0,
  //     0,
  //     250, 
  //     0
  //   ]);
  //   console.log('Added product ' + p.symbol);
  // }

  // Update products
  const network = hre.network.name;
  console.log('network', network);

  for (const p of products[network]) {
    await trading.updateProduct(p.id, [
      p.feed,
      parseUnits(""+p.leverage, 8),
      p.fee * 100,
      1600,
      true,
      parseUnits("400", 8),
      0,
      0,
      250, 
      0
    ]);
    console.log('Updated product ' + p.symbol);
  }
  
  
  // console.log('Treasury balance1', formatUnits(await provider.getBalance(treasuryAddress)));
  // await treasury.creditVault({value: parseUnits("2")});
  // console.log('Treasury balance2', formatUnits(await provider.getBalance(treasuryAddress)));

  let tx, receipt;

  
  // submit order
  // tx = await trading.connect(user).submitNewPosition(1, true, parseUnits("50", 8), {value: parseUnits("1")});
  // console.log('Submitted order long 1 ETH at 50x');
  // receipt = await provider.getTransactionReceipt(tx.hash);
  // console.log('Gas used:', (receipt.gasUsed).toNumber()); // 87109

  // const posId = await trading.nextPositionId();
  // console.log('Position', posId, await trading.getPositions([posId]));
  
  // // submit partial close order
  // tx = await trading.connect(user).submitCloseOrder(posId, parseUnits("0.3", 8));
  // console.log('Submitted close order for 0.3 ETH on position ', posId);
  // receipt = await provider.getTransactionReceipt(tx.hash);
  // console.log('Gas used:', (receipt.gasUsed).toNumber()); // 65222

  // // submit rest of close order (full)
  // tx = await trading.connect(user).submitCloseOrder(posId, parseUnits("0.7", 8));
  // console.log('Submitted close order for 0.7 ETH on position ', posId);
  // receipt = await provider.getTransactionReceipt(tx.hash);
  // console.log('Gas used:', (receipt.gasUsed).toNumber()); // 65222

  // // cancel close order
  // tx = await trading.connect(user).cancelOrder(3);
  // console.log('Cancelled close order', 3);
  // receipt = await provider.getTransactionReceipt(tx.hash);
  // console.log('Gas used:', (receipt.gasUsed).toNumber()); // 28987


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
