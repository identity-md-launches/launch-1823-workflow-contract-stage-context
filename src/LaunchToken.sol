// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice The factory distributes the fixed supply after deploying BegVault.
contract LaunchToken is ERC20 {
    constructor() ERC20("BEG", "BEG") {
        _mint(msg.sender, 1_000_000_000 ether);
    }
}
