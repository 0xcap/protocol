require("@nomiclabs/hardhat-waffle");

// This is a sample Hardhat task. To learn how to create your own go to
// https://hardhat.org/guides/create-task.html
task("accounts", "Prints the list of accounts", async (taskArgs, hre) => {
  const accounts = await hre.ethers.getSigners();

  for (const account of accounts) {
    console.log(account.address);
  }
});

/**
 * @type import('hardhat/config').HardhatUserConfig
 */
module.exports = {
  defaultNetwork: "hardhat",
  networks: {
    hardhat: {
      forking: {
        url: "https://eth-mainnet.alchemyapi.io/v2/zHbXABWwbDPf1xLXgoiFoR9T3si9iV_t"
      },
      mining: {
        auto: true,
        interval: [10000, 20000]
      }
    },
    rinkeby: {
      url: 'https://rinkeby.infura.io/v3/8cccc478d2e54cb3bc3ec5524793f636',
      accounts: ['3f9d3de8920ed69eaebf632a7d0a4315970ee72a1cb1b287f347a2342657e3e2']
    },
    mainnet: {
      url: 'https://mainnet.infura.io/v3/8cccc478d2e54cb3bc3ec5524793f636'
    },
    arbitrum: {
      url: 'https://arb1.arbitrum.io/rpc'
    }
  },
  solidity: {
    compilers: [{
      version: "0.8.6",
      settings: {
        optimizer: {
          enabled: true,
          runs: 200
        }
      }
    }]
  }
};
