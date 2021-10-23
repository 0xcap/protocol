// SPDX-License-Identifier: MIT
pragma solidity ^0.8.2;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MintableToken is ERC20 {

    address public owner;
    address public minter;

    constructor(string memory name, string memory symbol) ERC20(name, symbol) {
        owner = msg.sender;
    }

    function mint(address to, uint256 amount) public onlyMinter {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) public onlyMinter {
        _burn(from, amount);
    }

    modifier onlyMinter() {
        require(msg.sender == minter, "!minter");
        _;
    }

    function setMinter(address _minter) external {
        require(msg.sender == owner, "!owner");
        minter = _minter;
    }
}