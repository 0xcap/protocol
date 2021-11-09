// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "./libraries/SafeERC20.sol";
import "./libraries/Address.sol";

import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import "./interfaces/IRouter.sol";
import "./interfaces/ITreasury.sol";
import "./interfaces/IPool.sol";
import "./interfaces/IWETH.sol";

contract Trading {

	// Gas optimization:
	/*
	- get off WETH (use ETH directly)
	- 10 decimals instead of 18 for everything
	- review bytes in structs
	- get off enumerable set in positions, use events/graph to fetch latest user positions on client
	*/

	using SafeERC20 for IERC20;
    using Address for address payable;
    using EnumerableSet for EnumerableSet.UintSet;

	// Structs

	struct Product {
		uint256 maxLeverage; // set to 0 to deactivate product
		uint256 liquidationThreshold; // in bps. 8000 = 80%
		uint256 fee; // In sbps (10^6). 0.5% = 5000. 0.025% = 250
		uint256 interest; // For 360 days, in bps. 5.35% = 535
	}

	struct Position {

		// 27 bytes
		bool isLong; // 1
		address user; // 20
		uint16 productId; // 2
		uint32 positionId; // 4

		// 32 bytes
		address currency; // 20
		uint32 closeOrderId; // 4
		uint64 timestamp; // 8

		// 32 bytes
		uint88 size; // 11
		uint88 price; // 11
		uint80 fee; // 10

		// 
		uint88 margin; // 11
		
	}

	struct CloseOrder {
		uint256 positionId;
		uint256 productId;
		uint256 size;
		uint256 fee;
		uint256 timestamp;
		bool isLong; // position's isLong
	}

	// Contracts
	address public owner;
	address public router;
	address public weth;
	address public treasury;
	address public oracle;

	uint256 public nextPositionId; // Incremental
	uint256 public nextCloseOrderId; // Incremental

	mapping(uint256 => Product) private products;
	mapping(uint256 => Position) private positions;
	mapping(uint256 => CloseOrder) private closeOrders;

	mapping(address => EnumerableSet.UintSet) private userPositionIds;

	mapping(address => uint256) minMargin; // currency => amount

	mapping(address => uint256) pendingFees; // currency => amount

	uint256 public constant UNIT_DECIMALS = 18;
	uint256 public constant UNIT = 10**UNIT_DECIMALS;

	uint256 public constant PRICE_DECIMALS = 8;

	// Events
	event NewPosition(
		uint256 indexed positionId, 
		address indexed user, 
		uint256 indexed productId, 
		address currency,
		bool isLong, 
		uint256 price, 
		uint256 margin, 
		uint256 size,
		uint256 fee
	);
	event AddMargin(
		uint256 indexed positionId, 
		address indexed user, 
		address indexed currency,
		uint256 margin, 
		uint256 newMargin, 
		uint256 newLeverage
	);
	event ClosePosition(
		uint256 indexed positionId, 
		address indexed user, 
		uint256 indexed productId,
		uint256 price,
		uint256 margin,
		uint256 size,
		uint256 fee, 
		int256 pnl, 
		bool wasLiquidated
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
	}

	function setMinMargin(
		address currency,
		uint256 _minMargin
	) external onlyOwner {
		minMargin[currency] = _minMargin;
	}

	function addProduct(uint256 productId, Product memory _product) external onlyOwner {
		
		Product memory product = products[productId];
		
		require(product.liquidationThreshold == 0, "!product-exists");
		require(_product.liquidationThreshold > 0, "!liqThreshold");

		products[productId] = Product({
			maxLeverage: _product.maxLeverage,
			fee: _product.fee,
			interest: _product.interest,
			liquidationThreshold: _product.liquidationThreshold
		});

	}

	function updateProduct(uint256 productId, Product memory _product) external onlyOwner {

		Product storage product = products[productId];

		require(product.liquidationThreshold > 0, "!product-does-not-exist");

		product.maxLeverage = _product.maxLeverage;
		product.fee = _product.fee;
		product.interest = _product.interest;
		product.liquidationThreshold = _product.liquidationThreshold;

	}

	// Methods

	function distributeFees(address currency) external {
		uint256 pendingFee = pendingFees[currency];
		if (pendingFee > 0) {
			pendingFees[currency] = 0;
			_transferOut(currency, treasury, pendingFee, false);
			ITreasury(treasury).notifyFeeReceived(currency, pendingFee);
		}
	}

	// Submit new position (price pending)
	function submitNewPosition(
		address currency,
		uint256 productId,
		uint256 margin, // net margin
		uint256 size,
		bool isLong
	) external payable {

		if (currency == weth) { // User is sending ETH
			margin = msg.value;
			// 54K
			IWETH(weth).deposit{value: margin}();
		}

		// Check params
		require(margin > 0, "!margin");
		require(size > 0, "!size");
		require(IRouter(router).isSupportedCurrency(currency), "!currency");

		// 10K
		Product memory product = products[productId];

		uint256 fee = size * product.fee / 10**6;

		if (currency == weth) {
			require(margin > fee, "!margin<fee");
			margin -= fee;
		} else {
			_transferIn(currency, margin + fee);
		}

		// Checks 3K
		uint256 leverage = UNIT * size / margin;
		require(leverage >= UNIT, "!leverage");
		require(leverage <= product.maxLeverage, "!max-leverage");

		require(margin >= minMargin[currency], "!min-margin");

		// Check pool utlization 20K
		_updateOpenInterest(currency, size, false);

		address pool = IRouter(router).getPool(currency);
		uint256 utilization = IPool(pool).getUtilization();

		require(utilization < 10**4, "!utilization");

		// Add position 114
		nextPositionId++;
		positions[nextPositionId] = Position({
			positionId: 0,
			closeOrderId: 0,
			user: msg.sender,
			timestamp: uint64(block.timestamp),
			productId: uint16(productId),
			currency: currency,
			price: 0,
			size: uint88(size),
			margin: uint88(margin),
			fee: uint80(fee),
			isLong: isLong
		});

		// 72K
		userPositionIds[msg.sender].add(nextPositionId);

	}

	// Set price for newly submitted position (oracle)
	function settleNewPosition(
		uint256 positionId,
		uint256 price // 8 decimals
	) external onlyOracle {

		// Check position
		Position storage position = positions[positionId];
		require(position.margin > 0, "!position");
		require(position.price == 0, "!settled");

		// Validate price, returns 18 decimals
		price = _validatePrice(price);

		// Send fee to treasury
		address currency = position.currency;
		
		pendingFees[currency] += position.fee;

		position.price = uint88(price);

		emit NewPosition(
			positionId,
			position.user,
			position.productId,
			currency,
			position.isLong,
			price,
			position.margin,
			position.size,
			position.fee
		);

	}

	// User or oracle can cancel pending position e.g. in case of error or non-execution
	function cancelPosition(uint256 positionId) external {

		// Sanity check position. Checks should fail silently
		Position memory position = positions[positionId];
		uint256 margin = position.margin;
		address positionUser = position.user;

		if (
			position.price != 0 ||
			margin == 0 ||
			msg.sender != positionUser && msg.sender != oracle
		) return;

		address currency = position.currency;
		uint256 fee = position.fee;

		_updateOpenInterest(currency, position.size, true);

		delete positions[positionId];

		userPositionIds[positionUser].remove(positionId);

		// Refund margin + fee
		uint256 marginPlusFee = margin + fee;
		_transferOut(currency, positionUser, marginPlusFee, true);

	}

	// Submit order to close a position
	function submitCloseOrder( 
		uint256 positionId, 
		uint256 size
	) external payable {

		require(size > 0, "!size");

		// Check position
		Position storage position = positions[positionId];
		require(msg.sender == position.user, "!user");
		require(position.margin > 0, "!position");
		require(position.price > 0, "!opening");
		require(position.closeOrderId == 0, "!closing");

		if (size > position.size) {
			size = position.size;
		}

		address currency = position.currency;

		Product memory product = products[position.productId];

		uint256 fee = size * product.fee / 10**6;

		if (currency == weth) {
			require(msg.value >= fee && msg.value <= fee * 10100 / 10**4, "!fee");
			IWETH(currency).deposit{value: msg.value}();
		} else {
			_transferIn(currency, fee);
		}

		nextCloseOrderId++;
		closeOrders[nextCloseOrderId] = CloseOrder({
			positionId: positionId,
			productId: position.productId,
			size: size,
			fee: fee,
			isLong: position.isLong,
			timestamp: block.timestamp
		});

		position.closeOrderId = uint32(nextCloseOrderId);

	}

	// Closes position at the fetched price (oracle)
	function settleCloseOrder(
		uint256 orderId, 
		uint256 price // 8 decimals
	) external onlyOracle {

		// Check order and params
		CloseOrder memory _closeOrder = closeOrders[orderId];
		uint256 size = _closeOrder.size;
		require(size > 0, "!size");

		Position storage position = positions[_closeOrder.positionId];
		require(position.margin > 0, "!position");
		require(position.closeOrderId == orderId, "!order");
		require(position.price > 0, "!opening");

		if (size > position.size) {
			size = position.size;
		}

		uint256 leverage = UNIT * position.size / position.margin;
		uint256 margin = UNIT * size / leverage;

		if (margin > position.margin) {
			margin = position.margin;
		}

		Product storage product = products[position.productId];

		price = _validatePrice(price);

		int256 pnl = _getPnL(position, price, margin, product.interest);

		// Check if it's a liquidation
		if (pnl <= -1 * int256(position.margin * product.liquidationThreshold / 10**4)) {
			pnl = -1 * int256(uint256(position.margin));
			margin = position.margin;
			size = position.size;
			position.margin = 0;
			position.size = 0;
		} else {
			position.margin -= uint88(margin);
			position.size -= uint88(size);
		}

		address currency = position.currency;

		_updateOpenInterest(currency, size, true);

		pendingFees[currency] += _closeOrder.fee;

		emit ClosePosition(
			_closeOrder.positionId, 
			position.user, 
			position.productId,
			price, 
			margin,
			size, 
			_closeOrder.fee,
			pnl, 
			false
		);

		address positionUser = position.user;
		
		if (position.margin == 0) {
			//userPositionIds[positionUser].remove(_closeOrder.positionId);
			delete positions[_closeOrder.positionId];
		} else {
			position.closeOrderId = 0;
		}

		delete closeOrders[orderId];

		address pool = IRouter(router).getPool(currency);

		if (pnl < 0) {
			{
				uint256 positivePnl = uint256(-1 * pnl);
				_transferOut(currency, pool, positivePnl, false);
				if (positivePnl < margin) {
					_transferOut(currency, positionUser, margin - positivePnl, true);
				}
			}
		} else {
			IPool(pool).creditUserProfit(positionUser, uint256(pnl));
			_transferOut(currency, positionUser, margin, true);
		}

	}

	// User or oracle can cancel pending order e.g. in case of error or non-execution
	function cancelOrder(uint256 orderId) external {

		// Checks should fail silently
		CloseOrder memory _closeOrder = closeOrders[orderId];
		if (_closeOrder.positionId == 0) return;
		
		Position storage position = positions[_closeOrder.positionId];
		if (msg.sender != oracle && msg.sender != position.user) return;
		if (position.closeOrderId != orderId) return;
		
		position.closeOrderId = 0;

		uint256 fee = _closeOrder.fee;

		delete closeOrders[orderId];

		// Refund fee
		_transferOut(position.currency, position.user, fee, true);

	}

	function releaseMargin(
		uint256 positionId, 
		bool includeFee
	) external onlyOwner {

		Position storage position = positions[positionId];
		require(position.margin > 0, "!position");

		uint256 margin = position.margin;
		address positionUser = position.user;
		address currency = position.currency;

		emit ClosePosition(
			positionId, 
			positionUser, 
			position.productId, 
			position.price, 
			margin, 
			position.size,
			0,
			0, 
			false
		);

		if (position.closeOrderId > 0) {
			delete closeOrders[position.closeOrderId];
		}

		if (includeFee) {
			margin += position.fee;
		}

		_updateOpenInterest(currency, position.size, true);

		delete positions[positionId];

		_transferOut(currency, positionUser, margin, true);

	}

	// Add margin to Position with id = positionId
	function addMargin(
		uint256 positionId,
		uint256 margin
	) external payable {

		// Check position
		Position storage position = positions[positionId];
		require(msg.sender == position.user, "!user");
		require(position.price > 0, "!opening");
		require(position.closeOrderId == 0, "!closing");

		address currency = position.currency;

		if (currency == weth) {
			margin = msg.value;
			IWETH(currency).deposit{value: margin}();
		} else {
			_transferIn(currency, margin);
		}

		require(margin > 0 && margin >= minMargin[currency], "!min-margin");

		// New position params
		uint256 newMargin = position.margin + margin;
		uint256 newLeverage = UNIT * position.size / newMargin;
		require(newLeverage >= UNIT, "!low-leverage");

		position.margin = uint88(newMargin);

		emit AddMargin(
			positionId, 
			position.user, 
			currency,
			margin, 
			newMargin, 
			newLeverage
		);

	}

	// Liquidate positionIds (oracle)
	function liquidatePositions(
		address currency,
		uint256[] calldata positionIds,
		uint256[] calldata prices
	) external onlyOracle {

		uint256 sendToPool;
		uint256 openInterest;
		uint256 fees;

		for (uint256 i = 0; i < positionIds.length; i++) {

			uint256 positionId = positionIds[i];
			Position memory position = positions[positionId];
			
			if (position.margin == 0 || position.price == 0 || position.currency != currency) {
				continue;
			}

			Product storage product = products[position.productId];

			uint256 price = _validatePrice(prices[i]);

			uint256 margin = position.margin;

			int256 pnl = _getPnL(position, price, margin, product.interest);

			uint256 threshold = margin * product.liquidationThreshold / 10**4;

			if (pnl <= -1 * int256(threshold)) {

				sendToPool += threshold;
				uint256 fee = margin - threshold;
				fees += fee;
				openInterest += position.size;

				emit ClosePosition(
					positionId, 
					position.user, 
					position.productId, 
					price, 
					margin,
					position.size,
					fee,
					-1 * int256(margin), 
					true
				);

				userPositionIds[position.user].remove(positionId);
				delete positions[positionId];

			}

		}

		address pool = IRouter(router).getPool(currency);
		_transferOut(currency, pool, sendToPool, false);
		_updateOpenInterest(currency, openInterest, true);
		pendingFees[currency] += fees;

	}

	// To receive ETH from WETH
	fallback() external payable {}
	receive() external payable {}

	function _updateOpenInterest(address currency, uint256 amount, bool isDecrease) internal {
		address pool = IRouter(router).getPool(currency);
		IPool(pool).updateOpenInterest(amount, isDecrease);
	}

	function _transferIn(address currency, uint256 amount) internal {
		if (amount == 0 || currency == address(0)) return;
		// adjust decimals
		uint256 decimals = IRouter(router).getDecimals(currency);
		amount = amount * (10**decimals) / (10**UNIT_DECIMALS);
		IERC20(currency).safeTransferFrom(msg.sender, address(this), amount);
	}

	function _transferOut(address currency, address to, uint256 amount, bool sendETH) internal {
		if (amount == 0 || currency == address(0) || to == address(0)) return;
		// adjust decimals
		uint256 decimals = IRouter(router).getDecimals(currency);
		amount = amount * (10**decimals) / (10**UNIT_DECIMALS);
		if (currency == weth && sendETH) {
			IWETH(weth).withdraw(amount);
			payable(to).sendValue(amount);
		} else {
			IERC20(currency).safeTransfer(to, amount);
		}
	}

	function _validatePrice(
		uint256 price // 8 decimals
	) internal pure returns(uint256) {
		require(price > 0, "!price");
		return price * 10**(UNIT_DECIMALS - PRICE_DECIMALS);
	}
	
	function _getPnL(
		Position memory position,
		uint256 price,
		uint256 margin,
		uint256 interest
	) internal view returns(int256 _pnl) {

		bool pnlIsNegative;
		uint256 pnl;

		uint256 leverage = UNIT * position.size / position.margin;
		uint256 size = margin * leverage;

		if (position.isLong) {
			if (price >= position.price) {
				pnl = size * (price - position.price) / (position.price * UNIT);
			} else {
				pnl = size * (position.price - price) / (position.price * UNIT);
				pnlIsNegative = true;
			}
		} else {
			if (price > position.price) {
				pnl = size * (price - position.price) / (position.price * UNIT);
				pnlIsNegative = true;
			} else {
				pnl = size * (position.price - price) / (position.price * UNIT);
			}
		}

		// Subtract interest from P/L
		if (block.timestamp >= position.timestamp + 15 minutes) {

			uint256 _interest = size * interest * (block.timestamp - position.timestamp) / (UNIT * 10**4 * 360 days);

			if (pnlIsNegative) {
				pnl += _interest;
			} else if (pnl < _interest) {
				pnl = _interest - pnl;
				pnlIsNegative = true;
			} else {
				pnl -= _interest;
			}

		}

		if (pnlIsNegative) {
			_pnl = -1 * int256(pnl);
		} else {
			_pnl = int256(pnl);
		}

		return _pnl;

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

	function getCloseOrders(uint256[] calldata orderIds) external view returns(CloseOrder[] memory _orders) {
		uint256 length = orderIds.length;
		_orders = new CloseOrder[](length);
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