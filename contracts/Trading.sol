// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

//import "hardhat/console.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import "./interfaces/IRouter.sol";
import "./interfaces/ITrading.sol";
import "./interfaces/ITreasury.sol";
import "./interfaces/IPool.sol";
import "./interfaces/IReferrals.sol";
import "./interfaces/IWETH.sol";

contract Trading {

	using SafeERC20 for IERC20;
    using Address for address payable;
    using EnumerableSet for EnumerableSet.UintSet;

	// All amounts are stored with 8 decimals unless stated otherwise

	// Structs

	// TODO: review bytes

	// To deactivate product, set maxLeverage to 0
	struct Product {
		// 32 bytes
		address feed; // Chainlink. Can be address(0) for no bounding. 20 bytes
		uint32 maxLeverage; // 4 bytes. In units eg 100 = 100x
		uint16 oracleMaxDeviation; // in bps. 2 bytes
		uint16 liquidationThreshold; // in bps. 8000 = 80%. 2 bytes
		uint16 fee; // In sbps (10^6). 0.5% = 5000. 0.025% = 250. 2 bytes
		uint16 interest; // For 360 days, in bps. 5.35% = 535. 2 bytes
	}

	// Amounts stored in 8 decimals
	struct Position {
		// 32 bytes
		uint32 closeOrderId; // 4 bytes
		uint16 productId; // 2 bytes
		uint64 leverage; // 8 bytes
		uint64 price; // 8 bytes
		uint64 margin; // 8 bytes

		// 32 bytes
		address owner; // 20 bytes
		uint88 timestamp; // 11 bytes
		bool isLong; // 1 byte

		// 28 bytes
		address currency; // weth, usdc, etc. 20 bytes
		uint64 fee; // 8 bytes
		uint32 positionId; // 4 bytes
	}

	struct Order {
		uint32 positionId; // 4 bytes
		uint16 productId; // 2 bytes
		uint64 margin; // 8 bytes
		uint64 fee; // 8 bytes
		uint72 timestamp; // 9 bytes
		bool isLong; // 1 byte (position's isLong)
	}

	// Contracts
	address public owner;
	address public router;
	address public weth;
	address public treasury;
	address public oracle;
	address public referrals;

	// Variables

	uint128 public nextPositionId; // Incremental
	uint128 public nextCloseOrderId; // Incremental

	mapping(uint256 => Product) private products;
	mapping(uint256 => Position) private positions;
	mapping(uint256 => Order) private closeOrders;

	mapping(address => EnumerableSet.UintSet) private userPositionIds;

	mapping(address => uint256) activeMargin; // for pool utilization

	mapping(address => uint256) minMargin; // currency => amount

	// Events
	event NewPosition(
		uint256 indexed positionId, 
		address indexed user, 
		uint256 indexed productId, 
		address currency,
		bool isLong, 
		uint256 price, 
		uint256 margin, 
		uint256 leverage,
		uint256 fee
	);
	event AddMargin(
		uint256 indexed positionId, 
		address indexed user, 
		address currency,
		uint256 margin, 
		uint256 newMargin, 
		uint256 newLeverage
	);
	event ClosePosition(
		uint256 positionId, 
		address indexed user, 
		uint256 indexed productId,
		uint256 price,
		uint256 margin,
		uint256 fee, 
		uint256 pnl, 
		bool pnlIsNegative, 
		bool wasLiquidated
	);
	event OpenOrder(
		uint256 indexed positionId,
		address indexed user,
		uint256 indexed productId,
		address currency
	);

	constructor() {
		owner = msg.sender;
	}

	// Governance methods

	function setOwner(address newOwner) external onlyOwner {
		owner = newOwner;
	}

	function setRouter(address _router) external onlyOwner {
		router = _router;
		treasury = IRouter(router).treasury();
		oracle = IRouter(router).oracle();
		weth = IRouter(router).weth();
		referrals = IRouter(router).referrals();
	}

	function setMinMargin(
		address currency,
		uint256 _minMargin
	) external onlyOwner {
		minMargin[currency] = _minMargin;
	}

	function addProduct(uint256 productId, Product memory _product) external onlyOwner {
		Product memory product = products[productId];
		require(product.oracleMaxDeviation == 0, "!product-exists");

		require(_product.liquidationThreshold > 0, "!liqThreshold");

		products[productId] = Product({
			feed: _product.feed,
			maxLeverage: _product.maxLeverage,
			oracleMaxDeviation: _product.oracleMaxDeviation,
			fee: _product.fee,
			interest: _product.interest,
			liquidationThreshold: _product.liquidationThreshold
		});
	}

	function updateProduct(uint256 productId, Product memory _product) external onlyOwner {
		Product storage product = products[productId];
		require(product.oracleMaxDeviation > 0, "!product-does-not-exist");
		
		require(_product.oracleMaxDeviation > 0, "!oracleMaxDeviation");
		require(_product.liquidationThreshold > 0, "!liqThreshold");

		product.feed = _product.feed;
		product.maxLeverage = _product.maxLeverage;
		product.fee = _product.fee;
		product.interest = _product.interest;
		product.oracleMaxDeviation = _product.oracleMaxDeviation;
		product.liquidationThreshold = _product.liquidationThreshold;
	}

	// Methods

	// Submit new position (price pending)
	function submitNewPosition(
		address currency,
		uint256 productId,
		uint256 margin, // net margin
		uint256 leverage,
		bool isLong,
		address referrer
	) external payable {

		// Check params
		require(leverage >= 10**8, "!leverage");
		require(IRouter(router).isSupportedCurrency(currency), "!currency");

		Product storage product = products[productId];
		require(leverage <= uint256(product.maxLeverage) * 10**8, "!max-leverage");

		uint256 fee;

		if (currency == weth) { // User is sending ETH
			require(msg.value > 0, "!margin"); // margin plus fee
			fee = (msg.value / 10**10) * leverage * product.fee / 10**14;
			margin = msg.value / 10**10 - fee;
			IWETH(currency).deposit{value: msg.value}();
		} else {
			fee = margin * leverage * product.fee / 10**14;
			IERC20(currency).safeTransferFrom(msg.sender, address(this), (margin + fee) * 10**10);
		}

		require(margin > 0, "!margin");

		_checkMinMargin(currency, margin);

		// Add position
		nextPositionId++;
		positions[nextPositionId] = Position({
			closeOrderId: 0,
			owner: msg.sender,
			productId: uint16(productId),
			currency: currency,
			leverage: uint64(leverage),
			price: 0,
			margin: uint64(margin),
			fee: uint64(fee),
			timestamp: uint88(block.timestamp),
			isLong: isLong,
			positionId: 0
		});

		userPositionIds[msg.sender].add(nextPositionId);

		// Set referrer
		if (referrer != address(0) && referrer != msg.sender) {
			IReferrals(referrals).setReferrer(msg.sender, referrer);
		}


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
		_sendFeeToTreasury(position.owner, currency, feeAmount);

		activeMargin[currency] += position.margin;

		emit NewPosition(
			positionId,
			position.owner,
			position.productId,
			currency,
			position.isLong,
			price,
			position.margin,
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

		address currency = position.currency;
		uint256 fee = position.fee;

		delete positions[positionId];

		userPositionIds[positionOwner].remove(positionId);


		// Refund margin + fee
		uint256 marginPlusFee = (margin + fee) * 10**10;
		if (currency == weth) { // WETH
			_sendETH(positionOwner, marginPlusFee);
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

		address currency = position.currency;
		_checkMinMargin(currency, margin);

		Product memory product = products[position.productId];

		uint256 fee = margin * position.leverage * product.fee / 10**14;

		if (currency == weth) {
			require(msg.value >= fee * 10**10, "!fee");
			IWETH(currency).deposit{value: msg.value}();
		} else {
			IERC20(currency).safeTransferFrom(msg.sender, address(this), fee * 10**10);
		}

		nextCloseOrderId++;
		closeOrders[nextCloseOrderId] = Order({
			positionId: uint32(positionId),
			productId: uint16(position.productId),
			margin: uint64(margin),
			fee: uint64(fee),
			timestamp: uint72(block.timestamp),
			isLong: position.isLong
		});

		position.closeOrderId = uint32(nextCloseOrderId);

	}

	// Closes position at the fetched price (oracle)
	function settleCloseOrder(
		uint256 orderId, 
		uint256 price
	) external onlyOracle {

		// Check order and params
		Order memory _closeOrder = closeOrders[orderId];
		uint256 margin = _closeOrder.margin;
		require(margin > 0, "!margin");

		Position storage position = positions[_closeOrder.positionId];
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
		if (pnlIsNegative && pnl >= uint256(position.margin) * uint256(product.liquidationThreshold) / 10**4) {
			pnl = uint256(position.margin);
			margin = uint256(position.margin);
		}

		position.margin -= uint64(margin);

		address currency = position.currency;

		if (margin > activeMargin[currency]) {
			activeMargin[currency] = 0;
		} else {
			activeMargin[currency] -= margin;
		}

		_sendFeeToTreasury(position.owner, currency, _closeOrder.fee * 10**10);

		emit ClosePosition(
			_closeOrder.positionId, 
			position.owner, 
			position.productId,
			price, 
			margin, 
			_closeOrder.fee,
			pnl, 
			pnlIsNegative, 
			position.margin == 0
		);

		address positionOwner = position.owner;
		
		if (position.margin == 0) {
			userPositionIds[position.owner].remove(_closeOrder.positionId);
			delete positions[_closeOrder.positionId];
		} else {
			position.closeOrderId = 0;
		}

		delete closeOrders[orderId];

		address pool = IRouter(router).getPool(currency);

		if (pnlIsNegative) {
			IERC20(currency).safeTransfer(pool, pnl * 10**10);
			if (pnl < margin) {
				if (currency == weth) { // WETH
					// Unwrap and send
					_sendETH(positionOwner, (margin - pnl) * 10**10);
				} else {
					IERC20(currency).safeTransfer(positionOwner, (margin - pnl) * 10**10);
				}
			}
		} else {
			if (currency == weth) { // WETH
				_sendETH(positionOwner, margin * 10**10);
			} else {
				IERC20(currency).safeTransfer(positionOwner, margin * 10**10);
			}
			IPool(pool).creditUserProfit(positionOwner, pnl * 10**10);
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
			_sendETH(position.owner, fee * 10**10);
		} else {
			IERC20(currency).safeTransfer(position.owner, fee * 10**10);
		}

	}

	function releaseMargin(uint256 positionId, bool includeFee) external onlyOwner {

		Position storage position = positions[positionId];
		require(position.margin > 0, "!position");

		uint256 margin = position.margin;
		address positionOwner = position.owner;
		address currency = position.currency;

		emit ClosePosition(
			positionId, 
			positionOwner, 
			position.productId, 
			position.price, 
			margin, 
			0,
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

		delete positions[positionId];

		if (margin > activeMargin[currency]) {
			activeMargin[currency] = 0;
		} else {
			activeMargin[currency] -= margin;
		}

		IERC20(currency).safeTransfer(positionOwner, margin * 10**10);

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

		address currency = position.currency;

		if (currency == weth) { // User is sending ETH
			require(msg.value > 0, "!margin");
			margin = msg.value / 10**10;
			IWETH(currency).deposit{value: msg.value}();
		} else {
			IERC20(currency).safeTransferFrom(msg.sender, address(this), margin * 10**10);
		}

		_checkMinMargin(currency, margin);

		// New position params
		uint256 newMargin = position.margin + margin;
		uint256 newLeverage = position.leverage * position.margin / newMargin;
		require(newLeverage >= 10**8, "!low-leverage");

		position.margin = uint64(newMargin);
		position.leverage = uint64(newLeverage);

		activeMargin[currency] += newMargin;

		emit AddMargin(
			positionId, 
			position.owner, 
			currency,
			margin, 
			newMargin, 
			newLeverage
		);

	}

	// Liquidate positionIds (oracle)
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

			uint256 margin = position.margin;

			(uint256 pnl, bool pnlIsNegative) = _getPnL(position, price, margin, product.interest);

			if (pnlIsNegative && pnl >= uint256(margin) * uint256(product.liquidationThreshold) / 10**4) {

				_sendFeeToTreasury(position.owner, position.currency, margin * 10**10);

				if (margin > activeMargin[position.currency]) {
					activeMargin[position.currency] = 0;
				} else {
					activeMargin[position.currency] -= margin;
				}

				position.margin = 0;

				emit ClosePosition(
					positionId, 
					position.owner, 
					position.productId, 
					price, 
					margin, 
					0,
					margin, 
					true, 
					true
				);

				userPositionIds[position.owner].remove(positionId);

				delete positions[positionId];

			}

		}

	}

	// To receive ETH from WETH
	fallback() external payable {}
	receive() external payable {}

	// Utils

	function _checkMinMargin(
		address currency,
		uint256 margin
	) internal {
		require(margin >= minMargin[currency], "!min-margin");
	}

	// Send ETH from WETH
	function _sendETH(address to, uint256 amount) internal {
		IWETH(weth).withdraw(amount);
		payable(to).sendValue(amount);
	}

	function _sendFeeToTreasury(address user, address currency, uint256 amount) internal {
		IERC20(currency).safeTransfer(treasury, amount);
		ITreasury(treasury).notifyFeeReceived(user, currency, amount);
	}

	function _validatePrice(
		address feed,
		uint256 oracleMaxDeviation,
		uint256 price
	) internal view returns(uint256) {

		uint256 chainlinkPrice = _getChainlinkPrice(feed);

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

	function getActiveMargin(address currency) external view returns(uint256) {
		return activeMargin[currency];
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

	function getUserPositions(address user) external view returns(Position[] memory _positions) {
		uint256 length = userPositionIds[user].length();
		_positions = new Position[](length);
		for (uint256 i=0; i < length; i++) {
			uint256 id = userPositionIds[user].at(i);
			Position memory positionWithId = positions[id];
			positionWithId.positionId = uint32(id);
			_positions[i] = positionWithId;
		}
		return _positions;
	}

	// Modifiers

	modifier onlyOracle() {
		require(msg.sender == oracle, "!oracle");
		_;
	}

	modifier onlyOwner() {
		require(msg.sender == owner, "!owner");
		_;
	}

}