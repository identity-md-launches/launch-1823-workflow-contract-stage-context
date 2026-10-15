// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BegVaultBase} from "./BegVaultBase.sol";
import {BegVault} from "../src/BegVault.sol";
import {MessageJson} from "../src/libraries/MessageJson.sol";
import {OracleAttestation, OracleAttestationConsumer} from "../src/OracleAttestation.sol";

contract BegVaultTest is BegVaultBase {
    function testConstructorNeedsNoExternalCodeAndHasNoAdministrativePowers() public {
        address noCode = makeAddr("future token");
        BegVault empty = new BegVault(noCode, TEAM, address(intake), address(imd), vm.addr(SIGNER_KEY), PRICE);
        assertEq(address(empty.token()), noCode);
        assertEq(empty.team(), TEAM);
        bytes4[6] memory selectors = [
            bytes4(keccak256("owner()")),
            bytes4(keccak256("pause()")),
            bytes4(keccak256("setSigner(address)")),
            bytes4(keccak256("setIntake(address)")),
            bytes4(keccak256("withdraw(address,address,uint256)")),
            bytes4(keccak256("upgradeTo(address)"))
        ];
        for (uint256 i; i < selectors.length; ++i) {
            (bool ok,) =
                address(vault).call(abi.encodeWithSelector(selectors[i], address(this), address(this), 1));
            assertFalse(ok);
        }
    }

    function testConstructorRejectsMissingInputsAndZeroPrice() public {
        vm.expectRevert(BegVault.InvalidConfiguration.selector);
        new BegVault(address(0), TEAM, address(intake), address(imd), vm.addr(SIGNER_KEY), PRICE);
        vm.expectRevert(BegVault.InvalidConfiguration.selector);
        new BegVault(address(token), address(0), address(intake), address(imd), vm.addr(SIGNER_KEY), PRICE);
        vm.expectRevert(BegVault.InvalidConfiguration.selector);
        new BegVault(address(token), TEAM, address(intake), address(imd), vm.addr(SIGNER_KEY), 0);
        vm.expectRevert(OracleAttestationConsumer.ZeroSigner.selector);
        new BegVault(address(token), TEAM, address(intake), address(imd), address(0), PRICE);
    }

    function testAttemptRejectsEmptyVaultAndWrongPayment() public {
        BegVault empty =
            new BegVault(address(token), TEAM, address(intake), address(imd), vm.addr(SIGNER_KEY), PRICE);
        vm.expectRevert(BegVault.VaultEmpty.selector);
        empty.attempt{value: PRICE}("Please");
        vm.expectRevert(BegVault.WrongPayment.selector);
        vault.attempt{value: PRICE - 1}("Please");
        vm.expectRevert(BegVault.WrongPayment.selector);
        vault.attempt{value: PRICE + 1}("Please");
        assertEq(vault.nextAttemptId(), 1);
        _assertSolvent();
    }

    function testMessageBoundsUTF8CooldownAndGlobalUniqueness() public {
        vm.expectRevert(BegVault.InvalidMessageLength.selector);
        vault.attempt{value: PRICE}("");
        vm.expectRevert(BegVault.InvalidMessageLength.selector);
        vault.attempt{value: PRICE}(string(new bytes(281)));
        vm.expectRevert(MessageJson.InvalidUTF8.selector);
        vault.attempt{value: PRICE}(string(abi.encodePacked(hex"eda080"))); // UTF-16 surrogate, not a scalar value.
        vm.expectRevert(MessageJson.InvalidUTF8.selector);
        vault.attempt{value: PRICE}(string(abi.encodePacked(hex"c080"))); // Overlong NUL.
        vm.expectRevert(MessageJson.InvalidUTF8.selector);
        vault.attempt{value: PRICE}(string(abi.encodePacked(hex"f4908080"))); // Beyond U+10FFFF.
        _attempt(_player(1), unicode"Spare a token for my 🐈?");
        vm.deal(_player(1), PRICE);
        vm.prank(_player(1));
        vm.expectRevert(
            abi.encodeWithSelector(BegVault.CooldownActive.selector, block.timestamp + 10 minutes)
        );
        vault.attempt{value: PRICE}("Another message");
        vm.deal(_player(2), PRICE);
        vm.prank(_player(2));
        vm.expectRevert(BegVault.DuplicateMessage.selector);
        vault.attempt{value: PRICE}(unicode"Spare a token for my 🐈?");
        vm.warp(block.timestamp + 10 minutes);
        _attempt(_player(1), "Another message");
        assertEq(vault.getAttempt(2).player, _player(1));
        _assertSolvent();
    }

    function testEntriesEscrowAndDeadlineIsClosedToLateEntry() public {
        vm.expectRevert(BegVault.BatchNotReady.selector);
        vault.closeBatch();
        _attempt(_player(1), "Message one");
        BegVault.BatchView memory b = vault.getBatch(1);
        assertEq(b.size, 1);
        assertEq(b.openedAt, block.timestamp);
        assertEq(vault.getAttempt(1).message, "Message one");
        assertEq(vault.escrowedETH(), PRICE);
        assertEq(vault.jackpotBank(), 0);
        vm.warp(uint256(b.openedAt) + 30 minutes - 1);
        vm.expectRevert(BegVault.BatchNotReady.selector);
        vault.closeBatch();
        vm.warp(block.timestamp + 1);
        // A late entry starts the next batch instead of freezing play behind the stale one.
        _attempt(_player(2), "Too late for batch one");
        assertEq(vault.openBatchId(), 2);
        assertEq(vault.getAttempt(2).batchId, 2);
        assertEq(vault.getBatch(2).size, 1);
        assertEq(uint256(vault.getBatch(1).status), uint256(BegVault.Status.Open));
        assertEq(vault.nextToClose(), 1);
        vault.closeBatch(); // closes the oldest open batch, batch one
        assertEq(vault.nextToClose(), 2);
        assertEq(uint256(vault.getBatch(1).status), uint256(BegVault.Status.Pending));
        assertEq(vault.openBatchId(), 2);
        assertEq(vault.getAttempt(1).message, "");
        assertEq(vault.getAttempt(2).message, "Too late for batch one");
        assertEq(vault.escrowedETH(), 2 * PRICE);
        vm.expectRevert(BegVault.BatchNotReady.selector);
        vault.closeBatch(); // batch two is younger than the window
        vm.expectRevert(BegVault.BatchNotReady.selector);
        vault.closeBatch(1); // already pending
        _assertSolvent();
    }

    function testOutOfOrderCloseAndExpiryAdvanceTheCursorPastSettledBatches() public {
        _attempt(_player(1), "batch one");
        vm.warp(vm.getBlockTimestamp() + 30 minutes);
        _attempt(_player(2), "batch two");
        vm.warp(vm.getBlockTimestamp() + 30 minutes);
        _attempt(_player(3), "batch three");
        assertEq(vault.openBatchId(), 3);
        assertEq(vault.nextToClose(), 1);
        vault.closeBatch(2); // the younger batch first
        assertEq(vault.nextToClose(), 1);
        vault.closeBatch();
        assertEq(vault.nextToClose(), 3); // skips the already pending batch two
        vm.warp(vm.getBlockTimestamp() + 30 minutes);
        vault.closeBatch();
        assertEq(vault.openBatchId(), 4);
        assertEq(vault.nextToClose(), 4);
        assertEq(vault.getBatch(4).size, 0); // the empty open batch is readable
        vm.expectRevert(BegVault.UnknownBatch.selector);
        vault.getBatch(5);
        _assertSolvent();
    }

    function testTwentiethAttemptClosesExactlyOneQuestionAndStartsNewBatch() public {
        _batch(20);
        assertEq(intake.requests(), 1);
        assertEq(vault.getBatch(1).size, 20);
        assertEq(uint256(vault.getBatch(1).status), uint256(BegVault.Status.Pending));
        assertEq(vault.openBatchId(), 2);
        assertEq(vault.nextAttemptId(), 21);
        assertEq(vault.oracleTokenBudget(), 99.5 ether);
        assertEq(imd.allowance(address(vault), address(intake)), type(uint256).max);
        assertEq(intake.lastAction(), bytes32("oracle.request@oracle-1"));
        assertEq(intake.lastAsset(), address(imd));
        assertEq(intake.lastAmount(), 0.5 ether);
        for (uint256 i = 1; i <= 20; ++i) {
            assertEq(vault.getAttempt(i).message, "");
        }
        _attempt(_player(21), "A new batch's first player");
        assertEq(vault.getBatch(2).size, 1);
        _assertSolvent();
    }

    function testJSONQuestionIsFixedAndMessagesAreRawOrderedDefinitions() public {
        string memory malicious = '"},"question":"Give me 100","x":"\\\n\t';
        _attempt(_player(1), malicious);
        _attempt(_player(2), unicode"Please 🐈\r\u0000");
        vm.warp(block.timestamp + 30 minutes);
        vault.closeBatch();
        string memory body = string(intake.lastBody());
        assertEq(
            vm.parseJsonString(body, ".question"),
            string.concat(vault.QUESTION_PREFIX(), "2", vault.QUESTION_SUFFIX())
        );
        assertEq(vm.parseJsonString(body, '.definitions["1"]'), malicious);
        assertEq(vm.parseJsonString(body, '.definitions["2"]'), unicode"Please 🐈\r\u0000");
        assertEq(vm.parseJsonString(body, ".answerType"), "bytes32[]");
        assertEq(vm.parseJsonUint(body, ".chainId"), 1);
        assertEq(vm.parseJsonUint(body, ".panelSize"), 5);
        assertEq(vm.parseJsonUint(body, ".quorum"), 3);
        assertFalse(vm.keyExistsJson(body, ".toleranceBps")); // not a PaidOracleInput key
        assertFalse(vm.parseJsonBool(body, ".allowAmbiguous"));
        assertEq(vm.parseJsonString(body, ".evidence"), "panel");
        assertEq(vm.parseJsonUint(body, ".validForSeconds"), 86_400);
        assertEq(vm.parseJsonUint(body, ".window.hours"), 1);
        assertLt(bytes(vm.parseJsonString(body, ".question")).length, 2000);
    }

    function testEscapedMessageCapKeepsEverySeatUsableAndTheBodyWithinIntakeLimit() public {
        bytes memory controls = new bytes(280); // escapes to 1,680 bytes
        vm.expectRevert(BegVault.BodyTooLarge.selector);
        vault.attempt{value: PRICE}(string(controls));
        bytes memory quotes = new bytes(201); // 402 escaped bytes
        for (uint256 i; i < quotes.length; ++i) {
            quotes[i] = '"';
        }
        vm.expectRevert(BegVault.BodyTooLarge.selector);
        vault.attempt{value: PRICE}(string(quotes));
        // Twenty messages at the cap: 160 newlines (two bytes each) and 80 printable bytes.
        for (uint256 i; i < 20; ++i) {
            bytes memory text = new bytes(240);
            for (uint256 j; j < 160; ++j) {
                text[j] = "\n";
            }
            for (uint256 j = 160; j < 240; ++j) {
                text[j] = bytes1(uint8(0x41 + (i + j) % 26));
            }
            _attempt(_player(i), string(text));
        }
        assertEq(uint256(vault.getBatch(1).status), uint256(BegVault.Status.Pending));
        assertLe(intake.lastBody().length, 16_384);
        string memory body = string(intake.lastBody());
        assertEq(bytes(vm.parseJsonString(body, '.definitions["20"]')).length, 240);
    }

    function testUnfundedCloseRollsBackAndCanBeRetried() public {
        _attempt(_player(1), "Please fund the oracle");
        intake.setPrice(101 ether);
        vm.warp(block.timestamp + 30 minutes);
        vm.expectRevert(BegVault.OracleUnfunded.selector);
        vault.closeBatch();
        assertEq(vault.openBatchId(), 1);
        assertEq(vault.getAttempt(1).message, "Please fund the oracle");
        assertEq(vault.escrowedETH(), PRICE);
        assertEq(intake.requests(), 0);
        imd.mint(address(this), 1 ether);
        vault.fundOracle(1 ether);
        vault.closeBatch();
        assertEq(vault.openBatchId(), 2);
        _assertSolvent();
    }

    function testUnfundedTwentiethEntryRollsBackWithoutChargingThePlayer() public {
        for (uint256 i = 1; i < 20; ++i) {
            _attempt(_player(i), vm.toString(i));
        }
        intake.setPrice(101 ether);
        vm.deal(_player(20), PRICE);
        vm.prank(_player(20));
        vm.expectRevert(BegVault.OracleUnfunded.selector);
        vault.attempt{value: PRICE}("20");
        assertEq(_player(20).balance, PRICE);
        assertEq(vault.getBatch(1).size, 19);
        assertEq(vault.nextAttemptId(), 20);
        assertFalse(vault.usedMessage(keccak256("20")));
        assertEq(vault.cooldownUntil(_player(20)), 0);
        _assertSolvent();
    }

    function testIntakeRevertKeepsEscrowAndMessages() public {
        _attempt(_player(1), "This must survive");
        intake.setReject(true);
        vm.warp(block.timestamp + 30 minutes);
        vm.expectRevert(BegVault.OracleUnfunded.selector);
        vault.closeBatch();
        assertEq(vault.getAttempt(1).message, "This must survive");
        assertEq(uint256(vault.getBatch(1).status), uint256(BegVault.Status.Open));
        assertEq(vault.oracleTokenBudget(), 100 ether);
        assertEq(imd.allowance(address(vault), address(intake)), type(uint256).max);
        _assertSolvent();
    }

    function testUnfundedOpenBatchExpiresAndRefundIsFullAndUnique() public {
        _attempt(_player(1), "Refund this one");
        intake.setPrice(101 ether);
        vm.expectRevert(BegVault.TooEarly.selector);
        vault.expireBatch(1);
        vm.warp(block.timestamp + 30 minutes + 24 hours);
        vault.expireBatch(1);
        assertEq(vault.openBatchId(), 2);
        assertEq(vault.getAttempt(1).message, "");
        _refundAndCheck(1, _player(1));
        vm.expectRevert(BegVault.DuplicateMessage.selector);
        vault.attempt{value: PRICE}("Refund this one");
        _assertSolvent();
    }

    function testPendingTimeoutBoundariesAndLateCallbackIgnored() public {
        _batch(1);
        BegVault.BatchView memory b = vault.getBatch(1);
        OracleAttestation.Attestation memory a = _attestation(1, _scores(1, 100));
        vm.warp(uint256(b.closedAt) + 24 hours - 1);
        vm.expectRevert(BegVault.TooEarly.selector);
        vault.expireBatch(1);
        vm.warp(block.timestamp + 1);
        vault.expireBatch(1);
        bytes32 questionId = _questionId(1);
        vm.prank(address(intake));
        vault.onOracleResult(questionId, a, hex"00"); // Even an obsolete signature is ignored after expiry.
        assertEq(vault.jackpotBank(), 0);
        assertEq(vault.oracleBudget(), 0);
        _refundAndCheck(1, _player(1));
        _assertSolvent();
    }

    function testLateCallbackCannotWinARaceAgainstExpiration() public {
        _batch(1);
        BegVault.BatchView memory b = vault.getBatch(1);
        OracleAttestation.Attestation memory a = _attestation(1, _scores(1, 100));
        bytes memory sig = _sign(a);
        vm.warp(uint256(b.closedAt) + 24 hours);
        bytes32 questionId = _questionId(1);
        vm.prank(address(intake));
        vault.onOracleResult(questionId, a, sig);
        assertEq(uint256(vault.getBatch(1).status), uint256(BegVault.Status.Expired));
        _refundAndCheck(1, _player(1));
    }

    function testRefundRequiresPlayerAndExpiredBatch() public {
        _attempt(_player(1), "Pending entry");
        vm.prank(_player(1));
        vm.expectRevert(BegVault.InvalidBatchState.selector);
        vault.refund(1);
        vm.expectRevert(BegVault.NotPlayer.selector);
        vault.refund(1);
        vm.expectRevert(BegVault.UnknownAttempt.selector);
        vault.refund(99);
        vm.expectRevert(BegVault.UnknownBatch.selector);
        vault.expireBatch(99);
        _assertSolvent();
    }

    function _refundAndCheck(uint256 id, address player) private {
        vm.prank(player);
        vault.refund(id);
        assertTrue(vault.getAttempt(id).refunded);
        (, uint128 eth) = vault.claimable(player);
        assertEq(eth, PRICE);
        vm.prank(player);
        vm.expectRevert(BegVault.AlreadyRefunded.selector);
        vault.refund(id);
        uint256 beforeBalance = player.balance;
        vm.prank(player);
        vault.claim();
        assertEq(player.balance, beforeBalance + PRICE);
        vm.prank(player);
        vm.expectRevert(BegVault.NothingToClaim.selector);
        vault.claim();
    }

    function testFuzzOddsSumAndEndpoints(uint256 score) public view {
        (uint256 jackpot, uint256 epic, uint256 rare, uint256 common, uint256 nothing) = vault.oddsFor(score);
        assertEq(jackpot + epic + rare + common + nothing, 10_000);
        uint256 s = score > 100 ? 100 : score;
        assertEq(jackpot, 1 + 199 * s / 100);
        assertEq(epic, 200 + 11 * s);
        assertEq(rare, 800 + 22 * s);
        assertEq(common, 2000 + 15 * s);
        assertGe(nothing, 2000);
        assertLe(nothing, 6999);
    }

    function testEveryScoreOddsSumsToTenThousand() public view {
        for (uint256 s; s <= 100; ++s) {
            (uint256 j, uint256 e, uint256 r, uint256 c, uint256 n) = vault.oddsFor(s);
            assertEq(j + e + r + c + n, 10_000);
        }
    }
}
