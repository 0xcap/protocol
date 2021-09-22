// SPDX-License-Identifier: MIT
pragma solidity ^0.8.2;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract CapLiquidityPoolToken is ERC20 {

    address public staking;
    
    constructor() ERC20("Cap Liquidity Pool", "CLP") {
    }

    function mint(address to, uint256 amount) public onlyStaking {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) public onlyStaking {
        _burn(from, amount);
    }

    modifier onlyStaking() {
        require(msg.sender == staking, "!staking");
        _;
    }

}
