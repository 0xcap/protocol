const { ethers } = require("hardhat");
const { expect } = require("chai");

const { parseUnits, formatUnits } = require('./utils.js');

const VAULTS = [
	{
		id: 1,
		label: 'USDC1',
		cap: parseUnits(100000),
		maxOpenInterest: parseUnits(500000),
		maxDailyDrawdown: 10 * 100, // 10%
		stakingPeriod: 30 * 24 * 3600,
		redemptionPeriod: 8 * 3600
	},
	{
		id: 2,
		label: 'USDC2',
		cap: parseUnits(200000),
		maxOpenInterest: parseUnits(2500000),
		maxDailyDrawdown: 15 * 100, // 10%
		stakingPeriod: 30 * 24 * 3600,
		redemptionPeriod: 8 * 3600
	}
];

const PRODUCTS = [
	{
		id: 1,
		label: 'BTC-USD',
		leverage: parseUnits(50),
		fee: 0.5 * 100, // 0.5%
		interest: 5 * 100, // 5%
		feed: "0xF4030086522a5bEEa4988F8cA5B36dbC97BeE88c", // chainlink
		settlementTime: 3 * 60,
		minTradeDuration: 15 * 60,
		liquidationThreshold: 80 * 100, // 80%
		liquidationBounty: 5 * 100
	},
	{
		id: 2,
		label: 'ETH-USD',
		leverage: parseUnits(25),
		fee: 0.5 * 100,
		interest: 8 * 100,
		feed: "0x5f4ec3df9cbd43714fe2740f5e3616155c5b8419",
		settlementTime: 3 * 60,
		minTradeDuration: 15 * 60,
		liquidationThreshold: 80 * 100, // 80%
		liquidationBounty: 5 * 100
	},
];


let currentPositionId = 0;
const starting_balance = parseUnits(10000);

function _calculatePriceWithFee(price, isLong) {
	if (isLong) {
		return Math.round(price * (1 + PRODUCTS[1].fee/10000));
	} else {
		return Math.round(price * (1 - PRODUCTS[1].fee/10000));
	}	
}

describe("Trading", () => {

	let Trading, Bases = [], addrs = [], owner;

	before(async () => {

		addrs = await ethers.getSigners();
		addrs = addrs.slice(0,3); // keep first 3
		owner = addrs[0];

		const TradingContract = await ethers.getContractFactory("Trading");
		Trading = await TradingContract.deploy();

		const BaseTokenContract = await ethers.getContractFactory("USDCMock");
		Bases[1] = await BaseTokenContract.deploy();
		Bases[2] = await BaseTokenContract.deploy();

		// add vaults
		for (const v of VAULTS) {

			await Trading.addVault(v.id, Bases[v.id].address, v.cap, v.maxOpenInterest, v.maxDailyDrawdown, v.stakingPeriod, v.redemptionPeriod, 0);

			// mint & approve bases
			for (const addr of addrs) {
				Bases[v.id].mint(addr.address, starting_balance);
				Bases[v.id].connect(addr).approve(Trading.address, starting_balance);
			}

		}

		// add products
		for (const p of PRODUCTS) {
			await Trading.addProduct(p.id, p.leverage, p.fee, p.interest, p.feed, p.settlementTime, p.minTradeDuration, p.liquidationThreshold, p.liquidationBounty);
		}

	});

	it("Owner should be set", async () => {
		expect(await Trading.owner()).to.equal(owner.address);
	});

	it("Base balances should be set", async () => {
		for (const v of VAULTS) {
			for (const addr of addrs) {
				const balance = await Bases[v.id].balanceOf(addr.address);
				expect(balance).to.equal(starting_balance);
			}
		}
	});

	it("Should fail setting owner from other address", async () => {
		await expect(Trading.connect(addrs[1]).setOwner(addrs[1].address)).to.be.revertedWith('!O');
	});

	it("Should set owner", async () => {
		expect(await Trading.setOwner(addrs[1].address)).to.emit(Trading, "OwnerUpdated").withArgs(addrs[1].address);
	});

	it("Action to change token balance", async () => {
		// token.transfer(walletTo.address, 200)).to.changeTokenBalances(token, [wallet, walletTo], [-200, 200]);
		// token.transferFrom(wallet.address, walletTo.address, 200)).to.changeTokenBalance(token, walletTo, 200);
	});

	describe("submitOrder", () => {

		describe("openPosition", () => {

			// Successes

			let amountSum = 0;
			let userPositionIndexes = {1: 0, 2: 0};

			[
				{vaultId: 1, productId: 1, isLong: true, margin: parseUnits(100), leverage: parseUnits(50), userId: 1},
				{vaultId: 1, productId: 2, isLong: false, margin: parseUnits(200), leverage: parseUnits(25), userId: 2},
				{vaultId: 1, productId: 1, isLong: true, margin: parseUnits(1200), leverage: parseUnits(12), userId: 2},
				{vaultId: 1, productId: 2, isLong: false, margin: parseUnits(111), leverage: parseUnits(22), userId: 1}
			].forEach((p) => {

				const { vaultId, productId, isLong, margin, leverage, userId } = p;

				it(`opens ${isLong ? 'long' : 'short'} on ${vaultId}:${productId}`, async () => {

					const user = addrs[userId].address;

					const balance_user = await Bases[vaultId].balanceOf(user) * 1;
					const balance_contract = await Bases[vaultId].balanceOf(Trading.address) * 1;

					const tx = Trading.connect(addrs[userId]).submitOrder(vaultId, productId, isLong, margin, leverage, 0, false);

					const priceWithFee = _calculatePriceWithFee(await Trading.getLatestPrice(productId), isLong);

					currentPositionId++;

					// Check event
					expect(await tx).to.emit(Trading, "NewPosition").withArgs(currentPositionId, user, vaultId, productId, isLong, priceWithFee, margin, leverage);

					// Check balances
					expect(await Bases[vaultId].balanceOf(user)).to.equal(balance_user - margin);
					expect(await Bases[vaultId].balanceOf(Trading.address)).to.equal(balance_contract + margin);

					// Check user positions
					const user_positions = await Trading.getUserPositions(user, vaultId);
					const position = user_positions[userPositionIndexes[userId]];
					userPositionIndexes[userId]++;

					expect(position.id).to.equal(currentPositionId);
					expect(position.vaultId).to.equal(vaultId);
					expect(position.productId).to.equal(productId);
					expect(position.owner).to.equal(user);
					expect(position.isLong).to.equal(isLong);
					expect(position.margin).to.equal(margin);
					expect(position.leverage).to.equal(leverage);
					expect(position.price).to.equal(priceWithFee);

					// Check open interest
					// get vault for this
					/*
					amountSum += parseInt(position.margin * position.leverage / 10**6);
					const oi = await Trading.getCurrentOpenInterest(baseId);
					expect(oi).to.equal(amountSum);
					*/

				});
			
			});

			// Error scenarios
			// leverage, margin, product inactive, nonexistent, base
			// pause base, lock user (as params)

			it('fails to open position with leverage too high', async () => {
				const tx = Trading.connect(addrs[1]).submitOrder(1, 1, true, parseUnits(100), parseUnits(200), 0, false);
				await expect(tx).to.be.revertedWith('!max-leverage')
			});

		});

	});

	// test user methods & settlement
	// test vault methods
	// test owner methods
	// test liquidation
	// test getters
	// for each method have a describe block testing each case (good, error cases, and events emitted, balances changed)

});
