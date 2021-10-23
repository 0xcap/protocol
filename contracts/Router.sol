// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/Address.sol";

import "./interfaces/ITreasury.sol";
import "./interfaces/ITrading.sol";
import "./interfaces/IRouter.sol";

/*
TODO:
- compile
- events
- deploy and test in js
- client
*/

contract Router {

	using SafeERC20 for IERC20; 
    using Address for address payable;

	// Contract dependencies
	address public owner;
	address public trading;
	address public oracle;
	address public pool;
	address public staking;
	address public weth;

	address[] public currencies;

	mapping(address => address) poolContracts; // currency => contract
	mapping(address => address) poolRewardsContracts; // currency => contract
	mapping(address => address) capRewardsContracts; // currency => contract
	mapping(address => address) clpAddresses; // currency => clp-eth, clp-usdc
	
	address public tradingContract;
	address public capStakingContract;
	address public rebatesContract;
	address public referralsContract;
	address public oracleContract;
	address public wethContract;
	address public clpContract;
	address public treasuryContract;
	address public darkOracleAddress;

	constructor() {
		owner = msg.sender;
	}

	function isSupportedCurrency(address currency) external view returns(bool) {
		return currency != address(0) && poolContracts[currency] != address(0);
	}

	function currenciesLength() external view returns(uint256) {
		return currencies.length;
	}

	function getPoolContract(address currency) external view returns(address) {
		return poolContracts[currency];
	}

	function getClpAddress(address currency) external view returns(address) {
		return clpAddresses[currency];
	}

	function getPoolRewardsContract(address currency) external view returns(address) {
		return poolRewardsContracts[currency];
	}

	function getCapRewardsContract(address currency) external view returns(address) {
		return capRewardsContracts[currency];
	}

	// Setters

	function setCurrencies(address[] calldata _currencies) external onlyOwner {
		currencies = _currencies;
	}

	function setContracts(
		address _tradingContract,
		address _capStakingContract,
		address _rebatesContract,
		address _referralsContract,
		address _oracleContract,
		address _wethContract,
		address _treasuryContract,
		address _darkOracleAddress
	) external onlyOwner {
		tradingContract = _tradingContract;
		capStakingContract = _capStakingContract;
		rebatesContract = _rebatesContract;
		referralsContract = _referralsContract;
		oracleContract = _oracleContract;
		wethContract = _wethContract;
		treasuryContract = _treasuryContract;
		darkOracleAddress = _darkOracleAddress;
	}

	function setPoolContract(address currency, address _contract) external onlyOwner {
		poolContracts[currency] = _contract;
	}

	function setClpAddress(address currency, address _clp) external onlyOwner {
		clpAddresses[currency] = _clp;
	}

	function setPoolRewardsContract(address currency, address _contract) external onlyOwner {
		poolRewardsContracts[currency] = _contract;
	}

	function setCapRewardsContract(address currency, address _contract) external onlyOwner {
		capRewardsContracts[currency] = _contract;
	}

	// From router on the client, you can get the addresses of all the other contracts. No need for methods here

	// Owner methods

	function setOwner(address newOwner) external onlyOwner {
		owner = newOwner;
	}

	function setTrading(address _trading) external onlyOwner {
		trading = _trading;
	}

	function setOracle(address _oracle) external onlyOwner {
		oracle = _oracle;
	}

	// Modifiers

	modifier onlyOwner() {
		require(msg.sender == owner, "!owner");
		_;
	}

	modifier onlyTrading() {
		require(msg.sender == trading, "!trading");
		_;
	}

	modifier onlyOracle() {
		require(msg.sender == oracle, "!oracle");
		_;
	}

}