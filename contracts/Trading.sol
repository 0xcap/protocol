//SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "hardhat/console.sol";

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

import './libraries/UIntSet.sol';

contract Trading {

	using SafeERC20 for IERC20;
	using UintSet for UintSet.Set;

	// Structs

	struct Position {
		uint8 baseId; // 1 byte (1 => DAI address)
		uint16 productId; // 2 bytes (1 => Product)
		address owner; // 20 bytes
		uint64 timestamp; // 8 bytes
		bool isLong; // 1 byte
		bool isSettling; // 1 byte
		uint256 margin; // 32 bytes
		uint256 leverage; // 32 bytes
		uint256 price; // 32 bytes
		uint256 liquidationPrice; // 32 bytes
	}

	struct Product {
		uint256 leverage; // max leverage
		uint256 fee; // In % * 100. e.g. 0.5% is 50
		uint256 interest; // for 360 days, in % * 100. E.g. 5.35% is 535
		address feed; // chainlink
		bool isActive;
	}

	// Variables

	address public owner;
	uint256 public currentPositionId;
	uint256 public liquidatorBounty;

	// Bases lookup
	mapping(uint8 => address) private bases; // baseId => DAI address

	// Products lookup
	mapping(uint16 => Product) private products; // productId => Product
	
	// Positions lookup
	mapping(uint256 => Position) private positions; // positionId => Position

	// Used to keep track of a user's positions
	mapping(address => mapping(uint8 => UintSet.Set)) private userPositionIds; // user => baseId => [Position ids]
	
	// Tracks currently settling positions
	UintSet.Set private settlingIds;

	// Vaults
	uint256 public stakingPeriod; // in blocks
	uint256 public unstakingPeriod; // in blocks

	mapping(uint8 => uint256) private caps; // baseId => vault cap

	mapping(uint8 => uint256) private balances; // baseId => vault total balance (varies with profits and losses)

	mapping(uint8 => uint256) private totalStaked; // baseId => vault total staked by users
	mapping(address => mapping(uint8 => uint256)) private userStaked; // address => baseId => staked by user

	// Settlement
	uint256 settlementTime = 3 * 60;


	// Events
	event ProductAdded(uint16 productId, uint256 leverage, uint256 fee, uint256 interest, address feed);
	event ProductUpdated(uint16 productId, uint256 leverage, uint256 fee, uint256 interest, address feed, bool isActive);
	event ProductRemoved(uint16 productId);
	event BaseAdded(uint8 baseId, address base);
	event BaseRemoved(uint8 baseId);
	event VaultCapUpdated(uint8 baseId, uint256 newCap);
	event LiquidatorBountyUpdated(uint256 newShare);
	event StakingPeriodUpdated(uint256 period);
	event UnstakingPeriodUpdated(uint256 period);
	event OwnerUpdated(address newOwner);

	event Staked(address indexed from, uint8 indexed baseId, uint256 amount);
	event Unstaked(address indexed to, uint8 indexed baseId, uint256 amount);

	event NewPosition(uint256 id, address indexed user, uint8 indexed baseId, uint16 indexed productId, bool isLong, uint256 priceWithFee, uint256 margin, uint256 leverage);
	event AddMargin(uint256 id, address indexed user, uint256 margin, uint256 newMargin, uint256 newLeverage, uint256 newLiquidationPrice);
	event ClosePosition(uint256 id, address indexed user, uint256 priceWithFee, uint256 margin, int256 pnl);

	event NewPositionSettled(uint256 id, address indexed user, uint256 price);

	event LiquidatedPosition(uint256 indexed positionId, address indexed by, uint256 reward);

	// Constructor

	constructor() {
		console.log("Initialized Trading contract.");
		owner = msg.sender;
		liquidatorBounty = 5;
	}

	// Methods

	// Vault

	function stake(uint8 baseId, uint256 amount) external {
		// if pool + stake <= cap, stake
		require(bases[baseId] != address(0), "!B");
		require(balances[baseId] + amount <= caps[baseId], "!C");
		balances[baseId] += amount;
		userStaked[msg.sender][baseId] += amount;
		totalStaked[baseId] += amount;
		IERC20(bases[baseId]).safeTransferFrom(msg.sender, address(this), amount);
		emit Staked(msg.sender, baseId, amount);
	}

	function unstake(uint8 baseId, uint256 _stake) external {
		// if block.timestamp % stakingPeriod < unstakingPeriod (8 hours), user can unstake. amount = (userStaked / totalStaked) * vault balance
		require(block.timestamp % stakingPeriod < unstakingPeriod, "!P");
		// stake = share of user in pool, like tokens but not emitted
		require(_stake <= userStaked[msg.sender][baseId], "!S");
		// amount unstaked = (stake / total staked) * balance
		uint256 amountToSend = (_stake / totalStaked[baseId]) * balances[baseId];
		userStaked[msg.sender][baseId] -= _stake;
		totalStaked[baseId] -= _stake;
		balances[baseId] -= amountToSend;
		IERC20(bases[baseId]).safeTransfer(msg.sender, amountToSend);
		emit Unstaked(msg.sender, baseId, amountToSend);
	}

	// User

	function submitOrder(
		uint8 baseId,
		uint16 productId,
		bool isLong,
		uint256 existingPositionId,
		uint256 margin,
		uint256 leverage,
		bool releaseMargin
	) external {

		address base = bases[baseId];
		require(base != address(0), '!B');

		Product memory product = products[productId];
		require(product.isActive, "!PA"); // Product paused or doesn't exist

		require(leverage <= product.leverage, '!L');

		uint256 price = getLatestPrice(product.feed);

		console.log('PRICE', price);

		require(price > 0, "!P");
		
		console.log('existingPositionId', existingPositionId);

		// Add fee
		uint256 priceWithFee = _calculatePriceWithFee(price, product.fee, isLong);

		if (existingPositionId > 0) {

			Position memory position = positions[existingPositionId];

			if (position.isLong == isLong) {
				IERC20(base).safeTransferFrom(msg.sender, address(this), margin);
				_addMargin(existingPositionId, margin);

			} else {
				_closePosition(existingPositionId, margin, priceWithFee, product.interest, releaseMargin);

			}

		} else {
			IERC20(base).safeTransferFrom(msg.sender, address(this), margin);
			_openPosition(baseId, productId, isLong, margin, leverage, priceWithFee);
		}

	}

	function _openPosition(
		uint8 baseId,
		uint16 productId,
		bool isLong,
		uint256 margin,
		uint256 leverage,
		uint256 priceWithFee
	) internal {

		address user = msg.sender;

		console.log('priceWithFee', priceWithFee);

		// TODO: check against risk limits

		uint256 liquidationPrice;
		if (isLong) {
			liquidationPrice = (priceWithFee - priceWithFee * 80 / 100 / leverage);
		} else {
			liquidationPrice = (priceWithFee + priceWithFee * 80 / 100 / leverage);
		}
		
		// Create
		currentPositionId += 1;
		positions[currentPositionId] = Position({
			owner: user,
			baseId: baseId,
			productId: productId,
			margin: margin,
			leverage: leverage,
			price: priceWithFee,
			timestamp: uint64(block.timestamp),
			isLong: isLong,
			isSettling: true,
			liquidationPrice: liquidationPrice
		});
		userPositionIds[user][baseId].add(currentPositionId);
		settlingIds.add(currentPositionId);

		emit NewPosition(
			currentPositionId,
			user,
			baseId,
			productId,
			isLong,
			priceWithFee,
			margin,
			leverage
		);

	}

	function _addMargin(uint256 existingPositionId, uint256 margin) internal {

		Position storage position = positions[existingPositionId];

		require(!position.isSettling, "!S");

		// New position params
		uint256 newMargin = position.margin + margin;
		uint256 newLeverage = position.leverage * (position.margin / newMargin);
		require(newLeverage >= 1, "!L");

		uint256 newLiquidationPrice;
		uint256 price = position.price;
		if (position.isLong) {
			newLiquidationPrice = (price - price * 80 / 100 / newLeverage);
		} else {
			newLiquidationPrice = (price + price * 80 / 100 / newLeverage);
		}

		position.margin = newMargin;
		position.leverage = newLeverage;
		position.liquidationPrice = newLiquidationPrice;

		emit AddMargin(existingPositionId, msg.sender, margin, newMargin, newLeverage, newLiquidationPrice);

	}

	function _closePosition(
		uint256 existingPositionId, 
		uint256 margin, 
		uint256 priceWithFee, 
		uint256 interest,
		bool releaseMargin
	) internal {

		// Close (full or partial)

		Position storage position = positions[existingPositionId];

		require(!position.isSettling, "!S");

		require(margin <= position.margin, "!PM");

		address user = msg.sender;
		uint8 baseId = position.baseId;

		console.log('position price', position.price);
		console.log('priceWithFee', priceWithFee);
		console.log('margin', margin);

		// P/L
		int256 pnl;
		if (position.isLong) {
			pnl = int256(position.margin) * int256(position.leverage) * (int256(priceWithFee) - int256(position.price)) / int256(position.price);
		} else {
			pnl = int256(position.margin) * int256(position.leverage) * (int256(position.price) - int256(priceWithFee)) / int256(position.price);
		}
		
		// realize interest pro rata based on amount being closed
		uint256 interestToRealize = _calculateInterest(margin * position.leverage, position.timestamp, interest);
		
		console.log('interestToRealize', interestToRealize);

		// subtract interest from P/L
		pnl -= int256(interestToRealize);

		if (margin < position.margin) {
			// if partial close
			position.margin -= margin;
		} else {
			// if full close
			console.log('full close');
			delete positions[existingPositionId];
			userPositionIds[user][baseId].remove(existingPositionId);
		}

		// update vault
		uint256 positivePnl;
		uint256 amountToSendUser;
		if (pnl < 0) {
			positivePnl = uint256(-pnl);
			console.log('pnl-', positivePnl);
			balances[baseId] += positivePnl;
			if (positivePnl < margin) {
				amountToSendUser = margin - positivePnl;
			}
		} else {
			if (releaseMargin) pnl = 0; // in cases to unlock margin when there's not enough in the vault, user can always get back their margin
			positivePnl = uint256(pnl);
			console.log('pnl', positivePnl);
			require(balances[baseId] >= positivePnl, "!IF");
			balances[baseId] -= positivePnl;
			amountToSendUser = margin + positivePnl;
		}

		// send margin unlocked +/- pnl to user
		IERC20(bases[baseId]).safeTransfer(msg.sender, amountToSendUser);

		emit ClosePosition(existingPositionId, user, priceWithFee, margin, pnl);

	}

	// Liquidation

	function liquidatePosition(uint256 positionId) external {

		Position storage position = positions[positionId];
		require(!position.isSettling, "!S");
		require(position.margin > 0, "!M");

		Product memory product = products[position.productId];

		uint256 price = getLatestPrice(product.feed);
		uint256 priceWithFee = _calculatePriceWithFee(price, product.fee, !position.isLong);

		if (position.isLong && priceWithFee < position.liquidationPrice || !position.isLong && priceWithFee > position.liquidationPrice) {
			// Can be liquidated
			uint256 vaultReward = position.margin * (100 - liquidatorBounty) / 100;
			uint256 liquidatorReward = position.margin - vaultReward;
			balances[position.baseId] += vaultReward;

			// send margin liquidatorReward
			IERC20(bases[position.baseId]).safeTransfer(msg.sender, liquidatorReward);

			emit LiquidatedPosition(positionId, msg.sender, liquidatorReward);

		}

	}

	// Settlement

	function checkSettlement() external view returns (uint256[] memory) {

		uint256 length = settlingIds.length();
		if (length == 0) return new uint[](0);

		uint256[] memory settleTheseIds = new uint[](length);

		for (uint256 i=0; i < length; i++) {
			uint256 id = settlingIds.at(i);
			Position memory position = positions[id];
			Product memory product = products[position.productId];

			uint256 price = getLatestPrice(product.feed);

			console.log('block.timestamp', block.timestamp);
			console.log('position.timestamp', position.timestamp);

			// Add fee
			uint256 priceWithFee = _calculatePriceWithFee(price, product.fee, position.isLong);

			if (block.timestamp - uint256(position.timestamp) > settlementTime || priceWithFee != position.price) {
				settleTheseIds[i] = id;
			}

			// !!! Local test
			settleTheseIds[i] = id;

		}

		if (settleTheseIds[0] == 0) return new uint[](0);

		return settleTheseIds;

	}

	function performSettlement(uint256[] calldata positionIds) external {

		uint256 length = positionIds.length;

		console.log('length', length);
		
		for (uint256 i = 0; i < length; i++) {
		
			uint256 positionId = positionIds[i];

			console.log('positionId', positionId);

			Position storage position = positions[positionId];
			Product memory product = products[position.productId];

			uint256 price = getLatestPrice(product.feed);

			// Add fee
			uint256 priceWithFee = _calculatePriceWithFee(price, product.fee, position.isLong);

			if (block.timestamp - uint256(position.timestamp) > settlementTime || priceWithFee != position.price) {
				position.price = priceWithFee;
				position.isSettling = false;
				settlingIds.remove(positionId);
			}

			// !!! local test
			position.price = priceWithFee;
			position.isSettling = false;
			settlingIds.remove(positionId);

			emit NewPositionSettled(positionId, position.owner, priceWithFee);

		}

	}

	// Internal

	function _calculatePriceWithFee(uint256 price, uint256 fee, bool isLong) internal pure returns(uint256) {
		if (isLong) {
			return price + price * fee / 10000;
		} else {
			return price - price * fee / 10000;
		}
	}

	function _calculateInterest(uint256 amount, uint64 timestamp, uint256 interest) internal view returns (uint256) {
		if (block.timestamp < uint256(timestamp) - 1800) return 0;
		return amount * (interest / 10000) * (block.timestamp - uint256(timestamp)) / 360 days;
	}

	function getLatestPrice(address feed) public pure returns (uint256) {
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

	// Getters

	function getBase(uint8 baseId) external view returns(address) {
		return bases[baseId];
	}

	function getProduct(uint16 productId) external view returns(Product memory product) {
		product = products[productId];
		require(product.leverage > 0, "!PE");
		return product;
	}

	function getPosition(uint256 positionId) external view returns(Position memory position) {
		position = positions[positionId];
		return position;
	}

	function getCap(uint8 baseId) external view returns(uint256) {
		return caps[baseId];
	}

	function getBalance(uint8 baseId) external view returns(uint256) {
		return balances[baseId];
	}

	function getTotalStaked(uint8 baseId) external view returns(uint256) {
		return totalStaked[baseId];
	}

	function getUserStaked(address user, uint8 baseId) external view returns(uint256) {
		return userStaked[user][baseId];
	}
	
	function getUserPositions(address user, uint8 baseId) external view returns (Position[] memory _positions) {
		uint256 length = userPositionIds[user][baseId].length();
		_positions = new Position[](length);
		for (uint256 i=0; i < length; i++) {
			uint256 id = userPositionIds[user][baseId].at(i);
			_positions[i] = positions[id];
		}
		return _positions;
	}

	// Owner methods

	function addProduct(uint16 productId, uint256 leverage, uint256 fee, uint256 interest, address feed) external onlyOwner {
		Product memory product = products[productId];
		require(product.leverage == 0, "!PE"); // Product already exists with this id
		require(leverage > 0, "!L");
		require(feed != address(0), "!F");
		products[productId] = Product({
			leverage: leverage,
			fee: fee,
			interest: interest,
			feed: feed,
			isActive: true
		});
		emit ProductAdded(productId, leverage, fee, interest, feed);
	}

	function updateProduct(uint16 productId, uint256 leverage, uint256 fee, uint256 interest, address feed, bool isActive) external onlyOwner {
		Product storage product = products[productId];
		require(product.leverage > 0, "!PE"); // Product doesn't exist
		require(leverage > 0, "!L");
		require(feed != address(0), "!F");
		product.leverage = leverage;
		product.fee = fee;
		product.interest = interest;
		product.feed = feed;
		product.isActive = isActive;
		emit ProductUpdated(productId, product.leverage, product.fee, product.interest, product.feed, product.isActive);
	}

	function removeProduct(uint16 productId) external onlyOwner {
		delete products[productId];
		emit ProductRemoved(productId);
	}

	function addBase(uint8 baseId, address base) external onlyOwner {
		bases[baseId] = base;
		emit BaseAdded(baseId, base);
	}

	function removeBase(uint8 baseId) external onlyOwner {
		delete bases[baseId];
		emit BaseRemoved(baseId);
	}

	function setLiquidatorBounty(uint256 newBounty) external onlyOwner {
		liquidatorBounty = newBounty;
		emit LiquidatorBountyUpdated(newBounty);
	}

	function setStakingPeriod(uint256 period) external onlyOwner {
		stakingPeriod = period;
		emit StakingPeriodUpdated(period);
	}

	function setUnstakingPeriod(uint256 period) external onlyOwner {
		unstakingPeriod = period;
		emit UnstakingPeriodUpdated(period);
	}

	function setCap(uint8 baseId, uint256 newCap) external onlyOwner {
		caps[baseId] = newCap;
		emit VaultCapUpdated(baseId, newCap);
	}

	function setOwner(address newOwner) external onlyOwner {
		owner = newOwner;
		emit OwnerUpdated(newOwner);
	}

	// Modifiers

	modifier onlyOwner() {
		require(msg.sender == owner, '!O');
		_;
	}

}