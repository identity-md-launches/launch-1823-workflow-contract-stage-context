// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BegVaultBase} from "./BegVaultBase.sol";
import {BegVault} from "src/BegVault.sol";
import {OracleAttestation} from "src/OracleAttestation.sol";

/// @notice Metamorphic properties: changing an irrelevant input cannot change a player's roll.
contract RewardPropertiesTest is BegVaultBase {
    /// forge-config: default.fuzz.runs = 512
    function testFuzzOddsAreMonotoneAcrossScoresAndClampAtMaximum(uint8 rawLow, uint8 rawHigh) public view {
        uint256 low = bound(rawLow, 0, 100);
        uint256 high = bound(rawHigh, low, 100);
        (uint256 j0, uint256 e0, uint256 r0, uint256 c0, uint256 n0) = vault.oddsFor(low);
        (uint256 j1, uint256 e1, uint256 r1, uint256 c1, uint256 n1) = vault.oddsFor(high);
        assertEq(j0 + e0 + r0 + c0 + n0, 10_000);
        assertEq(j1 + e1 + r1 + c1 + n1, 10_000);
        assertGe(j1, j0);
        assertGe(e1, e0);
        assertGe(r1, r0);
        assertGe(c1, c0);
        assertLe(n1, n0);
        (j0, e0, r0, c0, n0) = vault.oddsFor(100);
        (j1, e1, r1, c1, n1) = vault.oddsFor(type(uint256).max);
        assertEq(abi.encode(j0, e0, r0, c0, n0), abi.encode(j1, e1, r1, c1, n1));
    }

    function testSameAccountAccumulatesTeamJackpotAndBountyWithoutOverwritingCredits() public {
        _attempt(TEAM, "The team wallet is also an ordinary player");
        _attempt(_player(2), "A second player makes the bounty affordable");
        vm.warp(vm.getBlockTimestamp() + 30 minutes);
        vault.closeBatch();
        _grade(1, 100);
        uint256 freeBefore = vault.vaultFreeBalance();
        uint256 bankBefore = vault.jackpotBank();
        bytes32 hash = _hashForFirstTier(1, BegVault.Tier.Jackpot);
        uint256 rollBlock = vault.getBatch(1).rollBlock;
        vm.roll(rollBlock + 1);
        vm.setBlockhash(rollBlock, hash);
        vm.prank(TEAM);
        vault.reveal(1);
        (uint128 tokens, uint128 eth) = vault.claimable(TEAM);
        assertEq(tokens, freeBefore / 100);
        assertEq(eth, 2 * PRICE / 10 + bankBefore / 2 + 0.001 ether);
        uint256 beforeBalance = TEAM.balance;
        vm.prank(TEAM);
        vault.claim();
        assertEq(token.balanceOf(TEAM), tokens);
        assertEq(TEAM.balance - beforeBalance, eth);
        _assertSolvent();
    }

    /// forge-config: default.fuzz.runs = 256
    function testFuzzMixedScoresRollInsideTheAdvertisedCumulativeOdds(bytes32 entropy) public {
        _batch(20);
        bytes32[] memory scores = new bytes32[](20);
        for (uint256 i; i < 20; ++i) {
            scores[i] = bytes32(uint256(keccak256(abi.encode(entropy, i))) % 101);
        }
        scores[0] = bytes32(0);
        scores[19] = bytes32(type(uint256).max);
        OracleAttestation.Attestation memory a = _attestation(1, scores);
        bytes memory signature = _sign(a);
        (bool ok,) = intake.deliver(_questionId(1), a, signature);
        assertTrue(ok);
        bytes32 hash = keccak256(abi.encode("mixed score roll", entropy));
        uint256 randao = vault.getBatch(1).prevrandao;
        bytes32 seed = keccak256(abi.encode(hash, randao, uint256(1), address(vault)));
        _reveal(1, hash);
        for (uint256 i; i < 20; ++i) {
            BegVault.AttemptView memory entry = vault.getAttempt(i + 1);
            uint256 score = uint256(scores[i]) > 100 ? 100 : uint256(scores[i]);
            assertEq(entry.score, score);
            (uint256 j, uint256 e, uint256 r, uint256 c, uint256 n) = vault.oddsFor(score);
            uint256[5] memory widths = [j, e, r, c, n];
            uint256 interval = 4 - uint256(entry.tier);
            uint256 lower;
            for (uint256 k; k < interval; ++k) {
                lower += widths[k];
            }
            uint256 roll = uint256(keccak256(abi.encode(seed, i))) % 10_000;
            assertGe(roll, lower, "roll fell below the advertised tier interval");
            assertLt(roll, lower + widths[interval], "roll fell above the advertised tier interval");
        }
        _assertSolvent();
    }

    function testRepeatedPlayerCreditsSumAcrossBothAnExpiredAndAGradedBatch() public {
        address player = _player(1);
        _attempt(player, "First request times out");
        vm.warp(vm.getBlockTimestamp() + 30 minutes);
        vault.closeBatch();
        vm.warp(vm.getBlockTimestamp() + 24 hours);
        vault.expireBatch(1);
        vm.prank(player);
        vault.refund(1);
        _attempt(player, "Second request wins");
        vm.warp(vm.getBlockTimestamp() + 10 minutes);
        _attempt(player, "Third request is independently rolled");
        vm.warp(vm.getBlockTimestamp() + 20 minutes);
        vault.closeBatch();
        _grade(2, 100);
        _reveal(2, _hashForFirstTier(2, BegVault.Tier.Jackpot));
        BegVault.AttemptView memory first = vault.getAttempt(2);
        BegVault.AttemptView memory second = vault.getAttempt(3);
        (uint128 tokens, uint128 eth) = vault.claimable(player);
        assertEq(tokens, uint256(first.tokenAmount) + second.tokenAmount);
        assertEq(eth, PRICE + uint256(first.ethAmount) + second.ethAmount);
        uint256 free = vault.vaultFreeBalance();
        vm.prank(player);
        vault.claim();
        assertEq(vault.vaultFreeBalance(), free);
        assertEq(token.balanceOf(player), tokens);
        assertEq(player.balance, eth);
        assertTrue(vault.getAttempt(1).refunded);
        assertEq(vault.getAttempt(2).tokenAmount, first.tokenAmount, "historical payouts survive claim");
        _assertSolvent();
    }

    /// forge-config: default.fuzz.runs = 128
    function testFuzzClaimingExistingCreditsCannotChangeALaterBatch(uint8 rawSize, bytes32 rawHash) public {
        _batch(1);
        _grade(1, 100);
        _reveal(1, _hashForFirstTier(1, BegVault.Tier.Jackpot));
        _batch(bound(rawSize, 1, 20));
        _grade(2, 71);
        bytes32 hash = keccak256(abi.encode("future hash", rawHash));
        uint256 snapshot = vm.snapshotState();
        _reveal(2, hash);
        bytes32 withoutClaim = _outcome(2);
        assertTrue(vm.revertToStateAndDelete(snapshot));
        uint256 freeBefore = vault.vaultFreeBalance();
        vm.prank(_player(1));
        vault.claim();
        assertEq(vault.vaultFreeBalance(), freeBefore);
        _reveal(2, hash);
        assertEq(_outcome(2), withoutClaim, "claim timing must not change free balances or payouts");
        _assertSolvent();
    }

    /// forge-config: default.fuzz.runs = 128
    function testFuzzRevealerAndCurrentRandaoCannotChangeCommittedRoll(bytes32 entropy, uint8 rawScore)
        public
    {
        _batch(20);
        _grade(1, bound(rawScore, 0, 100));
        uint256 rollBlock = vault.getBatch(1).rollBlock;
        bytes32 hash = keccak256(abi.encode("committed block hash", entropy));
        vm.roll(rollBlock + 1);
        vm.setBlockhash(rollBlock, hash);
        uint256 snapshot = vm.snapshotState();
        vm.prank(_player(1));
        vault.reveal(1);
        bytes32 first = _outcome(1);
        BegVault.AttemptView memory firstAttempt = vault.getAttempt(1);
        (, uint128 firstCredit) = vault.claimable(_player(1));
        assertEq(firstCredit, uint256(firstAttempt.ethAmount) + 0.001 ether);
        assertTrue(vm.revertToStateAndDelete(snapshot));
        vm.prevrandao(keccak256(abi.encode("different reveal randao", entropy)));
        vm.prank(_player(40));
        vault.reveal(1);
        assertEq(_outcome(1), first);
        (, uint128 playerCredit) = vault.claimable(_player(1));
        (, uint128 revealerCredit) = vault.claimable(_player(40));
        assertEq(playerCredit, firstAttempt.ethAmount);
        assertEq(revealerCredit, 0.001 ether);
        _assertSolvent();
    }

    function testOverlappingBatchesUseTheirOwnScoresRandaoAndAttemptIndices() public {
        _batch(3);
        _batch(2);
        bytes32[] memory secondScores = new bytes32[](2);
        secondScores[0] = bytes32(uint256(99));
        secondScores[1] = bytes32(type(uint256).max);
        OracleAttestation.Attestation memory a = _attestation(2, secondScores);
        vm.prevrandao(bytes32(uint256(202)));
        bytes memory signature = _sign(a);
        (bool ok,) = intake.deliver(_questionId(2), a, signature);
        assertTrue(ok);
        vm.prevrandao(bytes32(uint256(303)));
        _grade(1, 7);
        _reveal(2, keccak256("batch two revealed first"));
        _reveal(1, keccak256("batch one revealed second"));
        assertEq(vault.getBatch(1).prevrandao, 303);
        assertEq(vault.getBatch(2).prevrandao, 202);
        for (uint256 i = 1; i <= 5; ++i) {
            BegVault.AttemptView memory attempt = vault.getAttempt(i);
            assertEq(attempt.batchId, i <= 3 ? 1 : 2);
            assertEq(attempt.index, i <= 3 ? i - 1 : i - 4);
            assertEq(attempt.score, i <= 3 ? 7 : i == 4 ? 99 : 100);
        }
        _assertSolvent();
    }

    function testRepeatedRearmsNeverPayAndRetainTheOriginalGrade() public {
        _batch(20);
        _grade(1, 87);
        BegVault.BatchView memory original = vault.getBatch(1);
        bytes32 accountingBefore = _accounting();
        for (uint256 i; i < 3; ++i) {
            uint256 oldBlock = vault.getBatch(1).rollBlock;
            vm.roll(oldBlock + 257);
            vm.prevrandao(bytes32(i + 1000));
            vault.reveal(1);
            BegVault.BatchView memory current = vault.getBatch(1);
            assertEq(current.rollBlock, vm.getBlockNumber() + 2);
            assertEq(current.seed, bytes32(0));
            assertEq(current.prevrandao, original.prevrandao);
            assertEq(current.scores, original.scores);
            assertEq(current.missedWindows, i + 1);
            assertEq(uint256(current.status), uint256(BegVault.Status.Graded));
            assertEq(_accounting(), accountingBefore);
        }
        _reveal(1, keccak256("finally available"));
        (, uint128 bounty) = vault.claimable(address(this));
        assertEq(bounty, 0.001 ether);
        // Three missed windows forfeit Jackpot, Epic and Rare: no entry may exceed Common.
        for (uint256 i = 1; i <= 20; ++i) {
            BegVault.AttemptView memory a = vault.getAttempt(i);
            assertLe(uint256(a.tier), uint256(BegVault.Tier.Common));
            assertEq(a.ethAmount, 0);
        }
        _assertSolvent();
    }

    function testBountyAtOneWeiBelowThresholdIsZero() public {
        _batch(1);
        _grade(1, 100);
        vault.fundOracle{value: 0.0005 ether - 1}();
        _reveal(1, keccak256("one wei short"));
        (, uint128 bounty) = vault.claimable(address(this));
        assertEq(bounty, 0);
        assertEq(vault.oracleBudget(), 0.001 ether - 1);
        _assertSolvent();
    }

    function testTinyPrizeBalancesRoundDownAndZeroTokenJackpotStillPaysETH() public {
        _freshVault(PRICE, 99);
        _batch(1);
        _grade(1, 100);
        _reveal(1, _hashForFirstTier(1, BegVault.Tier.Jackpot));
        (uint128 tokens, uint128 eth) = vault.claimable(_player(1));
        assertEq(tokens, 0);
        assertEq(eth, PRICE * 4 / 10);
        assertEq(vault.vaultFreeBalance(), 99);
        vm.prank(_player(1));
        vault.claim();
        assertEq(_player(1).balance, eth);
        _assertSolvent();
    }

    function testOneWeiPricePreservesFullRefund() public {
        _freshVault(1, 1);
        vm.deal(_player(1), 1);
        vm.prank(_player(1));
        vault.attempt{value: 1}("One wei is still a complete escrow liability");
        vm.warp(vm.getBlockTimestamp() + 30 minutes + 24 hours);
        vault.expireBatch(1);
        vm.prank(_player(1));
        vault.refund(1);
        vm.prank(_player(1));
        vault.claim();
        assertEq(_player(1).balance, 1);
        assertEq(vault.escrowedETH(), 0);
        _assertSolvent();
    }

    function testMaximumPriceTwentyEntriesDoNotTruncateEscrowOrCredits() public {
        uint256 price = type(uint80).max;
        _freshVault(price, 1_000_000 ether);
        for (uint256 i = 1; i <= 20; ++i) {
            vm.deal(_player(i), price);
            vm.prank(_player(i));
            vault.attempt{value: price}(vm.toString(i));
        }
        uint256 gross = 20 * price;
        assertEq(vault.escrowedETH(), gross);
        _grade(1, 100);
        assertEq(vault.escrowedETH(), 0);
        assertEq(vault.jackpotBank(), gross - gross / 10 - 0.001 ether);
        assertEq(vault.oracleBudget(), 0.001 ether);
        (, uint128 teamCredit) = vault.claimable(TEAM);
        assertEq(teamCredit, gross / 10);
        _reveal(1, _hashForFirstTier(1, BegVault.Tier.Jackpot));
        for (uint256 i = 1; i <= 20; ++i) {
            (uint128 tokens, uint128 eth) = vault.claimable(_player(i));
            if (tokens != 0 || eth != 0) {
                vm.prank(_player(i));
                vault.claim();
                assertEq(_player(i).balance, eth);
                assertEq(token.balanceOf(_player(i)), tokens);
            }
        }
        _assertSolvent();
    }

    function _freshVault(uint256 price, uint256 rewardBalance) private {
        vault = new BegVault(address(token), TEAM, address(intake), address(imd), vm.addr(SIGNER_KEY), price);
        token.transfer(address(vault), rewardBalance);
        imd.mint(address(this), 2 ether);
        imd.approve(address(vault), 2 ether);
        vault.fundOracle(2 ether);
    }

    function _hashForFirstTier(uint256 id, BegVault.Tier tier) private view returns (bytes32) {
        BegVault.BatchView memory b = vault.getBatch(id);
        for (uint256 n = 1; n < 4096; ++n) {
            bytes32 hash = keccak256(abi.encode("tier fixture", n));
            bytes32 seed = keccak256(abi.encode(hash, b.prevrandao, id, address(vault)));
            uint256 roll = uint256(keccak256(abi.encode(seed, uint256(0)))) % 10_000;
            if (tier == BegVault.Tier.Jackpot && roll < 200) return hash;
        }
        revert("fixture could not find requested tier");
    }

    function _outcome(uint256 id) private view returns (bytes32 result) {
        BegVault.BatchView memory b = vault.getBatch(id);
        result = keccak256(abi.encode(b, vault.jackpotBank(), vault.oracleBudget(), vault.vaultFreeBalance()));
        for (uint256 i; i < b.size; ++i) {
            result = keccak256(abi.encode(result, vault.getAttempt(uint256(b.firstAttemptId) + i)));
        }
    }

    function _accounting() private view returns (bytes32) {
        return keccak256(
            abi.encode(
                address(vault).balance,
                vault.escrowedETH(),
                vault.jackpotBank(),
                vault.oracleBudget(),
                vault.totalClaimableETH(),
                vault.totalClaimableTokens(),
                vault.vaultFreeBalance()
            )
        );
    }
}
