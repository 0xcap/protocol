// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "./libraries/SafeERC20.sol";
import "./libraries/Address.sol";

import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import "./interfaces/IRouter.sol";
import "./interfaces/ITreasury.sol";
import "./interfaces/IPool.sol";

contract Trading {

	// Gas optimization:
	/*
	- get off WETH (use ETH directly)
	- 10 decimals for amounts instead of 18
	- review bytes in structs
	- get off enumerable set in positions, use events/graph to fetch latest user positions on client
	- positions can be stored with a position key combining user/currency/etc instead of next id. oracle can pull based on event emitted which contains position key
	- this can allow for 1 position for each currency and product and direction
	- next close order id not needed either if using mapping closing[positionKey] = CloseOrder
	*/

	using SafeERC20 for IERC20;
    using Address for address payable;
    using EnumerableSet for EnumerableSet.UintSet;

	// Structs

	struct Product {
		uint64 maxLeverage; // set to 0 to deactivate product
		uint64 liquidationThreshold; // in bps. 8000 = 80%
		uint64 fee; // In sbps (10^6). 0.5% = 5000. 0.025% = 250
		uint64 interest; // For 360 days, in bps. 5.35% = 535
	}

	struct Position {
		uint64 size;
		uint64 margin;
		uint64 timestamp;
		uint64 price;
	}

	struct Order {
		bool isClose;
		uint64 size;
		uint64 margin;
	}

	// Contracts
	address public owner;
	address public router;
	address public treasury;
	address public oracle;

	uint256 public nextPositionId; // Incremental
	uint256 public nextCloseOrderId; // Incremental

	mapping(bytes32 => Product) private products;
	mapping(bytes32 => Position) private positions; // key = currency,user,product,direction
	mapping(bytes32 => Order) private orders; // position key => Order

	mapping(address => EnumerableSet.UintSet) private userPositionIds;

	mapping(address => uint256) minMargin; // currency => amount

	mapping(address => uint256) pendingFees; // currency => amount

	uint256 public constant UNIT_DECIMALS = 10;
	uint256 public constant UNIT = 10**UNIT_DECIMALS;

	uint256 public constant PRICE_DECIMALS = 8;

	// Events
	event NewOrder(
		bytes32 key,
		address user,
		bytes32 productId,
		address currency,
		bool isLong,
		uint256 margin,
		uint256 size,
		bool isClose
	);

	event PositionUpdated(
		bytes32 key,
		address user,
		bytes32 productId,
		address currency,
		bool isLong,
		uint256 margin,
		uint256 size,
		uint256 price
	);

	event ClosePosition(
		bytes32 key,
		address user,
		bytes32 productId,
		address currency,
		bool isLong,
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
	}

	function setMinMargin(
		address currency,
		uint256 _minMargin
	) external onlyOwner {
		minMargin[currency] = _minMargin;
	}

	function addProduct(bytes32 productId, Product memory _product) external onlyOwner {
		
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

	function updateProduct(bytes32 productId, Product memory _product) external onlyOwner {

		Product storage product = products[productId];

		require(product.liquidationThreshold > 0, "!product-does-not-exist");

		product.maxLeverage = _product.maxLeverage;
		product.fee = _product.fee;
		product.interest = _product.interest;
		product.liquidationThreshold = _product.liquidationThreshold;

	}

	// Methods

	function getPositionKey(address user, address currency, bytes32 productId, bool isLong) public pure returns (bytes32) {
        return keccak256(abi.encodePacked(
            user,
            currency,
            productId,
            isLong
        ));
    }

	function distributeFees(address currency) external {
		uint256 pendingFee = pendingFees[currency];
		if (pendingFee > 0) {
			pendingFees[currency] = 0;
			_transferOut(currency, treasury, pendingFee);
			ITreasury(treasury).notifyFeeReceived(currency, pendingFee);
		}
	}

	function submitOrder(
		address currency,
		bytes32 productId,
		bool isLong,
		uint256 margin,
		uint256 size
	) external payable {

		if (currency == address(0)) { // User is sending ETH
			margin = msg.value;
		} else {
			require(IRouter(router).isSupportedCurrency(currency), "!currency");
		}

		// Check params
		require(margin > 0, "!margin");
		require(size > 0, "!size");

		Product memory product = products[productId];
		uint256 fee = size * product.fee / 10**6;

		if (currency == address(0)) {
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

		// Update and check pool utlization
		_updateOpenInterest(currency, size, false);
		address pool = IRouter(router).getPool(currency);
		uint256 utilization = IPool(pool).getUtilization();
		require(utilization < 10**4, "!utilization");

		bytes32 key = getPositionKey(msg.sender, currency, productId, isLong);

		Order memory order = orders[key];
		require(order.size == 0, "!order"); // existing order

		orders[key] = Order({
			isClose: false,
			size: uint64(size),
			margin: uint64(margin)
		});

		emit NewOrder(
			key,
			msg.sender,
			productId,
			currency,
			isLong,
			margin,
			size,
			false
		);

	}

	function submitCloseOrder(
		address currency,
		bytes32 productId,
		bool isLong,
		uint256 size
	) external payable {

		require(size > 0, "!size");

		bytes32 key = getPositionKey(msg.sender, currency, productId, isLong);

		Order memory order = orders[key];
		require(order.size == 0, "!order"); // existing order

		// Check position
		Position storage position = positions[key];
		require(position.margin > 0, "!position");

		if (size > position.size) {
			size = position.size;
		}

		Product memory product = products[productId];
		uint256 fee = size * product.fee / 10**6;

		if (currency == address(0)) {
			require(msg.value >= fee && msg.value <= fee * 10100 / 10**4, "!fee");
		} else {
			_transferIn(currency, fee);
		}

		orders[key] = Order({
			isClose: true,
			size: uint64(size),
			margin: 0 // not needed for close order?
		});

		emit NewOrder(
			key,
			msg.sender,
			productId,
			currency,
			isLong,
			0,
			size,
			true // isClose
		);

	}

	// User can cancel pending position e.g. in case of error or non-execution
	function cancelOrder(
		bytes32 productId,
		address currency,
		bool isLong
	) external {

		bytes32 key = getPositionKey(msg.sender, currency, productId, isLong);

		// Sanity check order. Checks should fail silently
		Order memory order = orders[key];

		// fee
		Product memory product = products[productId];
		uint256 fee = order.size * product.fee / 10**6;

		_updateOpenInterest(currency, order.size, true);

		delete orders[key];

		// Refund margin + fee
		uint256 marginPlusFee = order.margin + fee;
		_transferOut(currency, msg.sender, marginPlusFee);

	}

	// Set price for newly submitted position (oracle)
	function settleOrder(
		address user,
		bytes32 productId,
		address currency,
		bool isLong,
		uint256 price
	) external onlyOracle {

		bytes32 key = getPositionKey(user, currency, productId, isLong);

		Order storage order = orders[key];
		require(order.size > 0, "!order");

		// fee
		Product memory product = products[productId];
		uint256 fee = order.size * product.fee / 10**6;
		pendingFees[currency] += fee;

		if (order.isClose) {
			
			{
				(uint256 margin, uint256 size, int256 pnl) = _settleCloseOrder(user, productId, currency, isLong, price);

				address pool = IRouter(router).getPool(currency);

				if (pnl < 0) {
					{
						uint256 positivePnl = uint256(-1 * pnl);
						_transferOut(currency, pool, positivePnl);
						if (positivePnl < margin) {
							_transferOut(currency, user, margin - positivePnl);
						}
					}
				} else {
					IPool(pool).creditUserProfit(user, uint256(pnl));
					_transferOut(currency, user, margin);
				}

				emit ClosePosition(
					key, 
					user,
					productId,
					currency,
					isLong,
					price,
					margin,
					size,
					fee,
					pnl,
					false
				);

			}

		} else {

			// Validate price, returns 18 decimals
			price = _validatePrice(price);

			Position storage position = positions[key];

			uint256 averagePrice = (position.size * position.price + order.size * price) / (position.size + order.size);

			if (position.timestamp == 0) {
				position.timestamp = uint64(block.timestamp);
			}

			position.size += order.size;
			position.margin += order.margin;
			position.price = uint64(averagePrice);

			delete orders[key];

			emit PositionUpdated(
				key,
				user,
				productId,
				currency,
				isLong,
				position.margin,
				position.size,
				position.price
			);

		}

	}

	// Closes position at the fetched price (oracle)
	function _settleCloseOrder(
		address user,
		bytes32 productId,
		address currency,
		bool isLong,
		uint256 price
	) internal returns(uint256, uint256, int256) {

		bytes32 key = getPositionKey(user, currency, productId, isLong);

		// Check order and params
		Order memory order = orders[key];
		uint256 size = order.size;
		require(size > 0, "!size");

		Position storage position = positions[key];
		require(position.margin > 0, "!position");

		if (size > position.size) {
			size = position.size;
		}

		uint256 leverage = UNIT * position.size / position.margin;
		uint256 margin = UNIT * size / leverage;

		if (margin > position.margin) {
			margin = position.margin;
		}

		Product memory product = products[productId];

		price = _validatePrice(price);

		int256 pnl = _getPnL(position, !isLong, price, margin, product.interest);

		// Check if it's a liquidation
		if (pnl <= -1 * int256(uint256(position.margin) * uint256(product.liquidationThreshold) / 10**4)) {
			pnl = -1 * int256(uint256(position.margin));
			margin = position.margin;
			size = position.size;
			position.margin = 0;
			position.size = 0;
		} else {
			position.margin -= uint64(margin);
			position.size -= uint64(size);
		}

		_updateOpenInterest(currency, size, true);
		
		if (position.margin == 0) {
			delete positions[key];
		}

		delete orders[key];

		return (margin, size, pnl);

	}

	// Liquidate positionIds (oracle)
	function liquidatePosition(
		address user,
		address currency,
		bytes32 productId,
		bool isLong,
		uint256 price
	) external onlyOracle {

		bytes32 key = getPositionKey(user, currency, productId, isLong);

		Position memory position = positions[key];
		
		uint256 margin = position.margin;

		if (margin == 0) {
			return;
		}

		Product storage product = products[productId];

		price = _validatePrice(price);

		int256 pnl = _getPnL(position, !isLong, price, margin, product.interest);

		uint256 threshold = margin * product.liquidationThreshold / 10**4;

		if (pnl <= -1 * int256(threshold)) {

			uint256 fee = margin - threshold;
			address pool = IRouter(router).getPool(currency);

			_transferOut(currency, pool, threshold);
			_updateOpenInterest(currency, position.size, true);
			pendingFees[currency] += fee;

			emit ClosePosition(
				key, 
				user,
				productId,
				currency,
				isLong,
				price,
				margin,
				position.size,
				fee,
				-1 * int256(margin),
				true
			);

			delete positions[key];

		}

	}

	function releaseMargin(
		address user,
		address currency,
		bytes32 productId,
		bool isLong, 
		bool includeFee
	) external onlyOwner {

		bytes32 key = getPositionKey(user, currency, productId, isLong);

		Position storage position = positions[key];
		require(position.margin > 0, "!position");

		uint256 margin = position.margin;

		emit ClosePosition(
			key, 
			user,
			productId,
			currency,
			isLong,
			position.price,
			margin,
			position.size,
			0,
			0,
			false
		);

		delete orders[key];

		if (includeFee) {
			Product memory product = products[productId];
			uint256 fee = position.size * product.fee / 10**6;
			margin += fee;
		}

		_updateOpenInterest(currency, position.size, true);

		delete positions[key];

		_transferOut(currency, user, margin);

	}

	// To receive ETH
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

	function _transferOut(address currency, address to, uint256 amount) internal {
		if (amount == 0 || to == address(0)) return;
		// adjust decimals
		uint256 decimals = IRouter(router).getDecimals(currency);
		amount = amount * (10**decimals) / (10**UNIT_DECIMALS);
		if (currency == address(0)) {
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
		bool isLong,
		uint256 price,
		uint256 margin,
		uint256 interest
	) internal view returns(int256 _pnl) {

		bool pnlIsNegative;
		uint256 pnl;

		uint256 leverage = UNIT * position.size / position.margin;
		uint256 size = margin * leverage;

		if (isLong) {
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

	function getProduct(bytes32 productId) external view returns(Product memory) {
		return products[productId];
	}

	function getPosition(
		address user,
		address currency,
		bytes32 productId,
		bool isLong
	) external view returns(Position memory position) {
		bytes32 key = getPositionKey(user, currency, productId, isLong);
		return positions[key];
	}

	function getOrder(
		address user,
		address currency,
		bytes32 productId,
		bool isLong
	) external view returns(Order memory order) {
		bytes32 key = getPositionKey(user, currency, productId, isLong);
		return orders[key];
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