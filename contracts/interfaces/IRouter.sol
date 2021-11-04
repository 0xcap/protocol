// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

interface IRouter {
    function trading() external view returns (address);

    function capPool() external view returns (address);

    function oracle() external view returns (address);

    function weth() external view returns (address);

    function treasury() external view returns (address);

    function darkOracle() external view returns (address);

    function isSupportedCurrency(address currency) external view returns (bool);

    function currencies(uint256 index) external view returns (address);

    function currenciesLength() external view returns (uint256);

    function getPool(address currency) external view returns (address);

    function getPoolRewards(address currency) external view returns (address);

    function getCapRewards(address currency) external view returns (address);
}
