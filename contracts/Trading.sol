//SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "hardhat/console.sol";

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

import './libraries/UIntSet.sol';
import './interfaces/IStaking.sol';

contract Trading {

	/*
	TODO
	- user locking, closing/releasing of positions by owner, readjusting position price (not beyond margin)
	- unstake = redeem
	- support for fee redemption when user has CAP staked, % set by owner (can be 0)
	- support for referral rewards with % based on how much CAP you have staked (a percent even if you dont, e.g. 10%, then goes up to 25% with staking) [can be done offline, have temporary marketing programs to cover this]
	- max daily drawdown for vault, where if a position close makes it go down lower than that, it doesn't happen. Basically sampl vault balance at top of each day, low watermark is LW% below that. This is the only risk limit needed
	- pause all trading, for example when going to a v2 contract
	- should be it, the simpler the better and more flexible you remain
	- protocol fee that can be turned on (e.g. 0.5% of daily position close volume owed from vault if it's > its cap). Can set which address can claim this, can be governance treasury contract, value accruing to CAP holders
	- max open interest per vault to avoid trade size e.g. that is 3x bigger than vault, to avoid extreme scenarios (e.g. trader comes in with 100 wallets and does a quick scalp), can be re-adjusted as needed. This is already taken care of with the max drawdown mostly, so if previous scenario happens, user must be paused etc. This is to avoid pausing and discouraging such an attack
	- min trade duration, to avoid scalpers. can be adjusted, e.g. minimum 10minutes. This also gives time to hedge if needed.
	- add keeper reward option, pay user that settles prices. 0 at first, but at least have option that it can be updated, so to incentivize anyone to call it. Paid from pool
	*/

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
		uint256 leverage; // 32 bytes x 10**6
		uint256 price; // 32 bytes
		uint256 liquidationPrice; // 32 bytes
		uint256 id; // 32 bytes
	}

	struct Product {
		uint256 leverage; // max leverage x 10**6
		uint256 fee; // In % * 100. e.g. 0.5% is 50
		uint256 interest; // for 360 days, in % * 100. E.g. 5.35% is 535
		address feed; // chainlink
		bool isActive;
	}

	struct FeeRebates {
		uint256 minStaked; // CAP staked
		uint256 maxStaked; // CAP staked
		uint16 minReward; // in bps. 100 = 1%
		uint16 maxReward; // in bps. 100 = 1%
	}

	// Variables

	address public owner;
	uint256 public currentPositionId;
	uint256 public liquidatorBounty = 5; // 5 = 5%
	uint256 public stakingPeriod = 2592000; // 30 days
	uint256 public unstakingPeriod = 28800; // 8 hours
	uint256 public settlementTime = 3 * 60;
	uint256 public feeRebates = FeeRebates({minStaked: 0, minReward: 0, maxStaked: 0, maxReward: 0});
	address public stakingContractAddress;

	mapping(uint8 => address) private bases; // baseId => DAI address
	mapping(uint16 => Product) private products; // productId => Product
	mapping(uint256 => Position) private positions; // positionId => Position
	mapping(address => mapping(uint8 => UintSet.Set)) private userPositionIds; // user => baseId => [Position ids]
	UintSet.Set private settlingIds;

	mapping(uint8 => uint256) private caps; // baseId => vault cap
	mapping(uint8 => uint256) private balances; // baseId => vault total balance (varies with P/L)
	mapping(uint8 => uint256) private totalStaked; // baseId => vault total staked by users
	mapping(address => mapping(uint8 => uint256)) private userStaked; // address => baseId => staked by user

	mapping(uint8 => uint256) private maxOpenInterest; // risk limit, should be 1x-2x vault cap

	// Constructor

	constructor() {
		console.log("Initialized Trading contract.");
		owner = msg.sender;
	}

	// Vault methods

	function stake(uint8 baseId, uint256 amount) external {
		require(bases[baseId] != address(0), "!B");
		require(balances[baseId] + amount <= caps[baseId], "!C");
		balances[baseId] += amount;
		userStaked[msg.sender][baseId] += amount;
		totalStaked[baseId] += amount;
		IERC20(bases[baseId]).safeTransferFrom(msg.sender, address(this), amount);
		emit Staked(msg.sender, baseId, amount);
	}

	function unstake(uint8 baseId, uint256 _stake) external {
		// !!! Local test, uncomment in prod
		//require(block.timestamp % stakingPeriod < unstakingPeriod, "!P");
		require(_stake <= userStaked[msg.sender][baseId], "!S");
		uint256 amountToSend = _stake * balances[baseId] / totalStaked[baseId];
		console.log('>params Unstake', userStaked[msg.sender][baseId], totalStaked[baseId], balances[baseId]);
		console.log('>amountToSend Unstake', amountToSend);
		userStaked[msg.sender][baseId] -= _stake;
		totalStaked[baseId] -= _stake;
		balances[baseId] -= amountToSend;
		IERC20(bases[baseId]).safeTransfer(msg.sender, amountToSend);
		emit Unstaked(msg.sender, baseId, amountToSend);
	}

	// Trading methods

	function submitOrder(
		uint8 baseId,
		uint16 productId,
		bool isLong,
		uint256 existingPositionId,
		uint256 margin,
		uint256 leverage,
		bool releaseMargin
	) external {

		// TODO: these are not needed for add margin, just for close

		Product memory product = products[productId];
		require(product.isActive, "!PA"); // Product paused or doesn't exist

		require(leverage > 0, '!L1');
		require(leverage <= product.leverage, '!L2');

		uint256 price = getLatestPrice(productId);

		console.log('PRICE', price);

		require(price > 0, "!P");
		
		console.log('existingPositionId', existingPositionId);

		// Add fee
		uint256 priceWithFee = _calculatePriceWithFee(price, product.fee, isLong);

		if (existingPositionId > 0) {

			Position memory position = positions[existingPositionId];

			if (position.isLong == isLong) {
				address base = bases[position.baseId];
				require(base != address(0), '!BM');
				IERC20(base).safeTransferFrom(msg.sender, address(this), margin);
				_addMargin(existingPositionId, margin);

			} else {
				_closePosition(existingPositionId, margin, priceWithFee, product.interest, releaseMargin);

			}

		} else {
			address base = bases[baseId];
			require(base != address(0), '!B');
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
			liquidationPrice: liquidationPrice,
			id: currentPositionId
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
		uint256 newLeverage = position.leverage * position.margin / newMargin;
		console.log('params', position.leverage, position.margin, newMargin);
		console.log('newLeverage', newLeverage);
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

		uint8 baseId = position.baseId;

		console.log('position price', position.price);
		console.log('priceWithFee', priceWithFee);
		console.log('margin', margin);
		console.log('position.margin', position.margin);
		console.log('position.leverage', position.leverage);
		// P/L
		int256 pnl;
		if (position.isLong) {
			pnl = int256(margin) * int256(position.leverage) * (int256(priceWithFee) - int256(position.price)) / int256(position.price) / 1000000;
		} else {
			pnl = int256(margin) * int256(position.leverage) * (int256(position.price) - int256(priceWithFee)) / int256(position.price) / 1000000;
		}
		
		// realize interest pro rata based on amount being closed
		// subtract interest from P/L
		pnl -= int256(_calculateInterest(margin * position.leverage, position.timestamp, interest));

		// calculate fee rebate (kickback)
		uint256 feeRebate;
		if (feeRebates.maxReward > 0) {
			feeRebate = _calculateFeeRebate(position.owner, margin * position.leverage, position.productId);
			pnl += int256(feeRebate);
		}

		if (margin < position.margin) {
			// if partial close
			position.margin -= margin;
		} else {
			// if full close
			console.log('full close');
			delete positions[existingPositionId];
			userPositionIds[msg.sender][baseId].remove(existingPositionId);
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

		console.log('amountToSendUser', amountToSendUser);

		// send margin unlocked +/- pnl to user
		IERC20(bases[baseId]).safeTransfer(msg.sender, amountToSendUser);

		emit ClosePosition(existingPositionId, msg.sender, baseId, position.productId, priceWithFee, margin, position.leverage, pnl, feeRebate, false);

	}

	// Liquidation methods

	function liquidatePosition(uint256 positionId) external {

		Position storage position = positions[positionId];
		require(!position.isSettling, "!S");
		require(position.margin > 0, "!M");

		Product memory product = products[position.productId];

		uint256 price = getLatestPrice(position.productId);

		// !!! local test
		price = 1350000000000;

		uint256 priceWithFee = _calculatePriceWithFee(price, product.fee, !position.isLong);

		console.log('Price when liquidating', priceWithFee);
		console.log('position.liquidationPrice', position.liquidationPrice);

		if (position.isLong && priceWithFee <= position.liquidationPrice || !position.isLong && priceWithFee >= position.liquidationPrice) {
			console.log('liquidation happening');
			// Can be liquidated
			uint256 vaultReward = position.margin * (100 - liquidatorBounty) / 100;
			uint256 liquidatorReward = position.margin - vaultReward;
			balances[position.baseId] += vaultReward;

			// send margin liquidatorReward
			IERC20(bases[position.baseId]).safeTransfer(msg.sender, liquidatorReward);

			userPositionIds[position.owner][position.baseId].remove(positionId);
			
			console.log('rewards', vaultReward, liquidatorReward);

			emit ClosePosition(positionId, position.owner, position.baseId, position.productId, priceWithFee, position.margin, position.leverage, -1 * int256(position.margin), 0, true);

			delete positions[positionId];

			emit PositionLiquidated(positionId, msg.sender, vaultReward, liquidatorReward);
		}

	}

	// Price settlement methods

	function checkSettlement() external view returns (uint256[] memory) {

		uint256 length = settlingIds.length();
		if (length == 0) return new uint[](0);

		uint256[] memory settleTheseIds = new uint[](length);

		for (uint256 i=0; i < length; i++) {
			uint256 id = settlingIds.at(i);
			Position memory position = positions[id];
			Product memory product = products[position.productId];

			uint256 price = getLatestPrice(position.productId);

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

			uint256 price = getLatestPrice(position.productId);

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

	// Internal utilities

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

	function _calculateFeeRebate(address user, uint256 amount, uint16 productId) internal view returns (uint256) {
		// get fee rebate scale. min = [min CAP staked, min reward], max = [max CAP staked, max reward]. linear regression in between. can be [0, 10%], [200, 50%], means reward will be 10% back even with no CAP staked, up to 50%
		// get CAP staked by user
		// return amount * fee * rebate %
		if (stakingContractAddress == address(0)) return 0;
		if (feeRebates.maxReward == 0) return 0;
		uint256 stakedCAP = IStaking(stakingContractAddress).getUserStake(user);
		uint256 rebateBps;
		if (stakedCAP >= feeRebates.maxStaked) {
			rebateBps = feeRebates.maxReward;
		} else if (stakedCAP <= feeRebates.minStaked) {
			rebateBps = feeRebates.minReward;
		} else {
			rebateBps = (feeRebates.maxReward - feeRebates.minReward) * (stakedCAP - feeRebates.minStaked) * 10000 / (feeRebates.maxStaked - feeRebates.minStaked);
		}
		Product memory product = products[productId];
		return amount * product.fee * rebateBps / 10000;
	}

	// Getters

	function getLatestPrice(uint16 productId) public view returns (uint256) {
		Product memory product = products[productId];
		require(product.feed != address(0), "!PE");
		/*
		uint8 decimals = AggregatorV3Interface(product.feed).decimals();
		// standardize price to 8 decimals
		(
			, 
			int price,
			,
			,
		) = AggregatorV3Interface(product.feed).latestRoundData();
		if (decimals != 8) {
			price = price * (10**8) / (10**decimals);
		}
		*/
		// local test
		int256 price = 33500 * 10**8;
		return uint256(price);
	}

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

	function setSettlementTime(uint256 time) external onlyOwner {
		settlementTime = time;
		emit SettlementTimeUpdated(time);
	}

	function setCap(uint8 baseId, uint256 newCap) external onlyOwner {
		caps[baseId] = newCap;
		emit VaultCapUpdated(baseId, newCap);
	}

	function setStakingContractAddress(address _address) external onlyOwner {
		stakingContractAddress = _address;
		emit StakingContractAddressUpdated(_address);
	}

	function updateFeeRebates(uint256 _minStaked, uint16 _minReward, uint256 _maxStaked, uint16 _maxReward) external onlyOwner {
		require(_maxStaked >= _minStaked, '!M1');
		require(_maxReward >= _minReward, '!M2');
		feeRebates = FeeRebates({minStaked: _minStaked, minReward: _minReward, maxStaked: _maxStaked, maxReward: _maxReward});
		emit FeeRebatesUpdated(_minStaked, _minReward, _maxStaked, _maxReward);
	}

	function setOwner(address newOwner) external onlyOwner {
		owner = newOwner;
		emit OwnerUpdated(newOwner);
	}

	// Events

	event ProductAdded(uint16 productId, uint256 leverage, uint256 fee, uint256 interest, address feed);
	event ProductUpdated(uint16 productId, uint256 leverage, uint256 fee, uint256 interest, address feed, bool isActive);
	event ProductRemoved(uint16 productId);
	event BaseAdded(uint8 baseId, address base);
	event BaseRemoved(uint8 baseId);
	event VaultCapUpdated(uint8 baseId, uint256 newCap);
	event StakingPeriodUpdated(uint256 period);
	event UnstakingPeriodUpdated(uint256 period);
	event SettlementTimeUpdated(uint256 time);
	event LiquidatorBountyUpdated(uint256 newShare);
	event FeeRebatesUpdated(uint256 minStaked, uint16 minReward, uint256 maxStaked, uint16 maxReward);
	event StakingContractAddressUpdated(address _address);
	event OwnerUpdated(address newOwner);

	event Staked(address indexed from, uint8 indexed baseId, uint256 amount);
	event Unstaked(address indexed to, uint8 indexed baseId, uint256 amount);

	event NewPosition(uint256 id, address indexed user, uint8 indexed baseId, uint16 indexed productId, bool isLong, uint256 priceWithFee, uint256 margin, uint256 leverage);
	event AddMargin(uint256 id, address indexed user, uint256 margin, uint256 newMargin, uint256 newLeverage, uint256 newLiquidationPrice);
	event ClosePosition(uint256 id, address indexed user, uint8 indexed baseId, uint16 indexed productId, uint256 priceWithFee, uint256 margin, uint256 leverage, int256 pnl, uint256 feeRebate, bool wasLiquidated);

	event NewPositionSettled(uint256 id, address indexed user, uint256 price);

	event PositionLiquidated(uint256 indexed positionId, address indexed by, uint256 vaultReward, uint256 liquidatorReward);

	// Modifiers

	modifier onlyOwner() {
		require(msg.sender == owner, '!O');
		_;
	}

}