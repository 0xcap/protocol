//SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "hardhat/console.sol";

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

contract Trading {

	// Structs

	struct Position {
		bytes32 product; // 32 bytes

		address base;

		uint256 amount; //
		uint256 price; //
		uint256 createdAt; //
		uint256 updatedAt;

		uint256 realizedInterest; // interest realized up till updatedAt
		uint256 AMprice; // used for margin add
		uint256 AMamount; // used for margin add
		uint256 AMprevPrice; // used for margin add

		uint256 AMprevAmount; // used for margin add
		bool isLong; // 1
		bool isSettling; // 1

		address owner; // 20 bytes
	}

	struct Product {
		uint256 leverage; //
		uint256 fee; // In % * 100. e.g. 0.5% is 50
		uint256 interest; // for 360 days, in % * 100. E.g. 5.35% is 535
		address feed; // chainlink
		bool isActive;
	}

	// Variables

	address public owner;

	uint256 public currentPositionId;

	uint256 public liquidatorBounty;

	mapping(address => mapping(address => uint256)) public balances; // user balance. user => base => amount
	mapping(address => mapping(address => uint256)) public locked; // user locked margin. user => base => amount

	// Bases lookup
	mapping(address => bool) private bases; // USDC address => True

	// Products lookup
	mapping(bytes32 => Product) private products; // BTC-USD => Product
	
	// Positions lookup
	mapping(uint256 => Position) private positions; // Position id => Position

	// Used in UPL, liquidate, to display user positions on client
	mapping(address => mapping(address => UintSet.Set)) private userPositionIds; // user => base => [Position ids]

	// Used to find existing position for a given user, base, and product
	mapping(address => mapping(address => mapping(bytes32 => uint256))) private positionIdsMap; // user => base => product => position id
	
	// Tracks currently settling positions
	UintSet.Set private settlingIds;

	mapping(address => uint256) private poolBalance; // base => pool balance

	// Events
	event ProductAdded(bytes32 product, uint256 leverage, uint256 fee, uint256 interest, address feed);
	event ProductUpdated(bytes32 product, uint256 leverage, uint256 fee, uint256 interest, address feed, bool isActive);
	event ProductRemoved(bytes32 product);
	event BaseAdded(address base);
	event BaseRemoved(address base);
	event LiquidatorBountyUpdated(uint256 newShare);
	event OwnerUpdated(address newOwner);

	event PoolDeposit(address indexed from, address indexed base, uint256 amount);
	event PoolWithdrawal(address indexed to, address indexed base, uint256 amount);

	event Deposit(address indexed from, address indexed base, uint256 amount);
	event Withdrawal(address indexed to, address indexed base, uint256 amount);

	event NewPosition(uint256 id, address indexed user, address indexed base, bytes32 indexed product, bool isLong, uint256 priceWithFee, uint256 amount);
	event AddMargin(uint256 id, address indexed user, uint256 priceWithFee, uint256 amount);
	event ClosePosition(uint256 id, address indexed user, uint256 priceWithFee, uint256 amount, int256 pnl);

	event NewPositionSettled(uint256 id, address indexed user, uint256 price);
	event AddMarginSettled(uint256 id, address indexed user, uint256 price, uint256 amount);

	event UserLiquidated(address indexed user, address indexed by);

	// Constructor

	constructor() {
		console.log("Initialized Cap Trading.");
		owner = msg.sender;
		liquidatorBounty = 5;
	}

	// Methods

	// TODO: get product, get position, and other getters for private vars
	// TODO: bases should be added dynamically. retrieve list of bases in client so you don't have to keep track. Just have one contract (this one)
	// productList => products. bases & products
	// todo: release margin if profitable

	function addProduct(bytes32 product, uint256 leverage, uint256 fee, uint256 interest, address feed) external onlyOwner {
		products[product] = Product({
			leverage: leverage,
			fee: fee,
			interest: interest,
			feed: feed,
			isActive: true
		});
		emit ProductAdded(product, leverage, fee, interest, feed);
	}

	function updateProduct(bytes32 product, uint256 leverage, uint256 fee, uint256 interest, address feed, bool isActive) external onlyOwner {
		Product storage _product = products[product];
		if (leverage > 0) _product.leverage = leverage;
		if (fee > 0) _product.fee = fee;
		if (interest > 0) _product.interest = interest;
		if (feed != address(0)) _product.feed = feed;
		if (isActive == true || isActive == false) _product.isActive = isActive;
		emit ProductUpdated(product, _product.leverage, _product.fee, _product.interest, _product.feed, _product.isActive);
	}

	function removeProduct(bytes32 product) external onlyOwner {
		delete products[product];
		emit ProductRemoved(product);
	}

	function addBase(address base) external onlyOwner {
		bases[base] = true;
		emit BaseAdded(base);
	}

	function removeBase(address base) external onlyOwner {
		delete bases[base];
		emit BaseRemoved(base);
	}

	function setLiquidatorBounty(uint256 newBounty) external onlyOwner {
		liquidatorBounty = newBounty;
		emit LiquidatorBountyUpdated(newBounty);
	}

	function setOwner(address newOwner) external onlyOwner {
		owner = newOwner;
		emit OwnerUpdated(newOwner);
	}

	function getUserPositions(address user, address base) external view returns (Position[] memory _positions) {
		uint256 length = userPositionIds[user][base].length();
		_positions = new Position[](length);
		for (uint256 i=0; i < length; i++) {
			uint256 id = userPositionIds[user][base].at(i);
			_positions[i] = positions[id];
		}
		return _positions;
	}

	// Pool

	function poolDeposit(address base, uint256 amount) external onlyOwner {
		poolBalance[base] += amount;
		IERC20(base).safeTransferFrom(msg.sender, address(this), amount);
		emit PoolDeposit(msg.sender, base, amount);
	}

	function poolWithdraw(address base, uint256 amount) external onlyOwner {
		poolBalance[base] -= amount;
		IERC20(base).safeTransfer(msg.sender, amount);
		emit PoolWithdrawal(msg.sender, base, amount);
	}

	// User

	function deposit(address base, uint256 amount) external {
		IERC20(base).safeTransferFrom(msg.sender, address(this), amount);
		balances[msg.sender][base] += amount;
		emit Deposit(msg.sender, base, amount);
	}

	function withdraw(address base, uint256 amount) external {
		address user = msg.sender;
		int256 upl = getUPL(user, base);
		require(int256(locked[user][base]) <= int256(balances[user][base]) + upl - int256(amount), "!EQ");
		balances[user][base] -= amount;
		IERC20(base).safeTransfer(user, amount);
		emit Withdrawal(user, base, amount);
	}

	function submitOrder(address base, bytes32 _product, bool isLong, uint256 amount) external {

		Product memory product = products[_product];
		require(product.isActive, "!PA"); // Product paused or doesn't exist

		uint256 margin = amount / product.leverage;
		uint256 price = getLatestPrice(product.feed);

		console.log('PRICE', price);

		require(price > 0, "!P");

		uint256 existingPositionId = positionIdsMap[msg.sender][base][_product];
		
		console.log('existingPositionId', existingPositionId);

		// Add fee
		uint256 priceWithFee;
		if (isLong) {
			priceWithFee = price + price * product.fee / 10000;
		} else {
			priceWithFee = price - price * product.fee / 10000;
		}

		if (existingPositionId > 0) {

			Position memory position = positions[existingPositionId];

			if (position.isLong == isLong) {

				_addToExistingPosition(existingPositionId, base, amount, margin, priceWithFee, product.interest);

			} else {

				_closePosition(existingPositionId, base, _product, amount, margin, priceWithFee, product.interest);

			}

		} else {

			_createNewPosition(base, _product, isLong, amount, margin, priceWithFee);
			
		}

	}

	function _createNewPosition(address base, bytes32 product, bool isLong, uint256 amount, uint256 margin, uint256 priceWithFee) internal {

		require(bases[base], "!BASE");

		address user = msg.sender;

		// New position
		require(balances[user][base] > 0, "!B");

		// Check if enough funds
		int256 upl = getUPL(user, base);
		require(int256(locked[user][base]) <= int256(balances[user][base]) + upl - int256(margin), "!EQ");

		// Lock margin
		locked[user][base] += margin;

		console.log('priceWithFee', priceWithFee);
		// Create
		currentPositionId += 1;
		positions[currentPositionId] = Position({
			owner: user,
			base: base,
			product: product,
			amount: amount,
			price: priceWithFee,
			createdAt: block.timestamp,
			updatedAt: 0,
			realizedInterest: 0,
			isLong: isLong,
			isSettling: true,
			AMprice: 0,
			AMamount: 0,
			AMprevPrice: 0,
			AMprevAmount: 0
		});
		userPositionIds[user][base].add(currentPositionId);
		positionIdsMap[user][base][product] = currentPositionId;

		settlingIds.add(currentPositionId);

		emit NewPosition(currentPositionId, user, base, product, isLong, priceWithFee, amount);

	}

	function _addToExistingPosition(uint256 existingPositionId, address base, uint256 amount, uint256 margin, uint256 priceWithFee, uint256 interest) internal {

		// Add to existing position

		Position storage position = positions[existingPositionId];

		require(!position.isSettling, "!S");

		address user = msg.sender;

		require(balances[user][base] > 0, "!B");

		// Check if enough funds
		int256 upl = getUPL(user, base);
		require(int256(locked[user][base]) <= int256(balances[user][base]) + upl - int256(margin), "!EQ");

		// Lock margin
		locked[user][base] += margin;

		// New position params
		uint256 newAmount = position.amount + amount;

		uint256 newPrice = (position.price * position.amount + priceWithFee * amount) / (position.amount + amount);

		// used in settlement to check add margin price is good, to update position price otherwise based on newPrice formula above
		position.AMprice = priceWithFee;
		position.AMamount = amount;
		position.AMprevPrice = position.price;
		position.AMprevAmount = position.amount;
		
		position.price = newPrice;
		position.amount = newAmount;

		// interest
		uint256 timestamp;
		if (position.updatedAt > 0) {
			timestamp = position.updatedAt;
		} else {
			timestamp = position.createdAt;
		}
		position.realizedInterest += getPositionActiveInterest(position.amount, timestamp, interest);
		position.updatedAt = block.timestamp;

		position.isSettling = true;
		settlingIds.add(existingPositionId);

		emit AddMargin(existingPositionId, user, priceWithFee, amount);

	}

	function _closePosition(uint256 existingPositionId, address base, bytes32 product, uint256 amount, uint256 margin, uint256 priceWithFee, uint256 interest) internal {

		// Close (full or partial)

		Position storage position = positions[existingPositionId];

		require(!position.isSettling, "!S");

		require(amount <= position.amount, "!PA");

		address user = msg.sender;

		console.log('position price', position.price);
		console.log('priceWithFee', priceWithFee);
		console.log('amount', amount);

		// P/L
		int256 pnl;
		if (position.isLong) {
			pnl = int256(amount) * (int256(priceWithFee) - int256(position.price)) / int256(position.price);
		} else {
			pnl = int256(amount) * (int256(position.price) - int256(priceWithFee)) / int256(position.price);
		}

		if (pnl < 0) {
			console.log('pnl-', uint256(-pnl));
		} else {
			console.log('pnl', uint256(pnl));
		}
		

		// interest
		// realize interest pro rata based on amount being closed
		uint256 timestamp;
		if (position.updatedAt > 0) {
			timestamp = position.updatedAt;
		} else {
			timestamp = position.createdAt;
		}
		uint256 interestToRealize = position.realizedInterest + (amount / position.amount) * getPositionActiveInterest(position.amount, timestamp, interest);
		
		console.log('interestToRealize', interestToRealize);

		// subtract interest from P/L
		pnl -= int256(interestToRealize);

		if (amount < position.amount) {
			// if partial close
			position.amount -= amount;
			position.realizedInterest = interestToRealize;
			position.updatedAt = block.timestamp;
		} else {
			// if full close
			console.log('full close');
			delete positions[existingPositionId];
			delete positionIdsMap[user][base][product];
			userPositionIds[user][base].remove(existingPositionId);
		}

		console.log('locked[user]', locked[user][base], margin);
		console.log('balances[user]', balances[user][base]);

		// update account
		locked[user][base] -= margin;
		if (pnl < 0) {
			balances[user][base] -= uint256(-pnl);
			poolBalance[base] += uint256(-pnl);
		} else {
			balances[user][base] += uint256(pnl);
			poolBalance[base] -= uint256(pnl);
		}

		emit ClosePosition(existingPositionId, user, priceWithFee, amount, pnl);

	}

	// Check for settlement
	function checkUpkeep() external view returns (bool, bytes memory) {

		uint256 length = settlingIds.length();
		if (length > 0) {

			uint256[] memory settleTheseIds = new uint[](length);

			for (uint256 i=0; i < length; i++) {
				uint256 id = settlingIds.at(i);
				Position memory position = positions[id];
				Product memory product = products[position.product];

				uint256 price = getLatestPrice(product.feed);

				console.log('block.timestamp', block.timestamp);
				console.log('position.createdAt', position.createdAt);

				// Add fee
				uint256 priceWithFee;
				if (position.isLong) {
					priceWithFee = price + price * product.fee / 10000;
				} else {
					priceWithFee = price - price * product.fee / 10000;
				}

				if (position.AMprice > 0 && (block.timestamp - position.updatedAt > 10 * 60 || priceWithFee != position.AMprice) || (block.timestamp - position.createdAt > 10 * 60 || priceWithFee != position.price)) {
					settleTheseIds[i] = id;
				}

				// Local test
				settleTheseIds[i] = id;

			}

			// second argument is settle method calldata if in line with chainlink keepers
			if (settleTheseIds[0] == 0) return (false, bytes(''));

			return (true, abi.encode(settleTheseIds));

		}

		return (false, bytes(''));

	}

	// Settle
	function performUpkeep(bytes calldata performData) external {
		// settle positionIds with current prices if required
		uint256[] memory positionIds = abi.decode(performData, (uint256[]));
		uint256 length = positionIds.length;

		console.log('length', length);
		
		for (uint256 i = 0; i < length; i++) {
		
			uint256 positionId = positionIds[i];

			console.log('positionId', positionId);

			Position storage position = positions[positionId];
			Product memory product = products[position.product];

			uint256 price = getLatestPrice(product.feed);

			// Add fee
			uint256 priceWithFee;
			if (position.isLong) {
				priceWithFee = price + price * product.fee / 10000;
			} else {
				priceWithFee = price - price * product.fee / 10000;
			}

			if (position.AMprice > 0) {
				// settling add margin
				if (block.timestamp - position.updatedAt > 10 * 60) {
					if (priceWithFee != position.AMprice) {
						uint256 newPrice = (position.AMprevPrice * position.AMprevAmount + priceWithFee * position.AMamount) / (position.amount);
						position.price = newPrice;
					}
					position.AMprice = 0;
					position.AMprevPrice = 0;
					position.AMamount = 0;
					position.AMprevAmount = 0;
					position.isSettling = false;
					settlingIds.remove(positionId);
				}

				// local test
				uint256 newPrice = (position.AMprevPrice * position.AMprevAmount + priceWithFee * position.AMamount) / (position.amount);
				position.price = newPrice;
				position.AMprice = 0;
				position.AMprevPrice = 0;
				position.AMprevAmount = 0;
				position.isSettling = false;
				settlingIds.remove(positionId);

				emit AddMarginSettled(positionId, position.owner, newPrice, position.AMamount);

				position.AMamount = 0;

			} else {
				// settling new position
				if (block.timestamp - position.createdAt > 10 * 60) {
					if (priceWithFee != position.price) {
						position.price = priceWithFee;
					}
					position.isSettling = false;
					settlingIds.remove(positionId);
				}

				// local test
				position.price = priceWithFee;
				position.isSettling = false;
				settlingIds.remove(positionId);

				emit NewPositionSettled(positionId, position.owner, priceWithFee);

			}

		}

	}

	function liquidateUser(address user, address base) external {
		require(locked[user][base] > 0, "!L");
		int256 upl = getUPL(user, base);
		int256 equity = int256(balances[user][base]) + upl;
		int256 marginLevel = 100 * equity / int256(locked[user][base]);
		if (marginLevel < 20) {
			// liquidate account

			uint256 length = userPositionIds[user][base].length();
			for (uint256 i=0; i < length; i++) {

				uint256 id = userPositionIds[user][base].at(i);
				Position memory position = positions[id];

				delete positions[id];
				delete positionIdsMap[user][base][position.product];
				userPositionIds[user][base].remove(id);

			}

			uint256 liqRewards = (liquidatorBounty / 100) * locked[user][base];
			uint256 poolRewards = (100 - liquidatorBounty) * locked[user][base] / 100;

			// Reset account
			balances[user][base] = 0;
			locked[user][base] = 0;

			// Credit liquidator reward
			balances[msg.sender][base] += liqRewards;

			// Credit pool
			poolBalance[base] += poolRewards;

			emit UserLiquidated(user, msg.sender);
			
		}
	}

	function getUPL(address user, address base) public view returns(int256) {
		uint256 length = userPositionIds[user][base].length();
		int256 upl;
		for (uint256 i=0; i < length; i++) {
			uint256 id = userPositionIds[user][base].at(i);
			Position memory position = positions[id];
			Product memory product = products[position.product];
			uint256 price = getLatestPrice(product.feed);
			require(price > 0, "!P");

			uint256 timestamp;
			if (position.updatedAt > 0) {
				timestamp = position.updatedAt;
			} else {
				timestamp = position.createdAt;
			}

			uint256 interest = position.realizedInterest + getPositionActiveInterest(position.amount, timestamp, product.interest);

			if (position.isLong) {
				upl += int256(interest) + int256(position.amount) * (int256(price) - int256(position.price)) / int256(position.price);
			} else {
				upl += int256(interest) + int256(position.amount) * (int256(position.price) - int256(price)) / int256(position.price);
			}
		}
		return upl;
	}

	function getPositionActiveInterest(uint256 amount, uint256 timestamp, uint256 interest) public view returns (uint256) {
		if (block.timestamp < timestamp - 1800) return 0;
		return amount * (interest / 10000) * (block.timestamp - timestamp) / 360 days;
	}

	function getLatestPrice(address feed) public view returns (uint256) {
		/*
		uint8 decimals = AggregatorV3Interface(feed).decimals();
		// standardize price to 8 decimals
		(
			, 
			int price,
			,
			,
		) = AggregatorV3Interface(feed).latestRoundData();
		if (decimals != 8) {
			price = price * (10**8) / (10**decimals);
		}
		*/
		// local test
		int256 price = 33500 * 10**8;
		return uint256(price);
	}

	// Modifiers

	modifier onlyOwner() {
		require(msg.sender == owner, '!O');
		_;
	}



}