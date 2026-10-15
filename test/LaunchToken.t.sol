// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LaunchToken} from "../src/LaunchToken.sol";

contract LaunchTokenTest is Test {
    LaunchToken token;

    function setUp() public {
        token = new LaunchToken();
    }

    function testFixedSupplyMetadataAndTransfer() public {
        assertEq(token.name(), "BEG");
        assertEq(token.symbol(), "BEG");
        assertEq(token.decimals(), 18);
        assertEq(token.totalSupply(), 1_000_000_000 ether);
        assertEq(token.balanceOf(address(this)), token.totalSupply());
        address recipient = makeAddr("recipient");
        token.transfer(recipient, 500 ether);
        assertEq(token.balanceOf(recipient), 500 ether);
        assertEq(token.balanceOf(address(this)), token.totalSupply() - 500 ether);
    }

    function testAllowanceTransferAndInsufficientBalance() public {
        address spender = makeAddr("spender");
        address recipient = makeAddr("recipient");
        token.approve(spender, 42 ether);
        vm.prank(spender);
        token.transferFrom(address(this), recipient, 42 ether);
        assertEq(token.allowance(address(this), spender), 0);
        assertEq(token.balanceOf(recipient), 42 ether);
        vm.prank(spender);
        vm.expectRevert();
        token.transferFrom(address(this), recipient, 1);
        vm.prank(recipient);
        vm.expectRevert();
        token.transfer(spender, 43 ether);
    }

    function testNoMintOrAdmin() public {
        bytes4[6] memory selectors = [
            bytes4(keccak256("mint(address,uint256)")),
            bytes4(keccak256("owner()")),
            bytes4(keccak256("pause()")),
            bytes4(keccak256("upgradeTo(address)")),
            bytes4(keccak256("setMinter(address)")),
            bytes4(keccak256("initialize(address)"))
        ];
        for (uint256 i; i < selectors.length; ++i) {
            (bool ok,) = address(token).call(abi.encodeWithSelector(selectors[i], address(this), 1 ether));
            assertFalse(ok);
        }
        assertEq(token.totalSupply(), 1_000_000_000 ether);
    }
}
