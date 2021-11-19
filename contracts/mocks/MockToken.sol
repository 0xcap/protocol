// SPDX-License-Identifier: MIT
pragma solidity ^0.8.2;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockToken is ERC20 {

    uint8 _decimals;

    constructor(string memory name, string memory symbol, uint8 __decimals) ERC20(name, symbol) {
        _decimals = __decimals;
    }

    function decimals() public view virtual override returns (uint8) {
        if (_decimals > 0) return _decimals;
        return 18;
    }

    function mint(uint256 amount) public {
        _mint(msg.sender, amount);
    }

}