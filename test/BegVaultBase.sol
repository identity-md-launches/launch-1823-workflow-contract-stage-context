// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {BegVault} from "../src/BegVault.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {OracleAttestation, OracleAttestationConsumer} from "../src/OracleAttestation.sol";
import {MockIntake, MockIMD} from "./mocks/MockIntake.sol";

abstract contract BegVaultBase is Test {
    BegVault internal vault;
    LaunchToken internal token;
    MockIMD internal imd;
    MockIntake internal intake;
    uint256 internal constant PRICE = 0.005 ether;
    uint256 internal constant SIGNER_KEY = uint256(keccak256("BegVault local attester"));
    address internal constant TEAM = 0xA7e99BB7155D7477E0C838E201b16E62B9c0b5Ac;

    function setUp() public virtual {
        vm.chainId(1);
        vm.warp(1_800_000_000);
        vm.roll(1_000);
        vm.prevrandao(bytes32(uint256(101)));
        token = new LaunchToken();
        imd = new MockIMD();
        intake = new MockIntake();
        vault = new BegVault(address(token), TEAM, address(intake), address(imd), vm.addr(SIGNER_KEY), PRICE);
        token.transfer(address(vault), 800_000_000 ether);
        imd.mint(address(this), 100 ether);
        imd.approve(address(vault), type(uint256).max);
        vault.fundOracle(100 ether);
        vm.deal(address(this), 100 ether);
    }

    function _player(uint256 i) internal pure returns (address) {
        return address(uint160(0x1000 + i));
    }

    function _attempt(address player, string memory text) internal returns (uint256 id) {
        vm.deal(player, player.balance + PRICE);
        vm.prank(player);
        id = vault.attempt{value: PRICE}(text);
    }

    function _batch(uint256 size) internal returns (uint256 batchId) {
        batchId = vault.openBatchId();
        for (uint256 i; i < size; ++i) {
            uint256 id = vault.nextAttemptId();
            _attempt(_player(id), string.concat("I beg you for a crumb, entry ", vm.toString(id)));
        }
        if (size < 20) {
            vm.warp(vm.getBlockTimestamp() + 30 minutes);
            vault.closeBatch();
        }
    }

    function _scores(uint256 size, uint256 score) internal pure returns (bytes32[] memory scores) {
        scores = new bytes32[](size);
        for (uint256 i; i < size; ++i) {
            scores[i] = bytes32(score);
        }
    }

    function _attestation(uint256 batchId, bytes32[] memory scores)
        internal
        view
        returns (OracleAttestation.Attestation memory a)
    {
        BegVault.BatchView memory b = vault.getBatch(batchId);
        a = OracleAttestation.Attestation({
            requestId: keccak256(abi.encode("oracle UUID", _questionId(batchId))),
            chainId: 1,
            questionHash: keccak256(intake.lastBody()),
            answerType: OracleAttestation.ANSWER_BYTES32_LIST,
            answer: abi.encode(scores),
            figure: 0,
            fromBlock: 900,
            toBlock: 999,
            blockHash: bytes32(uint256(81)),
            panelJobId: keccak256(abi.encode("panel", batchId)),
            panelSize: 5,
            quorum: 3,
            agreed: 3,
            issuedAt: uint64(vm.getBlockTimestamp()),
            expiresAt: uint64(vm.getBlockTimestamp() + 1 hours)
        });
    }

    function _sign(OracleAttestation.Attestation memory a) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER_KEY, vault.attestationDigest(a));
        return abi.encodePacked(r, s, v);
    }

    function _grade(uint256 batchId, uint256 score) internal {
        BegVault.BatchView memory b = vault.getBatch(batchId);
        OracleAttestation.Attestation memory a = _attestation(batchId, _scores(b.size, score));
        bytes memory sig = _sign(a);
        // Clear EIP-2929 warming from preparatory reads to measure the actual cold callback.
        vm.cool(address(vault));
        (bool ok, bytes memory result) = intake.deliver(_questionId(batchId), a, sig);
        if (!ok) {
            assembly ("memory-safe") { revert(add(result, 32), mload(result)) }
        }
        assertEq(uint256(vault.getBatch(batchId).status), uint256(BegVault.Status.Graded));
    }

    function _reveal(uint256 batchId, bytes32 hash) internal {
        BegVault.BatchView memory b = vault.getBatch(batchId);
        vm.roll(uint256(b.rollBlock) + 1);
        vm.setBlockhash(b.rollBlock, hash);
        vault.reveal(batchId);
    }

    /// @dev Intake ids are the mock's request counter hashes; the vault maps each to its batch.
    function _questionId(uint256 batchId) internal view returns (bytes32) {
        for (uint256 n = intake.requests(); n > 0; --n) {
            bytes32 id = keccak256(abi.encode(n));
            if (vault.questionBatch(id) == batchId) return id;
        }
        revert("no question for batch");
    }

    function _assertSolvent() internal view {
        assertEq(
            address(vault).balance,
            uint256(vault.escrowedETH()) + vault.jackpotBank() + vault.oracleBudget()
                + vault.totalClaimableETH()
        );
        assertEq(token.balanceOf(address(vault)), vault.vaultFreeBalance() + vault.totalClaimableTokens());
    }

    receive() external payable {}
}
