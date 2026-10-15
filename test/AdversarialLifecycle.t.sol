// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BegVaultBase} from "./BegVaultBase.sol";
import {BegVault} from "src/BegVault.sol";
import {OracleAttestation, OracleAttestationConsumer} from "src/OracleAttestation.sol";
import {IIntake} from "src/interfaces/IIntake.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @notice Boundary and rollback cases that complement the original lifecycle tests.
contract AdversarialLifecycleTest is BegVaultBase {
    function testConstructorRejectsAliasedAssetsMissingOracleAndOversizedPrice() public {
        vm.expectRevert(BegVault.InvalidConfiguration.selector);
        new BegVault(address(token), TEAM, address(0), address(imd), vm.addr(SIGNER_KEY), PRICE);
        vm.expectRevert(BegVault.InvalidConfiguration.selector);
        new BegVault(address(token), TEAM, address(intake), address(0), vm.addr(SIGNER_KEY), PRICE);
        vm.expectRevert(BegVault.InvalidConfiguration.selector);
        new BegVault(address(token), TEAM, address(intake), address(token), vm.addr(SIGNER_KEY), PRICE);
        vm.expectRevert(BegVault.InvalidConfiguration.selector);
        new BegVault(
            address(token),
            TEAM,
            address(intake),
            address(imd),
            vm.addr(SIGNER_KEY),
            uint256(type(uint80).max) + 1
        );
    }

    function testUnknownViewsAndTransitionsCannotCreatePhantomBatches() public {
        uint256[4] memory ids = [uint256(0), uint256(1), uint256(2), type(uint256).max];
        for (uint256 i; i < ids.length; ++i) {
            vm.expectRevert(BegVault.UnknownAttempt.selector);
            vault.getAttempt(ids[i]);
            if (ids[i] == 1) {
                // The open batch is viewable before its first entry, but it has no state to act on.
                BegVault.BatchView memory empty = vault.getBatch(1);
                assertEq(empty.size, 0);
                assertEq(uint256(empty.status), uint256(BegVault.Status.Open));
                assertEq(empty.firstAttemptId, 0);
            } else {
                vm.expectRevert(BegVault.UnknownBatch.selector);
                vault.getBatch(ids[i]);
            }
            vm.expectRevert(BegVault.UnknownBatch.selector);
            vault.reveal(ids[i]);
            vm.expectRevert(BegVault.UnknownBatch.selector);
            vault.expireBatch(ids[i]);
            vm.expectRevert(BegVault.BatchNotReady.selector);
            vault.closeBatch(ids[i]);
        }
        vm.expectRevert(BegVault.BatchNotReady.selector);
        vault.closeBatch();
        assertEq(vault.nextAttemptId(), 1);
        assertEq(vault.openBatchId(), 1);
        assertEq(vault.nextToClose(), 1);
        _assertSolvent();
    }

    /// forge-config: default.fuzz.runs = 512
    function testFuzzRejectedPaymentLeavesMessageAndCooldownAvailable(uint96 rawPayment) public {
        uint256 payment = bound(rawPayment, 0, 2 * PRICE);
        if (payment == PRICE) ++payment;
        uint256 beforeETH = address(this).balance;
        vm.expectRevert(BegVault.WrongPayment.selector);
        vault.attempt{value: payment}("Retry the exact same text after a failed payment");
        assertEq(address(this).balance, beforeETH);
        assertFalse(vault.usedMessage(keccak256("Retry the exact same text after a failed payment")));
        assertEq(vault.cooldownUntil(address(this)), 0);
        assertEq(vault.nextAttemptId(), 1);
        vault.attempt{value: PRICE}("Retry the exact same text after a failed payment");
        assertEq(vault.getAttempt(1).player, address(this));
        _assertSolvent();
    }

    function testCooldownOneSecondBeforeAndExactlyAtBoundary() public {
        address player = _player(1);
        _attempt(player, "First request");
        uint256 until = vault.cooldownUntil(player);
        vm.warp(until - 1);
        vm.deal(player, PRICE);
        vm.prank(player);
        vm.expectRevert(abi.encodeWithSelector(BegVault.CooldownActive.selector, until));
        vault.attempt{value: PRICE}("Second request");
        assertFalse(vault.usedMessage(keccak256("Second request")));
        vm.warp(until);
        _attempt(player, "Second request");
        assertEq(vault.getAttempt(2).player, player);
        assertEq(vault.cooldownUntil(player), until + 10 minutes);
    }

    function testOpenTimeoutBoundaryRejectsCloseButPermitsFullRefund() public {
        _attempt(_player(1), "An oracle outage cannot retain my escrow");
        uint256 deadline = uint256(vault.getBatch(1).openedAt) + 30 minutes + 24 hours;
        vm.warp(deadline - 1);
        vm.expectRevert(BegVault.TooEarly.selector);
        vault.expireBatch(1);
        vm.warp(deadline);
        vm.expectRevert(BegVault.BatchTimedOut.selector);
        vault.closeBatch();
        vault.expireBatch(1);
        vm.prank(_player(1));
        vault.refund(1);
        (, uint128 refundCredit) = vault.claimable(_player(1));
        assertEq(refundCredit, PRICE);
        assertEq(intake.requests(), 0);
        vm.expectRevert(BegVault.InvalidBatchState.selector);
        vault.expireBatch(1);
        _assertSolvent();
    }

    function testCallbackAtLastSecondBeforeTimeoutPreventsExpiry() public {
        _batch(2);
        uint256 deadline = uint256(vault.getBatch(1).closedAt) + 24 hours;
        vm.warp(deadline - 1);
        _grade(1, 100);
        vm.warp(deadline);
        vm.expectRevert(BegVault.InvalidBatchState.selector);
        vault.expireBatch(1);
        vm.prank(_player(1));
        vm.expectRevert(BegVault.InvalidBatchState.selector);
        vault.refund(1);
        assertEq(vault.escrowedETH(), 0);
        _assertSolvent();
    }

    function testOldPendingExpiryDoesNotEraseOrAdvanceTheCurrentOpenBatch() public {
        _batch(1);
        uint256 deadline = uint256(vault.getBatch(1).closedAt) + 24 hours;
        vm.warp(deadline - 1);
        _attempt(_player(2), "I am in the fresh batch, not the expired one");
        bytes32 beforeBatch = keccak256(abi.encode(vault.getBatch(2)));
        vm.warp(deadline);
        vault.expireBatch(1);
        assertEq(vault.openBatchId(), 2);
        assertEq(keccak256(abi.encode(vault.getBatch(2))), beforeBatch);
        assertEq(vault.getAttempt(2).message, "I am in the fresh batch, not the expired one");
        vm.prank(_player(1));
        vault.refund(1);
        assertEq(vault.escrowedETH(), PRICE);
        vm.prank(_player(2));
        vm.expectRevert(BegVault.InvalidBatchState.selector);
        vault.refund(2);
        _assertSolvent();
    }

    function testSamePlayerCanRefundSeveralAttemptsSeparatelyAndClaimTheirSum() public {
        address player = _player(1);
        uint256 original = player.balance;
        for (uint256 i; i < 3; ++i) {
            _attempt(player, string.concat("Refundable message ", vm.toString(i)));
            vm.warp(vm.getBlockTimestamp() + 10 minutes);
        }
        vault.closeBatch();
        vm.warp(vm.getBlockTimestamp() + 24 hours);
        vault.expireBatch(1);
        uint256[3] memory order = [uint256(3), uint256(1), uint256(2)];
        for (uint256 i; i < order.length; ++i) {
            vm.prank(player);
            vault.refund(order[i]);
            assertEq(vault.escrowedETH(), (2 - i) * PRICE);
            (, uint128 credit) = vault.claimable(player);
            assertEq(credit, (i + 1) * PRICE);
        }
        assertEq(player.balance, original, "refund must only credit, never push ETH");
        vm.prank(player);
        vault.claim();
        assertEq(player.balance, original + 3 * PRICE);
        _assertSolvent();
    }

    function testRejectingTwentiethRequestCanRetryIdenticalMessageWithoutCooldown() public {
        for (uint256 i = 1; i < 20; ++i) {
            _attempt(_player(i), vm.toString(i));
        }
        intake.setReject(true);
        address lastPlayer = _player(20);
        vm.deal(lastPlayer, PRICE);
        vm.prank(lastPlayer);
        vm.expectRevert(BegVault.OracleUnfunded.selector);
        vault.attempt{value: PRICE}("twentieth entry");
        assertEq(lastPlayer.balance, PRICE);
        assertEq(vault.cooldownUntil(lastPlayer), 0);
        assertFalse(vault.usedMessage(keccak256("twentieth entry")));
        assertEq(vault.getBatch(1).size, 19);
        assertEq(vault.getBatch(1).lastPlayer, address(0));
        assertEq(vault.nextAttemptId(), 20);
        assertEq(vault.autoClosed(), 0);
        assertEq(vault.openBatchId(), 1);
        vm.expectRevert(BegVault.UnknownAttempt.selector);
        vault.getAttempt(20);
        intake.setReject(false);
        vm.prank(lastPlayer);
        assertEq(vault.attempt{value: PRICE}("twentieth entry"), 20);
        assertEq(intake.requests(), 1);
        assertEq(vault.getBatch(1).size, 20);
        assertEq(vault.getBatch(1).lastPlayer, lastPlayer);
        assertEq(vault.autoClosed(), 1);
        assertEq(vault.openBatchId(), 2);
        assertEq(vault.nextToClose(), 2);
        // The closing entry has no stored record, yet it is located by id like any other.
        BegVault.AttemptView memory closing = vault.getAttempt(20);
        assertEq(closing.player, lastPlayer);
        assertEq(closing.batchId, 1);
        assertEq(closing.index, 19);
        assertEq(bytes(closing.message).length, 0);
        _assertSolvent();
    }

    function testZeroIntakeIdRollsBackOpeningAllowanceAndMessages() public {
        _attempt(_player(1), "Keep this text when Intake returns no id");
        vm.warp(vm.getBlockTimestamp() + 30 minutes);
        vm.mockCall(address(intake), abi.encodePacked(IIntake.request.selector), abi.encode(bytes32(0)));
        vm.expectRevert(BegVault.InvalidQuestionId.selector);
        vault.closeBatch();
        assertEq(vault.getBatch(1).closedAt, 0);
        assertEq(vault.openBatchId(), 1);
        assertEq(vault.escrowedETH(), PRICE);
        assertEq(vault.getAttempt(1).message, "Keep this text when Intake returns no id");
        assertEq(vault.oracleTokenBudget(), 100 ether);
        assertEq(uint256(vault.getBatch(1).status), uint256(BegVault.Status.Open));
        vm.clearMockedCalls();
        vault.closeBatch();
        assertEq(intake.requests(), 1);
        _assertSolvent();
    }

    function testUnsoldActionAndETHDonationsCannotPayAnIMDFee() public {
        _attempt(_player(1), "Different assets must never be conflated");
        vm.warp(vm.getBlockTimestamp() + 30 minutes);
        intake.setPrice(0);
        vm.expectRevert(BegVault.OracleUnfunded.selector);
        vault.closeBatch();
        intake.setPrice(100 ether + 1);
        vault.fundOracle{value: 10 ether}();
        vm.expectRevert(BegVault.OracleUnfunded.selector);
        vault.closeBatch();
        assertEq(vault.oracleBudget(), 10 ether);
        imd.mint(address(this), 1);
        vault.fundOracle(1);
        vault.closeBatch();
        assertEq(vault.oracleTokenBudget(), 0);
        assertEq(vault.oracleBudget(), 10 ether);
        assertEq(imd.balanceOf(address(intake)), 100 ether + 1);
        _assertSolvent();
    }

    function testRejectedOracleFundingDoesNotAffectAnyETHLiability() public {
        _attempt(_player(1), "Escrow survives an unrelated failed donation");
        imd.mint(address(this), 1 ether);
        imd.approve(address(vault), 0);
        vm.expectRevert();
        vault.fundOracle(1 ether);
        assertEq(imd.balanceOf(address(this)), 1 ether);
        assertEq(vault.oracleTokenBudget(), 100 ether);
        assertEq(vault.escrowedETH(), PRICE);
        imd.approve(address(vault), 1 ether);
        vm.mockCall(
            address(imd),
            abi.encodeCall(IERC20.transferFrom, (address(this), address(vault), 1 ether)),
            abi.encode(false)
        );
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(imd)));
        vault.fundOracle(1 ether);
        assertEq(vault.oracleTokenBudget(), 100 ether);
        vm.clearMockedCalls();
        vault.fundOracle(1 ether);
        assertEq(vault.oracleTokenBudget(), 101 ether);
        _assertSolvent();
    }

    /// forge-config: default.fuzz.runs = 512
    function testFuzzScoreCountMismatchIsAtomicAndCorrectedAnswerCanSettle(uint8 rawSize, uint8 rawLength)
        public
    {
        uint256 size = bound(rawSize, 1, 20);
        uint256 length = bound(rawLength, 0, 21);
        if (length == size) length = (length + 1) % 22;
        _batch(size);
        BegVault.BatchView memory beforeBatch = vault.getBatch(1);
        bytes32 questionId = _questionId(1);
        OracleAttestation.Attestation memory a = _attestation(1, _scores(length, 50));
        bytes memory signature = _sign(a);
        vm.prank(address(intake));
        vm.expectRevert(BegVault.WrongScoreCount.selector);
        vault.onOracleResult(questionId, a, signature);
        assertFalse(vault.consumed(a.requestId));
        assertEq(keccak256(abi.encode(vault.getBatch(1))), keccak256(abi.encode(beforeBatch)));
        assertEq(vault.escrowedETH(), size * PRICE);
        assertEq(vault.totalClaimableETH(), 0);
        a.answer = abi.encode(_scores(size, 50));
        signature = _sign(a);
        (bool ok,) = intake.deliver(questionId, a, signature);
        assertTrue(ok, "a rejected callback must not consume the request or UUID");
        assertTrue(vault.consumed(a.requestId));
        _assertSolvent();
    }

    function testSignedFieldsCannotBeChangedAfterSigning() public {
        _batch(1);
        bytes32 questionId = _questionId(1);
        for (uint256 field; field < 15; ++field) {
            OracleAttestation.Attestation memory a = _attestation(1, _scores(1, 50));
            a.agreed = 5; // Quorum and agreement mutations must still describe valid panels.
            bytes memory signature = _sign(a);
            if (field == 0) a.requestId = keccak256("different UUID");
            if (field == 1) a.chainId = 4663;
            if (field == 2) a.questionHash = keccak256("different question");
            if (field == 3) a.answerType = 4;
            if (field == 4) a.answer = abi.encode(_scores(1, 51));
            if (field == 5) a.figure = 1;
            if (field == 6) ++a.fromBlock;
            if (field == 7) ++a.toBlock;
            if (field == 8) a.blockHash = keccak256("different block");
            if (field == 9) a.panelJobId = keccak256("different panel");
            if (field == 10) ++a.panelSize;
            if (field == 11) ++a.quorum;
            if (field == 12) --a.agreed;
            if (field == 13) ++a.issuedAt;
            if (field == 14) ++a.expiresAt;
            bytes4 errorSelector =
                field == 1 ? BegVault.WrongChain.selector : OracleAttestationConsumer.BadSignature.selector;
            vm.prank(address(intake));
            vm.expectRevert(errorSelector);
            vault.onOracleResult(questionId, a, signature);
            assertFalse(vault.consumed(a.requestId));
        }
        assertEq(vault.escrowedETH(), PRICE);
        _grade(1, 50);
        _assertSolvent();
    }

    function testSignatureForAnotherVaultIsRejectedEvenWithSameImmutableParameters() public {
        _batch(1);
        BegVault other =
            new BegVault(address(token), TEAM, address(intake), address(imd), vm.addr(SIGNER_KEY), PRICE);
        OracleAttestation.Attestation memory a = _attestation(1, _scores(1, 50));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER_KEY, other.attestationDigest(a));
        bytes32 questionId = _questionId(1);
        vm.prank(address(intake));
        vm.expectRevert(OracleAttestationConsumer.BadSignature.selector);
        vault.onOracleResult(questionId, a, abi.encodePacked(r, s, v));
        assertFalse(vault.consumed(a.requestId));
        _grade(1, 50);
    }

    /// @dev A batch past its 30-minute window stops taking entries; the next entry opens a new batch and
    ///      the stale one is left to the close cursor. Neither path may lose or double count an entry.
    function testStaleOpenBatchIsLeftBehindAndClosedByTheCursorNotTheNewEntry() public {
        _attempt(_player(1), "Early bird in batch one");
        uint256 openedAt = vm.getBlockTimestamp();
        vm.warp(openedAt + 30 minutes - 1);
        _attempt(_player(2), "Still inside the window");
        assertEq(vault.getAttempt(2).batchId, 1);
        vm.warp(openedAt + 30 minutes);
        uint256 id = _attempt(_player(3), "One second too late opens batch two");
        assertEq(id, 3);
        assertEq(vault.getAttempt(3).batchId, 2);
        assertEq(vault.getAttempt(3).index, 0);
        assertEq(vault.openBatchId(), 2);
        assertEq(vault.nextToClose(), 1, "the stale batch is still the oldest open batch");
        assertEq(vault.getBatch(1).size, 2);
        assertEq(uint256(vault.getBatch(1).status), uint256(BegVault.Status.Open));
        assertEq(vault.getBatch(2).openedAt, openedAt + 30 minutes);
        assertEq(vault.escrowedETH(), 3 * PRICE);
        // Closing by id the batch that is not ready reverts; the cursor closes the stale one.
        vm.expectRevert(BegVault.BatchNotReady.selector);
        vault.closeBatch(2);
        vault.closeBatch();
        assertEq(uint256(vault.getBatch(1).status), uint256(BegVault.Status.Pending));
        assertEq(vault.nextToClose(), 2);
        assertEq(vault.openBatchId(), 2, "closing an old batch must not skip the current one");
        string memory body = string(intake.lastBody());
        assertEq(vm.parseJsonKeys(body, ".definitions").length, 2);
        assertEq(vm.parseJsonString(body, '.definitions["2"]'), "Still inside the window");
        assertEq(vault.getAttempt(3).message, "One second too late opens batch two");
        vm.expectRevert(BegVault.BatchNotReady.selector);
        vault.closeBatch();
        vm.warp(vm.getBlockTimestamp() + 30 minutes);
        vault.closeBatch(2);
        assertEq(vault.openBatchId(), 3);
        assertEq(vault.nextToClose(), 3);
        assertEq(intake.requests(), 2);
        _grade(1, 10);
        _grade(2, 90);
        assertEq(vault.getAttempt(2).score, 10);
        assertEq(vault.getAttempt(3).score, 90);
        _assertSolvent();
    }

    function testTimedOutStaleBatchBlocksOnlyTheCursorUntilExpiredThenCursorAdvances() public {
        _attempt(_player(1), "Nobody closes me in time");
        vm.warp(vm.getBlockTimestamp() + 30 minutes + 24 hours);
        _attempt(_player(2), "A day later the game continues");
        assertEq(vault.openBatchId(), 2);
        assertEq(vault.nextToClose(), 1);
        vm.expectRevert(BegVault.BatchTimedOut.selector);
        vault.closeBatch();
        vm.warp(vm.getBlockTimestamp() + 30 minutes);
        vm.expectRevert(BegVault.BatchTimedOut.selector);
        vault.closeBatch();
        vault.closeBatch(2);
        assertEq(vault.openBatchId(), 3);
        assertEq(vault.nextToClose(), 1, "a timed-out open batch keeps the cursor until it is expired");
        vault.expireBatch(1);
        assertEq(vault.nextToClose(), 3);
        vm.prank(_player(1));
        vault.refund(1);
        vm.prank(_player(2));
        vm.expectRevert(BegVault.InvalidBatchState.selector);
        vault.refund(2);
        assertEq(vault.escrowedETH(), PRICE);
        _assertSolvent();
    }

    /// @dev The previous revision had a `retire()` dead-man path that handed the pool to the team after an
    ///      expiry and 30 quiet days. It was reported and removed. These cases pin the sequence that used
    ///      to arm it: an unrevealed grade and an expiry followed by a month of silence must leave every
    ///      balance where it was, with the graded batch still rolling against the whole pool afterwards.
    function testAnExpiryFollowedByAQuietMonthLeavesAnUnrevealedGradeRollingAgainstTheWholePool() public {
        uint256 pool = vault.vaultFreeBalance();
        _batch(2);
        _batch(1);
        _grade(1, 60);
        vm.warp(vm.getBlockTimestamp() + 24 hours);
        vault.expireBatch(2);
        vm.warp(vm.getBlockTimestamp() + 30 days);
        (bool ok,) = address(vault).call(abi.encodeWithSignature("retire()"));
        assertFalse(ok, "a retire() entry point exists");
        (uint128 teamTokens, uint128 teamETH) = vault.claimable(TEAM);
        assertEq(teamTokens, 0, "tokens credited to the team outside of a roll");
        assertEq(teamETH, 2 * PRICE / 10, "the team only ever earns its tenth of a graded escrow");
        assertEq(vault.vaultFreeBalance(), pool);
        assertEq(vault.jackpotBank(), 2 * PRICE - 2 * (2 * PRICE / 10));
        assertEq(vault.oracleBudget(), 2 * PRICE / 10);
        assertEq(vault.escrowedETH(), PRICE, "an expired entry's escrow waits for its refund");
        // The month-old grade still reveals, missing windows only forfeit tiers, and the pool is intact.
        _reveal(1, keccak256("batch one hash"));
        assertEq(uint256(vault.getBatch(1).status), uint256(BegVault.Status.Revealed));
        assertEq(vault.vaultFreeBalance() + vault.totalClaimableTokens(), pool);
        (teamTokens,) = vault.claimable(TEAM);
        assertEq(teamTokens, 0);
        vm.prank(_player(3));
        vault.refund(3);
        assertEq(vault.escrowedETH(), 0);
        // Play resumes without anyone's intervention.
        _attempt(_player(7), "Proof of life for the oracle");
        vm.warp(vm.getBlockTimestamp() + 30 minutes);
        vault.closeBatch();
        _grade(3, 1);
        _reveal(3, keccak256("batch three hash"));
        _assertSolvent();
    }

    function testAQuietMonthWithAnOpenBatchAndDonatedBountyBudgetMovesNothingToAnyone() public {
        uint256 pool = vault.vaultFreeBalance();
        _batch(1);
        vm.warp(vm.getBlockTimestamp() + 24 hours);
        vault.expireBatch(1);
        _attempt(_player(5), "Open while the oracle is silent");
        vault.fundOracle{value: 0.3 ether}();
        vm.warp(vm.getBlockTimestamp() + 30 days);
        for (uint256 i; i < 3; ++i) {
            vm.prank(_player(9));
            (bool ok,) = address(vault).call(abi.encodeWithSignature("retire()"));
            assertFalse(ok, "a retire() entry point exists");
        }
        (uint128 teamTokens, uint128 teamETH) = vault.claimable(TEAM);
        assertEq(teamTokens, 0);
        assertEq(teamETH, 0);
        assertEq(vault.vaultFreeBalance(), pool);
        assertEq(vault.totalClaimableTokens(), 0);
        assertEq(vault.jackpotBank(), 0);
        assertEq(vault.oracleBudget(), 0.3 ether, "donated bounty budget is not anyone's to take");
        assertEq(vault.escrowedETH(), 2 * PRICE);
        // The stale open batch can only be closed within its window or expired; its entry is refundable.
        vm.expectRevert(BegVault.BatchTimedOut.selector);
        vault.closeBatch();
        vm.expectRevert(BegVault.BatchTimedOut.selector);
        vault.closeBatch(2);
        vault.expireBatch(2);
        vm.prank(_player(1));
        vault.refund(1);
        vm.prank(_player(5));
        vault.refund(2);
        assertEq(vault.escrowedETH(), 0);
        vm.prank(_player(5));
        vault.claim();
        assertEq(_player(5).balance, PRICE);
        // Tokens that arrive later only grow the pool players roll against.
        token.transfer(address(vault), 1234);
        assertEq(vault.vaultFreeBalance(), pool + 1234);
        vm.prank(TEAM);
        vm.expectRevert(BegVault.NothingToClaim.selector);
        vault.claim();
        uint256 batchId = _batch(20);
        _grade(batchId, 100);
        _reveal(batchId, keccak256("full table after the quiet month"));
        assertGt(vault.totalClaimableTokens(), 0, "players rolled against an empty pool");
        assertEq(vault.vaultFreeBalance() + vault.totalClaimableTokens(), pool + 1234);
        assertEq(token.balanceOf(TEAM), 0);
        _assertSolvent();
    }

    function testAttestationTimeToleranceAndExpiryAreInclusiveAtTheirBoundaries() public {
        _batch(1);
        OracleAttestation.Attestation memory a = _attestation(1, _scores(1, 0));
        a.issuedAt -= 300;
        a.expiresAt = uint64(vm.getBlockTimestamp());
        bytes memory signature = _sign(a);
        (bool ok,) = intake.deliver(_questionId(1), a, signature);
        assertTrue(ok, "issuance at close minus tolerance and expiry at now are valid");
        _batch(1);
        a = _attestation(2, _scores(1, 100));
        a.issuedAt += 300;
        signature = _sign(a);
        (ok,) = intake.deliver(_questionId(2), a, signature);
        assertTrue(ok, "issuance at now plus tolerance is valid");
        _assertSolvent();
    }
}
