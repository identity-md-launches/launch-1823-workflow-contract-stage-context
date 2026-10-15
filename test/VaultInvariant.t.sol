// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BegVaultBase} from "./BegVaultBase.sol";
import {Test} from "forge-std/Test.sol";
import {BegVault} from "../src/BegVault.sol";
import {OracleAttestation} from "../src/OracleAttestation.sol";
import {MockIntake} from "./mocks/MockIntake.sol";

contract VaultHandler is Test {
    BegVault public immutable vault;
    MockIntake public immutable intake;
    address public immutable team;
    uint256 private immutable signerKey;
    uint256 public deposits;
    uint256 public withdrawals;
    uint256 private nonce;

    constructor(BegVault vault_, MockIntake intake_, address team_, uint256 key_) {
        vault = vault_;
        intake = intake_;
        team = team_;
        signerKey = key_;
    }

    function actor(uint256 i) public pure returns (address) {
        return address(uint160(0xB000 + i % 8));
    }

    function enter(uint256 actorSeed) external {
        address player = actor(actorSeed);
        vm.deal(player, player.balance + 0.005 ether);
        string memory text = string.concat("Stateful plea ", vm.toString(++nonce));
        vm.prank(player);
        try vault.attempt{value: 0.005 ether}(text) returns (uint256) {
            deposits += 0.005 ether;
        } catch {}
    }

    function advance(uint32 delta) external {
        vm.warp(vm.getBlockTimestamp() + delta % 26 hours);
    }

    function close() external {
        try vault.closeBatch() {} catch {}
    }

    function grade(uint256 batchSeed, uint8 score) external {
        uint256 id = 1 + batchSeed % vault.openBatchId();
        BegVault.BatchView memory b;
        try vault.getBatch(id) returns (BegVault.BatchView memory value) {
            b = value;
        } catch {
            return;
        }
        if (b.status != BegVault.Status.Pending) return;
        bytes32[] memory scores = new bytes32[](b.size);
        for (uint256 i; i < b.size; ++i) {
            scores[i] = bytes32(uint256(score));
        }
        OracleAttestation.Attestation memory a;
        bytes32 questionId = _questionId(id);
        a.requestId = keccak256(abi.encode("stateful UUID", questionId));
        a.chainId = 1;
        a.answerType = OracleAttestation.ANSWER_BYTES32_LIST;
        a.answer = abi.encode(scores);
        a.panelSize = 5;
        a.quorum = 3;
        a.agreed = 5;
        a.issuedAt = uint64(vm.getBlockTimestamp());
        a.expiresAt = a.issuedAt + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, vault.attestationDigest(a));
        intake.deliver(questionId, a, abi.encodePacked(r, s, v));
    }

    function _questionId(uint256 batchId) private view returns (bytes32) {
        for (uint256 n = intake.requests(); n > 0; --n) {
            bytes32 id = keccak256(abi.encode(n));
            if (vault.questionBatch(id) == batchId) return id;
        }
        revert("no question for batch");
    }

    function expire(uint256 batchSeed) external {
        uint256 id = 1 + batchSeed % vault.openBatchId();
        try vault.expireBatch(id) {} catch {}
    }

    function reveal(uint256 batchSeed, bytes32 hash, bool missWindow) external {
        uint256 id = 1 + batchSeed % vault.openBatchId();
        BegVault.BatchView memory b;
        try vault.getBatch(id) returns (BegVault.BatchView memory value) {
            b = value;
        } catch {
            return;
        }
        if (b.status != BegVault.Status.Graded) return;
        uint256 next = uint256(b.rollBlock) + (missWindow ? 257 : 1);
        if (next > vm.getBlockNumber()) vm.roll(next);
        if (!missWindow && hash != bytes32(0) && vm.getBlockNumber() <= uint256(b.rollBlock) + 256) {
            vm.setBlockhash(b.rollBlock, hash);
        }
        vault.reveal(id);
    }

    function refund(uint256 attemptSeed) external {
        uint256 count = vault.nextAttemptId() - 1;
        if (count == 0) return;
        uint256 id = 1 + attemptSeed % count;
        address player = vault.getAttempt(id).player;
        vm.prank(player);
        try vault.refund(id) {} catch {}
    }

    function claim(uint256 actorSeed) external {
        address player =
            actorSeed % 10 < 8 ? actor(actorSeed % 10) : actorSeed % 10 == 8 ? team : address(this);
        (, uint128 eth) = vault.claimable(player);
        vm.prank(player);
        try vault.claim() {
            withdrawals += eth;
        } catch {}
    }

    function fund(uint96 amount) external {
        uint256 value = uint256(amount) % 1 ether;
        vm.deal(address(this), address(this).balance + value);
        vault.fundOracle{value: value}();
        deposits += value;
    }

    receive() external payable {}
}

contract VaultInvariantTest is BegVaultBase {
    VaultHandler handler;

    function setUp() public override {
        super.setUp();
        intake.setRecordBody(false);
        handler = new VaultHandler(vault, intake, TEAM, SIGNER_KEY);
        bytes4[] memory selectors = new bytes4[](9);
        selectors[0] = handler.enter.selector;
        selectors[1] = handler.advance.selector;
        selectors[2] = handler.close.selector;
        selectors[3] = handler.grade.selector;
        selectors[4] = handler.expire.selector;
        selectors[5] = handler.reveal.selector;
        selectors[6] = handler.refund.selector;
        selectors[7] = handler.claim.selector;
        selectors[8] = handler.fund.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
        targetContract(address(handler));
    }

    function invariantETHAndTokenLiabilitiesAreFullyBacked() public view {
        _assertSolvent();
    }

    function invariantNoETHIsCreatedLostOrPaidTwice() public view {
        assertEq(address(vault).balance, handler.deposits() - handler.withdrawals());
    }

    function invariantCreditsEqualIndividualBalances() public view {
        uint256 tokens;
        uint256 eth;
        for (uint256 i; i < 10; ++i) {
            address account = i < 8 ? handler.actor(i) : i == 8 ? TEAM : address(handler);
            (uint128 t, uint128 e) = vault.claimable(account);
            tokens += t;
            eth += e;
        }
        assertEq(tokens, vault.totalClaimableTokens());
        assertEq(eth, vault.totalClaimableETH());
    }

    function invariantEscrowExactlyCoversUnsettledAndUnrefundedAttempts() public view {
        uint256 escrow;
        for (uint256 i = 1; i < vault.nextAttemptId(); ++i) {
            BegVault.AttemptView memory a = vault.getAttempt(i);
            BegVault.BatchView memory b = vault.getBatch(a.batchId);
            if (
                b.status == BegVault.Status.Open || b.status == BegVault.Status.Pending
                    || (b.status == BegVault.Status.Expired && !a.refunded)
            ) escrow += PRICE;
        }
        assertEq(escrow, vault.escrowedETH());
    }
}
