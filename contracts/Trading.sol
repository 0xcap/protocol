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
		address feed; // Chainlink. Can be address(0) for no bounding. 20 bytes
		uint56 maxLeverage; // 7 bytes
		uint16 fee; // In bps. 0.5% = 50. 2 bytes
		uint16 interest; // For 360 days, in bps. 5.35% = 535. 2 bytes
		bool isActive; // 1 byte
		// 32 bytes
		uint64 maxExposure; // Maximum allowed long/short imbalance. 8 bytes
		uint64 openInterestLong; // 8 bytes
		uint64 openInterestShort; // 8 bytes
		uint32 oracleMaxDeviation; // 4 bytes
		uint32 minTradeDuration; // In seconds. 4 bytes
	}

	struct Position {
		// 32 bytes
		uint40 closeOrderId; // 5 bytes
		uint24 productId; // 3 bytes
		uint64 leverage; // 8 bytes
		uint64 price; // 8 bytes
		uint64 margin; // 8 bytes
		// 32 bytes
		address owner; // 20 bytes
		uint88 timestamp; // 11 bytes
		bool isLong; // 1 byte
	}

	struct Order {
		uint64 positionId; // 8 bytes
		uint32 productId; // 4 bytes
		uint64 margin; // 8 bytes
		uint72 timestamp; // 9 bytes
		bool isLong; // 1 byte
		bool releaseMargin; // 1 byte
		bool ownerOverride; // 1 byte
	}

	// Variables

	address public owner; // Contract owner
	address public treasury;
	address public oracle;

	// 32 bytes
	uint64 public minMargin = 100000; // 0.001 ETH. 8 bytes
	uint64 public maxSettlementTime = 30 minutes; // 8 bytes
	uint24 public liquidationThreshold = 8000; // In bps. 8000 = 80%. 3 bytes
	uint48 public nextPositionId; // Incremental. 6 bytes
	uint48 public nextCloseOrderId; // Incremental. 6 bytes
	bool public allowGlobalMarginRelease = false;

	mapping(uint256 => Product) private products;
	mapping(uint256 => Position) private positions;
	mapping(uint256 => Order) private closeOrders;


	// Events
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
	event ClosePosition(
		uint256 positionId, 
		address indexed user, 
		uint256 indexed productId, 
		bool indexed isFullClose, 
		bool isLong,
		uint256 price, 
		uint256 entryPrice, 
		uint256 margin, 
		uint256 leverage, 
		uint256 pnl, 
		bool pnlIsNegative, 
		bool wasLiquidated
	);
	event OpenOrder(
		uint256 indexed positionId,
		address indexed user,
		uint256 indexed productId
	);

	// Constructor

	constructor() {
		owner = msg.sender;
	}

	// Methods

	// Submit new position (price pending)
	function submitNewPosition(
		uint256 productId,
		bool isLong,
		uint256 leverage
	) external payable {

		uint256 margin = msg.value / 10**10; // truncate to 8 decimals

		// Check params
		require(margin >= minMargin, "!margin");
		require(leverage >= 10**8, "!leverage");

		// Check product
		Product memory product = products[productId];
		require(product.isActive, "!product-active");
		require(leverage <= product.maxLeverage, "!max-leverage");

		// Add position
		nextPositionId++;
		positions[nextPositionId] = Position({
			closeOrderId: 0,
			owner: msg.sender,
			productId: uint24(productId),
			margin: uint64(margin),
			leverage: uint64(leverage),
			price: 0,
			timestamp: uint88(block.timestamp),
			isLong: isLong
		});

		emit OpenOrder(
			nextPositionId,
			msg.sender,
			productId
		);

	}

	// Set price for newly submitted position
	function settleNewPosition(
		uint256 positionId,
		uint256 price
	) external onlyOracle {

		console.log('settleNewPosition', positionId, price);

		// Check position
		Position storage position = positions[positionId];
		require(position.margin > 0, "!position");
		require(position.price == 0, "!settled");

		console.log('timestamps', block.timestamp, position.timestamp);

		require(block.timestamp <= position.timestamp + maxSettlementTime, "!time");

		Product storage product = products[position.productId];

		// Update exposure
		uint256 amount = position.margin * position.leverage / 10**8;
		if (position.isLong) {
			product.openInterestLong += uint64(amount);
			require(product.openInterestLong <= product.maxExposure + product.openInterestShort, "!exposure-long");
		} else {
			product.openInterestShort += uint64(amount);
			require(product.openInterestShort <= product.maxExposure + product.openInterestLong, "!exposure-short");
		}

		// Set price
		price = _validatePrice(product, price, position.isLong);

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

	// User or oracle can cancel pending position e.g. in case of error or non-execution
	function cancelPosition(uint256 positionId) external {

		// Sanity check position. Checks should fail silently
		Position memory position = positions[positionId];
		if (
			position.price != 0 ||
			position.margin == 0 ||
			msg.sender != position.owner && msg.sender != oracle
		) return;

		uint256 margin = position.margin;
		address positionOwner = position.owner;

		delete positions[positionId];

		// Refund margin
		payable(positionOwner).transfer(margin * 10**10);

	}

	// Submit order to close a position
	function submitCloseOrder( 
		uint256 positionId, 
		uint256 margin,
		bool releaseMargin
	) external {

		require(margin >= minMargin, "!margin");

		// Check position
		Position storage position = positions[positionId];
		require(msg.sender == owner || msg.sender == position.owner, "!owner");
		require(position.margin > 0, "!position");
		require(position.price > 0, "!opening");
		require(position.closeOrderId == 0, "!closing");

		// Check product
		Product memory product = products[position.productId];
		require(block.timestamp >= position.timestamp + product.minTradeDuration, "!duration");

		// Governance can release margin from any position to protect from malicious profits
		bool ownerOverride;
		if (msg.sender == owner) {
			ownerOverride = true;
			releaseMargin = true;
			margin = position.margin;
		}

		nextCloseOrderId++;
		closeOrders[nextCloseOrderId] = Order({
			positionId: uint64(positionId),
			productId: uint32(position.productId),
			margin: uint64(margin),
			timestamp: uint72(block.timestamp),
			isLong: position.isLong,
			releaseMargin: releaseMargin,
			ownerOverride: ownerOverride
		});

		position.closeOrderId = uint40(nextCloseOrderId);

	}

	// TODO: explicit cast everything

	// Closes position at the fetched price
	function settleCloseOrder(
		uint256 orderId, 
		uint256 price
	) external onlyOracle {

		console.log('settleCloseOrder', orderId, price);

		// Check order and params
		Order memory _closeOrder = closeOrders[orderId];
		uint256 margin = _closeOrder.margin;
		require(margin > 0, "!margin");

		uint256 positionId = _closeOrder.positionId;

		Position storage position = positions[positionId];
		require(position.margin > 0, "!position");
		require(position.closeOrderId == orderId, "!order");
		require(position.price > 0, "!opening");

		if (margin >= position.margin) {
			margin = position.margin;
		}

		Product storage product = products[position.productId];

		uint256 pnl;
		bool pnlIsNegative;

		if (_closeOrder.releaseMargin && allowGlobalMarginRelease) {
			(pnl, pnlIsNegative) = (0, false);
		} else {

			require(block.timestamp <= _closeOrder.timestamp + maxSettlementTime, "!time");
			
			price = _validatePrice(product, price, !position.isLong);

			console.log('price', product.fee, price);

			(pnl, pnlIsNegative) = _getPnL(position, price, margin, product.interest);

		}

		console.log('pnl', pnl, pnlIsNegative);

		// Can't release margin on pnl negative position
		if (_closeOrder.ownerOverride && pnlIsNegative) {
			revert("!override");
		}

		// Check if it's a liquidation
		bool isLiquidation;
		if (pnlIsNegative && pnl >= position.margin * liquidationThreshold / 10**4) {
			pnl = position.margin;
			margin = position.margin;
			isLiquidation = true;
		}

		console.log('params', margin, position.margin, isLiquidation);

		position.margin -= uint64(margin);

		// Set exposure
		if (position.isLong) {
			if (product.openInterestLong >= margin * uint256(position.leverage) / 10**8) {
				product.openInterestLong -= uint64(margin * uint256(position.leverage) / 10**8);
			} else {
				product.openInterestLong = 0;
			}
		} else {
			if (product.openInterestShort >= margin * uint256(position.leverage) / 10**8) {
				product.openInterestShort -= uint64(margin * uint256(position.leverage) / 10**8);
			} else {
				product.openInterestShort = 0;
			}
		}

		emit ClosePosition(
			positionId, 
			position.owner, 
			position.productId, 
			position.margin == 0,
			position.isLong,
			price, 
			position.price,
			margin, 
			position.leverage, 
			pnl, 
			pnlIsNegative, 
			isLiquidation
		);

		if (position.margin == 0) {
			delete positions[positionId];
		} else {
			position.closeOrderId = 0;
		}

		delete closeOrders[orderId];

		console.log('h1');

		if (pnlIsNegative) {
			ITreasury(treasury).creditVault{value: pnl* 10**10}();
			console.log('h2');
			if (pnl < margin) {
				payable(position.owner).transfer((margin - pnl) * 10**10);
			}
			console.log('h3');
		} else {
			if (_closeOrder.releaseMargin) {
				pnl = 0;
			}
			console.log('h4');
			ITreasury(treasury).debitVault(position.owner, pnl * 10**10);
			payable(position.owner).transfer(margin * 10**10);
			console.log('h5');
		}

	}

	// User or oracle can cancel pending order e.g. in case of error or non-execution
	function cancelOrder(uint256 orderId) external {

		// Checks should fail silently
		Order memory _closeOrder = closeOrders[orderId];
		if (_closeOrder.positionId == 0) return;
		
		Position storage position = positions[_closeOrder.positionId];
		if (msg.sender != oracle && msg.sender != position.owner) return;
		if (position.closeOrderId != orderId) return;
		
		position.closeOrderId = 0;
		delete closeOrders[orderId];

	}

	// Add margin to Position with id = positionId
	function addMargin(uint256 positionId) external payable {

		uint256 margin = msg.value / 10**10; // truncate to 8 decimals

		// Check params
		require(margin >= minMargin, "!margin");

		// Check position
		Position storage position = positions[positionId];
		require(msg.sender == position.owner, "!owner");
		require(position.price > 0, "!opening");
		require(position.closeOrderId == 0, "!closing");

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
	function liquidatePositions(
		uint256[] calldata positionIds,
		uint256[] calldata prices
	) external onlyOracle {

		uint256 totalVaultReward;

		for (uint256 i = 0; i < positionIds.length; i++) {

			uint256 positionId = positionIds[i];
			Position memory position = positions[positionId];
			
			if (position.productId == 0 || position.price == 0) {
				continue;
			}

			Product storage product = products[position.productId];

			// Attempt to get chainlink price
			uint256 price = _getChainlinkPrice(product.feed);

			if (price == 0) {
				price = prices[i];
				if (price == 0) {
					continue;
				}
			}

			(uint256 pnl, bool pnlIsNegative) = _getPnL(position, price, position.margin, product.interest);

			console.log('liq', positionId, pnl, pnlIsNegative);
			console.log('pos', position.margin, liquidationThreshold);

			if (pnlIsNegative && pnl >= uint256(position.margin) * liquidationThreshold / 10**4) {

				totalVaultReward += uint256(position.margin);

				uint256 amount = uint256(position.margin) * uint256(position.leverage) / 10**8;
				if (position.isLong) {
					if (product.openInterestLong >= amount) {
						product.openInterestLong -= uint64(amount);
					} else {
						product.openInterestLong = 0;
					}
				} else {
					if (product.openInterestShort >= amount) {
						product.openInterestShort -= uint64(amount);
					} else {
						product.openInterestShort = 0;
					}
				}

				emit ClosePosition(
					positionId, 
					position.owner, 
					position.productId, 
					true,
					position.isLong,
					price, 
					position.price,
					position.margin, 
					position.leverage, 
					position.margin,
					true,
					true
				);

				delete positions[positionId];

			}

		}

		if (totalVaultReward > 0) {
			ITreasury(treasury).creditVault{value: totalVaultReward * 10**10}();
		}

	}

	// Internal methods

	function _validatePrice(
		Product memory product,
		uint256 price,
		bool isLong
	) internal view returns(uint256) {

		uint256 chainlinkPrice = _getChainlinkPrice(product.feed);

		if (chainlinkPrice == 0) {
			require(price > 0, "!price");
			return price;
		}

		// Bound check oracle price against chainlink price
		if (
			price == 0 ||
			price > chainlinkPrice + chainlinkPrice * product.oracleMaxDeviation / 10**4 ||
			price < chainlinkPrice - chainlinkPrice * product.oracleMaxDeviation / 10**4
		) {
			if (isLong) {
				return chainlinkPrice + chainlinkPrice * product.fee / 10**4;
			} else {
				return chainlinkPrice - chainlinkPrice * product.fee / 10**4;
			}
		}

		return price;

	}

	function _getChainlinkPrice(address feed) internal view returns (uint256) {

		if (feed == address(0)) return 0;

		(
			, 
            int price,
            ,
            uint timeStamp,
            
		) = AggregatorV3Interface(feed).latestRoundData();

		if (price <= 0 || timeStamp == 0) return 0;

		uint8 decimals = AggregatorV3Interface(feed).decimals();

		uint256 feedPrice;
		if (decimals != 8) {
			feedPrice = uint256(price) * 10**8 / 10**decimals;
		} else {
			feedPrice = uint256(price);
		}

		return feedPrice;

	}
	
	function _getPnL(
		Position memory position,
		uint256 price,
		uint256 margin,
		uint256 interest
	) internal view returns(uint256 pnl, bool pnlIsNegative) {

		// position.price = 3266, price = 3254

		console.log('_getPnL', price, position.price, margin);
		console.log('_getPnL2', position.isLong, position.leverage, interest);

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

		console.log('k1', pnl, pnlIsNegative);

		// Subtract interest from P/L
		if (block.timestamp >= position.timestamp + 900) {

			uint256 _interest = margin * uint256(position.leverage) * interest * (block.timestamp - uint256(position.timestamp)) / (10**12 * 360 days);

			if (pnlIsNegative) {
				pnl += _interest;
			} else if (pnl < _interest) {
				pnl = _interest - pnl;
				pnlIsNegative = true;
			} else {
				pnl -= _interest;
			}

		}

		console.log('k2', pnl, pnlIsNegative);

		return (pnl, pnlIsNegative);

	}

	// Getters

	function getChainlinkPrice(uint256 productId) external view returns(uint256) {
		Product memory product = products[productId];
		return _getChainlinkPrice(product.feed);
	}

	// gets latest positions and close orders that need to be settled
	function getOrdersToSettle(uint256 limit) external view returns(
		uint256[] memory _positionIds,
		Position[] memory _positions,
		uint256[] memory _orderIds,
		Order[] memory _orders
	) {

		require(limit > 0 && limit <= 300, "!limit");

		_positionIds = new uint256[](limit);
		_positions = new Position[](limit);
		_orderIds = new uint256[](limit);
		_orders = new Order[](limit);

		uint256 until1 = nextPositionId >= limit ? nextPositionId - limit : 0;
		uint256 j = 0;
		for (uint256 i = nextPositionId; i > until1; i--) {
			Position memory position = positions[i];
			if (position.price == 0 && position.margin > 0) {
				_positionIds[j] = i;
				_positions[j] = position;
			}
			j++;
		}

		uint256 until2 = nextCloseOrderId >= limit ? nextCloseOrderId - limit : 0;
		uint256 k = 0;
		for (uint256 i = nextCloseOrderId; i > until2; i--) {
			_orderIds[k] = i;
			_orders[k] = closeOrders[i];
			k++;
		}

		return (
			_positionIds,
			_positions,
			_orderIds,
			_orders
		);

	}

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

	function getOrders(uint256[] calldata orderIds) external view returns(Order[] memory _orders) {
		uint256 length = orderIds.length;
		_orders = new Order[](length);
		for (uint256 i=0; i < length; i++) {
			_orders[i] = closeOrders[orderIds[i]];
		}
		return _orders;
	}

	// Governance methods

	function updateParams(
		uint256 _minMargin,
		uint256 _maxSettlementTime,
		uint256 _liquidationThreshold,
		bool _allowGlobalMarginRelease
	) external onlyOwner {
		minMargin = uint64(_minMargin);
		maxSettlementTime = uint64(_maxSettlementTime);
		liquidationThreshold = uint16(_liquidationThreshold);
		allowGlobalMarginRelease = _allowGlobalMarginRelease;
	}

	function addProduct(uint256 productId, Product memory _product) external onlyOwner {

		Product memory product = products[productId];
		require(product.maxLeverage == 0, "!product-exists");

		require(_product.maxLeverage > 0, "!max-leverage");
		require(_product.oracleMaxDeviation > 0, "!oracleMaxDeviation");

		products[productId] = Product({
			feed: _product.feed,
			maxLeverage: _product.maxLeverage,
			fee: _product.fee,
			interest: _product.interest,
			isActive: true,
			maxExposure: _product.maxExposure,
			openInterestLong: 0,
			openInterestShort: 0,
			oracleMaxDeviation: _product.oracleMaxDeviation,
			minTradeDuration: _product.minTradeDuration
		});

	}

	function updateProduct(uint256 productId, Product memory _product) external onlyOwner {

		Product storage product = products[productId];
		require(product.maxLeverage > 0, "!product-exists");

		require(_product.maxLeverage >= 1 * 10**8, "!max-leverage");
		require(_product.oracleMaxDeviation > 0, "!oracleMaxDeviation");

		product.feed = _product.feed;
		product.maxLeverage = _product.maxLeverage;
		product.fee = _product.fee;
		product.interest = _product.interest;
		product.isActive = _product.isActive;
		product.maxExposure = _product.maxExposure;
		product.oracleMaxDeviation = _product.oracleMaxDeviation;
		product.minTradeDuration = _product.minTradeDuration;
	
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