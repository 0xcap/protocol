//SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "hardhat/console.sol";

import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import './libraries/UIntSet.sol';

contract Trading {

	using UintSet for UintSet.Set;

	// Structs

	struct Vault {
		uint256 cap;
		uint256 maxOpenInterest;
		uint256 openInterest;
		uint256 balance;
		uint256 staked;
		uint256 lastCheckpointBalance;
		
		uint256 lastCheckpointTime;
		uint256 maxDailyDrawdown; // in bps. 1000 = 10%
		uint256 protocolFee;  // in bps. 100 = 1%
		uint256 stakingPeriod; // in seconds
		uint256 redemptionPeriod; // in seconds

		bool isActive;
	}

	struct Product {
		uint256 leverage; // max leverage x 10**18
		address feed; // from chainlink
		uint256 fee; // in basis points (bps). 0.5% = 50
		uint256 interest; // for 360 days, in bps. 5.35% = 535
		uint256 settlementTime; // in seconds
		uint256 minTradeDuration; // in seconds

		uint256 liquidationThreshold; // in bps. 8000 = 80% loss can be liquidated
		uint256 liquidationBounty; // in bps. 500 = 5%
		bool isActive;
	}

	struct Position {
		uint16 productId; // 2 bytes
		address payable owner; // 20 bytes
		uint64 timestamp; // 8 bytes
		bool isLong; // 1 byte
		bool isSettling; // 1 byte

		uint256 leverage; // 4 bytes x 10**6
		uint256 price; // 8 bytes x 10**8
		uint256 positionId; // 4 bytes
		uint256 margin; // 16 bytes
	}

	// Variables
	address payable public owner; // contract owner
	uint256 public currentPositionId; // incremental
	Vault private vault;

	// Mappings
	mapping(address => uint256) userStaked;
	mapping(uint16 => Product) private products; // productId => product info
	mapping(uint256 => Position) private positions; // positionId => position info
	mapping(address => UintSet.Set) private userPositionIds; // user => [Position ids]
	UintSet.Set private settlingIds; // IDs of positions in settlement
	mapping(address => bool) private lockedUsers;

	// Constructor

	constructor() {
		console.log("Initialized Trading contract.");
		vault = Vault({
			cap: 0,
			maxOpenInterest: 0,
			maxDailyDrawdown: 0,
			stakingPeriod: 30 * 24 * 3600,
			redemptionPeriod: 8 * 3600,
			openInterest: 0,
			balance: 0,
			staked: 0,
			lastCheckpointBalance: 0,
			lastCheckpointTime: block.timestamp,
			protocolFee: 0,
			isActive: true
		});
		owner = payable(msg.sender);
	}

	// Vault methods

	function stake() external payable {
		address user = msg.sender;
		uint256 amount = msg.value;
		require(vault.staked + amount <= vault.cap, "!cap");
		vault.balance += amount;
		userStaked[user] += amount;
		vault.staked += amount;
		emit Staked(user, amount);
	}

	function redeem() external payable {
		address payable user = payable(msg.sender);
		uint256 amount = msg.value;
		require(block.timestamp % vault.stakingPeriod < vault.redemptionPeriod, "!redemption");
		require(amount <= userStaked[user], "!redeem-amount");
		require(vault.staked > 0, "!staked");
		uint256 amountToSend = amount * vault.balance / vault.staked;
		userStaked[user] -= amount;
		vault.staked -= amount;
		vault.balance -= amountToSend;
		user.transfer(amountToSend);
		emit Redeemed(user, amountToSend);
	}

	// Trading methods

	function submitOrder(
		uint16 productId,
		bool isLong,
		uint256 leverage,
		uint256 positionId,
		bool releaseMargin
	) external payable {

		// Checks: input
		uint256 margin = msg.value;
		require(margin > 0, "!margin");
		require(leverage > 0, '!leverage');

		address user = msg.sender;

		require(!lockedUsers[user], '!locked');

		// Checks: vault
		require(vault.isActive, "!vault-active");

		// Checks: product
		Product memory product = products[productId];
		require(product.isActive, "!product-active");
		
		require(leverage <= product.leverage, "!max-leverage");

		// Get price
		uint256 price = _calculatePriceWithFee(getLatestPrice(productId), product.fee, isLong);
		require(price > 0, "!price");

		if (positionId > 0) {

			Position memory position = positions[positionId];
			require(position.productId > 0, "!position");
			require(!position.isSettling, "!settling");

			// Check owner
			if (user == position.owner || lockedUsers[position.owner] && user == owner) {

				if (position.isLong == isLong) {
					_addMargin(positionId, margin);
				} else {
					require(block.timestamp > position.timestamp + product.minTradeDuration, '!duration');
					console.log('margin', margin);
					console.log('position.margin', position.margin);
					if (margin > position.margin) margin = position.margin;
					_closePosition(positionId, margin, price, product.interest, releaseMargin);
				}
			}

		} else {
			_openPosition(productId, isLong, margin, leverage, price);
		}

	}

	function _openPosition(
		uint16 productId,
		bool isLong,
		uint256 margin,
		uint256 leverage,
		uint256 price
	) internal {

		address payable user = payable(msg.sender);
		
		// Create position
		currentPositionId += 1;
		positions[currentPositionId] = Position({
			owner: user,
			productId: productId,
			margin: margin,
			leverage: leverage,
			price: price,
			timestamp: uint64(block.timestamp),
			isLong: isLong,
			isSettling: true,
			positionId: currentPositionId
		});
		userPositionIds[user].add(currentPositionId);
		settlingIds.add(currentPositionId);

		console.log('margin', margin);
		console.log('vault.maxOpenInterest', vault.maxOpenInterest);
		console.log('vault.openInterest', vault.openInterest);
		console.log('leverage', leverage);
		console.log('amount', margin * leverage / 10**18);

		vault.openInterest += margin * leverage / 10**18;
		require(vault.openInterest <= vault.maxOpenInterest, "!max-open-interest");

		emit NewPosition(
			currentPositionId,
			user,
			productId,
			isLong,
			price,
			margin,
			leverage
		);

	}

	function _addMargin(uint256 positionId, uint256 margin) internal {

		Position storage position = positions[positionId];

		// New position params
		uint256 newMargin = position.margin + margin;
		uint256 newLeverage = position.leverage * position.margin / newMargin;
		require(newLeverage >= 1, "!low-leverage");

		position.margin = newMargin;
		position.leverage = newLeverage;

		emit AddMargin(positionId, position.owner, margin, newMargin, newLeverage);

	}

	function _closePosition(
		uint256 positionId, 
		uint256 margin, 
		uint256 price, 
		uint256 interest,
		bool releaseMargin
	) internal {

		// Close (full or partial)

		Position storage position = positions[positionId];

		int256 pnl;
		uint256 protocolFeeAmount;

		// is liquidatable?
		bool isLiquidatable = _checkLiquidation(position, price);

		console.log('isLiquidatable', isLiquidatable);

		if (isLiquidatable) {
			margin = position.margin;
			pnl = -1 * int256(margin);
		} else {
		
			if (position.isLong) {
				pnl = int256(margin) * int256(position.leverage) * (int256(price) - int256(position.price)) / int256(position.price) / 10**18;
			} else {
				pnl = int256(margin) * int256(position.leverage) * (int256(position.price) - int256(price)) / int256(position.price) / 10**18;
			}

			// subtract interest from P/L
			pnl -= int256(_calculateInterest(margin * position.leverage / 10**18, position.timestamp, interest));

			// calculate protocol fee
			if (vault.protocolFee > 0) {
				protocolFeeAmount = vault.protocolFee * (margin * position.leverage / 10**18) / 10**4;
				pnl -= int256(protocolFeeAmount);
				owner.transfer(protocolFeeAmount);
			}

		}

		// checkpoint vault
		if (vault.lastCheckpointTime < block.timestamp - 24 hours) {
			vault.lastCheckpointTime = block.timestamp;
			vault.lastCheckpointBalance = vault.balance;
		}

		// update vault
		if (pnl < 0) {
			if (uint256(-pnl) < margin) {
				position.owner.transfer(margin - uint256(-pnl));
				vault.balance += uint256(-pnl);
			} else {
				vault.balance += margin;
			}
		} else {
			if (releaseMargin) pnl = 0; // in cases to unlock margin when there's not enough in the vault, user can always get back their margin
			require(vault.balance >= uint256(pnl), "!vault-insufficient");
			// Require vault not below max drawdown
			require(vault.balance - uint256(pnl) >= vault.lastCheckpointBalance * (10**4 - vault.maxDailyDrawdown) / 10**4, "!max-drawdown");
			vault.balance -= uint256(pnl);
			position.owner.transfer(margin + uint256(pnl));
		}

		vault.openInterest -= margin * position.leverage / 10**18;

		emit ClosePosition(positionId, position.owner, position.productId, price, margin, position.leverage, pnl, protocolFeeAmount, isLiquidatable);

		if (margin < position.margin) {
			// if partial close
			position.margin -= margin;
		} else {
			// if full close
			userPositionIds[position.owner].remove(positionId);
			delete positions[positionId];
		}

	}

	// Liquidation methods

	function liquidatePosition(uint256 positionId) external {

		Position memory position = positions[positionId];
		require(!position.isSettling, "!settling");

		Product memory product = products[position.productId];

		uint256 price = _calculatePriceWithFee(getLatestPrice(position.productId), product.fee, !position.isLong);
		require(price > 0, "!price");

		// !!! local test
		//price = 1350000000000;

		if (_checkLiquidation(position, price)) {

			// Can be liquidated
			uint256 vaultReward = position.margin * (10**4 - product.liquidationBounty) / 100;
			uint256 liquidatorReward = position.margin - vaultReward;

			vault.balance += vaultReward;

			payable(msg.sender).transfer(liquidatorReward);
			userPositionIds[position.owner].remove(positionId);

			emit ClosePosition(positionId, position.owner, position.productId, price, position.margin, position.leverage, -1 * int256(position.margin), 0, true);

			delete positions[positionId];

			emit PositionLiquidated(positionId, msg.sender, vaultReward, liquidatorReward);

		}

	}

	// Price settlement methods

	function checkPositionsToSettle() external view returns (uint256[] memory) {

		uint256 length = settlingIds.length();
		if (length == 0) return new uint[](0);

		uint256[] memory settleTheseIds = new uint[](length);

		for (uint256 i=0; i < length; i++) {

			uint256 id = settlingIds.at(i);
			Position memory position = positions[id];
			Product memory product = products[position.productId];

			// Add fee
			uint256 price = _calculatePriceWithFee(getLatestPrice(position.productId), product.fee, position.isLong);

			if (price > 0) {
				if (block.timestamp - uint256(position.timestamp) > product.settlementTime || price != position.price) {
					settleTheseIds[i] = id;
				}
			}

			// !!! Local test
			settleTheseIds[i] = id;

		}

		if (settleTheseIds[0] == 0) return new uint[](0);

		return settleTheseIds;

	}

	function settlePositions(uint256[] calldata positionIds) external {

		uint256 length = positionIds.length;
		
		for (uint256 i = 0; i < length; i++) {
		
			uint256 positionId = positionIds[i];

			Position storage position = positions[positionId];
			if (!position.isSettling) continue;

			Product memory product = products[position.productId];

			uint256 price = _calculatePriceWithFee(getLatestPrice(position.productId), product.fee, position.isLong);

			if (price > 0) {

				if (block.timestamp - uint256(position.timestamp) > product.settlementTime || price != position.price) {
					position.price = price;
					position.isSettling = false;
					settlingIds.remove(positionId);
				}

				// !!! local test
				position.price = price;
				position.isSettling = false;
				settlingIds.remove(positionId);

				emit NewPositionSettled(positionId, position.owner, price);

			}

		}

	}

	// Internal utilities

	function _calculatePriceWithFee(uint256 price, uint256 fee, bool isLong) internal pure returns(uint256) {
		if (price == 0) return 0;
		if (isLong) {
			return price + price * fee / 10**4;
		} else {
			return price - price * fee / 10**4;
		}
	}

	function _calculateInterest(uint256 amount, uint64 timestamp, uint256 interest) internal view returns (uint256) {
		if (block.timestamp < uint256(timestamp) - 900) return 0;
		return amount * (interest / 10**4) * (block.timestamp - uint256(timestamp)) / 360 days;
	}

	// TODO: should include interest
	function _checkLiquidation(Position memory position, uint256 price) internal view returns (bool) {
		Product memory product = products[position.productId];
		uint256 liquidationPrice;
		if (position.isLong) {
			liquidationPrice = (price - price * product.liquidationThreshold / 10**4 / (position.leverage / 10**18));
		} else {
			liquidationPrice = (price + price * product.liquidationThreshold / 10**4 / (position.leverage / 10**18));
		}

		console.log('liquidationPrice', liquidationPrice);
		
		if (position.isLong && price <= liquidationPrice || !position.isLong && price >= liquidationPrice) {
			return true;
		} else {
			return false;
		}
	}

	// Getters

	function getLatestPrice(uint16 productId) public view returns (uint256) {
		Product memory product = products[productId];
		require(product.feed != address(0), "!feed");

		uint8 decimals = AggregatorV3Interface(product.feed).decimals();
		// standardize price to 8 decimals
		(
			, 
			int price,
			,
			,
		) = AggregatorV3Interface(product.feed).latestRoundData();
		uint256 price_returned;
		if (decimals != 8) {
			price_returned = uint256(price) * (10**8) / (10**uint256(decimals));
		} else {
			price_returned = uint256(price);
		}

		// local test
		//int256 price = 33500 * 10**8;
		return price_returned;
	}

	function getVault() external view returns(Vault memory) {
		return vault;
	}

	function getProduct(uint16 productId) external view returns(Product memory) {
		return products[productId];
	}

	function getPosition(uint256 positionId) external view returns(Position memory) {
		return positions[positionId];
	}
	
	function getUserPositions(address user) external view returns (Position[] memory _positions) {
		uint256 length = userPositionIds[user].length();
		_positions = new Position[](length);
		for (uint256 i=0; i < length; i++) {
			uint256 id = userPositionIds[user].at(i);
			_positions[i] = positions[id];
		}
		return _positions;
	}

	function getUserStaked(address user) external view returns (uint256) {
		return userStaked[user];
	}

	// Owner methods

	function updateVault(Vault memory _vault) external onlyOwner {

		if (_vault.cap > 0) vault.cap = _vault.cap;
		if (_vault.maxOpenInterest > 0) vault.maxOpenInterest = _vault.maxOpenInterest;
		if (_vault.maxDailyDrawdown > 0) vault.maxDailyDrawdown = _vault.maxDailyDrawdown;
		if (_vault.stakingPeriod > 0) vault.stakingPeriod = _vault.stakingPeriod;
		if (_vault.redemptionPeriod > 0) vault.redemptionPeriod = _vault.redemptionPeriod;

		if (_vault.protocolFee <= 200) vault.protocolFee = _vault.protocolFee;

		vault.isActive = _vault.isActive;

		emit VaultUpdated(vault);

	}

	function addProduct(uint16 productId, Product memory _product) external onlyOwner {

		Product memory product = products[productId];

		require(product.leverage == 0, "!product-exists");

		require(_product.leverage > 0, "!leverage");
		require(_product.feed != address(0), "!feed");
		require(_product.settlementTime > 0, "!settlementTime");
		require(_product.liquidationThreshold > 0, "!liquidationThreshold");

		products[productId] = Product({
			leverage: _product.leverage,
			fee: _product.fee,
			interest: _product.interest,
			feed: _product.feed,
			settlementTime: _product.settlementTime,
			minTradeDuration: _product.minTradeDuration,
			liquidationThreshold: _product.liquidationThreshold,
			liquidationBounty: _product.liquidationBounty,
			isActive: true
		});

		emit ProductAdded(productId, products[productId]);

	}

	function updateProduct(uint16 productId, Product memory _product) external onlyOwner {

		Product storage product = products[productId];
		
		require(product.leverage > 0, "!product-exists");

		require(_product.leverage > 0, "!leverage");
		require(_product.feed != address(0), "!feed");

		product.leverage = _product.leverage;
		product.fee = _product.fee;
		product.interest = _product.interest;
		product.feed = _product.feed;

		if (_product.settlementTime > 0) product.settlementTime = _product.settlementTime;
		product.minTradeDuration = _product.minTradeDuration;
		if (_product.liquidationThreshold > 0) product.liquidationThreshold = _product.liquidationThreshold;
		product.liquidationBounty = _product.liquidationBounty;
		product.isActive = _product.isActive;
		
		emit ProductUpdated(productId, product);
	
	}

	function lockUser(address _address, bool _lock) external onlyOwner {
		lockedUsers[_address] = _lock;
		emit LockedUsersUpdated(_address, _lock);
	}

	function setOwner(address payable newOwner) external onlyOwner {
		owner = newOwner;
		emit OwnerUpdated(newOwner);
	}

	// Events

	event Staked(address indexed from, uint256 amount);
	event Redeemed(address indexed to, uint256 amount);

	event NewPosition(uint256 positionId, address indexed user, uint16 indexed productId, bool isLong, uint256 price, uint256 margin, uint256 leverage);
	event AddMargin(uint256 positionId, address indexed user, uint256 margin, uint256 newMargin, uint256 newLeverage);
	event ClosePosition(uint256 positionId, address indexed user, uint16 indexed productId, uint256 price, uint256 margin, uint256 leverage, int256 pnl, uint256 protocolFee, bool wasLiquidated);

	event NewPositionSettled(uint256 positionId, address indexed user, uint256 price);

	event PositionLiquidated(uint256 indexed positionId, address indexed by, uint256 vaultReward, uint256 liquidatorReward);

	event VaultUpdated(Vault vault);

	event ProductAdded(uint16 productId, Product product);
	event ProductUpdated(uint16 productId, Product product);

	event LockedUsersUpdated(address _address, bool _lock);
	event OwnerUpdated(address newOwner);

	// Modifiers

	modifier onlyOwner() {
		require(msg.sender == owner, '!O');
		_;
	}

}