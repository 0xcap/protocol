// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "hardhat/console.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

import "./interfaces/IDarkOracle.sol";
import "./interfaces/IVault.sol";

contract Trading {

	// All amounts are stored with 8 decimals

	// Structs

	struct Product {
		// 32 bytes
		address feed; // Chainlink (and DO) feed. 20 bytes
		uint64 maxLeverage; // 8 bytes
		uint16 fee; // In bps. 0.5% = 50. 2 bytes
		bool isActive; // 1 byte
		bool doActive; // 1 byte, dark oracle active
		// 32 bytes
		uint48 maxExposure; // Maximum allowed long/short imbalance. 6 bytes
		uint48 openInterestLong; // 6 bytes
		uint48 openInterestShort; // 6 bytes
		uint16 doMaxDeviation; // 2 bytes, max price deviation tolerated for dark oracle vs chainlink, in bps
		uint16 interest; // For 360 days, in bps. 5.35% = 535. 2 bytes
		uint32 settlementTime; // In seconds. 4 bytes
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

	// Variables

	address public owner; // Contract owner

	address public vault;
	address public staking;
	address public treasury;
	address public darkOracle;


	uint256 public MIN_MARGIN = 100000; // 0.001 ETH - should be configurable
	uint256 public DARK_ORACLE_STALE_PERIOD = 30 * 60; // 30 min - should be configurable

	uint256 public nextPositionId; // Incremental

	mapping(uint256 => Product) private products;
	mapping(uint256 => Position) private positions;

	uint256[] public pnlShares; // in bps [7000, 2000, 1000] = 70% to vault, 20% to staking, 10% to treasury

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
	event ProductAdded(
		uint256 productId, 
		Product product
	);
	event ProductUpdated(
		uint256 productId, 
		Product product
	);
	event OwnerUpdated(
		address newOwner
	);

	// Constructor

	constructor() {
		owner = msg.sender;
	}

	// Methods

	// Opens position with margin = msg.value
	function openPosition(
		uint256 productId,
		bool isLong,
		uint256 leverage
	) external payable {

		uint256 margin = msg.value / 10**10; // truncate to 8 decimals

		// Check params
		require(margin >= MIN_MARGIN, "!margin");
		require(leverage >= 1 * 10**8, "!leverage");

		// Check product
		Product storage product = products[productId];
		require(product.isActive, "!product-active");
		require(leverage <= uint256(product.maxLeverage), "!max-leverage");

		// Check exposure
		uint256 amount = margin * leverage / 10**8;

		if (isLong) {
			product.openInterestLong += uint48(amount);
			require(
				uint256(product.openInterestLong) <= 
				uint256(product.maxExposure) + uint256(product.openInterestShort)
			, "!exposure-long");
		} else {
			product.openInterestShort += uint48(amount);
			require(
				uint256(product.openInterestShort) <= 
				uint256(product.maxExposure) + uint256(product.openInterestLong)
			, "!exposure-short");
		}

		uint256 price = _getPriceWithFee(productId, isLong);
		
		address user = msg.sender;

		nextPositionId++;
		positions[nextPositionId] = Position({
			owner: user,
			productId: uint64(productId),
			margin: uint64(margin),
			leverage: uint64(leverage),
			price: uint64(price),
			timestamp: uint88(block.timestamp),
			isLong: isLong
		});
		
		emit NewPosition(
			nextPositionId,
			user,
			productId,
			isLong,
			price,
			margin,
			leverage
		);

	}

	// Add margin = msg.value to Position with id = positionId
	function addMargin(uint256 positionId) external payable {

		uint256 margin = msg.value / 10**10; // truncate to 8 decimals

		// Check params
		require(margin >= MIN_MARGIN, "!margin");

		// Check position
		Position storage position = positions[positionId];
		require(msg.sender == position.owner, "!owner");

		// New position params
		uint256 newMargin = uint256(position.margin) + margin;
		uint256 newLeverage = uint256(position.leverage) * uint256(position.margin) / newMargin;
		require(newLeverage >= 1 * 10**8, "!low-leverage");

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

	// Closes margin from Position with id = positionId
	function closePosition(
		uint256 positionId, 
		uint256 margin,
		bool releaseMargin
	) external {

		// Check params
		require(margin >= MIN_MARGIN, "!margin");

		// Check position
		Position storage position = positions[positionId];
		require(msg.sender == position.owner, "!owner");

		// Check product
		Product storage product = products[uint256(position.productId)];
		require(
			block.timestamp >= uint256(position.timestamp) + uint256(product.minTradeDuration)
		, "!duration");
		
		bool isFullClose;
		if (margin >= uint256(position.margin)) {
			margin = uint256(position.margin);
			isFullClose = true;
		}

		uint256 price = _getPriceWithFee(position.productId);

		uint256 pnl;
		bool pnlIsNegative;

		bool isLiquidatable = _checkLiquidation(position, uint256(product.liquidationThreshold), 0);

		if (isLiquidatable) {
			margin = uint256(position.margin);
			pnl = uint256(position.margin);
			pnlIsNegative = true;
			isFullClose = true;
		} else {
			
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
			uint256 interest = _calculateInterest(margin * uint256(position.leverage) / 10**8, uint256(position.timestamp), uint256(product.interest));
			if (pnlIsNegative) {
				pnl += interest;
			} else if (pnl < interest) {
				pnl = interest - pnl;
				pnlIsNegative = true;
			} else {
				pnl -= interest;
			}

		}

		// Checkpoint vault
		IVault(vault).checkpoint();

		// Update vault

		if (pnlIsNegative) {
			_splitSend(pnl);
			if (pnl < margin) payable(position.owner).transfer((margin - pnl) * 10**10);
		} else {
			
			if (releaseMargin) {
				// When there's not enough funds in the vault, user can choose to receive their margin without profit
				pnl = 0;
			}
			
			IVault(vault).pay(position.owner, pnl); // pay P/L from vault, checks max drawdown etc.
			payable(position.owner).transfer(margin * 10**10); // pay margin from this contract
			
		}

		if (position.isLong) {
			if (uint256(product.openInterestLong) >= margin * uint256(position.leverage) / 10**8) {
				product.openInterestLong -= uint48(margin * uint256(position.leverage) / 10**8);
			} else {
				product.openInterestLong = 0;
			}
		} else {
			if (uint256(product.openInterestShort) >= margin * uint256(position.leverage) / 10**8) {
				product.openInterestShort -= uint48(margin * uint256(position.leverage) / 10**8);
			} else {
				product.openInterestShort = 0;
			}
		}

		emit ClosePosition(
			positionId, 
			position.owner, 
			uint256(position.productId), 
			isFullClose,
			price, 
			uint256(position.price),
			margin, 
			uint256(position.leverage), 
			pnl, 
			pnlIsNegative, 
			isLiquidatable
		);

		if (isFullClose) {
			delete positions[positionId];
		} else {
			position.margin -= uint64(margin);
		}

	}

	// Liquidate positionIds
	function liquidatePositions(uint256[] calldata positionIds) external {

		address liquidator = msg.sender;
		uint256 length = positionIds.length;
		uint256 totalVaultReward;
		uint256 totalLiquidatorReward;

		for (uint256 i = 0; i < length; i++) {

			uint256 positionId = positionIds[i];
			Position memory position = positions[positionId];
			
			if (position.productId == 0 || position.isSettling) {
				continue;
			}

			Product storage product = products[uint256(position.productId)];

			// Liquidations can only happen at the chainlink price, avoiding dark oracle liquidations
			uint256 price = getLatestPrice(position.productId, true);

			if (_checkLiquidation(position, uint256(product.liquidationThreshold), price)) {

				uint256 vaultReward = uint256(position.margin) * (10**4 - uint256(product.liquidationBounty)) / 10**4;
				totalVaultReward += uint96(vaultReward);

				uint256 liquidatorReward = uint256(position.margin) - vaultReward;
				totalLiquidatorReward += liquidatorReward;

				uint256 amount = uint256(position.margin) * uint256(position.leverage) / 10**8;

				if (position.isLong) {
					if (uint256(product.openInterestLong) >= amount) {
						product.openInterestLong -= uint48(amount);
					} else {
						product.openInterestLong = 0;
					}
				} else {
					if (uint256(product.openInterestShort) >= amount) {
						product.openInterestShort -= uint48(amount);
					} else {
						product.openInterestShort = 0;
					}
				}

				emit ClosePosition(
					positionId, 
					position.owner, 
					uint256(position.productId), 
					true,
					price, 
					uint256(position.price),
					uint256(position.margin), 
					uint256(position.leverage), 
					uint256(position.margin),
					true,
					true
				);

				delete positions[positionId];

				emit PositionLiquidated(
					positionId, 
					liquidator, 
					uint256(vaultReward), 
					uint256(liquidatorReward)
				);

			}

		}

		if (totalVaultReward > 0) {
			_splitSend(totalVaultReward);
		}

		if (totalLiquidatorReward > 0) {
			payable(liquidator).transfer(totalLiquidatorReward * 10**10);
		}

	}

	// Sends ETH to the different contract receipients: vault, CAP staking, treasury
	function _splitSend(uint256 amount) internal {
		if (amount == 0) return;
		if (pnlShares[0] > 0) {
			IVault(vault).receive{amount * pnlShares[0] * 10**6}(); // transfers pnl and there updates balance etc. pnlShareVault in bps
		}
		if (pnlShares[1] > 0) {
			IStaking(staking).receive{amount * pnlShares[1] * 10**6}(); // transfers pnl and there updates balance etc.
		}
		if (pnlShares[2] > 0) {
			ITreasury(treasury).receive{amount * pnlShares[2] * 10**6}(); // transfers pnl and there updates balance etc.
		}
	}

	function _getPriceWithFee(
		uint256 productId, 
		bool isLong,
	) internal returns(uint256) {
		uint256 price = getLatestPrice(productId);
		if (isLong) {
			return price + price * fee / 10**4;
		} else {
			return price - price * fee / 10**4;
		}
	}

	function getLatestPrice(uint256 productId, bool useChainlink) public view returns (uint256) {

		Product memory product = products[productId];
		require(product.feed != address(0), '!feed-error');

		// Get chainlink price

		(
			uint80 roundID, 
            int price,
            uint startedAt,
            uint timeStamp,
            uint80 answeredInRound
		) = AggregatorV3Interface(product.feed).latestRoundData();

		require(price > 0, '!price');
		require(timeStamp > 0, '!timeStamp');

		uint8 decimals = AggregatorV3Interface(product.feed).decimals();

		uint256 chainLinkPrice;
		if (decimals != 8) {
			chainLinkPrice = uint256(price) * (10**8) / (10**uint256(decimals));
		} else {
			chainLinkPrice = uint256(price);
		}

		if (useChainlink) {
			return chainLinkPrice;
		}

		if (product.doActive) {
			// Dark oracle active

			// TODO: pay DO from Treasury

			(
				uint256 doPrice, 
				uint256 doTimestamp
			) = IDarkOracle(darkOracle).getLatestData(product.feed);

			// If it's too old / too different, use chainlink
			if (
				doPrice == 0 ||
				doTimestamp < block.timestamp - DARK_ORACLE_STALE_PERIOD ||
				doPrice > chainLinkPrice + chainLinkPrice * product.doMaxDeviation / 10**4 ||
				doPrice < chainLinkPrice - chainLinkPrice * product.doMaxDeviation / 10**4
			) {
				return chainLinkPrice;
			}

			return doPrice;

		} else {
			return chainLinkPrice;
		}

	}

	function _calculateInterest(uint256 amount, uint256 timestamp, uint256 interest) internal view returns (uint256) {
		if (block.timestamp < timestamp + 900) return 0;
		return amount * interest * (block.timestamp - timestamp) / (10**4 * 360 days);
	}

	function _checkLiquidation(
		Position memory position, 
		uint256 liquidationThreshold,
		uint256 price
	) internal pure returns (bool) {

		if (price == 0) {
			price = getLatestPrice(position.productId, true);
		}
		
		uint256 liquidationPrice;
		
		if (position.isLong) {
			liquidationPrice = position.price - position.price * liquidationThreshold * 10**4 / uint256(position.leverage);
		} else {
			liquidationPrice = position.price + position.price * liquidationThreshold * 10**4 / uint256(position.leverage);
		}

		if (position.isLong && price <= liquidationPrice || !position.isLong && price >= liquidationPrice) {
			return true;
		} else {
			return false;
		}

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

	// Governance methods

	// TODO: extra product attributes

	function addProduct(uint256 productId, Product memory _product) external onlyOwner {

		Product memory product = products[productId];
		require(product.maxLeverage == 0, "!product-exists");

		require(_product.maxLeverage > 0, "!max-leverage");
		require(_product.feed != address(0), "!feed");
		require(_product.settlementTime > 0, "!settlementTime");
		require(_product.liquidationThreshold > 0, "!liquidationThreshold");

		products[productId] = Product({
			feed: _product.feed,
			maxLeverage: _product.maxLeverage,
			fee: _product.fee,
			isActive: true,
			maxExposure: _product.maxExposure,
			openInterestLong: 0,
			openInterestShort: 0,
			interest: _product.interest,
			settlementTime: _product.settlementTime,
			minTradeDuration: _product.minTradeDuration,
			liquidationThreshold: _product.liquidationThreshold,
			liquidationBounty: _product.liquidationBounty
		});

		emit ProductAdded(productId, products[productId]);

	}

	function updateProduct(uint256 productId, Product memory _product) external onlyOwner {

		Product storage product = products[productId];
		require(product.maxLeverage > 0, "!product-exists");

		require(_product.maxLeverage >= 1 * 10**8, "!max-leverage");
		require(_product.feed != address(0), "!feed");
		require(_product.settlementTime > 0, "!settlementTime");
		require(_product.liquidationThreshold > 0, "!liquidationThreshold");

		product.feed = _product.feed;
		product.maxLeverage = _product.maxLeverage;
		product.fee = _product.fee;
		product.isActive = _product.isActive;
		product.maxExposure = _product.maxExposure;
		product.interest = _product.interest;
		product.settlementTime = _product.settlementTime;
		product.minTradeDuration = _product.minTradeDuration;
		product.liquidationThreshold = _product.liquidationThreshold;
		product.liquidationBounty = _product.liquidationBounty;
		
		emit ProductUpdated(productId, product);
	
	}

	function setOwner(address newOwner) external onlyOwner {
		owner = newOwner;
		emit OwnerUpdated(newOwner);
	}

	modifier onlyOwner() {
		require(msg.sender == owner, "!owner");
		_;
	}

}