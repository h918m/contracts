// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity 0.8.4;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol"; // TODO change to permit
import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";


contract psOHM is AccessControl, ERC20 {

    mapping (address => bool) public whitelist;

    constructor() ERC20("Principal sOHM", "psOHM") {}

    function decimals() public view virtual override returns (uint8) {
        return 9;
    }

    function mint(address recipient_) external onlyWhitelisted {
    }

    function setWhitelist(address addr_, bool isWhitelisted_) public {
        whitelist[addr_] = isWhitelisted_;
    }

    // TODO
    modifier onlyWhitelisted {
        if (whitelist[msg.sender]) {
            _;
        } else {
            revert();
        }
    }
}