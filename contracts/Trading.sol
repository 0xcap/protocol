// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "hardhat/console.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

import "./interfaces/ITreasury.sol";

contract Trading {

	// All amounts are stored with 8 decimals

	// Structs

	struct Product {
		// 32 bytes
		address feed; // Chainlink and dark feed. 20 bytes
		uint48 maxLeverage; // 6 bytes
		uint16 fee; // In bps. 0.5% = 50. 2 bytes
		uint16 interest; // For 360 days, in bps. 5.35% = 535. 2 bytes
		bool isActive; // 1 byte
		bool darkFeedActive; // 1 byte, dark feed active
		// 32 bytes
		uint48 maxExposure; // Maximum allowed long/short imbalance. 6 bytes
		uint48 openInterestLong; // 6 bytes
		uint48 openInterestShort; // 6 bytes
		uint32 mainFeedStaleAfter; // 4 bytes
		uint16 darkFeedStaleAfter; // 2 bytes
		uint16 darkFeedMaxDeviation; // 2 bytes
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
		uint88 timestamp; // 11 bytes
		bool isLong; // 1 byte
	}

	struct Order {
		uint256 margin;
		bool releaseMargin;
		bool ownerOverride;
		uint256 timestamp;
	}

	// Variables

	address public owner; // Contract owner
	address public treasury;
	address public oracle;

	// 32 bytes
	uint64 public vaultBalance;
	uint64 public vaultThreshold = 10 * 10**8; // 10 ETH
	uint64 public minMargin = 100000; // 0.001 ETH
	uint64 public nextPositionId; // Incremental

	mapping(uint256 => Product) private products;
	mapping(uint256 => Position) private positions;
	mapping(uint256 => Order) private closeOrders;


	// Events
	event OpenOrder(
		uint256 indexed positionId, 
		address indexed user, 
		uint256 indexed productId, 
		bool isLong, 
		uint256 margin, 
		uint256 leverage
	);
	event NewPosition(
		uint256 indexed positionId, 
		address indexed user, 
		uint256 indexed productId, 
		bool isLong, 
		uint256 price, 
		uint256 margin, 
		uint256 leverage
	);
	event AddMargin(
		uint256 indexed positionId, 
		address indexed user, 
		uint256 margin, 
		uint256 newMargin, 
		uint256 newLeverage
	);
	event CloseOrder(
		uint256 indexed positionId,
		uint256 indexed productId,
		uint256 margin,
		bool ownerOverride,
		bool releaseMargin
	);
	event ClosePosition(
		uint256 positionId, 
		address indexed user, 
		uint256 indexed productId, 
		bool indexed isFullClose, 
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
		address indexed liquidator, 
		uint256 vaultReward, 
		uint256 liquidatorReward
	);

	// Constructor

	constructor() {
		owner = msg.sender;
	}

	// Methods

	// Opens position with margin = msg.value
	function openOrder(
		uint256 productId,
		bool isLong,
		uint256 leverage
	) external payable {

		uint256 margin = msg.value / 10**10; // truncate to 8 decimals

		// Check params
		require(margin >= minMargin, "!margin");
		require(leverage >= 10**8, "!leverage");

		// Check product
		Product storage product = products[productId];
		require(product.isActive, "!product-active");
		require(leverage <= product.maxLeverage, "!max-leverage");

		// Check exposure
		uint256 amount = margin * leverage / 10**8;

		if (isLong) {
			product.openInterestLong += uint48(amount);
			require(
				product.openInterestLong <= 
				product.maxExposure + product.openInterestShort
			, "!exposure-long");
		} else {
			product.openInterestShort += uint48(amount);
			require(
				product.openInterestShort <= 
				product.maxExposure + product.openInterestLong
			, "!exposure-short");
		}
		
		address user = msg.sender;

		nextPositionId++;
		positions[nextPositionId] = Position({
			owner: user,
			productId: uint64(productId),
			margin: uint64(margin),
			leverage: uint64(leverage),
			price: 0,
			timestamp: uint88(block.timestamp),
			isLong: isLong
		});
		
		emit OpenOrder(
			nextPositionId,
			user,
			productId,
			isLong,
			margin,
			leverage
		);

	}

	// Opens position with price from dark feed
	function openPosition(
		uint256 positionId,
		uint256 price
	) external onlyOracle {

		Position storage position = positions[positionId];
		require(position.productId > 0, "!position");
		require(position.price == 0, "!settled");

		Product memory product = products[position.productId];

		price = _checkPrice(product, position.timestamp, price);
		price = _getPriceWithFee(price, product.fee, position.isLong);

		if (price == 0) {
			payable(position.owner).transfer(position.margin * 10**10);
			delete positions[positionId];
			return;
		}

		position.price = uint64(price);

		emit NewPosition(
			positionId,
			position.owner,
			position.productId,
			position.isLong,
			price,
			position.margin,
			position.leverage
		);

	}

	function deletePosition(uint256 positionId) external onlyOracle {
		Position storage position = positions[positionId];
		payable(position.owner).transfer(position.margin * 10**10);
		delete positions[positionId];
	}

	function closeOrder(
		uint256 positionId, 
		uint256 margin,
		bool releaseMargin
	) external {

		// Check params
		require(margin >= minMargin, "!margin");

		// Check for existing close order on this position
		require(closeOrders[positionId].margin == 0, "!exists");

		// Governance can release-margin close any position to protect from malicious profits
		bool ownerOverride;
		if (msg.sender == owner) {
			ownerOverride = true;
			releaseMargin = true;
		}

		// Check position
		Position memory position = positions[positionId];
		require(ownerOverride || msg.sender == position.owner, "!owner");

		// Check product
		Product memory product = products[position.productId];
		require(
			block.timestamp >= position.timestamp + product.minTradeDuration
		, "!duration");
		
		if (margin >= position.margin) {
			margin = position.margin;
		}

		closeOrders[positionId] = Order({
			margin: margin,
			ownerOverride: ownerOverride,
			releaseMargin: releaseMargin,
			timestamp: block.timestamp
		});

		emit CloseOrder(
			positionId,
			position.productId,
			margin,
			ownerOverride,
			releaseMargin
		);

	}

	function closePosition(
		uint256 positionId, 
		uint256 price
	) external onlyOracle {

		Order memory _closeOrder = closeOrders[positionId];
		uint256 margin = _closeOrder.margin;
		require(margin > 0, "!order");

		Position storage position = positions[positionId];
		require(position.margin > 0, "!position");

		bool releaseMargin = _closeOrder.releaseMargin;

		Product storage product = products[position.productId];

		price = _checkPrice(product, _closeOrder.timestamp, price);
		price = _getPriceWithFee(price, product.fee, !position.isLong);		

		(uint256 pnl, bool pnlIsNegative) = _getPnL(position, price, margin, product.interest);

		if (_closeOrder.ownerOverride && pnlIsNegative) {
			// Can't release margin on pnl negative position
			revert("!override");
		}

		position.margin -= uint64(margin);

		// Set exposure
		if (position.isLong) {
			if (product.openInterestLong >= margin * position.leverage / 10**8) {
				product.openInterestLong -= uint48(margin * position.leverage / 10**8);
			} else {
				product.openInterestLong = 0;
			}
		} else {
			if (product.openInterestShort >= margin * position.leverage / 10**8) {
				product.openInterestShort -= uint48(margin * position.leverage / 10**8);
			} else {
				product.openInterestShort = 0;
			}
		}

		if (pnlIsNegative) {
			_creditVault(pnl);
			if (pnl < margin) {
				payable(position.owner).transfer((margin - pnl) * 10**10);
			}
		} else {
			if (releaseMargin) {
				// User can choose to receive their margin without profit in edge cases
				pnl = 0;
			}
			require(pnl <= vaultBalance, "!vault-insufficient");
			vaultBalance -= uint64(pnl);
			payable(position.owner).transfer((margin + pnl) * 10**10);
		}

		emit ClosePosition(
			positionId, 
			position.owner, 
			position.productId, 
			position.margin == 0,
			price, 
			position.price,
			margin, 
			position.leverage, 
			pnl, 
			pnlIsNegative, 
			false
		);

		if (position.margin == 0) {
			delete positions[positionId];
		}

		delete closeOrders[positionId];

	}

	function deleteOrder(uint256 positionId) external onlyOracle {
		delete closeOrders[positionId];
	}

	// Add margin = msg.value to Position with id = positionId
	function addMargin(uint256 positionId) external payable {

		uint256 margin = msg.value / 10**10; // truncate to 8 decimals

		// Check params
		require(margin >= minMargin, "!margin");

		// Check position
		Position storage position = positions[positionId];
		require(msg.sender == position.owner, "!owner");

		// New position params
		uint256 newMargin = position.margin + margin;
		uint256 newLeverage = position.leverage * position.margin / newMargin;
		require(newLeverage >= 10**8, "!low-leverage");

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

	// Liquidate positionIds
	function liquidatePositions(uint256[] calldata positionIds) external {

		uint256 totalVaultReward;
		uint256 totalLiquidatorReward;

		for (uint256 i = 0; i < positionIds.length; i++) {

			uint256 positionId = positionIds[i];
			Position memory position = positions[positionId];
			
			if (position.productId == 0) {
				continue;
			}

			Product storage product = products[position.productId];

			// Liquidations can only happen at the chainlink price, avoiding dark feed liquidations
			uint256 price = _getMainFeedPrice(product);

			if (price == 0) continue;

			(uint256 pnl, bool pnlIsNegative) = _getPnL(position, price, position.margin, product.interest);

			if (pnlIsNegative && pnl >= position.margin * product.liquidationThreshold / 10**4) {

				uint256 vaultReward = position.margin * (10**4 - product.liquidationBounty) / 10**4;
				totalVaultReward += uint96(vaultReward);

				uint256 liquidatorReward = position.margin - vaultReward;
				totalLiquidatorReward += liquidatorReward;

				if (position.isLong) {
					if (product.openInterestLong >= position.margin * position.leverage / 10**8) {
						product.openInterestLong -= uint48(position.margin * position.leverage / 10**8);
					} else {
						product.openInterestLong = 0;
					}
				} else {
					if (product.openInterestShort >= position.margin * position.leverage / 10**8) {
						product.openInterestShort -= uint48(position.margin * position.leverage / 10**8);
					} else {
						product.openInterestShort = 0;
					}
				}

				emit ClosePosition(
					positionId, 
					position.owner, 
					position.productId, 
					true,
					price, 
					position.price,
					position.margin, 
					position.leverage, 
					position.margin,
					true,
					true
				);

				delete positions[positionId];

				emit PositionLiquidated(
					positionId, 
					msg.sender, 
					vaultReward, 
					liquidatorReward
				);

			}

		}

		if (totalVaultReward > 0) {
			_creditVault(totalVaultReward);
		}

		if (totalLiquidatorReward > 0) {
			payable(msg.sender).transfer(totalLiquidatorReward * 10**10);
		}

	}

	function fundVault() external payable {
		require(msg.value > 0, "!value");
		vaultBalance += uint64(msg.value / 10**10);
	}

	// Internal methods

	function _creditVault(uint256 amount) internal {
		if (amount == 0) return;
		// send excess to treasury
		if (vaultBalance + amount > vaultThreshold) {
			uint256 excess = vaultBalance + amount - vaultThreshold;
			if (vaultBalance != vaultThreshold) {
				vaultBalance = vaultThreshold;
			}
			ITreasury(treasury).receiveETH{value: excess * 10**10}();
		} else {
			vaultBalance += uint64(amount);
		}
	}

	function _getPnL(
		Position memory position,
		uint256 price,
		uint256 margin,
		uint256 interest
	) internal view returns(uint256 pnl, bool pnlIsNegative) {

		if (position.isLong) {
			if (price >= position.price) {
				pnl = margin * position.leverage * (price - position.price) / (position.price * 10**8);
			} else {
				pnl = margin * position.leverage * (position.price - price) / (position.price * 10**8);
				pnlIsNegative = true;
			}
		} else {
			if (price > position.price) {
				pnl = margin * position.leverage * (price - position.price) / (position.price * 10**8);
				pnlIsNegative = true;
			} else {
				pnl = margin * position.leverage * (position.price - price) / (position.price * 10**8);
			}
		}

		// Subtract interest from P/L
		uint256 _interest;
		if (block.timestamp >= position.timestamp + 900) {
			_interest = margin * position.leverage * interest * (block.timestamp - position.timestamp) / (10**12 * 360 days);
		}

		if (pnlIsNegative) {
			pnl += _interest;
		} else if (pnl < _interest) {
			pnl = _interest - pnl;
			pnlIsNegative = true;
		} else {
			pnl -= _interest;
		}

		return (pnl, pnlIsNegative);

	}

	function _getPriceWithFee(
		uint256 price,
		uint256 fee,
		bool isLong
	) internal pure returns(uint256) {
		if (isLong) {
			return price + price * fee / 10**4;
		} else {
			return price - price * fee / 10**4;
		}
	}

	function _getMainFeedPrice(
		Product memory product
	) internal view returns (uint256) {

		if (product.feed == address(0)) return 0;

		// Get chainlink price

		(
			, 
            int price,
            ,
            uint timeStamp,
            
		) = AggregatorV3Interface(product.feed).latestRoundData();

		if (price <= 0 || timeStamp == 0 || timeStamp < block.timestamp - product.mainFeedStaleAfter) return 0;

		uint8 decimals = AggregatorV3Interface(product.feed).decimals();

		uint256 feedPrice;
		if (decimals != 8) {
			feedPrice = uint256(price) * 10**8 / 10**decimals;
		} else {
			feedPrice = uint256(price);
		}

		return feedPrice;

	}

	function _checkPrice(
		Product memory product,
		uint256 timestamp,
		uint256 price
	) internal view returns(uint256) {

		uint256 mainFeedPrice = _getMainFeedPrice(product);

		if (mainFeedPrice == 0 || timestamp < block.timestamp - product.mainFeedStaleAfter) {
			return 0;
		}

		// If it's too old / too different, use chainlink
		if (
			price == 0 ||
			price > mainFeedPrice + mainFeedPrice * product.darkFeedMaxDeviation / 10**4 ||
			price < mainFeedPrice - mainFeedPrice * product.darkFeedMaxDeviation / 10**4
		) {
			return mainFeedPrice;
		}

		return price;

	}

	// Called from client
	function getMainFeedPrice(uint256 productId) external view returns(uint256) {
		Product memory product = products[productId];
		return _getMainFeedPrice(product);
	}

	// Getters

	function getProduct(uint256 productId) external view returns(Product memory) {
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

	// Governance methods

	function updateMinMargin(uint256 _minMargin) external onlyOwner {
		minMargin = uint64(_minMargin);
	}

	function updateVaultThreshold(uint256 _vaultThreshold) external onlyOwner {
		vaultThreshold = uint64(_vaultThreshold);
	}

	function addProduct(uint256 productId, Product memory _product) external onlyOwner {

		Product memory product = products[productId];
		require(product.maxLeverage == 0, "!product-exists");

		require(_product.maxLeverage > 0, "!max-leverage");
		require(_product.feed != address(0), "!feed");
		require(_product.mainFeedStaleAfter > 0, "!mainFeedStaleAfter");
		require(_product.darkFeedStaleAfter > 0, "!darkFeedStaleAfter");
		require(_product.darkFeedMaxDeviation > 0, "!darkFeedMaxDeviation");
		require(_product.liquidationThreshold > 0, "!liquidationThreshold");

		products[productId] = Product({
			feed: _product.feed,
			maxLeverage: _product.maxLeverage,
			fee: _product.fee,
			interest: _product.interest,
			isActive: true,
			darkFeedActive: _product.darkFeedActive,
			maxExposure: _product.maxExposure,
			openInterestLong: 0,
			openInterestShort: 0,
			mainFeedStaleAfter: _product.mainFeedStaleAfter,
			darkFeedStaleAfter: _product.darkFeedStaleAfter,
			darkFeedMaxDeviation: _product.darkFeedMaxDeviation,
			minTradeDuration: _product.minTradeDuration,
			liquidationThreshold: _product.liquidationThreshold,
			liquidationBounty: _product.liquidationBounty
		});

	}

	function updateProduct(uint256 productId, Product memory _product) external onlyOwner {

		Product storage product = products[productId];
		require(product.maxLeverage > 0, "!product-exists");

		require(_product.maxLeverage >= 1 * 10**8, "!max-leverage");
		require(_product.feed != address(0), "!feed");
		require(_product.mainFeedStaleAfter > 0, "!mainFeedStaleAfter");
		require(_product.darkFeedStaleAfter > 0, "!darkFeedStaleAfter");
		require(_product.darkFeedMaxDeviation > 0, "!darkFeedMaxDeviation");
		require(_product.liquidationThreshold > 0, "!liquidationThreshold");

		product.feed = _product.feed;
		product.maxLeverage = _product.maxLeverage;
		product.fee = _product.fee;
		product.interest = _product.interest;
		product.isActive = _product.isActive;
		product.darkFeedActive = _product.darkFeedActive;
		product.maxExposure = _product.maxExposure;
		product.mainFeedStaleAfter = _product.mainFeedStaleAfter;
		product.darkFeedStaleAfter = _product.darkFeedStaleAfter;
		product.darkFeedMaxDeviation = _product.darkFeedMaxDeviation;
		product.minTradeDuration = _product.minTradeDuration;
		product.liquidationThreshold = _product.liquidationThreshold;
		product.liquidationBounty = _product.liquidationBounty;
	
	}

	function setTreasury(address _treasury) external onlyOwner {
		treasury = _treasury;
	}

	function setOracle(address _oracle) external onlyOwner {
		oracle = _oracle;
	}

	function setOwner(address newOwner) external onlyOwner {
		owner = newOwner;
	}

	modifier onlyOracle() {
		require(msg.sender == oracle, "!oracle");
		_;
	}

	modifier onlyOwner() {
		require(msg.sender == owner, "!owner");
		_;
	}

}