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
	-- user locking, closing/releasing of positions by owner
	-- unstake = redeem
	-- support for fee rebates when user has CAP staked, % set by owner (can be 0)
	-- max daily drawdown for vault, where if a position close makes it go down lower than that, it doesn't happen. Basically sampl vault balance at top of each day, low watermark is LW% below that. This is the only risk limit needed. This can be done on closePosition, if last vault sample > 24 hours, set vault sampled balance (checkpoint) 
	-- pause all trading, or new positions, for example when going to a v2 contract (can't pause releaseMargin)
	-- protocol fee that can be turned on (e.g. 0.5% of daily position close volume owed from vault if it's > its cap). Can set which address can claim this, can be governance treasury contract, value accruing to CAP holders
	-- max open interest per vault to avoid trade size e.g. that is 3x bigger than vault, to avoid extreme scenarios (e.g. trader comes in with 100 wallets and does a quick scalp), can be re-adjusted as needed. This is already taken care of with the max drawdown mostly, so if previous scenario happens, user must be paused etc. This is to avoid pausing and discouraging such an attack
	-- min trade duration, to avoid scalpers. can be adjusted, e.g. minimum 10minutes. This also gives time to hedge if needed.
	- later, v2: add keeper reward option, pay user that settles prices. 0 at first, but at least have option that it can be updated, so to incentivize anyone to call it. Paid from pool
	- DRY & document
	*/

	using SafeERC20 for IERC20;
	using UintSet for UintSet.Set;

	// Structs

	struct Vault {
		address base;
		uint256 cap;
		uint256 maxOpenInterest;
		uint256 maxDailyDrawdown; // in bps. 1000 = 10%
		uint256 stakingPeriod; // in seconds
		uint256 redemptionPeriod; // in seconds
		uint256 protocolFee;  // in bps. 100 = 1%
		uint256 openInterest;
		uint256 balance;
		uint256 totalStaked;
		uint256 lastCheckpointBalance;
		uint256 lastCheckpointTime;
		bool isActive;
	}

	struct Product {
		uint256 leverage; // max leverage x 10**6
		uint256 fee; // in basis points (bps). 0.5% = 50
		uint256 interest; // for 360 days, in bps. 5.35% = 535
		address feed; // from chainlink
		uint256 settlementTime; // in seconds
		uint256 minTradeDuration; // in seconds
		uint256 liquidationThreshold; // in bps. 8000 = 80% loss can be liquidated
		uint256 liquidationBounty; // in bps. 500 = 5%
		bool isActive;
	}

	struct Position {
		uint8 vaultId; // 1 byte
		uint16 productId; // 2 bytes
		address owner; // 20 bytes
		uint64 timestamp; // 8 bytes
		bool isLong; // 1 byte
		bool isSettling; // 1 byte
		uint256 margin; // 32 bytes x 10**6
		uint256 leverage; // 32 bytes x 10**6
		uint256 price; // 32 bytes x 10**8
		uint256 id; // 32 bytes
	}

	// Variables
	address public owner; // contract owner
	uint256 public currentPositionId; // incremental
	address public CAPStakingContract;

	// Fee rebate scale
	uint256 frMinStaked; // CAP staked. 0 = min rebate without stake
	uint256 frMaxStaked; // CAP staked. 0 = no fee rebates
	uint16 frMinRebate; // in bps. 1000 = 10%
	uint16 frMaxRebate; // in bps. 5000 = 50%

	// Mappings

	mapping(uint8 => Vault) private vaults; // vaultId => vault info
	mapping(uint16 => Product) private products; // productId => product info
	mapping(uint256 => Position) private positions; // positionId => position info
	mapping(address => mapping(uint8 => UintSet.Set)) private userPositionIds; // user => vaultId => [Position ids]
	UintSet.Set private settlingIds; // IDs of positions in settlement
	mapping(address => mapping(uint8 => uint256)) vaultUserStaked;
	mapping(address => bool) private lockedUsers;

	// Constructor

	constructor() {
		console.log("Initialized Trading contract.");
		owner = msg.sender;
	}

	// Vault methods

	function stake(uint8 vaultId, uint256 amount) external {
		Vault storage vault = vaults[vaultId];
		require(vault.base != address(0), "!V");
		require(vault.balance + amount <= vault.cap, "!C");
		vault.balance += amount;
		vaultUserStaked[msg.sender][vaultId] += amount;
		vault.totalStaked += amount;
		IERC20(vault.base).safeTransferFrom(msg.sender, address(this), amount);
		emit Staked(msg.sender, vaultId, amount);
	}

	function redeem(uint8 vaultId, uint256 amount) external {
		Vault storage vault = vaults[vaultId];
		require(vault.base != address(0), "!V");
		// !!! Local test, uncomment in prod
		//require(block.timestamp % vault.stakingPeriod < vault.redemptionPeriod, "!P");
		require(amount <= vaultUserStaked[msg.sender][vaultId], "!S");
		uint256 amountToSend = amount * vault.balance / vault.totalStaked;
		vaultUserStaked[msg.sender][vaultId] -= amount;
		vault.totalStaked -= amount;
		vault.balance -= amountToSend;
		IERC20(vault.base).safeTransfer(msg.sender, amountToSend);
		emit Redeemed(msg.sender, vaultId, amountToSend);
	}

	// Trading methods

	function submitOrder(
		uint8 vaultId,
		uint16 productId,
		bool isLong,
		uint256 margin,
		uint256 leverage,
		uint256 positionId,
		bool releaseMargin
	) external {

		// Checks: input

		require(margin > 0, "!margin");
		require(leverage > 0, '!leverage');

		require(!lockedUsers[msg.sender], '!locked');

		// Checks: vault

		Vault memory vault = vaults[vaultId];
		require(vault.base != address(0), "!vault");
		require(vault.isActive, "!vault-active");

		// Checks: product

		Product memory product = products[productId];
		require(product.leverage > 0, "!product");
		require(product.isActive, "!product-active");
		
		require(leverage <= product.leverage, "!max-leverage");

		// Get price
		uint256 price = _calculatePriceWithFee(getLatestPrice(productId), product.fee, isLong);
		require(price > 0, "!price");

		if (positionId > 0) {

			Position memory position = positions[positionId];
			require(position.vaultId > 0, "!position");
			require(!position.isSettling, "!settling");

			// Check owner
			if (msg.sender == position.owner || lockedUsers[position.owner] && msg.sender == owner) {

				if (position.isLong == isLong) {
					IERC20(vault.base).safeTransferFrom(msg.sender, address(this), margin);
					_addMargin(positionId, margin);

				} else {
					require(block.timestamp > position.timestamp + product.minTradeDuration, '!duration');
					require(margin <= position.margin, "!margin-too-high");
					_closePosition(positionId, margin, price, product.interest, releaseMargin);
				}
			}

		} else {
			IERC20(vault.base).safeTransferFrom(msg.sender, address(this), margin);
			_openPosition(vaultId, productId, isLong, margin, leverage, price);
		}

	}

	function _openPosition(
		uint8 vaultId,
		uint16 productId,
		bool isLong,
		uint256 margin,
		uint256 leverage,
		uint256 price
	) internal {

		address user = msg.sender;
		
		// Create position
		currentPositionId += 1;
		positions[currentPositionId] = Position({
			owner: user,
			vaultId: vaultId,
			productId: productId,
			margin: margin,
			leverage: leverage,
			price: price,
			timestamp: uint64(block.timestamp),
			isLong: isLong,
			isSettling: true,
			id: currentPositionId
		});
		userPositionIds[user][vaultId].add(currentPositionId);
		settlingIds.add(currentPositionId);

		Vault storage vault = vaults[vaultId];
		vault.openInterest += margin * leverage / 10**6;
		require(vault.openInterest <= vault.maxOpenInterest, "!max-open-interest");

		emit NewPosition(
			currentPositionId,
			user,
			vaultId,
			productId,
			isLong,
			price,
			margin,
			leverage
		);

	}

	function _addMargin(uint256 positionId, uint256 margin) internal {

		Position storage position = positions[positionId];

		// New position params
		uint256 newMargin = position.margin + margin;
		uint256 newLeverage = position.leverage * position.margin / newMargin;
		require(newLeverage >= 1, "!low-leverage");

		position.margin = newMargin;
		position.leverage = newLeverage;

		emit AddMargin(positionId, position.owner, margin, newMargin, newLeverage);

	}

	function _closePosition(
		uint256 positionId, 
		uint256 margin, 
		uint256 price, 
		uint256 interest,
		bool releaseMargin
	) internal {

		// Close (full or partial)

		Position storage position = positions[positionId];
		Vault storage vault = vaults[position.vaultId];

		// P/L
		int256 pnl;
		if (position.isLong) {
			pnl = int256(margin) * int256(position.leverage) * (int256(price) - int256(position.price)) / int256(position.price) / 10**6;
		} else {
			pnl = int256(margin) * int256(position.leverage) * (int256(position.price) - int256(price)) / int256(position.price) / 10**6;
		}

		// subtract interest from P/L
		pnl -= int256(_calculateInterest(margin * position.leverage / 10**6, position.timestamp, interest));

		// calculate fee rebate
		uint256 feeRebateAmount;
		if (frMaxRebate > 0) {
			feeRebateAmount = _calculateFeeRebate(position.owner, margin * position.leverage / 10**6, position.productId);
			pnl += int256(feeRebateAmount);
		}

		// calculate protocol fee
		uint256 protocolFeeAmount;
		if (vault.protocolFee > 0) {
			protocolFeeAmount = vault.protocolFee * (margin * position.leverage / 10**6) / 10**4;
			pnl -= int256(protocolFeeAmount);
			IERC20(vault.base).safeTransfer(owner, protocolFeeAmount);
		}

		if (margin < position.margin) {
			// if partial close
			position.margin -= margin;
		} else {
			// if full close
			delete positions[positionId];
			userPositionIds[position.owner][position.vaultId].remove(positionId);
		}

		// checkpoint vault
		if (vault.lastCheckpointTime < block.timestamp - 24 hours) {
			vault.lastCheckpointTime = block.timestamp;
			vault.lastCheckpointBalance = vault.balance;
		}

		// update vault
		uint256 amountToSendUser;
		if (pnl < 0) {
			if (uint256(-pnl) < margin) {
				amountToSendUser = margin - uint256(-pnl);
				vault.balance += uint256(-pnl);
			} else {
				vault.balance += margin;
			}
		} else {
			if (releaseMargin) pnl = 0; // in cases to unlock margin when there's not enough in the vault, user can always get back their margin
			require(vault.balance >= uint256(pnl), "!vault-insufficient");
			// Require vault not below max drawdown
			require(vault.balance - uint256(pnl) >= vault.lastCheckpointBalance * (10**4 - vault.maxDailyDrawdown) / 10**4, "!max-drawdown");
			vault.balance -= uint256(pnl);
			amountToSendUser = margin + uint256(pnl);			
		}

		// send margin unlocked +/- pnl to user
		IERC20(vault.base).safeTransfer(position.owner, amountToSendUser);

		vault.openInterest -= margin * position.leverage / 10**6;

		emit ClosePosition(positionId, position.owner, position.vaultId, position.productId, price, margin, position.leverage, pnl, feeRebateAmount, protocolFeeAmount, false);

	}

	// Liquidation methods

	function liquidatePosition(uint256 positionId) external {

		Position memory position = positions[positionId];
		require(!position.isSettling, "!settling");

		Product memory product = products[position.productId];

		uint256 price = _calculatePriceWithFee(getLatestPrice(position.productId), product.fee, !position.isLong);
		require(price > 0, "!price");

		// !!! local test
		price = 1350000000000;

		uint256 liquidationPrice;
		if (position.isLong) {
			liquidationPrice = (price - price * product.liquidationThreshold / 10**4 / position.leverage);
		} else {
			liquidationPrice = (price + price * product.liquidationThreshold / 10**4 / position.leverage);
		}

		if (position.isLong && price <= liquidationPrice || !position.isLong && price >= liquidationPrice) {

			// Can be liquidated
			uint256 vaultReward = position.margin * (10**4 - product.liquidationBounty) / 100;
			uint256 liquidatorReward = position.margin - vaultReward;

			Vault storage vault = vaults[position.vaultId];
			vault.balance += vaultReward;

			// send margin liquidatorReward
			IERC20(vault.base).safeTransfer(msg.sender, liquidatorReward);

			userPositionIds[position.owner][position.vaultId].remove(positionId);

			emit ClosePosition(positionId, position.owner, position.vaultId, position.productId, price, position.margin, position.leverage, -1 * int256(position.margin), 0, 0, true);

			delete positions[positionId];

			emit PositionLiquidated(positionId, msg.sender, vaultReward, liquidatorReward);

		}

	}

	// Price settlement methods

	function checkPositionsToSettle() external view returns (uint256[] memory) {

		uint256 length = settlingIds.length();
		if (length == 0) return new uint[](0);

		uint256[] memory settleTheseIds = new uint[](length);

		for (uint256 i=0; i < length; i++) {

			uint256 id = settlingIds.at(i);
			Position memory position = positions[id];
			Product memory product = products[position.productId];

			// Add fee
			uint256 price = _calculatePriceWithFee(getLatestPrice(position.productId), product.fee, position.isLong);

			if (price > 0) {
				if (block.timestamp - uint256(position.timestamp) > product.settlementTime || price != position.price) {
					settleTheseIds[i] = id;
				}
			}

			// !!! Local test
			settleTheseIds[i] = id;

		}

		if (settleTheseIds[0] == 0) return new uint[](0);

		return settleTheseIds;

	}

	function settlePositions(uint256[] calldata positionIds) external {

		uint256 length = positionIds.length;
		
		for (uint256 i = 0; i < length; i++) {
		
			uint256 positionId = positionIds[i];

			Position storage position = positions[positionId];
			if (!position.isSettling) continue;

			Product memory product = products[position.productId];

			uint256 price = _calculatePriceWithFee(getLatestPrice(position.productId), product.fee, position.isLong);

			if (price > 0) {

				if (block.timestamp - uint256(position.timestamp) > product.settlementTime || price != position.price) {
					position.price = price;
					position.isSettling = false;
					settlingIds.remove(positionId);
				}

				// !!! local test
				position.price = price;
				position.isSettling = false;
				settlingIds.remove(positionId);

				emit NewPositionSettled(positionId, position.owner, price);

			}

		}

	}

	// Internal utilities

	function _calculatePriceWithFee(uint256 price, uint256 fee, bool isLong) internal pure returns(uint256) {
		if (price == 0) return 0;
		if (isLong) {
			return price + price * fee / 10**4;
		} else {
			return price - price * fee / 10**4;
		}
	}

	function _calculateInterest(uint256 amount, uint64 timestamp, uint256 interest) internal view returns (uint256) {
		if (block.timestamp < uint256(timestamp) - 900) return 0;
		return amount * (interest / 10**4) * (block.timestamp - uint256(timestamp)) / 360 days;
	}

	function _calculateFeeRebate(address user, uint256 amount, uint16 productId) internal view returns (uint256) {
		// get fee rebate scale. min = [min CAP staked, min reward], max = [max CAP staked, max reward]. linear regression in between. can be [0, 10%], [200, 50%], means reward will be 10% back even with no CAP staked, up to 50%
		// get CAP staked by user
		// return amount * fee * rebate %
		if (frMaxRebate == 0) return 0;
		if (CAPStakingContract == address(0)) return 0;
		uint256 stakedCAP = IStaking(CAPStakingContract).getUserStake(user);
		uint256 rebateBps;
		if (stakedCAP >= frMaxStaked) {
			rebateBps = frMaxRebate;
		} else if (stakedCAP <= frMinStaked) {
			rebateBps = frMinRebate;
		} else {
			rebateBps = (frMaxRebate - frMinRebate) * (stakedCAP - frMinStaked) * 10**4 / (frMaxStaked - frMinStaked);
		}
		return amount * products[productId].fee * rebateBps / 10**4;
	}

	// Getters

	function getLatestPrice(uint16 productId) public view returns (uint256) {
		Product memory product = products[productId];
		require(product.feed != address(0), "!feed");
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

	function getVault(uint8 vaultId) external view returns(Vault memory) {
		return vaults[vaultId];
	}

	function getProduct(uint16 productId) external view returns(Product memory) {
		return products[productId];
	}

	function getPosition(uint256 positionId) external view returns(Position memory) {
		return positions[positionId];
	}
	
	function getUserPositions(address user, uint8 vaultId) external view returns (Position[] memory _positions) {
		uint256 length = userPositionIds[user][vaultId].length();
		_positions = new Position[](length);
		for (uint256 i=0; i < length; i++) {
			uint256 id = userPositionIds[user][vaultId].at(i);
			_positions[i] = positions[id];
		}
		return _positions;
	}

	// Owner methods

	function addVault(uint8 vaultId, address base, uint256 cap, uint256 maxOpenInterest, uint256 maxDailyDrawdown, uint256 stakingPeriod, uint256 redemptionPeriod, uint256 protocolFee) external onlyOwner {
		
		Vault memory vault = vaults[vaultId];
		require(vault.base == address(0), "!vault-exists");

		require(cap > 0, "!cap");
		require(maxOpenInterest > 0, "!maxOpenInterest");
		require(maxDailyDrawdown > 0, "!maxDailyDrawdown");
		require(stakingPeriod > 0, "!stakingPeriod");
		require(redemptionPeriod > 0, "!redemptionPeriod");
		require(protocolFee <= 200, "!protocolFee");

		vaults[vaultId] = Vault({
			base: base,
			cap: cap,
			maxOpenInterest: maxOpenInterest,
			maxDailyDrawdown: maxDailyDrawdown,
			stakingPeriod: stakingPeriod,
			redemptionPeriod: redemptionPeriod,
			openInterest: 0,
			balance: 0,
			totalStaked: 0,
			lastCheckpointBalance: 0,
			lastCheckpointTime: block.timestamp,
			protocolFee: protocolFee,
			isActive: true
		});

		emit VaultAdded(vaultId, base, cap, maxOpenInterest, maxDailyDrawdown, stakingPeriod, redemptionPeriod, protocolFee);

	}

	function updateVault(uint8 vaultId, address base, uint256 cap, uint256 maxOpenInterest, uint256 maxDailyDrawdown, uint256 stakingPeriod, uint256 redemptionPeriod, uint256 protocolFee, bool isActive) external onlyOwner {

		Vault storage vault = vaults[vaultId];
		require(vault.base == base, "!vault-base");

		if (cap > 0) vault.cap = cap;
		if (maxOpenInterest > 0) vault.maxOpenInterest = maxOpenInterest;
		if (maxDailyDrawdown > 0) vault.maxDailyDrawdown = maxDailyDrawdown;
		if (stakingPeriod > 0) vault.stakingPeriod = stakingPeriod;
		if (redemptionPeriod > 0) vault.redemptionPeriod = redemptionPeriod;

		if (protocolFee <= 200) {
			vault.protocolFee = protocolFee;
		}

		vault.isActive = isActive;

		emit VaultUpdated(vaultId, base, vault.cap, vault.maxOpenInterest, vault.maxDailyDrawdown, vault.stakingPeriod, vault.redemptionPeriod, vault.protocolFee, vault.isActive);

	}

	function addProduct(uint16 productId, uint256 leverage, uint256 fee, uint256 interest, address feed, uint256 settlementTime, uint256 minTradeDuration, uint256 liquidationThreshold, uint256 liquidationBounty) external onlyOwner {

		Product memory product = products[productId];

		require(product.leverage == 0, "!product-exists");
		require(leverage > 0, "!leverage");
		require(feed != address(0), "!feed");
		require(settlementTime > 0, "!settlementTime");
		require(liquidationThreshold > 0, "!liquidationThreshold");

		products[productId] = Product({
			leverage: leverage,
			fee: fee,
			interest: interest,
			feed: feed,
			settlementTime: settlementTime,
			minTradeDuration: minTradeDuration,
			liquidationThreshold: liquidationThreshold,
			liquidationBounty: liquidationBounty,
			isActive: true
		});

		emit ProductAdded(productId, leverage, fee, interest, feed, settlementTime, minTradeDuration, liquidationThreshold, liquidationBounty);

	}

	function updateProduct(uint16 productId, uint256 leverage, uint256 fee, uint256 interest, address feed, uint256 settlementTime, uint256 minTradeDuration, uint256 liquidationThreshold, uint256 liquidationBounty, bool isActive) external onlyOwner {

		Product storage product = products[productId];
		
		require(product.leverage > 0, "!product-exists");
		require(leverage > 0, "!leverage");
		require(feed != address(0), "!feed");

		product.leverage = leverage;
		product.fee = fee;
		product.interest = interest;
		product.feed = feed;

		if (settlementTime > 0) product.settlementTime = settlementTime;
		product.minTradeDuration = minTradeDuration;
		if (liquidationThreshold > 0) product.liquidationThreshold = liquidationThreshold;
		product.liquidationBounty = liquidationBounty;
		product.isActive = isActive;
		
		emit ProductUpdated(productId, product.leverage, product.fee, product.interest, product.feed, product.settlementTime, product.minTradeDuration, product.liquidationThreshold, product.liquidationBounty, product.isActive);
	
	}

	function setCAPStakingContract(address _address) external onlyOwner {
		CAPStakingContract = _address;
		emit CAPStakingContractUpdated(_address);
	}

	function lockUser(address _address, bool _lock) external onlyOwner {
		lockedUsers[_address] = _lock;
		emit LockedUsersUpdated(_address, _lock);
	}

	function updateFeeRebates(uint256 minStaked, uint16 minRebate, uint256 maxStaked, uint16 maxRebate) external onlyOwner {
		require(maxStaked >= minStaked, '!M1');
		require(maxRebate >= minRebate, '!M2');
		frMinStaked = minStaked;
		frMinRebate = minRebate;
		frMaxStaked = maxStaked;
		frMaxRebate = maxRebate;
		emit FeeRebatesUpdated(minStaked, minRebate, maxStaked, maxRebate);
	}

	function setOwner(address newOwner) external onlyOwner {
		owner = newOwner;
		emit OwnerUpdated(newOwner);
	}

	// Events

	event Staked(address indexed from, uint8 indexed vaultId, uint256 amount);
	event Redeemed(address indexed to, uint8 indexed vaultId, uint256 amount);

	event NewPosition(uint256 id, address indexed user, uint8 indexed vaultId, uint16 indexed productId, bool isLong, uint256 price, uint256 margin, uint256 leverage);
	event AddMargin(uint256 id, address indexed user, uint256 margin, uint256 newMargin, uint256 newLeverage);
	event ClosePosition(uint256 id, address indexed user, uint8 indexed vaultId, uint16 indexed productId, uint256 price, uint256 margin, uint256 leverage, int256 pnl, uint256 feeRebate, uint256 protocolFee, bool wasLiquidated);

	event NewPositionSettled(uint256 id, address indexed user, uint256 price);

	event PositionLiquidated(uint256 indexed positionId, address indexed by, uint256 vaultReward, uint256 liquidatorReward);

	event VaultAdded(uint8 vaultId, address base, uint256 cap, uint256 maxOpenInterest, uint256 maxDailyDrawdown, uint256 stakingPeriod, uint256 redemptionPeriod, uint256 protocolFee);
	event VaultUpdated(uint8 vaultId, address base, uint256 cap, uint256 maxOpenInterest, uint256 maxDailyDrawdown, uint256 stakingPeriod, uint256 redemptionPeriod, uint256 protocolFee, bool isActive);

	event ProductAdded(uint16 productId, uint256 leverage, uint256 fee, uint256 interest, address feed, uint256 settlementTime, uint256 minTradeDuration, uint256 liquidationThreshold, uint256 liquidationBounty);
	event ProductUpdated(uint16 productId, uint256 leverage, uint256 fee, uint256 interest, address feed, uint256 settlementTime, uint256 minTradeDuration, uint256 liquidationThreshold, uint256 liquidationBounty, bool isActive);

	event FeeRebatesUpdated(uint256 minStaked, uint16 minRebate, uint256 maxStaked, uint16 maxRebate);
	event CAPStakingContractUpdated(address _address);
	event LockedUsersUpdated(address _address, bool _lock);
	event OwnerUpdated(address newOwner);

	// Modifiers

	modifier onlyOwner() {
		require(msg.sender == owner, '!O');
		_;
	}

}