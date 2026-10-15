// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {BegVault} from "src/BegVault.sol";
import {LaunchToken} from "src/LaunchToken.sol";
import {IIntake} from "src/interfaces/IIntake.sol";
import {OracleAttestation, OracleAttestationConsumer} from "src/OracleAttestation.sol";
import {MockIMD} from "./mocks/MockIntake.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

/// @dev Fault injection at the dependency boundary, not an implementation of production Intake.
/// Unlike a mock that only reverts before payment, this writes state and pulls IMD first.
/// Delivery records completion even when its single 200,000-gas callback fails.
contract FaultInjectingIntake is IIntake {
    enum Fault {
        None,
        Quote,
        AfterPull,
        ZeroId,
        DuplicateId,
        Reenter
    }
    error QuoteUnavailable();
    error RequestRejectedAfterPayment();
    error AlreadyDelivered();
    error UnknownRequest();

    Fault public fault;
    uint256 public price = 0.5 ether;
    uint256 public requests;
    mapping(bytes32 => Callback) public callbacks;
    mapping(bytes32 => bool) public completed;
    bytes public lastBody;
    bytes public reentry;
    bytes public reentryResult;
    bool public reentrySucceeded;

    function configure(Fault fault_, uint256 price_, bytes calldata reentry_) external {
        fault = fault_;
        price = price_;
        reentry = reentry_;
    }

    function priceOf(bytes32 action, address asset) external view returns (uint256) {
        require(action == bytes32("oracle.request@oracle-1") && asset != address(0), "wrong quote");
        if (fault == Fault.Quote) revert QuoteUnavailable();
        return price;
    }

    function request(
        bytes32 action,
        bytes calldata body,
        Callback calldata callback,
        address asset,
        uint256 amount
    ) external payable returns (bytes32 id) {
        require(action == bytes32("oracle.request@oracle-1"), "wrong action");
        require(msg.value == 0 && amount == price && body.length <= 16_384, "wrong payment/body");
        require(
            callback.target == msg.sender && callback.selector == BegVault.onOracleResult.selector, "callback"
        );
        require(IERC20(asset).transferFrom(msg.sender, address(this), amount), "IMD pull failed");
        ++requests;
        id = keccak256(abi.encode(requests));
        lastBody = body;
        callbacks[id] = callback;
        if (fault == Fault.AfterPull) revert RequestRejectedAfterPayment();
        if (fault == Fault.ZeroId) return bytes32(0);
        if (fault == Fault.DuplicateId) return keccak256(abi.encode(uint256(1)));
        if (fault == Fault.Reenter) {
            (reentrySucceeded, reentryResult) = msg.sender.call(reentry);
        }
    }

    function complete(bytes32 id, OracleAttestation.Attestation calldata a, bytes calldata signature)
        external
        returns (bool ok, bytes memory result)
    {
        Callback memory callback = callbacks[id];
        if (callback.target == address(0)) revert UnknownRequest();
        if (completed[id]) revert AlreadyDelivered();
        completed[id] = true;
        return callback.target.call{gas: 200_000}(abi.encodeWithSelector(callback.selector, id, a, signature));
    }
}

contract IntakeFailureRecoveryTest is Test {
    uint256 private constant PRICE = 0.005 ether;
    uint256 private constant PRIZES = 800_000_000 ether;
    uint256 private constant KEY = uint256(keccak256("Intake failure tests, local attester only"));
    LaunchToken private token;
    MockIMD private imd;
    FaultInjectingIntake private intake;
    BegVault private vault;
    address private team;

    function setUp() public {
        vm.chainId(1);
        vm.warp(1_800_000_000);
        vm.roll(1_000);
        token = new LaunchToken();
        imd = new MockIMD();
        intake = new FaultInjectingIntake();
        team = makeAddr("failure suite team");
        vault = new BegVault(address(token), team, address(intake), address(imd), vm.addr(KEY), PRICE);
        token.transfer(address(vault), PRIZES);
        imd.mint(address(this), 100 ether);
        imd.approve(address(vault), 100 ether);
        vault.fundOracle(100 ether);
    }

    /// forge-config: default.fuzz.runs = 128
    function testFuzzCloseFailureRollsBackPaymentAndExternalStateThenRetries(
        uint8 rawSize,
        uint8 rawFault,
        uint96 rawFee
    ) public {
        uint256 size = bound(rawSize, 1, 19);
        uint256 fee = bound(rawFee, 1, 100 ether);
        _entries(size);
        vm.warp(vm.getBlockTimestamp() + 30 minutes);
        bytes32 beforeState = _stateDigest();
        FaultInjectingIntake.Fault fault = FaultInjectingIntake.Fault(1 + rawFault % 3);
        intake.configure(fault, fee, "");
        vm.expectRevert(_closeError(fault));
        vault.closeBatch();
        assertEq(_stateDigest(), beforeState, "failed close mutated escrow, batch or payment state");
        assertEq(intake.lastBody().length, 0, "reverted external state was retained");
        (address callback,) = intake.callbacks(_id(1));
        assertEq(callback, address(0));
        assertEq(vault.getAttempt(1).message, "failure-boundary entry 1");
        intake.configure(FaultInjectingIntake.Fault.None, fee, "");
        vault.closeBatch();
        assertEq(intake.requests(), 1);
        assertEq(imd.balanceOf(address(intake)), fee);
        assertEq(vault.oracleTokenBudget(), 100 ether - fee);
        assertEq(vault.escrowedETH(), size * PRICE);
        assertEq(vault.questionBatch(_id(1)), 1);
        assertEq(uint256(vault.getBatch(1).status), uint256(BegVault.Status.Pending));
        _assertETH(size * PRICE);
    }

    function testAutomaticCloseRejectionAfterPaymentDoesNotReserveTwentiethEntry() public {
        _entries(19);
        address player = _actor(20);
        vm.deal(player, PRICE);
        bytes32 beforeState = _stateDigest();
        uint64 creationNonce = vm.getNonce(address(vault));
        intake.configure(FaultInjectingIntake.Fault.AfterPull, 0.5 ether, "");
        vm.prank(player);
        vm.expectRevert(BegVault.OracleUnfunded.selector);
        vault.attempt{value: PRICE}("closing entry can be retried");
        assertEq(_stateDigest(), beforeState);
        assertEq(vm.getNonce(address(vault)), creationNonce);
        assertEq(vault.cooldownUntil(player), 0);
        assertFalse(vault.usedMessage(keccak256("closing entry can be retried")));
        assertEq(player.balance, PRICE);
        assertEq(vault.autoClosed(), 0);
        assertEq(vault.nextToClose(), 1);
        vm.expectRevert(BegVault.UnknownAttempt.selector);
        vault.getAttempt(20);
        intake.configure(FaultInjectingIntake.Fault.None, 0.5 ether, "");
        vm.prank(player);
        assertEq(vault.attempt{value: PRICE}("closing entry can be retried"), 20);
        assertEq(vault.getAttempt(20).player, player);
        assertEq(vault.autoClosed(), 1);
        assertEq(intake.requests(), 1);
        assertEq(imd.balanceOf(address(intake)), 0.5 ether);
        _assertETH(20 * PRICE);
    }

    function testRetiredIntakeIdCannotBeReassignedToANewBatch() public {
        _entries(1);
        vm.warp(vm.getBlockTimestamp() + 30 minutes);
        vault.closeBatch();
        vm.warp(vm.getBlockTimestamp() + 24 hours);
        vault.expireBatch(1);
        vm.prank(_actor(1));
        vault.refund(1);
        _entries(1);
        vm.warp(vm.getBlockTimestamp() + 30 minutes);
        bytes32 beforeState = _stateDigest();
        intake.configure(FaultInjectingIntake.Fault.DuplicateId, 0.5 ether, "");
        vm.expectRevert(BegVault.InvalidQuestionId.selector);
        vault.closeBatch();
        assertEq(_stateDigest(), beforeState);
        assertEq(vault.questionBatch(_id(1)), 1);
        assertEq(vault.questionBatch(_id(2)), 0);
        (address callback,) = intake.callbacks(_id(2));
        assertEq(callback, address(0));
        intake.configure(FaultInjectingIntake.Fault.None, 0.5 ether, "");
        vault.closeBatch();
        assertEq(vault.questionBatch(_id(2)), 2);
        assertEq(imd.balanceOf(address(intake)), 1 ether);
        _assertETH(2 * PRICE);
    }

    /// forge-config: default.fuzz.runs = 128
    function testFuzzOneShotFailedDeliveryStillAllowsEveryPlayerAFullRefund(
        uint8 rawSize,
        uint8 rawFailure,
        uint8 refundStart
    ) public {
        uint256 size = bound(rawSize, 1, 20);
        _entries(size);
        if (size < 20) {
            vm.warp(vm.getBlockTimestamp() + 30 minutes);
            vault.closeBatch();
        }
        OracleAttestation.Attestation memory a = _answer(1, size);
        uint256 mode = rawFailure % 4;
        bytes memory error;
        if (mode == 1) {
            a.answer = abi.encode(new bytes32[](size + 1));
            error = abi.encodeWithSelector(BegVault.WrongScoreCount.selector);
        } else if (mode == 2) {
            a.expiresAt = uint64(vm.getBlockTimestamp() - 1);
            error = abi.encodeWithSelector(OracleAttestationConsumer.AttestationExpired.selector, a.expiresAt);
        } else if (mode == 3) {
            a.agreed = 2;
            error = abi.encodeWithSelector(BegVault.InvalidPanel.selector);
        } else {
            error = abi.encodeWithSelector(OracleAttestationConsumer.BadSignature.selector);
        }
        bytes memory signature = mode == 0 ? bytes("invalid signature") : _sign(a);
        vm.cool(address(vault));
        (bool ok, bytes memory reason) = intake.complete(_id(1), a, signature);
        assertFalse(ok);
        assertEq(reason, error);
        assertTrue(intake.completed(_id(1)), "the failed callback is not retried by Intake");
        assertFalse(vault.consumed(a.requestId));
        assertEq(uint256(vault.getBatch(1).status), uint256(BegVault.Status.Pending));
        assertEq(vault.escrowedETH(), size * PRICE);
        assertEq(vault.totalClaimableETH(), 0);
        OracleAttestation.Attestation memory corrected = _answer(1, size);
        bytes memory correctedSignature = _sign(corrected);
        vm.expectRevert(FaultInjectingIntake.AlreadyDelivered.selector);
        intake.complete(_id(1), corrected, correctedSignature);
        vm.prank(_actor(1));
        vm.expectRevert(BegVault.InvalidBatchState.selector);
        vault.refund(1);
        uint256 deadline = vault.getBatch(1).closedAt + 24 hours;
        vm.warp(deadline - 1);
        vm.expectRevert(BegVault.TooEarly.selector);
        vault.expireBatch(1);
        vm.warp(deadline);
        vault.expireBatch(1);
        for (uint256 i; i < size; ++i) {
            uint256 id = (uint256(refundStart) + i) % size + 1;
            address player = _actor(id);
            vm.startPrank(player);
            vault.refund(id);
            vault.claim();
            vm.expectRevert(BegVault.AlreadyRefunded.selector);
            vault.refund(id);
            vm.expectRevert(BegVault.NothingToClaim.selector);
            vault.claim();
            vm.stopPrank();
            assertEq(player.balance, PRICE, "a failed oracle charged a player");
            assertEq(vault.getAttempt(id).refunded, true);
            assertEq(vault.escrowedETH(), (size - i - 1) * PRICE);
        }
        assertEq(vault.totalClaimableETH(), 0);
        assertEq(vault.jackpotBank(), 0);
        assertEq(vault.oracleBudget(), 0);
        assertEq(vault.vaultFreeBalance(), PRIZES);
        assertEq(imd.balanceOf(address(intake)), 0.5 ether, "spent oracle fees are not refundable");
        assertEq(vault.oracleTokenBudget(), 99.5 ether);
        _assertETH(0);
    }

    /// forge-config: default.fuzz.runs = 64
    function testFuzzReentrantIntakeCannotEnterAnyMutatorDuringClose(uint8 rawSelector) public {
        _entries(1);
        vm.warp(vm.getBlockTimestamp() + 30 minutes);
        bytes[] memory calls = new bytes[](10);
        calls[0] = abi.encodeCall(BegVault.attempt, ("nested attempt"));
        calls[1] = abi.encodeWithSignature("closeBatch()");
        calls[2] = abi.encodeWithSignature("closeBatch(uint256)", 1);
        calls[3] = abi.encodeCall(BegVault.expireBatch, (1));
        calls[4] = abi.encodeCall(BegVault.reveal, (1));
        calls[5] = abi.encodeCall(BegVault.refund, (1));
        calls[6] = abi.encodeCall(BegVault.claim, ());
        calls[7] = abi.encodeWithSignature("fundOracle(uint256)", 0);
        calls[8] = abi.encodeWithSignature("fundOracle()");
        calls[9] = abi.encodeCall(BegVault.onOracleResult, (_id(1), _answer(1, 1), bytes("")));
        intake.configure(FaultInjectingIntake.Fault.Reenter, 0.5 ether, calls[rawSelector % 10]);
        vault.closeBatch();
        assertFalse(intake.reentrySucceeded());
        assertEq(
            intake.reentryResult(),
            abi.encodeWithSelector(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector)
        );
        assertEq(vault.nextAttemptId(), 2);
        assertEq(vault.questionBatch(_id(1)), 1);
        assertEq(vault.totalClaimableETH(), 0);
        assertEq(vault.escrowedETH(), PRICE);
        // The guard must be clear in a later transaction from the same Intake.
        OracleAttestation.Attestation memory a = _answer(1, 1);
        bytes memory signature = _sign(a);
        vm.cool(address(vault));
        (bool ok,) = intake.complete(_id(1), a, signature);
        assertTrue(ok);
        assertEq(uint256(vault.getBatch(1).status), uint256(BegVault.Status.Graded));
        _assertETH(PRICE);
    }

    function testApprovalFailureAfterFundingPullRestoresDonorBalanceAndAllowance() public {
        imd.mint(address(this), 1 ether);
        imd.approve(address(vault), 1 ether);
        vm.mockCall(address(imd), abi.encodeWithSelector(IERC20.approve.selector), abi.encode(false));
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(imd)));
        vault.fundOracle(1 ether);
        assertEq(imd.balanceOf(address(this)), 1 ether);
        assertEq(imd.allowance(address(this), address(vault)), 1 ether);
        assertEq(vault.oracleTokenBudget(), 100 ether);
        vm.clearMockedCalls();
        vault.fundOracle(1 ether);
        assertEq(imd.balanceOf(address(this)), 0);
        assertEq(imd.allowance(address(this), address(vault)), 0);
        assertEq(vault.oracleTokenBudget(), 101 ether);
        _assertETH(0);
    }

    function testDirectIMDDonationNeedsAllowanceAndAnyoneCanEstablishItWithZeroFunding() public {
        vault = new BegVault(address(token), team, address(intake), address(imd), vm.addr(KEY), PRICE);
        token.transfer(address(vault), 1 ether);
        imd.mint(address(vault), 0.5 ether); // Models tokens received without calling fundOracle.
        _entries(1);
        vm.warp(vm.getBlockTimestamp() + 30 minutes);
        vm.expectRevert(BegVault.OracleUnfunded.selector);
        vault.closeBatch();
        assertEq(vault.oracleTokenBudget(), 0.5 ether);
        assertEq(imd.allowance(address(vault), address(intake)), 0);
        address sponsor = makeAddr("zero-balance sponsor");
        assertEq(imd.balanceOf(sponsor), 0);
        vm.prank(sponsor);
        vault.fundOracle(0);
        assertEq(imd.allowance(address(vault), address(intake)), type(uint256).max);
        vault.closeBatch();
        assertEq(vault.oracleTokenBudget(), 0);
        assertEq(imd.balanceOf(address(intake)), 0.5 ether);
        _assertETH(PRICE);
    }

    function _entries(uint256 count) private {
        for (uint256 i; i < count; ++i) {
            uint256 id = vault.nextAttemptId();
            address player = _actor(id);
            vm.deal(player, PRICE);
            vm.prank(player);
            assertEq(
                vault.attempt{value: PRICE}(string.concat("failure-boundary entry ", vm.toString(id))), id
            );
        }
    }

    function _answer(uint256 request, uint256 size)
        private
        view
        returns (OracleAttestation.Attestation memory a)
    {
        a.requestId = keccak256(abi.encode("oracle UUID, not Intake id", request));
        a.chainId = 1;
        a.answerType = 5;
        a.answer = abi.encode(new bytes32[](size));
        a.panelSize = 5;
        a.quorum = 3;
        a.agreed = 3;
        a.issuedAt = uint64(vm.getBlockTimestamp());
        a.expiresAt = uint64(vm.getBlockTimestamp() + 1 hours);
    }

    function _sign(OracleAttestation.Attestation memory a) private view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(KEY, vault.attestationDigest(a));
        return abi.encodePacked(r, s, v);
    }

    function _actor(uint256 id) private pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encode("failure suite player", id)))));
    }

    function _id(uint256 n) private pure returns (bytes32) {
        return keccak256(abi.encode(n));
    }

    function _closeError(FaultInjectingIntake.Fault fault) private pure returns (bytes4) {
        if (fault == FaultInjectingIntake.Fault.Quote) return FaultInjectingIntake.QuoteUnavailable.selector;
        if (fault == FaultInjectingIntake.Fault.ZeroId) return BegVault.InvalidQuestionId.selector;
        return BegVault.OracleUnfunded.selector;
    }

    function _stateDigest() private view returns (bytes32) {
        return keccak256(
            abi.encode(
                vault.getBatch(vault.openBatchId()),
                vault.openBatchId(),
                vault.nextAttemptId(),
                vault.nextToClose(),
                vault.escrowedETH(),
                vault.totalClaimableETH(),
                vault.oracleBudget(),
                vault.jackpotBank(),
                address(vault).balance,
                vault.oracleTokenBudget(),
                imd.balanceOf(address(intake)),
                imd.allowance(address(vault), address(intake)),
                intake.requests()
            )
        );
    }

    function _assertETH(uint256 expected) private view {
        assertEq(address(vault).balance, expected);
        assertEq(
            expected,
            uint256(vault.escrowedETH()) + vault.totalClaimableETH() + vault.oracleBudget()
                + vault.jackpotBank()
        );
    }
}
