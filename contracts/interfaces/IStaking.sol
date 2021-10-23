// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

interface IStaking {
    
    function getStakedSupply() external view returns (uint256);
    function getStakedBalance(address account) external view returns (uint256);

}