const { ethers } = require('hardhat');

exports.parseUnits = function (number, units) {
  if (!units) units = 6; // usdc
  return ethers.utils.parseUnits(""+number, units) * 1;
}

exports.formatUnits = function (number, units) {
  if (!units) units = 6; // usdc
  return ethers.utils.formatUnits(number, units) * 1;
}