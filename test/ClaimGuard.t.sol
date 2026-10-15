// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BegVaultBase} from "./BegVaultBase.sol";
import {BegVault} from "src/BegVault.sol";
import {OracleAttestation} from "src/OracleAttestation.sol";

/// @dev Probes CEI at the actual ETH interaction, including cross-function reentry.
contract AllEntrypointsReceiver {
    BegVault public immutable vault;
    bool public observedClearedCredit;
    uint256 public guardedCalls;
    bytes public secondClaimResult;

    constructor(BegVault vault_) {
        vault = vault_;
    }

    function enter(string calldata message) external payable {
        vault.attempt{value: msg.value}(message);
    }

    function refund(uint256 id) external {
        vault.refund(id);
    }

    function collectAndRetry() external {
        vault.claim();
        (bool ok, bytes memory result) = address(vault).call(abi.encodeCall(vault.claim, ()));
        require(!ok, "second claim unexpectedly paid");
        secondClaimResult = result;
    }

    receive() external payable {
        (uint128 tokens, uint128 eth) = vault.claimable(address(this));
        observedClearedCredit = tokens == 0 && eth == 0;
        bytes[] memory calls = new bytes[](10);
        calls[0] = abi.encodeCall(vault.attempt, ("reentrant submission"));
        calls[1] = abi.encodeWithSignature("closeBatch()");
        OracleAttestation.Attestation memory a;
        calls[2] = abi.encodeCall(vault.onOracleResult, (bytes32(0), a, bytes("")));
        calls[3] = abi.encodeCall(vault.expireBatch, (uint256(1)));
        calls[4] = abi.encodeCall(vault.refund, (uint256(1)));
        calls[5] = abi.encodeCall(vault.reveal, (uint256(1)));
        calls[6] = abi.encodeCall(vault.claim, ());
        calls[7] = abi.encodeWithSignature("fundOracle(uint256)", uint256(0));
        calls[8] = abi.encodeWithSignature("fundOracle()");
        calls[9] = abi.encodeWithSignature("closeBatch(uint256)", uint256(1));
        bytes32 expected = keccak256(abi.encodeWithSignature("ReentrancyGuardReentrantCall()"));
        for (uint256 i; i < calls.length; ++i) {
            (bool ok, bytes memory result) = address(vault).call(calls[i]);
            require(!ok && keccak256(result) == expected, "mutation bypassed the shared reentrancy guard");
            ++guardedCalls;
        }
    }
}

contract ClaimGuardTest is BegVaultBase {
    function testClaimClearsCreditsBeforeETHInteractionAndGuardsEveryMutation() public {
        AllEntrypointsReceiver receiver = new AllEntrypointsReceiver(vault);
        receiver.enter{value: PRICE}("A contract may beg, but may not reenter the vault");
        vm.warp(vm.getBlockTimestamp() + 30 minutes);
        vault.closeBatch();
        _grade(1, 100);
        _reveal(1, _jackpotHash());
        (uint128 tokens, uint128 eth) = vault.claimable(address(receiver));
        assertGt(tokens, 0);
        assertGt(eth, 0);
        uint256 freeBefore = vault.vaultFreeBalance();
        receiver.collectAndRetry();
        assertTrue(receiver.observedClearedCredit());
        assertEq(receiver.guardedCalls(), 10);
        assertEq(receiver.secondClaimResult(), abi.encodeWithSelector(BegVault.NothingToClaim.selector));
        assertEq(token.balanceOf(address(receiver)), tokens);
        assertEq(address(receiver).balance, eth);
        assertEq(vault.vaultFreeBalance(), freeBefore);
        assertFalse(vault.usedMessage(keccak256("reentrant submission")));
        // Guard must be cleared on return, including when the recipient made failed nested calls.
        receiver.enter{value: PRICE}("An ordinary later transaction is allowed");
        assertEq(vault.getAttempt(2).player, address(receiver));
        _assertSolvent();
    }

    function testRefundCreditUsesTheSameCEIAndReentrancyProtectionAsPrizes() public {
        AllEntrypointsReceiver receiver = new AllEntrypointsReceiver(vault);
        receiver.enter{value: PRICE}("An unanswered contract request remains refundable");
        vm.warp(vm.getBlockTimestamp() + 30 minutes + 24 hours);
        vault.expireBatch(1);
        receiver.refund(1);
        assertEq(address(receiver).balance, 0);
        receiver.collectAndRetry();
        assertEq(address(receiver).balance, PRICE);
        assertTrue(receiver.observedClearedCredit());
        assertEq(receiver.guardedCalls(), 10);
        assertEq(receiver.secondClaimResult(), abi.encodeWithSelector(BegVault.NothingToClaim.selector));
        assertTrue(vault.getAttempt(1).refunded);
        _assertSolvent();
    }

    function _jackpotHash() private view returns (bytes32) {
        uint256 randao = vault.getBatch(1).prevrandao;
        for (uint256 n = 1; n < 4096; ++n) {
            bytes32 hash = keccak256(abi.encode("guard test hash", n));
            bytes32 seed = keccak256(abi.encode(hash, randao, uint256(1), address(vault)));
            if (uint256(keccak256(abi.encode(seed, uint256(0)))) % 10_000 < 200) return hash;
        }
        revert("jackpot fixture search exhausted");
    }
}
