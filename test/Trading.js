const { ethers } = require("hardhat");
const { expect } = require("chai");

const { parseUnits, formatUnits } = require('./utils.js');

const BASES = [
	{
		id: 1,
		label: 'USDC'
	},
	{
		id: 2,
		label: 'USDC2'
	}
];

const PRODUCTS = [
	{
		id: 1,
		label: 'BTC-USD',
		leverage: 50,
		fee: 50, // 0.5%
		interest: 500, // 5%
		feed: "0xF4030086522a5bEEa4988F8cA5B36dbC97BeE88c" // chainlink
	},
	{
		id: 2,
		label: 'ETH-USD',
		leverage: 25,
		fee: 50,
		interest: 800,
		feed: "0x5f4ec3df9cbd43714fe2740f5e3616155c5b8419"
	},
];

const DATA = {
	vault_cap: 100000,
	vault_max_open_interest: 500000,
	address_balance: 10000
}

let currentPositionId = 0;

function _calculatePriceWithFee(price, isLong) {
	if (isLong) {
		return Math.round(price * (1 + PRODUCTS[1].fee/10000));
	} else {
		return Math.round(price * (1 - PRODUCTS[1].fee/10000));
	}	
}

describe("Trading", () => {

	let Trading, TradingA1, TradingA2, Base = [], addrs = [], owner;

	before(async () => {

		addrs = await ethers.getSigners();
		addrs = addrs.slice(0,3); // keep first 3
		owner = addrs[0];

		const TradingContract = await ethers.getContractFactory("Trading");
		Trading = await TradingContract.deploy();

		TradingA1 = Trading.connect(addrs[1]);
		TradingA2 = Trading.connect(addrs[2]);

		const BaseTokenContract = await ethers.getContractFactory("USDCMock");
		Base[1] = await BaseTokenContract.deploy();
		Base[2] = await BaseTokenContract.deploy();

		// add bases
		for (const b of BASES) {
			await Trading.addBase(b.id, Base[b.id].address);
			await Trading.setCap(b.id, parseUnits(DATA.vault_cap));
			await Trading.setMaxOpenInterest(b.id, parseUnits(DATA.vault_max_open_interest));
			// mint & approve bases
			for (const addr of addrs) {
				Base[b.id].mint(addr.address, parseUnits(DATA.address_balance));
				Base[b.id].connect(addr).approve(Trading.address, parseUnits(DATA.address_balance));
			}
			// set max open interest

		}

		// add products
		for (const p of PRODUCTS) {
			await Trading.addProduct(p.id, parseUnits(p.leverage), p.fee, p.interest, p.feed);
		}

	});

	it("Owner should be set", async () => {
		expect(await Trading.owner()).to.equal(owner.address);
	});

	it("Base balances should be set", async () => {
		for (const b of BASES) {
			for (const addr of addrs) {
				const balance = formatUnits(await Base[b.id].balanceOf(addr.address));
				expect(balance).to.equal(DATA.address_balance);
			}
		}
	});

	it("Should fail setting owner from other address", async () => {
		await expect(TradingA1.setOwner(addrs[1].address)).to.be.revertedWith('!O');
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

			let amountSum = 0;
			
			[
				{baseId: 1, productId: 1, isLong: true, margin: parseUnits(100), leverage: parseUnits(50), userId: 1},
				{baseId: 1, productId: 2, isLong: false, margin: parseUnits(200), leverage: parseUnits(25), userId: 1},
			].forEach((p, i) => {

				const { baseId, productId, isLong, margin, leverage, userId } = p;

				it(`opens ${isLong ? 'long' : 'short'} on ${baseId}:${productId}`, async () => {

					const user = addrs[userId].address;

					const balance_user = await Base[baseId].balanceOf(user) * 1;
					const balance_contract = await Base[baseId].balanceOf(Trading.address) * 1;
					
					const priceWithFee = _calculatePriceWithFee(await Trading.getLatestPrice(productId), isLong);

					currentPositionId++;

					const tx = await TradingA1.submitOrder(baseId, productId, isLong, 0, margin, leverage, false);

					// Check event
					expect(tx).to.emit(Trading, "NewPosition").withArgs(currentPositionId, user, baseId, productId, isLong, priceWithFee, margin, leverage);

					// Check balances
					expect(await Base[baseId].balanceOf(user)).to.equal(balance_user - margin);
					expect(await Base[baseId].balanceOf(Trading.address)).to.equal(balance_contract + margin);

					// Check user positions
					const user_positions = await Trading.getUserPositions(user, baseId);
					const position = user_positions[i];

					expect(position.id).to.equal(currentPositionId);
					expect(position.baseId).to.equal(baseId);
					expect(position.productId).to.equal(productId);
					expect(position.owner).to.equal(user);
					expect(position.isLong).to.equal(isLong);
					expect(position.margin).to.equal(margin);
					expect(position.leverage).to.equal(leverage);
					expect(position.price).to.equal(priceWithFee);

					let liquidationPrice;
					if (isLong) {
						liquidationPrice = (priceWithFee - priceWithFee * 80 / 100 / leverage);
					} else {
						liquidationPrice = (priceWithFee + priceWithFee * 80 / 100 / leverage);
					}

					expect(position.liquidationPrice).to.equal(liquidationPrice);

					// Check open interest
					amountSum += parseInt(position.margin * position.leverage / 10**6);
					const oi = await Trading.getCurrentOpenInterest(baseId);
					expect(oi).to.equal(amountSum);

				});
			
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
