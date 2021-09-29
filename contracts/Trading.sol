// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "hardhat/console.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

import "./interfaces/ITreasury.sol";

contract Trading {

	// All amounts are stored with 8 decimals

	// Structs

	// TODO: option to be unbounded by chainlink, per product, to scale possible products available

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
		uint16 oracleMaxDeviation; // 2 bytes
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
		uint80 positionId;
		uint80 margin;
		uint72 timestamp;
		bool releaseMargin;
		bool fromLiquidator;
		bool ownerOverride;
	}

	// Variables

	address public owner; // Contract owner
	address public treasury;
	address public oracle;

	// TODO: review bytes
	// 32 bytes
	uint64 public vaultBalance;
	uint64 public vaultThreshold = 10 * 10**8; // 10 ETH
	uint64 public minMargin = 100000; // 0.001 ETH
	uint64 public maxSettlementTime = 10 minutes;
	uint64 public nextPositionId; // Incremental
	uint64 public nextCloseOrderId;
	bool allowGlobalMarginRelease = false;

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

	// Submit new position (no price)
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
			owner: msg.sender,
			productId: uint64(productId),
			margin: uint64(margin),
			leverage: uint64(leverage),
			price: 0,
			timestamp: uint88(block.timestamp),
			isLong: isLong
		});

	}

	// Set price for newly submitted position
	function settleNewPosition(
		uint256 positionId,
		uint256 price
	) external onlyOracle {

		// Check position
		Position storage position = positions[positionId];
		require(position.margin > 0, "!position");
		require(position.price == 0, "!settled");
		require(block.timestamp <= position.timestamp + maxSettlementTime, "!time");

		Product storage product = products[position.productId];

		// Update exposure
		uint256 amount = position.margin * position.leverage / 10**8;
		if (position.isLong) {
			product.openInterestLong += uint48(amount);
			require(product.openInterestLong <= product.maxExposure + product.openInterestShort, "!exposure-long");
		} else {
			product.openInterestShort += uint48(amount);
			require(product.openInterestShort <= product.maxExposure + product.openInterestLong, "!exposure-short");
		}

		// Set price
		price = _validatePrice(product, price);
		price = _addFeeToPrice(price, product.fee, position.isLong);

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

		// ! Multiple close orders can be submitted on the same position before they are settled
		_submitCloseOrder(
			msg.sender,
			positionId,
			margin,
			releaseMargin,
			false
		);

	}

	// Internal method used also by liquidator
	function _submitCloseOrder(
		address sender,
		uint256 positionId,
		uint256 margin,
		bool releaseMargin,
		bool fromLiquidator
	) internal {

		require(margin >= minMargin, "!margin");

		// Check position
		Position memory position = positions[positionId];
		require(fromLiquidator || sender == owner || sender == position.owner, "!owner");
		require(position.margin > 0, "!position");

		// Check product
		Product memory product = products[position.productId];
		require(block.timestamp >= position.timestamp + product.minTradeDuration, "!duration");

		// Governance can release margin from any position to protect from malicious profits
		bool ownerOverride;
		if (sender == owner) {
			ownerOverride = true;
			releaseMargin = true;
		}

		nextCloseOrderId++;
		closeOrders[nextCloseOrderId] = Order({
			positionId: uint80(positionId),
			margin: uint80(margin),
			timestamp: uint72(block.timestamp),
			releaseMargin: releaseMargin,
			fromLiquidator: fromLiquidator,
			ownerOverride: ownerOverride
		});

	}

	// Closes position at the fetched price
	function settleCloseOrder(
		uint256 orderId, 
		uint256 price
	) external onlyOracle {

		// Check order and params
		Order memory _closeOrder = closeOrders[orderId];
		uint256 margin = _closeOrder.margin;
		require(margin > 0, "!margin");

		uint256 positionId = _closeOrder.positionId;

		Position storage position = positions[positionId];
		require(position.margin > 0, "!position");

		bool isFullClose;
		if (margin > position.margin) {
			margin = position.margin;
			isFullClose = true;
		}

		Product storage product = products[position.productId];

		uint256 pnl;
		bool pnlIsNegative;

		if (_closeOrder.releaseMargin && allowGlobalMarginRelease) {
			(pnl, pnlIsNegative) = (0, false);
		} else {

			require(block.timestamp <= _closeOrder.timestamp + maxSettlementTime, "!time");
			
			price = _validatePrice(product, price);
			price = _addFeeToPrice(price, product.fee, !position.isLong);

			(pnl, pnlIsNegative) = _getPnL(position, price, margin, product.interest);

		}

		// Can't release margin on pnl negative position
		if (_closeOrder.ownerOverride && pnlIsNegative) {
			revert("!override");
		}

		// Check if it's a liquidation
		bool isLiquidation;
		if (pnlIsNegative && pnl >= position.margin * product.liquidationThreshold / 10**4) {
			pnl = position.margin;
			margin = position.margin;
			isLiquidation = true;
			isFullClose = true;
		}

		if (_closeOrder.fromLiquidator && !isLiquidation) {
			revert("!liquidation");
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

		address positionOwner = position.owner;

		emit ClosePosition(
			positionId, 
			positionOwner, 
			position.productId, 
			isFullClose,
			price, 
			position.price,
			margin, 
			position.leverage, 
			pnl, 
			pnlIsNegative, 
			isLiquidation
		);

		if (isFullClose) {
			delete positions[positionId];
		}

		delete closeOrders[orderId];

		if (pnlIsNegative) {
			_creditVault(pnl);
			if (pnl < margin) {
				payable(positionOwner).transfer((margin - pnl) * 10**10);
			}
		} else {
			if (_closeOrder.releaseMargin) {
				pnl = 0;
			}
			require(pnl <= vaultBalance, "!vault-insufficient");
			vaultBalance -= uint64(pnl);
			payable(positionOwner).transfer((margin + pnl) * 10**10);
		}

	}

	// User or oracle can cancel pending order e.g. in case of error or non-execution
	function cancelOrder(uint256 orderId) external {

		// Checks should fail silently
		Order memory _closeOrder = closeOrders[orderId];
		if (_closeOrder.positionId == 0) return;
		
		Position memory position = positions[_closeOrder.positionId];
		if (msg.sender != oracle && msg.sender != position.owner) return;
		
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
	// TODO: dark oracle should liquidate. That way it comes directly with a price, use chainlink if available otherwise this price. dark oracle gets liq rewards
	function liquidatePositions(
		uint256[] calldata positionIds,
		uint256[] calldata prices
	) external onlyOracle {

		uint256 totalVaultReward;
		uint256 totalLiquidatorReward;

		for (uint256 i = 0; i < positionIds.length; i++) {

			uint256 positionId = positionIds[i];
			Position memory position = positions[positionId];
			
			if (position.productId == 0) {
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

	function _validatePrice(
		Product memory product,
		uint256 price
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
			return chainlinkPrice;
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

	function _addFeeToPrice(
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

	// Credit vault with trader losses and send excess to treasury
	function _creditVault(uint256 amount) internal {
		if (amount == 0) return;
		if (vaultBalance + amount > vaultThreshold) {
			uint256 excess = vaultBalance + amount - vaultThreshold;
			vaultBalance = vaultThreshold;
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

	

	

	

	// Called from client
	function getChainlinkPrice(uint256 productId) external view returns(uint256) {
		Product memory product = products[productId];
		return _getChainlinkPrice(product.feed);
	}

	// Getters

	// gets latest positions and close orders that need to be settled
	function getPendingOrderIds() external view returns(
		uint256[] memory openOrderIds,
		uint256[] memory openOrderProductIds,
		uint256[] memory closeOrderIds, 
		uint256[] memory closeOrderProductIds
	) {

		uint256 lookback = 10;

		openOrderIds = new uint256[](lookback);
		openOrderProductIds = new uint256[](lookback);

		uint256 until1 = nextPositionId >= lookback ? nextPositionId - lookback : 0;

		uint256 j = 0;
		for (uint256 i = nextPositionId; i >= until1; i--) {
			Position memory position = positions[i];
			if (position.price == 0) {
				openOrderIds[j] = i;
				openOrderProductIds[j] = position.productId;
			}
			j++;
		}

		closeOrderIds = new uint256[](lookback);
		closeOrderProductIds = new uint256[](lookback);

		uint256 until2 = nextCloseOrderId >= lookback ? nextCloseOrderId - lookback : 0;

		uint256 k = 0;
		for (uint256 i = nextCloseOrderId; i >= until2; i--) {
			Order memory _closeOrder = closeOrders[i];
			closeOrderIds[k] = i;
			Position memory position = positions[_closeOrder.positionId];
			closeOrderProductIds[k] = position.productId;
			k++;
		}

		return (
			openOrderIds,
			openOrderProductIds,
			closeOrderIds, 
			closeOrderProductIds
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
		require(_product.oracleMaxDeviation > 0, "!oracleMaxDeviation");
		require(_product.liquidationThreshold > 0, "!liquidationThreshold");

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
		require(_product.oracleMaxDeviation > 0, "!oracleMaxDeviation");
		require(_product.liquidationThreshold > 0, "!liquidationThreshold");

		product.feed = _product.feed;
		product.maxLeverage = _product.maxLeverage;
		product.fee = _product.fee;
		product.interest = _product.interest;
		product.isActive = _product.isActive;
		product.maxExposure = _product.maxExposure;
		product.oracleMaxDeviation = _product.oracleMaxDeviation;
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