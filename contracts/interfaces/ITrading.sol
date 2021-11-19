// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

interface ITrading {

    function distributeFees(address currency) external;
    
    function settleOrder(address user, bytes32 productId, address currency, bool isLong, uint256 price) external;

    function liquidatePosition(address user, bytes32 productId, address currency, bool isLong, uint256 price) external;

    function getPendingFee(address currency) external view returns(uint256);
    
}
