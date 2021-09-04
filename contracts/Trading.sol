//SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "hardhat/console.sol";

import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

contract Trading {

	// Structs

	// All amount numbers with 8 decimals

	struct Vault {

		// 32 bytes
		uint96 cap; // can be updated upwards by owner. 12 bytes
		uint96 balance; // 12 bytes
		uint64 staked; // 8 bytes
			
		// 32 bytes
		uint80 lastCheckpointBalance; // 10 bytes
		uint80 lastCheckpointTime; // 10 bytes
		uint32 stakingPeriod; // in seconds. make default. 4 bytes
		uint32 redemptionPeriod; // in seconds. make default. 4 bytes
		uint32 maxDailyDrawdown; // in bps. 1000 = 10%. can be updated upwards by owner. 4 bytes
		
	}

	struct Stake {
		// 32 bytes
		uint64 amount; // 8 bytes
		uint32 timestamp; // 4 bytes
		address owner; // 20 bytes
	}

	// Highly liquid products only so you don't have to deal with risk limits so much
	struct Product {

		// 32 bytes
		address feed; // from chainlink. 20 bytes
		uint64 maxLeverage; // 8 bytes
		uint16 fee; // in basis points (bps). 0.5% = 50. 2 bytes
		bool isActive; // 1 byte

		// 32 bytes
		uint64 maxExposure; // 8 bytes
		uint56 openInterestLong; // 8 decimal units. 7 bytes
		uint56 openInterestShort; // 8 decimal units. 7 bytes
		uint16 interest; // for 360 days, in bps. 5.35% = 535. 2 bytes
		uint16 settlementTime; // in seconds. make default 6min. 2 bytes
		uint16 minTradeDuration; // in seconds. make default 15min. 2 bytes
		uint16 liquidationThreshold; // in bps. 8000 = 80% loss can be liquidated. 2 bytes
		uint16 liquidationBounty; // in bps. 500 = 5%. 2 bytes
		
	}

	struct Position {

		// 32 bytes
		uint64 productId; // 8 bytes
		uint64 leverage; // 8 bytes x 10**8
		uint64 price; // 8 bytes x 10**8
		uint64 margin; // 8 bytes x 10**8

		// 32 bytes
		address owner; // 20 bytes
		uint80 timestamp; // 10 bytes
		bool isLong; // 1 byte
		bool isSettling; // 1 byte

	}

	// Variables
	address public owner; // contract owner
	uint256 public nextStakeId; // incremental
	uint256 public nextPositionId; // incremental
	uint256 public protocolFee;  // in bps. 100 = 1%
	Vault private vault;

	// Mappings
	mapping(uint256 => Stake) private stakes;
	mapping(uint64 => Product) private products;
	mapping(uint256 => Position) private positions;

	// Events

	event VaultUpdated(Vault vault);

	event ProductAdded(uint16 productId, Product product);
	event ProductUpdated(uint16 productId, Product product);

	event Staked(uint256 stakeId, address indexed from, uint256 amount);
	event Redeemed(uint256 stakeId, address indexed to, uint256 amount, bool isFullRedeem);

	event NewPosition(uint256 positionId, address indexed user, uint64 indexed productId, bool isLong, uint256 price, uint256 margin, uint256 leverage);
	event AddMargin(uint256 positionId, address indexed user, uint256 margin, uint256 newMargin, uint256 newLeverage);
	event ClosePosition(uint256 positionId, address indexed user, uint64 indexed productId, uint256 price, uint256 margin, uint256 leverage, uint256 pnl, bool pnlIsNegative, uint256 protocolFee, bool isFullClose, bool wasLiquidated);

	event NewPositionSettled(uint256 positionId, address indexed user, uint256 price);

	event PositionLiquidated(uint256 indexed positionId, address indexed by, uint256 vaultReward, uint256 liquidatorReward);
	
	event ProtocolFeeUpdated(uint256 bps);
	event OwnerUpdated(address newOwner);

	// Constructor

	constructor() {
		console.log("Initialized Trading contract.");
		owner = payable(msg.sender);
		vault = Vault({
			cap: 0,
			maxDailyDrawdown: 0,
			staked: 0,
			balance: 0,
			lastCheckpointBalance: 0,
			lastCheckpointTime: uint80(block.timestamp),
			stakingPeriod: uint32(30 * 24 * 3600),
			redemptionPeriod: uint32(8 * 3600)
		});
	}

	// Vault methods

	function stake() external payable {

		address user = msg.sender;
		uint256 amount = msg.value / 10**10; // cut to 8 decimals
		uint256 blockTimestamp = block.timestamp;

		require(uint256(vault.staked) + amount <= uint256(vault.cap), "!cap");

		vault.balance += uint96(amount);
		vault.staked += uint64(amount);

		nextStakeId++;
		stakes[nextStakeId] = Stake({
			owner: user,
			amount: uint64(amount),
			timestamp: uint32(blockTimestamp)
		});

		emit Staked(nextStakeId, user, amount);

	}

	function redeem(uint256 stakeId, uint256 amount) external {
		// amount in 8 decimals
		address user = msg.sender;
		Stake storage _stake = stakes[stakeId];
		require(_stake.owner == user, "!owner");

		if (amount >= uint256(_stake.amount)) amount = uint256(_stake.amount);

		console.log('amount', amount);
		console.log('uint256(_stake.amount)', uint256(_stake.amount));

		/* local test - UNCOMMENT IN PROD
		uint256 blockTimestamp = block.timestamp;
		uint256 stakeTimestamp = uint256(_stake.timestamp);
		require((blockTimestamp - stakeTimestamp) % uint256(vault.stakingPeriod) < uint256(vault.redemptionPeriod), "!period");
		*/
		
		bool isFullRedeem = amount >= uint256(_stake.amount);
		uint256 amountToSend = amount * uint256(vault.balance) / uint256(vault.staked);
		
		_stake.amount -= uint64(amount);
		vault.staked -= uint64(amount);
		vault.balance -= uint96(amountToSend);

		if (isFullRedeem) delete stakes[stakeId];

		payable(user).transfer(amountToSend * 10**10);
		emit Redeemed(stakeId, user, amountToSend, isFullRedeem);

	}

	// Trading methods

	function openPosition(
		uint16 productId,
		bool isLong,
		uint256 leverage
	) external payable {

		// leverage already sent with 8 decimals
		uint256 margin = msg.value / 10**10; // cut to 8 decimals

		require(margin > 0, "!margin");
		require(leverage > 0, "!leverage");

		// Checks: product
		// 3K gas
		Product storage product = products[productId];
		require(product.isActive, "!product-active");
		require(leverage <= product.maxLeverage, "!max-leverage");

		// 6K gas
		uint256 amount = margin * leverage / 10**8;
		if (isLong) {
			product.openInterestLong += uint56(amount);
		} else {
			product.openInterestShort += uint56(amount);
		}

		if (product.openInterestLong > product.openInterestShort) {
			require(uint256(product.openInterestLong) - uint256(product.openInterestShort) <= uint256(product.maxExposure), "!exposure-long");
		} else {
			require(uint256(product.openInterestShort) - uint256(product.openInterestLong) <= uint256(product.maxExposure), "!exposure-short");
		}

		// Checks: price
		// 20K gas
		uint256 price = _calculatePriceWithFee(product.feed, product.fee, isLong);
		require(price > 0, "!price");

		// Create position
		// 22K gas
		nextPositionId++;
		
		address user = msg.sender;

		// 47K gas
		positions[nextPositionId] = Position({
			owner: user,
			productId: productId,
			margin: uint64(margin),
			leverage: uint64(leverage),
			price: uint64(price),
			timestamp: uint80(block.timestamp),
			isLong: isLong,
			isSettling: true
		});
		
		// 3K gas
		emit NewPosition(
			nextPositionId,
			user,
			productId,
			isLong,
			price,
			margin,
			leverage
		);

	}

	function addMargin(uint256 positionId) external payable {

		uint256 margin = msg.value / 10**10;

		require(margin > 0, "!margin");

		Position storage position = positions[positionId];
		require(position.margin > 0, "!position");
		require(msg.sender == position.owner, "!owner");
		require(!position.isSettling, "!settling");

		// New position params
		uint256 newMargin = uint256(position.margin) + margin;
		uint256 newLeverage = uint256(position.leverage) * uint256(position.margin) / newMargin;
		require(newLeverage >= 1, "!low-leverage");

		position.margin = uint64(newMargin);
		position.leverage = uint64(newLeverage);

		emit AddMargin(
			positionId, 
			position.owner, 
			margin, 
			newMargin, 
			newLeverage
		);

	}

	function closePosition(
		uint256 positionId, 
		uint256 margin,
		bool releaseMargin
	) external {

		// margin already sent with 8 decimals
		require(margin > 0, "!margin");

		// Get position
		Position storage position = positions[positionId];
		require(position.margin > 0, "!position");
		require(!position.isSettling, "!settling");

		address user = msg.sender;
		require(user == position.owner, "!owner");

		Product storage product = products[position.productId];

		require(block.timestamp > uint256(position.timestamp) + uint256(product.minTradeDuration), '!duration');
		
		if (margin > uint256(position.margin)) margin = uint256(position.margin);

		uint256 price = _calculatePriceWithFee(product.feed, product.fee, !position.isLong);
		require(price > 0, "!price");

		// Close (full or partial)

		uint256 pnl;
		bool pnlIsNegative;
		uint256 protocolFeeAmount;

		// is liquidatable?
		bool isLiquidatable = _checkLiquidation(position, price, uint256(product.liquidationThreshold));

		if (isLiquidatable) {
			margin = uint256(position.margin);
			pnl = margin;
			pnlIsNegative = true;
		} else {
			
			if (position.isLong) {
				if (price > uint256(position.price)) {
					pnl = margin * uint256(position.leverage) * (price - uint256(position.price)) / (uint256(position.price) * 10**8);
				} else {
					pnl = margin * uint256(position.leverage) * (uint256(position.price) - price) / (uint256(position.price) * 10**8);
					pnlIsNegative = true;
				}
			} else {
				if (price > uint256(position.price)) {
					pnl = margin * uint256(position.leverage) * (price - uint256(position.price)) / (uint256(position.price) * 10**8);
					pnlIsNegative = true;
				} else {
					pnl = margin * uint256(position.leverage) * (uint256(position.price) - price) / (uint256(position.price) * 10**8);
				}
			}

			// subtract interest from P/L
			uint256 interest = _calculateInterest(margin * uint256(position.leverage) / 10**8, uint256(position.timestamp), product.interest);
			if (pnlIsNegative) {
				pnl += interest;
			} else if (pnl < interest) {
				pnl = interest - pnl;
				pnlIsNegative = true;
			} else {
				pnl -= interest;
			}

			// calculate protocol fee
			if (protocolFee > 0) {
				protocolFeeAmount = protocolFee * (margin * position.leverage / 10**8) / 10**4;
				payable(owner).transfer(protocolFeeAmount * 10**10);
				if (pnlIsNegative) {
					pnl += protocolFeeAmount;
				} else if (pnl < protocolFeeAmount) {
					pnl = protocolFeeAmount - pnl;
					pnlIsNegative = true;
				} else {
					pnl -= protocolFeeAmount;
				}
			}

		}

		bool isFullClose;
		if (margin < uint256(position.margin)) {
			// if partial close
			position.margin -= uint64(margin);
		} else {
			isFullClose = true;
		}

		// checkpoint vault
		if (uint256(vault.lastCheckpointTime) < block.timestamp - 24 hours) {
			vault.lastCheckpointTime = uint80(block.timestamp);
			vault.lastCheckpointBalance = uint80(vault.balance);
		}

		// update vault
		if (pnlIsNegative) {
			if (pnl < margin) {
				payable(position.owner).transfer((margin - pnl) * 10**10);
				vault.balance += uint96(pnl);
			} else {
				vault.balance += uint96(margin);
			}
		} else {
			if (releaseMargin) pnl = 0; // in cases to unlock margin when there's not enough in the vault, user can always get back their margin
			require(uint256(vault.balance) >= pnl, "!vault-insufficient");
			// Require vault not below max drawdown
			require(uint256(vault.balance) - pnl >= uint256(vault.lastCheckpointBalance) * (10**4 - uint256(vault.maxDailyDrawdown)) / 10**4, "!max-drawdown");
			vault.balance -= uint96(pnl);
			payable(position.owner).transfer((margin + pnl) * 10**10);
		}

		if (position.isLong) {
			product.openInterestLong -= uint56(margin * uint256(position.leverage) / 10**8);
		} else {
			product.openInterestShort -= uint56(margin * uint256(position.leverage) / 10**8);
		}

		emit ClosePosition(
			positionId, 
			position.owner, 
			position.productId, 
			price, 
			margin, 
			uint256(position.leverage), 
			pnl, 
			pnlIsNegative,
			protocolFeeAmount, 
			isFullClose, 
			isLiquidatable
		);

		if (isFullClose) {
			delete positions[positionId];
		}

	}

	function liquidatePosition(uint256 positionId) external {

		Position memory position = positions[positionId];
		require(!position.isSettling, "!settling");

		Product memory product = products[position.productId];

		uint256 price = _calculatePriceWithFee(product.feed, product.fee, !position.isLong);
		require(price > 0, "!price");

		// !!! local test
		price = 1350000000000;

		if (_checkLiquidation(position, price, uint256(product.liquidationThreshold))) {

			// Can be liquidated
			uint256 vaultReward = uint256(position.margin) * (10**4 - uint256(product.liquidationBounty)) / 100;
			uint256 liquidatorReward = uint256(position.margin) - vaultReward;

			vault.balance += uint96(vaultReward);

			payable(msg.sender).transfer(liquidatorReward);

			emit ClosePosition(
				positionId, 
				position.owner, 
				position.productId, 
				price, 
				uint256(position.margin), 
				uint256(position.leverage), 
				uint256(position.margin),
				true, 
				0, 
				true,
				true
			);

			delete positions[positionId];

			emit PositionLiquidated(
				positionId, 
				msg.sender, 
				uint256(vaultReward), 
				uint256(liquidatorReward)
			);

		}

	}

	function settlePositions(uint256[] calldata positionIds) external {

		uint256 length = positionIds.length;
		
		for (uint256 i = 0; i < length; i++) {
		
			uint256 positionId = positionIds[i];

			Position storage position = positions[positionId];
			if (!position.isSettling) continue;

			Product storage product = products[position.productId];

			uint256 price = _calculatePriceWithFee(product.feed, product.fee, position.isLong);

			if (price > 0) {

				if (block.timestamp - uint256(position.timestamp) > uint256(product.settlementTime) || price != uint256(position.price)) {
					position.price = uint64(price);
					position.isSettling = false;
				}

				// !!! local test
				position.price = uint64(price);
				position.isSettling = false;

				emit NewPositionSettled(
					positionId,
					position.owner,
					price
				);

			}

		}

	}

	// Getters

	function getPositions(uint256[] calldata positionIds) external view returns(Position[] memory _positions) {
		uint256 length = positionIds.length;
		_positions = new Position[](length);
		for (uint256 i=0; i < length; i++) {
			_positions[i] = positions[positionIds[i]];
		}
		return _positions;
	}

	function getStakes(uint256[] calldata stakeIds) external view returns(Stake[] memory _stakes) {
		uint256 length = stakeIds.length;
		_stakes = new Stake[](length);
		for (uint256 i=0; i < length; i++) {
			_stakes[i] = stakes[stakeIds[i]];
		}
		return _stakes;
	}

	function getVault() external view returns(Vault memory) {
		return vault;
	}

	function getProduct(uint16 productId) external view returns(Product memory) {
		return products[productId];
	}

	// Internal methods

	function _calculatePriceWithFee(address feed, uint256 fee, bool isLong) internal view returns(uint256) {
		uint256 price = getLatestPrice(feed, 0);
		if (price == 0) return 0;
		if (isLong) {
			return price + price * fee / 10**4;
		} else {
			return price - price * fee / 10**4;
		}
	}

	function getLatestPrice(address feed, uint16 productId) public view returns (uint256) {
		// local test
		return 33500 * 10**8;

		if (productId > 0) { // for client
			Product memory product = products[productId];
			feed = product.feed;
		}
		if (feed == address(0)) return 0;
		// 2K gas
		uint8 decimals = AggregatorV3Interface(feed).decimals();
		// 12k gas
		// standardize price to 8 decimals
		(
			, 
			int price,
			,
			,
		) = AggregatorV3Interface(feed).latestRoundData();
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

	function _calculateInterest(uint256 amount, uint256 timestamp, uint256 interest) internal view returns (uint256) {
		if (block.timestamp < uint256(timestamp) - 900) return 0;
		return amount * (interest / 10**4) * (block.timestamp - timestamp) / 360 days;
	}

	// TODO: should include interest
	function _checkLiquidation(Position memory position, uint256 price, uint256 liquidationThreshold) internal pure returns (bool) {
		uint256 liquidationPrice;
		if (position.isLong) {
			liquidationPrice = (price - price * liquidationThreshold / 10**4 / (uint256(position.leverage) / 10**8));
		} else {
			liquidationPrice = (price + price * liquidationThreshold / 10**4 / (uint256(position.leverage) / 10**8));
		}

		if (position.isLong && price <= liquidationPrice || !position.isLong && price >= liquidationPrice) {
			return true;
		} else {
			return false;
		}
	}


	// Owner methods

	function updateVault(Vault memory _vault) external onlyOwner {

		if (_vault.cap > 0) vault.cap = _vault.cap;
		if (_vault.maxDailyDrawdown > 0) vault.maxDailyDrawdown = _vault.maxDailyDrawdown;
		if (_vault.stakingPeriod > 0) vault.stakingPeriod = _vault.stakingPeriod;
		if (_vault.redemptionPeriod > 0) vault.redemptionPeriod = _vault.redemptionPeriod;

		emit VaultUpdated(vault);

	}

	function addProduct(uint16 productId, Product memory _product) external onlyOwner {

		Product memory product = products[productId];

		require(product.maxLeverage == 0, "!product-exists");

		require(_product.maxLeverage > 0, "!max-leverage");
		require(_product.feed != address(0), "!feed");
		require(_product.settlementTime > 0, "!settlementTime");
		require(_product.liquidationThreshold > 0, "!liquidationThreshold");

		products[productId] = Product({
			feed: _product.feed,
			maxLeverage: _product.maxLeverage,
			fee: _product.fee,
			isActive: true,
			maxExposure: _product.maxExposure,
			openInterestLong: 0,
			openInterestShort: 0,
			interest: _product.interest,
			settlementTime: _product.settlementTime,
			minTradeDuration: _product.minTradeDuration,
			liquidationThreshold: _product.liquidationThreshold,
			liquidationBounty: _product.liquidationBounty
		});

		emit ProductAdded(productId, products[productId]);

	}

	function updateProduct(uint16 productId, Product memory _product) external onlyOwner {

		Product storage product = products[productId];
		
		require(product.maxLeverage > 0, "!product-exists");

		require(_product.maxLeverage > 0, "!leverage");
		require(_product.feed != address(0), "!feed");

		product.maxLeverage = _product.maxLeverage;
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

	function setProtocolFee(uint256 bps) external onlyOwner {
		require(bps < 300, '!too-much'); // 3% in bps
		protocolFee = bps;
		emit ProtocolFeeUpdated(protocolFee);
	}

	function setOwner(address payable newOwner) external onlyOwner {
		owner = newOwner;
		emit OwnerUpdated(newOwner);
	}

	modifier onlyOwner() {
		require(msg.sender == owner, '!owner');
		_;
	}

}