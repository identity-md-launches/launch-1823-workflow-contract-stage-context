// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BegVault} from "../src/BegVault.sol";
import {BegVaultBase} from "./BegVaultBase.sol";

/// @notice The brief: "No owner, no admin, no pause ... Payouts come from the Vault." Nothing but a
///         roll, a refund or a revealer bounty may ever move the prize pool or the ETH banks, however
///         long the oracle stays silent, and the game can never be closed.
contract NoDeadManPathTest is BegVaultBase {
    function _assertNothingSwept(uint256 pool) private view {
        (uint128 teamTokens, uint128 teamEth) = vault.claimable(TEAM);
        assertEq(teamTokens, 0, "prize pool credited to the team outside of a roll");
        assertEq(teamEth, 0, "ETH credited to the team outside of a grade");
        assertEq(vault.vaultFreeBalance(), pool, "free prize pool changed without a roll");
        assertEq(vault.totalClaimableTokens(), 0);
    }

    function _noRetireFunction() private {
        (bool ok,) = address(vault).call(abi.encodeWithSignature("retire()"));
        assertFalse(ok, "a retire() entry point exists");
    }

    function testUnfundedOpenExpiryAndAQuietMonthMoveNothingAndNeverPauseTheGame() public {
        uint256 pool = vault.vaultFreeBalance();
        assertEq(pool, 800_000_000 ether);
        _attempt(_player(1), "Please, swarm, a single crumb");
        // The fee now exceeds the IMD budget: the batch cannot close and expires on the Open path.
        intake.setPrice(101 ether);
        vm.warp(vm.getBlockTimestamp() + 30 minutes);
        vm.expectRevert(BegVault.OracleUnfunded.selector);
        vault.closeBatch();
        vm.warp(vm.getBlockTimestamp() + 24 hours);
        vault.expireBatch(1);
        vm.prank(_player(1));
        vault.refund(1);

        vm.warp(vm.getBlockTimestamp() + 30 days);
        _noRetireFunction();
        _assertNothingSwept(pool);

        // The game goes on at full strength once a fee can be paid again.
        intake.setPrice(0.5 ether);
        uint256 batchId = _batch(2);
        _grade(batchId, 100);
        _reveal(batchId, keccak256("after a quiet month"));
        assertEq(uint256(vault.getBatch(batchId).status), uint256(BegVault.Status.Revealed));
        assertEq(vault.vaultFreeBalance() + vault.totalClaimableTokens(), pool);
        (uint128 teamTokens, uint128 teamEth) = vault.claimable(TEAM);
        assertEq(teamTokens, 0);
        assertEq(teamEth, 2 * PRICE / 10, "the team only ever earns its tenth of a graded escrow");
        _assertSolvent();
    }

    function testPaidButUnansweredExpiryAndAQuietMonthMoveNothing() public {
        uint256 pool = vault.vaultFreeBalance();
        _batch(1);
        vm.warp(vm.getBlockTimestamp() + 24 hours);
        vault.expireBatch(1);
        vm.prank(_player(1));
        vault.refund(1);
        vm.warp(vm.getBlockTimestamp() + 30 days);
        _noRetireFunction();
        _assertNothingSwept(pool);

        // A batch graded after the quiet month rolls against the whole pool and keeps its bank.
        uint256 batchId = _batch(20);
        _grade(batchId, 100);
        assertEq(vault.jackpotBank(), 0.089 ether);
        _noRetireFunction();
        assertEq(vault.jackpotBank(), 0.089 ether);
        assertEq(vault.vaultFreeBalance(), pool);
        _reveal(batchId, keccak256("full table"));
        assertGt(vault.totalClaimableTokens(), 0, "players rolled against an empty pool");
        _assertSolvent();
    }
}
