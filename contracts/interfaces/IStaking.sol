pragma solidity ^0.8.0;

interface IStaking {

	function getUserStake(address user) external view returns (uint256);

}