const { ethers } = require("hardhat");
const { expect } = require("chai");

describe("Trading", () => {

	let Trading, owner, addr1, addr2;

	before(async () => {
		[owner, addr1, addr2] = await ethers.getSigners();
		const TradingContract = await ethers.getContractFactory("Trading");
		Trading = await TradingContract.deploy();
	});

	it("Owner should be set", async () => {
		expect(await Trading.owner()).to.equal(owner.address);
	});

	it("Should fail setting owner from other address", async () => {
		await expect(Trading.connect(addr1).setOwner(addr1.address)).to.be.revertedWith('!O');
	});

});
