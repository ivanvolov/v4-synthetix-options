// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "forge-std/console.sol";

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {OptionBaseLib} from "@src/libraries/OptionBaseLib.sol";
import {IWETH} from "@forks/IWETH.sol";

contract SynthetixPerpHelper is ERC20 {
    // We need this to do atomic operation in synthetix perp trading
    // So we need to implement this here properly and clean up the code

    IWETH WETH = IWETH(OptionBaseLib.WETH);

    constructor() ERC20("PowerToken", "PW") {}

    function shortAmount() public pure returns (uint256) {
        return 100;
    }

    function collateralAmount() public pure returns (uint256) {
        return 10000;
    }

    function burn(uint256 amountToken, uint256 amountCollateral) public {
        _burn(msg.sender, amountToken);
        WETH.transfer(msg.sender, amountCollateral);
    }

    function deposit(uint256 amountCollateral) public {
        WETH.transferFrom(msg.sender, address(this), amountCollateral);
    }

    function mint(uint256 amount) public {
        _mint(msg.sender, amount);
    }
}
