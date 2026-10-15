// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BegVaultBase} from "./BegVaultBase.sol";
import {BegVault} from "../src/BegVault.sol";
import {OracleAttestation, OracleAttestationConsumer} from "../src/OracleAttestation.sol";

contract OracleCallbackTest is BegVaultBase {
    function testCallbackRejectsWrongSenderUnknownIdAndDuplicate() public {
        _batch(1);
        bytes32 questionId = _questionId(1);
        OracleAttestation.Attestation memory a = _attestation(1, _scores(1, 75));
        bytes memory signature = _sign(a);
        vm.expectRevert(BegVault.NotIntake.selector);
        vault.onOracleResult(questionId, a, signature);
        vm.prank(address(intake));
        vm.expectRevert(BegVault.InvalidQuestionId.selector);
        vault.onOracleResult(keccak256("not requested"), a, signature);
        vm.prank(address(intake));
        vault.onOracleResult(questionId, a, signature);
        vm.prank(address(intake));
        vm.expectRevert(BegVault.InvalidBatchState.selector);
        vault.onOracleResult(questionId, a, signature);
        assertTrue(vault.consumed(a.requestId));
        _assertSolvent();
    }

    function testWrongArrayLengthAndAnswerTypeRevertWithoutConsuming() public {
        _batch(2);
        bytes32 questionId = _questionId(1);
        OracleAttestation.Attestation memory a = _attestation(1, _scores(1, 50));
        _expect(a, questionId, BegVault.WrongScoreCount.selector);
        a.answer = abi.encode(_scores(3, 50));
        _expect(a, questionId, BegVault.WrongScoreCount.selector);
        a.answer = abi.encode(_scores(2, 50));
        a.answerType = OracleAttestation.ANSWER_ADDRESS_LIST;
        _expect(
            a, questionId, abi.encodeWithSelector(OracleAttestationConsumer.WrongAnswerType.selector, 5, 4)
        );
        assertFalse(vault.consumed(a.requestId));
        assertEq(vault.escrowedETH(), 2 * PRICE);
    }

    function testExpiredFutureTamperedAndWrongDomainSignaturesFail() public {
        _batch(1);
        bytes32 questionId = _questionId(1);
        OracleAttestation.Attestation memory a = _attestation(1, _scores(1, 50));
        a.expiresAt = uint64(block.timestamp - 1);
        _expect(
            a,
            questionId,
            abi.encodeWithSelector(OracleAttestationConsumer.AttestationExpired.selector, a.expiresAt)
        );
        a.expiresAt = uint64(block.timestamp + 1 hours);
        a.issuedAt = uint64(block.timestamp + 301);
        _expect(
            a,
            questionId,
            abi.encodeWithSelector(OracleAttestationConsumer.AttestationNotYetValid.selector, a.issuedAt)
        );
        a.issuedAt = uint64(block.timestamp);
        bytes memory signature = _sign(a);
        a.answer = abi.encode(_scores(1, 100));
        vm.prank(address(intake));
        vm.expectRevert(OracleAttestationConsumer.BadSignature.selector);
        vault.onOracleResult(questionId, a, signature);
        signature = _sign(a);
        vm.chainId(2);
        vm.prank(address(intake));
        vm.expectRevert(OracleAttestationConsumer.BadSignature.selector);
        vault.onOracleResult(questionId, a, signature);
        vm.chainId(1);
        assertFalse(vault.consumed(a.requestId));
        _assertSolvent();
    }

    function testWrongQuestionChainStaleIssuanceAndWeakPanelsFail() public {
        _batch(1);
        bytes32 questionId = _questionId(1);
        OracleAttestation.Attestation memory a = _attestation(1, _scores(1, 50));
        a.chainId = 4663;
        _expect(a, questionId, BegVault.WrongChain.selector);
        a.chainId = 1;
        a.issuedAt = uint64(block.timestamp - 301);
        _expect(a, questionId, BegVault.StaleAnswer.selector);
        a.issuedAt = uint64(block.timestamp);
        a.panelSize = 4;
        _expect(a, questionId, BegVault.InvalidPanel.selector);
        a.panelSize = 5;
        a.quorum = 2;
        _expect(a, questionId, BegVault.InvalidPanel.selector);
        a.quorum = 3;
        a.agreed = 2;
        _expect(a, questionId, BegVault.InvalidPanel.selector);
        a.agreed = 6;
        _expect(a, questionId, BegVault.InvalidPanel.selector);
        assertEq(vault.escrowedETH(), PRICE);
    }

    function testOracleUUIDReplayAcrossDifferentIntakeRequestsFails() public {
        _batch(1);
        OracleAttestation.Attestation memory a = _attestation(1, _scores(1, 50));
        bytes32 firstId = _questionId(1);
        bytes memory signature = _sign(a);
        vm.prank(address(intake));
        vault.onOracleResult(firstId, a, signature);
        _batch(1);
        a.issuedAt = uint64(block.timestamp);
        a.expiresAt = uint64(block.timestamp + 1 hours);
        _expect(
            a,
            _questionId(2),
            abi.encodeWithSelector(OracleAttestationConsumer.AlreadyConsumed.selector, a.requestId)
        );
        assertEq(uint256(vault.getBatch(2).status), uint256(BegVault.Status.Pending));
    }

    function testClampEveryScoreAndSplitOnlyGradedEscrowUnderStipend() public {
        _batch(20);
        bytes32[] memory scores = new bytes32[](20);
        for (uint256 i; i < 20; ++i) {
            scores[i] = bytes32(i * 20);
        }
        scores[19] = bytes32(type(uint256).max);
        OracleAttestation.Attestation memory a = _attestation(1, scores);
        bytes memory signature = _sign(a);
        bytes32 questionId = _questionId(1);
        _attempt(_player(21), "Second batch still escrowed");
        vm.cool(address(vault));
        (bool ok,) = intake.deliver(questionId, a, signature);
        assertTrue(ok, "callback exceeds Intake stipend");
        BegVault.BatchView memory b = vault.getBatch(1);
        for (uint256 i; i < 20; ++i) {
            assertEq(uint8(b.scores >> (i * 8)), i > 5 ? 100 : i * 20);
        }
        assertEq(vault.escrowedETH(), PRICE);
        assertEq(vault.jackpotBank(), 20 * PRICE - 20 * PRICE / 10 - 0.001 ether);
        assertEq(vault.oracleBudget(), 0.001 ether);
        (, uint128 teamCredit) = vault.claimable(TEAM);
        assertEq(teamCredit, 20 * PRICE / 10);
        assertEq(b.prevrandao, block.prevrandao);
        assertEq(b.rollBlock, block.number + 2);
        assertEq(TEAM.balance, 0); // Team payment is a pull credit too.
        _assertSolvent();
    }

    function testAllZeroIsAValidAnswerUnderStipend() public {
        _batch(20);
        _grade(1, 0);
        assertEq(vault.getBatch(1).scores, 0);
        assertEq(vault.escrowedETH(), 0);
        _assertSolvent();
    }

    function testMalformedABICannotConsumeRequest() public {
        _batch(1);
        OracleAttestation.Attestation memory a = _attestation(1, _scores(1, 50));
        // The length matches, but the dynamic offset points outside the answer.
        a.answer = abi.encode(uint256(4096), uint256(1), uint256(50));
        bytes memory signature = _sign(a);
        bytes32 questionId = _questionId(1);
        vm.prank(address(intake));
        vm.expectRevert();
        vault.onOracleResult(questionId, a, signature);
        assertFalse(vault.consumed(a.requestId));
    }

    function testReusedIntakeIdRollsBackSecondClose() public {
        _batch(1);
        _attempt(_player(2), "second request");
        intake.setDuplicateId(true);
        vm.warp(block.timestamp + 30 minutes);
        vm.expectRevert(BegVault.InvalidQuestionId.selector);
        vault.closeBatch();
        assertEq(vault.openBatchId(), 2);
        assertEq(vault.getAttempt(2).message, "second request");
        assertEq(vault.oracleTokenBudget(), 99.5 ether);
    }

    function _expect(OracleAttestation.Attestation memory a, bytes32 questionId, bytes4 selector) private {
        bytes memory signature = _sign(a);
        vm.prank(address(intake));
        vm.expectRevert(selector);
        vault.onOracleResult(questionId, a, signature);
    }

    function _expect(OracleAttestation.Attestation memory a, bytes32 questionId, bytes memory revertData)
        private
    {
        bytes memory signature = _sign(a);
        vm.prank(address(intake));
        vm.expectRevert(revertData);
        vault.onOracleResult(questionId, a, signature);
    }
}
