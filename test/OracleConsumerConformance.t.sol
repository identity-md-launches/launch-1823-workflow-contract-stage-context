// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {BegVault} from "../src/BegVault.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {OracleAttestation} from "../src/OracleAttestation.sol";
import {MockIMD, MockIntake} from "./mocks/MockIntake.sol";

/// @notice Protocol-owned test vector, adapted only to BegVault's request setup.
contract OracleConsumerConformanceTest is Test {
    uint256 constant VECTOR_CHAIN = 11155111;
    address constant VECTOR_CONSUMER = 0x0000000000000000000000000000000000002748;
    bytes32 constant VECTOR_DIGEST = 0x95fefa8b7c529852f4e2b6aec888930eb2bf5078e6443a85808e36df19e1325c;
    bytes constant VECTOR_SIGNATURE =
        hex"a26b14918607eb565af126beb54d3c5d19e923c41506def500b3521a4f9aa6d603ab44fd22f15dd2191732961a7131e4641244add8b0f09f20e6ae64381be8481b";
    address constant SIGNER = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8;
    uint256 constant SIGNER_KEY = 0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d;
    uint64 constant ISSUED_AT = 1800000000;
    uint64 constant EXPIRES_AT = 1800003600;
    string constant CALLBACK =
        "onOracleResult(bytes32,(bytes32,uint256,bytes32,uint8,bytes,uint256,uint64,uint64,bytes32,bytes32,uint16,uint16,uint16,uint64,uint64),bytes)";

    BegVault consumer;
    MockIntake intake;
    bytes32 sourceRequestId;

    function setUp() public {
        vm.chainId(VECTOR_CHAIN);
        vm.warp(ISSUED_AT - 30 minutes);
        vm.roll(1_000);
        LaunchToken token = new LaunchToken();
        MockIMD imd = new MockIMD();
        intake = new MockIntake();
        deployCodeTo(
            "BegVault.sol:BegVault",
            abi.encode(address(token), address(this), address(intake), address(imd), SIGNER, 0.005 ether),
            VECTOR_CONSUMER
        );
        consumer = BegVault(VECTOR_CONSUMER);
        vm.setNonce(VECTOR_CONSUMER, 1); // etched code has nonce 0; a created contract starts at 1
        token.transfer(VECTOR_CONSUMER, 800_000_000 ether);
        imd.mint(address(this), 1 ether);
        imd.approve(VECTOR_CONSUMER, 1 ether);
        consumer.fundOracle(1 ether);
        vm.deal(address(this), 1 ether);
        consumer.attempt{value: 0.005 ether}("A protocol vector's humble request");
        vm.warp(ISSUED_AT);
        consumer.closeBatch();
        sourceRequestId = keccak256(abi.encode(uint256(1)));
        assertEq(consumer.questionBatch(sourceRequestId), 1);
    }

    function vector() internal pure returns (OracleAttestation.Attestation memory a) {
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = bytes32(uint256(1));
        a = OracleAttestation.Attestation({
            requestId: 0x0000000000004000800000000000000100000000000000000000000000000000,
            chainId: 1,
            questionHash: 0x2117f4362ebfa37aa8a8c0fed548604fe09ac46faf8ae7559cd64780f26a46fb,
            answerType: OracleAttestation.ANSWER_BYTES32_LIST,
            answer: abi.encode(ids),
            figure: 12345,
            fromBlock: 100,
            toBlock: 200,
            blockHash: bytes32(uint256(7)),
            panelJobId: 0x0000000000004000800000000000000200000000000000000000000000000000,
            panelSize: 5,
            quorum: 4,
            agreed: 5,
            issuedAt: ISSUED_AT,
            expiresAt: EXPIRES_AT
        });
    }

    function testDigestMatchesTheProtocol() public view {
        assertEq(consumer.attestationDigest(vector()), VECTOR_DIGEST);
    }

    function testCallbackSelectorIsCanonical() public view {
        assertEq(consumer.onOracleResult.selector, bytes4(keccak256(bytes(CALLBACK))));
    }

    function testAcceptsTheProtocolSignatureAsDelivered() public {
        vm.cool(address(consumer));
        (bool called,) = intake.deliver(sourceRequestId, vector(), VECTOR_SIGNATURE);
        assertTrue(called, "canonical callback failed under 200,000 gas");
        assertTrue(consumer.consumed(vector().requestId));
        assertEq(uint256(consumer.getBatch(1).status), uint256(BegVault.Status.Graded));
    }

    function testAcceptsAFreshSignatureFromTheVectorKey() public {
        OracleAttestation.Attestation memory a = vector();
        a.requestId = keccak256("another request");
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER_KEY, consumer.attestationDigest(a));
        vm.prank(address(intake));
        consumer.onOracleResult(sourceRequestId, a, abi.encodePacked(r, s, v));
        assertTrue(consumer.consumed(a.requestId));
    }
}
