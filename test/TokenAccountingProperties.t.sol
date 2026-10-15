// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LaunchToken} from "src/LaunchToken.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

contract TokenAccountingPropertiesTest is Test {
    LaunchToken private token;
    address private alice;
    address private bob;

    function setUp() public {
        token = new LaunchToken();
        alice = makeAddr("token property alice");
        bob = makeAddr("token property bob");
    }

    /// forge-config: default.fuzz.runs = 512
    function testFuzzTransferRoundTripConservesEntireSupply(uint256 rawAmount) public {
        uint256 supply = token.totalSupply();
        uint256 amount = bound(rawAmount, 0, supply);
        assertTrue(token.transfer(alice, amount));
        vm.prank(alice);
        assertTrue(token.transfer(address(this), amount));
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(address(this)), supply);
        assertEq(token.totalSupply(), supply);
    }

    function testZeroSelfAndFullSupplyTransfersDoNotMintBurnOrChargeFees() public {
        uint256 supply = token.totalSupply();
        token.transfer(alice, 0);
        token.transfer(address(this), supply);
        assertEq(token.balanceOf(address(this)), supply);
        token.transfer(alice, supply);
        assertEq(token.balanceOf(address(this)), 0);
        assertEq(token.balanceOf(alice), supply);
        vm.prank(alice);
        token.transfer(alice, supply);
        assertEq(token.balanceOf(alice), supply);
        assertEq(token.totalSupply(), supply);
    }

    function testTransferToZeroAndOverspendingRevertWithoutChangingSupply() public {
        uint256 supply = token.totalSupply();
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientBalance.selector, address(this), supply, supply + 1
            )
        );
        token.transfer(alice, supply + 1);
        assertEq(token.balanceOf(address(this)), supply);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(address(0)), 0);
        assertEq(token.totalSupply(), supply);
    }

    /// forge-config: default.fuzz.runs = 512
    function testFuzzFiniteAllowanceIsExactAndCannotBeOverspent(uint256 rawAmount) public {
        uint256 amount = bound(rawAmount, 0, token.totalSupply());
        token.approve(alice, amount);
        vm.prank(alice);
        token.transferFrom(address(this), bob, amount);
        assertEq(token.allowance(address(this), alice), 0);
        assertEq(token.balanceOf(bob), amount);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, alice, 0, 1));
        token.transferFrom(address(this), bob, 1);
        assertEq(token.balanceOf(bob), amount);
        assertEq(token.balanceOf(address(this)) + token.balanceOf(bob), token.totalSupply());
    }

    function testInfiniteAllowancePersistsAndAnOwnerCanRevokeIt() public {
        token.approve(alice, type(uint256).max);
        vm.prank(alice);
        token.transferFrom(address(this), bob, 1 ether);
        assertEq(token.allowance(address(this), alice), type(uint256).max);
        token.approve(alice, 0);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, alice, 0, 1));
        token.transferFrom(address(this), bob, 1);
        assertEq(token.balanceOf(bob), 1 ether);
    }

    function testBalanceFailureRestoresAllowanceConsumedBeforeTransfer() public {
        token.transfer(alice, 7);
        vm.prank(alice);
        token.approve(bob, 8);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 7, 8));
        token.transferFrom(alice, address(this), 8);
        assertEq(token.allowance(alice, bob), 8);
        assertEq(token.balanceOf(alice), 7);
    }
}
