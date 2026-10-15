// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BegVaultBase} from "./BegVaultBase.sol";
import {BegVault} from "src/BegVault.sol";
import {OracleAttestation, OracleAttestationConsumer} from "src/OracleAttestation.sol";

/// @notice Adversarial wire encodings supplement the existing independent protocol vector.
/// These tests deliberately sign malformed answers so signature rejection cannot mask decoding bugs.
contract OracleWirePropertiesTest is BegVaultBase {
    /// forge-config: default.fuzz.runs = 256
    function testFuzzMalformedSignedAnswerCannotConsumeUUIDOrReleaseEscrow(
        uint8 rawSize,
        uint8 rawFault,
        uint256 rawWord
    ) public {
        uint256 size = bound(rawSize, 1, 20);
        _batch(size);
        OracleAttestation.Attestation memory a = _attestation(1, _scores(size, 73));
        uint256 fault = rawFault % 6;
        bytes memory expectedError;
        if (fault == 0) {
            a.answer = bytes.concat(a.answer, hex"00");
            expectedError = abi.encodeWithSelector(BegVault.WrongScoreCount.selector);
        } else if (fault == 1) {
            bytes memory answer = a.answer;
            assembly ("memory-safe") { mstore(answer, sub(mload(answer), 1)) }
            expectedError = abi.encodeWithSelector(BegVault.WrongScoreCount.selector);
        } else if (fault == 2) {
            // An offset outside the buffer, including type(uint256).max, cannot name an array.
            uint256 offset = bound(rawWord, a.answer.length, type(uint256).max);
            bytes memory answer = a.answer;
            assembly ("memory-safe") { mstore(add(answer, 32), offset) }
        } else if (fault == 3) {
            // The outer byte length is right, but the array claims more elements than it contains.
            uint256 length = bound(rawWord, size + 1, type(uint256).max);
            bytes memory answer = a.answer;
            assembly ("memory-safe") { mstore(add(answer, 64), length) }
        } else if (fault == 4) {
            // Decoding succeeds for a shorter array; the explicit count check must still reject it.
            uint256 length = bound(rawWord, 0, size - 1);
            bytes memory answer = a.answer;
            assembly ("memory-safe") { mstore(add(answer, 64), length) }
            expectedError = abi.encodeWithSelector(BegVault.WrongScoreCount.selector);
        } else {
            uint8 wrongType = uint8(rawWord % 255);
            if (wrongType >= 5) ++wrongType;
            a.answerType = wrongType;
            expectedError =
                abi.encodeWithSelector(OracleAttestationConsumer.WrongAnswerType.selector, 5, wrongType);
        }
        bytes memory signature = _sign(a);
        bytes32 question = _questionId(1);
        bytes32 beforeState = _stateDigest(1);
        vm.cool(address(vault));
        (bool ok, bytes memory reason) = intake.deliver(question, a, signature);
        assertFalse(ok, "signed malformed answer was accepted");
        if (expectedError.length != 0) assertEq(reason, expectedError);
        assertEq(_stateDigest(1), beforeState, "rejection changed the batch or a liability");
        assertFalse(vault.consumed(a.requestId));
        assertEq(vault.escrowedETH(), size * PRICE);
        assertEq(vault.totalClaimableETH(), 0);
        _assertSolvent();
    }

    /// forge-config: default.fuzz.runs = 128
    function testFuzzNon65ByteSignatureCannotChangeAPendingBatch(uint8 rawLength) public {
        _batch(1);
        OracleAttestation.Attestation memory a = _attestation(1, _scores(1, 100));
        bytes memory valid = _sign(a);
        uint256 length = bound(rawLength, 0, 128);
        if (length >= 65) ++length;
        bytes memory invalid = new bytes(length);
        for (uint256 i; i < length && i < valid.length; ++i) {
            invalid[i] = valid[i];
        }
        bytes32 beforeState = _stateDigest(1);
        (bool ok, bytes memory reason) = intake.deliver(_questionId(1), a, invalid);
        assertFalse(ok);
        assertEq(reason, abi.encodeWithSelector(OracleAttestationConsumer.BadSignature.selector));
        assertFalse(vault.consumed(a.requestId));
        assertEq(_stateDigest(1), beforeState);
    }

    function testMalleatedHighSAndInvalidVSignaturesAreRejected() public {
        _batch(1);
        OracleAttestation.Attestation memory a = _attestation(1, _scores(1, 100));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER_KEY, vault.attestationDigest(a));
        uint256 curveOrder = 0xfffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141;
        bytes memory highS = abi.encodePacked(r, bytes32(curveOrder - uint256(s)), uint8(v == 27 ? 28 : 27));
        bytes32 question = _questionId(1);
        bytes32 beforeState = _stateDigest(1);
        _assertBadSignature(question, a, highS);
        _assertBadSignature(question, a, abi.encodePacked(r, s, uint8(0)));
        _assertBadSignature(question, a, abi.encodePacked(r, s, uint8(1)));
        _assertBadSignature(question, a, abi.encodePacked(r, s, uint8(29)));
        _assertBadSignature(question, a, abi.encodePacked(bytes32(0), s, v));
        _assertBadSignature(question, a, abi.encodePacked(r, bytes32(0), v));
        assertEq(_stateDigest(1), beforeState);
        assertFalse(vault.consumed(a.requestId));
        // A well-formed signature verifies; the malformed cases did not accidentally corrupt state.
        (bool ok,) = intake.deliver(question, a, abi.encodePacked(r, s, v));
        assertTrue(ok);
        assertTrue(vault.consumed(a.requestId));
    }

    /// forge-config: default.fuzz.runs = 128
    function testFuzzEveryBatchSizeAndScoreWordFitsColdCallbackStipend(uint8 rawSize, bytes32 entropy)
        public
    {
        uint256 size = bound(rawSize, 1, 20);
        _batch(size);
        bytes32[] memory scores = new bytes32[](size);
        for (uint256 i; i < size; ++i) {
            // Include zero, the clamp boundary, just above it and full uint256 values.
            uint256 choice = uint256(keccak256(abi.encode(entropy, i)));
            scores[i] = choice % 4 == 0
                ? bytes32(0)
                : choice % 4 == 1
                    ? bytes32(uint256(100))
                    : choice % 4 == 2 ? bytes32(uint256(101)) : bytes32(choice);
        }
        OracleAttestation.Attestation memory a = _attestation(1, scores);
        bytes memory signature = _sign(a);
        bytes32 question = _questionId(1);
        vm.cool(address(vault));
        (bool ok,) = intake.deliver(question, a, signature);
        assertTrue(ok, "valid answer exhausted the 200,000-gas callback");
        assertEq(uint256(vault.getBatch(1).status), uint256(BegVault.Status.Graded));
        assertTrue(vault.consumed(a.requestId));
        for (uint256 i; i < size; ++i) {
            BegVault.AttemptView memory attempt = vault.getAttempt(i + 1);
            assertEq(attempt.score, uint256(scores[i]) > 100 ? 100 : uint256(scores[i]));
            assertEq(attempt.player, _player(i + 1));
            assertEq(attempt.tokenAmount, 0, "callback must only grade, not roll prizes");
            assertEq(attempt.ethAmount, 0);
        }
        assertEq(vault.totalClaimableTokens(), 0);
        assertEq(token.balanceOf(address(vault)), 800_000_000 ether);
        assertEq(vault.escrowedETH(), 0);
        assertEq(vault.totalClaimableETH(), size * PRICE / 10);
        _assertSolvent();
    }

    function testMaximumArrayLengthWordIsRejectedWithoutAnyAccountingChange() public {
        // Pin the huge-allocation edge independently of the fuzz seed.
        _batch(20);
        OracleAttestation.Attestation memory a = _attestation(1, _scores(20, 100));
        bytes memory answer = a.answer;
        assembly ("memory-safe") { mstore(add(answer, 64), not(0)) }
        bytes memory signature = _sign(a);
        bytes32 beforeState = _stateDigest(1);
        vm.cool(address(vault));
        (bool ok,) = intake.deliver(_questionId(1), a, signature);
        assertFalse(ok);
        assertFalse(vault.consumed(a.requestId));
        assertEq(_stateDigest(1), beforeState);
    }

    function _assertBadSignature(
        bytes32 question,
        OracleAttestation.Attestation memory a,
        bytes memory signature
    ) private {
        (bool ok, bytes memory reason) = intake.deliver(question, a, signature);
        assertFalse(ok);
        assertEq(reason, abi.encodeWithSelector(OracleAttestationConsumer.BadSignature.selector));
    }

    function _stateDigest(uint256 batch) private view returns (bytes32) {
        (uint128 teamTokens, uint128 teamETH) = vault.claimable(TEAM);
        return keccak256(
            abi.encode(
                vault.getBatch(batch),
                vault.escrowedETH(),
                vault.jackpotBank(),
                vault.oracleBudget(),
                vault.totalClaimableTokens(),
                vault.totalClaimableETH(),
                teamTokens,
                teamETH,
                address(vault).balance,
                token.balanceOf(address(vault)),
                vault.oracleTokenBudget()
            )
        );
    }
}
