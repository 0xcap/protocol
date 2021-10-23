// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

interface IRouter {

    function tradingContract() external view returns (address);
    function capStakingContract() external view returns (address);
    function rebatesContract() external view returns (address);
    function referralsContract() external view returns (address);
    function oracleContract() external view returns (address);
    function wethContract() external view returns (address);
    function clpContract() external view returns (address);
    function treasuryContract() external view returns (address);
    function darkOracleAddress() external view returns (address);
    
    function isSupportedCurrency(address currency) external view returns(bool);

    function currencies(uint256 index) external view returns(address);

    function currenciesLength() external view returns(uint256);

    function getPoolContract(address currency) external view returns(address);

    function getPoolRewardsContract(address currency) external view returns(address);

    function getCapRewardsContract(address currency) external view returns(address);

}