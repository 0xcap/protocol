// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

//import "hardhat/console.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/Address.sol";

import "./libraries/Price.sol";

import "./interfaces/ITreasury.sol";

// keep everything in one contract

contract Trading {

	using SafeERC20 for IERC20;
    using Address for address payable;

	// Structs

	// TODO: review bytes

	struct Product {
		// 32 bytes
		address feed; // Chainlink. Can be address(0) for no bounding. 20 bytes
		uint24 maxLeverage; // 3 bytes
		uint16 oracleMaxDeviation; // in bps. 2 bytes
		uint16 liquidationThreshold; // in bps. 8000 = 80%. 2 bytes
		uint16 fee; // In sbps (10^6). 0.5% = 5000. 0.025% = 250. 2 bytes
		uint16 interest; // For 360 days, in bps. 5.35% = 535. 2 bytes
		bool isActive; // 1 byte
	}

	// amounts stored in 8 decimals
	struct Position {
		// 32 bytes
		uint32 closeOrderId; // 4 bytes
		uint16 productId; // 2 bytes
		uint64 leverage; // 8 bytes
		uint64 price; // 8 bytes
		uint64 margin; // 8 bytes

		address currency; // weth, usdc, etc.
		uint64 fee; // 8 bytes

		// 32 bytes
		address owner; // 20 bytes
		uint88 timestamp; // 11 bytes
		bool isLong; // 1 byte
	}

	struct Order {
		uint64 positionId; // 8 bytes
		uint16 productId; // 2 bytes
		uint64 margin; // 8 bytes
		uint64 fee; // 8 bytes
		uint88 timestamp; // 11 bytes
		bool isLong; // 1 byte (position's isLong)
	}

	// Variables

	address public owner; 
	address public weth;
	address public treasury;
	address public oracle;

	// 32 bytes
	uint256 public nextPositionId; // Incremental. 6 bytes
	uint256 public nextCloseOrderId; // Incremental. 6 bytes
	uint256 public minMarginInUSD; // in wei units

	mapping(uint256 => Product) private products;
	mapping(uint256 => Position) private positions;
	mapping(uint256 => Order) private closeOrders;

	mapping(address => uint256) minMargins; // currency => amount
	mapping(address => uint256) marginPerCurrency; // for pool utilization

	// Events
	event NewPosition(
		uint256 indexed positionId, 
		address indexed user, 
		uint256 indexed productId, 
		bool isLong, 
		uint256 price, 
		uint256 margin, 
		uint256 marginInUSD, 
		uint256 leverage,
		uint256 fee
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
		uint256 collateralId,
		bool isLong,
		uint256 price, 
		uint256 entryPrice, 
		uint256 margin, 
		uint256 leverage, 
		uint256 fee, 
		uint256 pnl, 
		bool pnlIsNegative, 
		bool wasLiquidated
	);
	event OpenOrder(
		uint256 indexed positionId,
		address indexed user,
		uint256 indexed productId,
		uint256 collateralId
	);

	// Constructor

	constructor() {
		owner = msg.sender;
	}

	function setRouter(address _router) onlyOwner {
		router = _router;
	}

	function setContracts() external {
		treasury = IRouter(router).treasuryContract();
		oracle = IRouter(router).oracleContract();
		weth = IRouter(router).wethContract();
		referrals = IRouter(router).referralsContract();
	}

	// Methods

	// Submit new position (price pending)
	function submitNewPosition(
		address currency,
		uint256 productId,
		uint256 margin,
		uint256 leverage,
		bool isLong,
		address referrer
	) external payable {

		// Set referrer
		if (referrer != address(0) && referrer != msg.sender) {
			IReferrals(referrals).setReferrer(msg.sender, referrer);
		}

		// Check params
		require(leverage >= 10**8, "!leverage");
		require(currency != address(0), "!currency");

		if (currency == weth) { // User is sending ETH
			require(msg.value > 0, "!margin");
			margin = msg.value;
			IWETH(currency).deposit{value: margin}();
		} else {
			IERC20(currency).safeTransferFrom(msg.sender, address(this), margin);
		}

		require(margin > 0, "!margin");

		Product storage product = products[productId];
		require(product.isActive, "!product-active");
		require(leverage / 10**18 <= product.maxLeverage, "!max-leverage");

		uint256 netMargin = margin * (1 - product.fee / 10**6);

		_checkMinMargin(currency, netMargin);

		uint256 fee = margin - netMargin;

		// Add position
		nextPositionId++;
		positions[nextPositionId] = Position({
			closeOrderId: 0,
			owner: msg.sender,
			productId: uint16(productId),
			currency: currency,
			leverage: uint64(leverage / 10**10),
			price: 0,
			margin: uint64(netMargin / 10**10),
			fee: uint64(fee / 10**10),
			timestamp: uint88(block.timestamp),
			isLong: isLong
		});

		emit OpenOrder(
			nextPositionId,
			msg.sender,
			productId,
			currency
		);

	}

	// Set price for newly submitted position (oracle)
	function settleNewPosition(
		uint256 positionId,
		uint256 price
	) external onlyOracle {

		// Check position
		Position storage position = positions[positionId];
		require(position.margin > 0, "!position");
		require(position.price == 0, "!settled");

		Product memory product = products[position.productId];

		// Validate price
		price = _validatePrice(product.feed, product.oracleMaxDeviation, price);

		// Set position price
		position.price = uint64(price);

		// Send fee to treasury
		address currency = position.currency;
		uint256 feeAmount = position.fee * 10**10;
		IERC20(currency).safeTransfer(treasury, feeAmount);
		ITreasury(treasury).notifyFeeReceived(currency, feeAmount);

		marginPerCurrency[position.currency] += position.margin;

		emit NewPosition(
			positionId,
			position.owner,
			position.productId,
			position.currency,
			position.isLong,
			price,
			position.margin,
			position.marginInUSD,
			position.leverage,
			position.fee
		);

	}

	// User or oracle can cancel pending position e.g. in case of error or non-execution
	function cancelPosition(uint256 positionId) external {

		// Sanity check position. Checks should fail silently
		Position memory position = positions[positionId];
		uint256 margin = position.margin;
		address positionOwner = position.owner;

		if (
			position.price != 0 ||
			margin == 0 ||
			msg.sender != positionOwner && msg.sender != oracle
		) return;

		uint256 currency = position.currency;
		uint256 fee = position.fee;

		delete positions[positionId];

		// Refund margin + fee
		uint256 marginPlusFee = (margin + fee) * 10**10;
		if (currency == weth) { // WETH
			// Unwrap and send
			IWETH(currency).withdraw(marginPlusFee);
			payable(positionOwner).sendValue(marginPlusFee);
		} else {
			IERC20(currency).safeTransfer(positionOwner, marginPlusFee);
		}

	}

	// Submit order to close a position
	function submitCloseOrder( 
		uint256 positionId, 
		uint256 margin
	) external payable {

		require(margin > 0, "!margin");

		// Check position
		Position storage position = positions[positionId];
		require(msg.sender == position.owner, "!owner");
		require(position.margin > 0, "!position");
		require(position.price > 0, "!opening");
		require(position.closeOrderId == 0, "!closing");

		Product memory product = products[position.productId];

		uint256 currency = position.currency;

		_checkMinMargin(currency, margin);

		uint256 fee = margin * product.fee / 10**6;

		if (currency == weth) {
			require(msg.value >= fee, "!fee");
			IWETH(currency).deposit{value: msg.value}();
		} else {
			IERC20(currency).safeTransferFrom(msg.sender, address(this), fee);
		}

		nextCloseOrderId++;
		closeOrders[nextCloseOrderId] = Order({
			positionId: uint64(positionId),
			productId: uint32(position.productId),
			margin: uint64(margin),
			fee: uint64(fee),
			timestamp: uint88(block.timestamp),
			isLong: position.isLong,
		});

		position.closeOrderId = uint40(nextCloseOrderId);

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
		require(position.closeOrderId == orderId, "!order");
		require(position.price > 0, "!opening");

		if (margin >= position.margin) {
			margin = position.margin;
		}

		Product storage product = products[position.productId];
		
		price = _validatePrice(product.feed, product.oracleMaxDeviation, price);

		(uint256 pnl, bool pnlIsNegative) = _getPnL(position, price, margin, product.interest);

		// Check if it's a liquidation
		bool isLiquidation;
		if (pnlIsNegative && pnl >= uint256(position.margin) * uint256(product.liquidationThreshold) / 10**4) {
			pnl = uint256(position.margin);
			margin = uint256(position.margin);
			isLiquidation = true;
		}

		position.margin -= uint64(margin);

		if (margin > marginPerCurrency[position.currency]) {
			marginPerCurrency[position.currency] = 0;
		} else {
			marginPerCurrency[position.currency] -= margin;
		}

		// Send fee to treasury
		address currency = position.currency;
		IERC20(currency).safeTransfer(treasury, _closeOrder.fee * 10**10);
		// todo: notify fee received

		address positionOwner = position.owner;

		emit ClosePosition(
			positionId, 
			positionOwner, 
			position.productId, 
			position.margin == 0,
			position.collateralId, 
			position.isLong,
			price, 
			position.price,
			margin, 
			position.leverage, 
			_closeOrder.fee,
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

		if (pnlIsNegative) {
			IERC20(currency).safeTransfer(pool, pnl * 10**10);
			if (pnl < margin) {
				IERC20(currency).safeTransfer(positionOwner, (margin - pnl) * 10**10);
			}
		} else {
			IERC20(currency).safeTransfer(positionOwner, margin * 10**10);
			IPool(pool).creditUserProfit(positionOwner, currency, pnl * 10**10);
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

		uint256 fee = _closeOrder.fee;

		delete closeOrders[orderId];

		// Refund fee
		address currency = position.currency;
		if (currency == weth) { // WETH
			// Unwrap and send
			IWETH(currency).withdraw(fee);
			payable(position.owner).sendValue(fee);
		} else {
			IERC20(currency).safeTransfer(position.owner, fee);
		}

	}

	function releaseMargin(uint256 positionId, bool includeFee) external onlyOwner {

		Position storage position = positions[positionId];
		require(position.margin > 0, "!position");

		Product storage product = products[position.productId];

		uint256 margin = position.margin;
		address positionOwner = position.owner;

		emit ClosePosition(
			positionId, 
			positionOwner, 
			position.productId, 
			true,
			position.collateralId, 
			position.isLong,
			position.price, 
			position.price,
			margin, 
			position.leverage, 
			position.fee, 
			0, 
			false, 
			false
		);

		if (position.closeOrderId > 0) {
			delete closeOrders[position.closeOrderId];
		}

		if (includeFee) {
			margin += position.fee;
		}

		if (margin > marginPerCurrency[position.currency]) {
			marginPerCurrency[position.currency] = 0;
		} else {
			marginPerCurrency[position.currency] -= margin;
		}

		IERC20(position.currency).safeTransfer(positionOwner, margin * 10**10);

		delete positions[positionId];

	}

	// Add margin to Position with id = positionId
	function addMargin(
		uint256 positionId,
		uint256 margin
	) external payable {

		// Check position
		Position storage position = positions[positionId];
		require(msg.sender == position.owner, "!owner");
		require(position.price > 0, "!opening");
		require(position.closeOrderId == 0, "!closing");

		uint256 currency = position.currency;

		if (currency == weth) { // User is sending ETH
			require(msg.value > 0, "!margin");
			margin = msg.value;
			IWETH(currency).deposit{value: margin}();
		} else {
			IERC20(currency).safeTransferFrom(msg.sender, address(this), margin);
		}

		_checkMinMargin(currency, margin);

		// New position params
		uint256 newMargin = position.margin + margin / 10**10;
		uint256 newLeverage = position.leverage * position.margin / newMargin;
		require(newLeverage >= 10**8, "!low-leverage");

		position.margin = uint64(newMargin);
		position.leverage = uint64(newLeverage);

		marginPerCurrency[currency] += newMargin;

		emit AddMargin(
			positionId, 
			position.owner, 
			margin / 10**10, 
			newMargin, 
			newLeverage
		);

	}

	// Liquidate positionIds
	function liquidatePositions(
		uint256[] calldata positionIds,
		uint256[] calldata prices
	) external onlyOracle {

		for (uint256 i = 0; i < positionIds.length; i++) {

			uint256 positionId = positionIds[i];
			Position memory position = positions[positionId];
			
			if (position.productId == 0 || position.price == 0) {
				continue;
			}

			Product storage product = products[position.productId];

			uint256 price = _validatePrice(product.feed, product.oracleMaxDeviation, prices[i]);

			// Chainlink fallback
			if (price == 0) {
				price = _getChainlinkPrice(product.feed);
				if (price == 0) {
					continue;
				}
			}

			(uint256 pnl, bool pnlIsNegative) = _getPnL(position, price, position.margin, product.interest);

			if (pnlIsNegative && pnl >= uint256(position.margin) * uint256(product.liquidationThreshold) / 10**4) {

				IERC20(position.currency).safeTransfer(treasury, position.margin * 10**10);

				if (position.margin > marginPerCurrency[position.currency]) {
					marginPerCurrency[position.currency] = 0;
				} else {
					marginPerCurrency[position.currency] -= position.margin;
				}

				emit ClosePosition(
					positionId, 
					position.owner, 
					position.productId, 
					true,
					position.collateralId,
					position.isLong,
					price, 
					position.price,
					position.margin, 
					position.leverage, 
					position.fee,
					position.margin,
					true,
					true
				);

				delete positions[positionId];

			}

		}

	}

	// Internal methods

	function _checkMinMargin(
		address currency,
		uint256 margin
	) internal {
		require(margin >= minMargins[currency], "!min-margin");
	}

	function _validatePrice(
		address feed,
		uint256 oracleMaxDeviation,
		uint256 price
	) internal view returns(uint256) {

		uint256 chainlinkPrice = Price.get(feed);

		if (chainlinkPrice == 0) {
			require(price > 0, "!price");
			return price;
		}

		// Bound check oracle price against chainlink price
		if (
			price == 0 ||
			price > chainlinkPrice + chainlinkPrice * oracleMaxDeviation / 10**4 ||
			price < chainlinkPrice - chainlinkPrice * oracleMaxDeviation / 10**4
		) {
			return chainlinkPrice;
		}

		return price;

	}
	
	function _getPnL(
		Position memory position,
		uint256 price,
		uint256 margin,
		uint256 interest
	) internal view returns(uint256 pnl, bool pnlIsNegative) {

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

		return (pnl, pnlIsNegative);

	}

	// Getters

	function getMarginPerCurrency(address currency) external view returns(uint256) {
		return marginPerCurrency[currency];
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

	function getCloseOrders(uint256[] calldata orderIds) external view returns(Order[] memory _orders) {
		uint256 length = orderIds.length;
		_orders = new Order[](length);
		for (uint256 i=0; i < length; i++) {
			_orders[i] = closeOrders[orderIds[i]];
		}
		return _orders;
	}

	// Governance methods

	function setParams(
		uint256 _minMarginInUSD
	) external onlyOwner {
		minMarginInUSD = _minMarginInUSD;
	}

	function setContracts(
		uint256 _treasury,
		uint256 _oracle,
		uint256 _pool
	) external onlyOwner {
		treasury = _treasury;
		oracle = _oracle;
		pool = _pool;
	}

	function setOwner(address newOwner) external onlyOwner {
		owner = newOwner;
	}

	function addProduct(uint256 productId, Product memory _product) external onlyOwner {

		Product memory product = products[productId];
		require(product.maxLeverage == 0, "!product-exists");

		require(_product.maxLeverage >= 10**8, "!max-leverage");

		products[productId] = Product({
			feed: _product.feed,
			maxLeverage: _product.maxLeverage,
			fee: _product.fee,
			interest: _product.interest,
			isActive: true,
			oracleMaxDeviation: _product.oracleMaxDeviation
		});

	}

	function updateProduct(uint256 productId, Product memory _product) external onlyOwner {

		Product storage product = products[productId];
		require(product.maxLeverage > 0, "!product-does-not-exist");

		require(_product.maxLeverage >= 10**8, "!max-leverage");
		require(_product.oracleMaxDeviation > 0, "!oracleMaxDeviation");

		product.feed = _product.feed;
		product.maxLeverage = _product.maxLeverage;
		product.fee = _product.fee;
		product.interest = _product.interest;
		product.isActive = _product.isActive;
		product.oracleMaxDeviation = _product.oracleMaxDeviation;
	
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