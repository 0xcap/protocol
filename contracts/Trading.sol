//SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "hardhat/console.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

contract Trading {

	// All amounts are stored with 8 decimals

	// Structs

	struct Vault {
		// 32 bytes
		uint96 cap; // Maximum capacity. 12 bytes
		uint96 balance; // 12 bytes
		uint64 staked; // Total staked by users. 8 bytes
		// 32 bytes
		uint80 lastCheckpointBalance; // Used for max drawdown. 10 bytes
		uint80 lastCheckpointTime; // Used for max drawdown. 10 bytes
		uint32 stakingPeriod; // Time required to lock stake (seconds). 4 bytes
		uint32 redemptionPeriod; // Duration for redemptions (seconds). 4 bytes
		uint32 maxDailyDrawdown; // In basis points (bps) 1000 = 10%. 4 bytes
	}

	struct Stake {
		// 32 bytes
		uint64 amount; // 8 bytes
		uint32 timestamp; // 4 bytes
		address owner; // 20 bytes
	}

	struct Product {
		// 32 bytes
		address feed; // Chainlink feed. 20 bytes
		uint64 maxLeverage; // 8 bytes
		uint16 fee; // In bps. 0.5% = 50. 2 bytes
		bool isActive; // 1 byte
		// 32 bytes
		uint64 maxExposure; // Maximum allowed long/short imbalance. 8 bytes
		uint48 openInterestLong; // 6 bytes
		uint48 openInterestShort; // 6 bytes
		uint16 interest; // For 360 days, in bps. 5.35% = 535. 2 bytes
		uint32 settlementTime; // In seconds. 4 bytes
		uint16 minTradeDuration; // In seconds. 2 bytes
		uint16 liquidationThreshold; // In bps. 8000 = 80%. 2 bytes
		uint16 liquidationBounty; // In bps. 500 = 5%. 2 bytes
	}

	struct Position {
		// 32 bytes
		uint64 productId; // 8 bytes
		uint64 leverage; // 8 bytes
		uint64 price; // 8 bytes
		uint64 margin; // 8 bytes
		// 32 bytes
		address owner; // 20 bytes
		uint80 timestamp; // 10 bytes
		bool isLong; // 1 byte
		bool isSettling; // 1 byte
	}

	// Variables

	uint256 public MIN_MARGIN = 100000; // 0.001 ETH
	address public owner; // Contract owner
	uint256 public nextStakeId; // Incremental
	uint256 public nextPositionId; // Incremental
	uint256 public protocolFee;  // In bps. 100 = 1%
	Vault private vault;

	// Mappings

	mapping(uint64 => Product) private products;
	mapping(uint256 => Stake) private stakes;
	mapping(uint256 => Position) private positions;

	// Events

	event Staked(
		uint256 stakeId, 
		address indexed user, 
		uint256 amount
	);
	event Redeemed(
		uint256 stakeId, 
		address indexed user, 
		uint256 amount, 
		bool isFullRedeem
	);

	event NewPosition(
		uint256 positionId, 
		address indexed user, 
		uint64 indexed productId, 
		bool isLong, 
		uint256 price, 
		uint256 margin, 
		uint256 leverage
	);
	event NewPositionSettled(
		uint256 positionId, 
		address indexed user, 
		uint256 price
	);
	event AddMargin(
		uint256 positionId, 
		address indexed user, 
		uint256 margin, 
		uint256 newMargin, 
		uint256 newLeverage
	);
	event ClosePosition(
		uint256 positionId, 
		address indexed user, 
		bool indexed isFullClose, 
		uint64 indexed productId, 
		uint256 price, 
		uint256 entryPrice, 
		uint256 margin, 
		uint256 leverage, 
		uint256 pnl, 
		bool pnlIsNegative, 
		bool wasLiquidated
	);
	event PositionLiquidated(
		uint256 indexed positionId, 
		address indexed by, 
		uint256 vaultReward, 
		uint256 liquidatorReward
	);
	
	event VaultUpdated(
		Vault vault
	);
	event ProductAdded(
		uint16 productId, 
		Product product
	);
	event ProductUpdated(
		uint16 productId, 
		Product product
	);

	event ProtocolFeeUpdated(
		uint256 bps
	);
	event OwnerUpdated(
		address newOwner
	);

	// Constructor

	constructor() {
		owner = msg.sender;
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

	// Methods

	// Stakes msg.value in the vault
	function stake() external payable {

		uint256 amount = msg.value / 10**10; // truncate to 8 decimals
		require(uint256(vault.staked) + amount <= uint256(vault.cap), "!cap");

		vault.balance += uint96(amount);
		vault.staked += uint64(amount);

		address user = msg.sender;

		nextStakeId++;
		stakes[nextStakeId] = Stake({
			owner: user,
			amount: uint64(amount),
			timestamp: uint32(block.timestamp)
		});

		emit Staked(
			nextStakeId, 
			user, 
			amount
		);

	}

	// Redeems amount from Stake with id = stakeId
	function redeem(
		uint256 stakeId, 
		uint256 amount
	) external {

		require(uint256(vault.staked) >= uint256(amount), "!staked");

		address user = msg.sender;
		Stake storage _stake = stakes[stakeId];
		require(_stake.owner == user, "!owner");

		bool isFullRedeem = amount >= uint256(_stake.amount);
		if (isFullRedeem) {
			amount = uint256(_stake.amount);
		}

		uint256 timeDiff = block.timestamp - uint256(_stake.timestamp);
		require(
			(timeDiff > uint256(vault.stakingPeriod)) &&
			(timeDiff % uint256(vault.stakingPeriod)) < uint256(vault.redemptionPeriod)
		, "!period");
		
		uint256 amountBalance = amount * uint256(vault.balance) / uint256(vault.staked);
		
		_stake.amount -= uint64(amount);
		vault.staked -= uint64(amount);
		vault.balance -= uint96(amountBalance);

		if (isFullRedeem) {
			delete stakes[stakeId];
		}

		payable(user).transfer(amountBalance * 10**10);

		emit Redeemed(
			stakeId, 
			user, 
			amountBalance, 
			isFullRedeem
		);

	}

	// Opens position with margin = msg.value
	function openPosition(
		uint16 productId,
		bool isLong,
		uint256 leverage
	) external payable {

		uint256 margin = msg.value / 10**10; // truncate to 8 decimals

		// Check params
		require(margin >= MIN_MARGIN, "!margin");
		require(leverage > 0, "!leverage");

		// Check product
		Product storage product = products[productId];
		require(product.isActive, "!product-active");
		require(leverage <= uint256(product.maxLeverage), "!max-leverage");

		// Check exposure
		uint256 amount = margin * leverage / 10**8;

		if (isLong) {
			
			product.openInterestLong += uint48(amount);
			
			if (product.openInterestLong > product.openInterestShort) {
				require(
					uint256(product.openInterestLong) - uint256(product.openInterestShort) <= uint256(product.maxExposure)
				, "!exposure-long");
			}

		} else {

			product.openInterestShort += uint48(amount);

			if (product.openInterestShort > product.openInterestLong) {
				require(
					uint256(product.openInterestShort) - uint256(product.openInterestLong) <= uint256(product.maxExposure)
				, "!exposure-short");
			}

		}

		uint256 price = _calculatePriceWithFee(product.feed, product.fee, isLong);
		
		address user = msg.sender;

		nextPositionId++;
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

	// Add margin = msg.value to Position with id = positionId
	function addMargin(uint256 positionId) external payable {

		uint256 margin = msg.value / 10**10; // truncate to 8 decimals

		// Check params
		require(margin >= MIN_MARGIN, "!margin");

		// Check position
		Position storage position = positions[positionId];
		require(msg.sender == position.owner, "!owner");

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

	// Closes margin from Position with id = positionId
	function closePosition(
		uint256 positionId, 
		uint256 margin,
		bool releaseMargin
	) external {

		// Check params
		require(margin > MIN_MARGIN, "!margin");

		// Check position
		Position storage position = positions[positionId];
		require(msg.sender == position.owner, "!owner");
		require(!position.isSettling, "!settling");

		// Check product
		Product storage product = products[position.productId];
		require(
			block.timestamp > uint256(position.timestamp) + uint256(product.minTradeDuration)
		, "!duration");
		
		bool isFullClose;
		if (margin >= uint256(position.margin)) {
			margin = uint256(position.margin);
			isFullClose = true;
		}

		uint256 price = _calculatePriceWithFee(product.feed, product.fee, !position.isLong);

		uint256 pnl;
		bool pnlIsNegative;

		bool isLiquidatable = _checkLiquidation(position, price, product.liquidationThreshold);

		if (isLiquidatable) {
			margin = uint256(position.margin);
			pnl = uint256(position.margin);
			pnlIsNegative = true;
			isFullClose = true;
		} else {
			
			if (position.isLong) {
				if (price >= uint256(position.price)) {
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

			// Subtract interest from P/L
			uint256 interest = _calculateInterest(margin * uint256(position.leverage) / 10**8, uint256(position.timestamp), uint256(product.interest));
			if (pnlIsNegative) {
				pnl += interest;
			} else if (pnl < interest) {
				pnl = interest - pnl;
				pnlIsNegative = true;
			} else {
				pnl -= interest;
			}

			// Calculate protocol fee
			if (protocolFee > 0) {
				uint256 protocolFeeAmount = protocolFee * (margin * position.leverage / 10**8) / 10**4;
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

		// Checkpoint vault
		if (uint256(vault.lastCheckpointTime) < block.timestamp - 24 hours) {
			vault.lastCheckpointTime = uint80(block.timestamp);
			vault.lastCheckpointBalance = uint80(vault.balance);
		}

		// Update vault
		if (pnlIsNegative) {
			
			if (pnl < margin) {
				payable(position.owner).transfer((margin - pnl) * 10**10);
				vault.balance += uint96(pnl);
			} else {
				vault.balance += uint96(margin);
			}

		} else {
			
			if (releaseMargin) {
				// When there's not enough funds in the vault, user can choose to receive their margin without profit
				pnl = 0;
			}
			
			// Check vault
			require(uint256(vault.balance) >= pnl, "!vault-insufficient");
			require(
				uint256(vault.balance) - pnl >= uint256(vault.lastCheckpointBalance) * (10**4 - uint256(vault.maxDailyDrawdown)) / 10**4
			, "!max-drawdown");
			
			vault.balance -= uint96(pnl);

			payable(position.owner).transfer((margin + pnl) * 10**10);
		
		}

		if (position.isLong) {
			if (uint256(product.openInterestLong) >= margin * uint256(position.leverage) / 10**8) {
				product.openInterestLong -= uint48(margin * uint256(position.leverage) / 10**8);
			} else {
				product.openInterestLong = 0;
			}
		} else {
			if (uint256(product.openInterestShort) >= margin * uint256(position.leverage) / 10**8) {
				product.openInterestShort -= uint48(margin * uint256(position.leverage) / 10**8);
			} else {
				product.openInterestShort = 0;
			}
		}

		emit ClosePosition(
			positionId, 
			position.owner, 
			isFullClose,
			position.productId, 
			price, 
			uint256(position.price),
			margin, 
			uint256(position.leverage), 
			pnl, 
			pnlIsNegative, 
			isLiquidatable
		);

		if (isFullClose) {
			delete positions[positionId];
		} else {
			position.margin -= uint64(margin);
		}

	}

	// Checks if positionIds can be settled
	function canSettlePositions(uint256[] calldata positionIds) external view returns(uint256[] memory _positionIds) {

		uint256 length = positionIds.length;
		_positionIds = new uint256[](length);
		
		for (uint256 i = 0; i < length; i++) {
		
			uint256 positionId = positionIds[i];

			Position storage position = positions[positionId];
			
			if (position.productId == 0 || !position.isSettling) {
				continue;
			}

			Product storage product = products[position.productId];

			uint256 price = _calculatePriceWithFee(product.feed, product.fee, position.isLong);

			if (block.timestamp - uint256(position.timestamp) > uint256(product.settlementTime) || price != uint256(position.price)) {
				_positionIds[i] = positionId;
			}

		}

		return _positionIds;

	}

	// Settles positionIds
	function settlePositions(uint256[] calldata positionIds) external {

		uint256 length = positionIds.length;
		
		for (uint256 i = 0; i < length; i++) {
		
			uint256 positionId = positionIds[i];

			Position storage position = positions[positionId];
			
			if (position.productId == 0 || !position.isSettling) {
				continue;
			}

			Product storage product = products[position.productId];

			uint256 price = _calculatePriceWithFee(product.feed, product.fee, position.isLong);

			if (block.timestamp - uint256(position.timestamp) > uint256(product.settlementTime) || price != uint256(position.price)) {
				position.price = uint64(price);
				position.isSettling = false;
			}

			emit NewPositionSettled(
				positionId,
				position.owner,
				price
			);

		}

	}

	// Liquidate positionIds
	function liquidatePositions(uint256[] calldata positionIds) external {

		address liquidator = msg.sender;

		uint256 length = positionIds.length;
		uint256 liquidatorReward;

		for (uint256 i = 0; i < length; i++) {

			uint256 positionId = positionIds[i];
			Position memory position = positions[positionId];
			
			if (position.productId == 0 || position.isSettling) {
				continue;
			}

			Product memory product = products[position.productId];

			uint256 price = _calculatePriceWithFee(product.feed, product.fee, !position.isLong);

			if (_checkLiquidation(position, price, product.liquidationThreshold)) {

				uint256 vaultReward = uint256(position.margin) * (10**4 - uint256(product.liquidationBounty)) / 10**4;
				
				liquidatorReward += uint256(position.margin) - vaultReward;

				vault.balance += uint96(vaultReward);

				emit ClosePosition(
					positionId, 
					position.owner, 
					true,
					position.productId, 
					price, 
					uint256(position.price),
					uint256(position.margin), 
					uint256(position.leverage), 
					uint256(position.margin),
					true,
					true
				);

				delete positions[positionId];

				emit PositionLiquidated(
					positionId, 
					liquidator, 
					uint256(vaultReward), 
					uint256(liquidatorReward)
				);

			}

		}

		if (liquidatorReward > 0) {
			payable(liquidator).transfer(liquidatorReward);
		}

	}

	// Getters

	function getVault() external view returns(Vault memory) {
		return vault;
	}

	function getProduct(uint16 productId) external view returns(Product memory) {
		return products[productId];
	}

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

	function getLatestPrice(
		address feed, 
		uint16 productId
	) public view returns (uint256) {

		if (productId > 0) { // for client
			Product memory product = products[productId];
			feed = product.feed;
		}

		require(feed != address(0), '!feed-error');

		(
			, 
            int price,
            uint startedAt,
            uint timeStamp,
            
		) = AggregatorV3Interface(feed).latestRoundData();

		require(price > 0, '!price');
		require(startedAt > 0, '!startedAt');
		require(timeStamp > 0, '!timeStamp');

		uint8 decimals = AggregatorV3Interface(feed).decimals();

		uint256 priceToReturn;
		if (decimals != 8) {
			priceToReturn = uint256(price) * (10**8) / (10**uint256(decimals));
		} else {
			priceToReturn = uint256(price);
		}

		return priceToReturn;

	}

	// Internal methods

	function _calculatePriceWithFee(
		address feed, 
		uint256 fee, 
		bool isLong
	) internal view returns(uint256) {

		uint256 price = getLatestPrice(feed, 0);
		
		if (isLong) {
			return price + price * fee / 10**4;
		} else {
			return price - price * fee / 10**4;
		}

	}

	function _calculateInterest(uint256 amount, uint256 timestamp, uint256 interest) internal view returns (uint256) {
		if (block.timestamp < uint256(timestamp) - 900) return 0;
		return amount * interest * (block.timestamp - timestamp) / (10**4 * 360 days);
	}

	function _checkLiquidation(
		Position memory position, 
		uint256 price, 
		uint16 liquidationThreshold
	) internal pure returns (bool) {
		
		uint256 liquidationPrice;
		
		if (position.isLong) {
			liquidationPrice = (position.price - position.price * uint256(liquidationThreshold) / 10**4 / (uint256(position.leverage) / 10**8));
		} else {
			liquidationPrice = (position.price + position.price * uint256(liquidationThreshold) / 10**4 / (uint256(position.leverage) / 10**8));
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

		product.feed = _product.feed;
		product.maxLeverage = _product.maxLeverage;
		product.fee = _product.fee;
		product.interest = _product.interest;
		
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

	function setOwner(address newOwner) external onlyOwner {
		owner = newOwner;
		emit OwnerUpdated(newOwner);
	}

	modifier onlyOwner() {
		require(msg.sender == owner, '!owner');
		_;
	}

}