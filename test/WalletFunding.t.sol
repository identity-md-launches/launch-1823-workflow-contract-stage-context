// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BegVaultBase} from "./BegVaultBase.sol";
import {BegVault} from "../src/BegVault.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {MockIMD, MockIntake} from "./mocks/MockIntake.sol";

/// @dev Test-only constructor caller. Production deployment belongs to the launch service.
contract FundingDeploymentProbe {
    function deploy(address team, address intake, address imd, address signer)
        external
        returns (LaunchToken token, BegVault vault)
    {
        token = new LaunchToken();
        vault = new BegVault(address(token), team, intake, imd, signer, 0.005 ether);
    }
}

/// @notice Launch-specific regression coverage: the wallet funds the vault after deployment.
contract WalletFundingTest is BegVaultBase {
    FundingDeploymentProbe private factory;
    uint256 private constant WALLET_ALLOCATION = 800_000_000 ether;

    function setUp() public override {
        vm.chainId(1);
        vm.warp(1_800_000_000);
        vm.roll(1_000);
        vm.prevrandao(bytes32(uint256(101)));
        imd = new MockIMD();
        intake = new MockIntake();
        factory = new FundingDeploymentProbe();
        (token, vault) = factory.deploy(TEAM, address(intake), address(imd), vm.addr(SIGNER_KEY));
        vm.deal(address(this), 1 ether);
    }

    function testFactoryKeepsEntireSupplyUntilAllocationAndHasNoTeamEntitlement() public {
        assertEq(token.totalSupply(), 1_000_000_000 ether);
        assertEq(token.balanceOf(address(factory)), token.totalSupply());
        assertEq(token.balanceOf(address(vault)), 0);
        assertEq(token.balanceOf(TEAM), 0);
        assertEq(vault.team(), TEAM);
        assertTrue(vault.team() != address(factory));
        assertEq(vault.vaultFreeBalance(), 0);
        _assertClosedBeforeFunding(_player(1), "Waiting for the launch wallet");
    }

    function testWalletAllocationThenTransferOpensVaultWithoutInitialization() public {
        _allocate();
        assertEq(token.balanceOf(TEAM), WALLET_ALLOCATION);
        assertEq(token.balanceOf(address(factory)), 0);
        assertEq(token.balanceOf(address(vault)), 0);

        address player = _player(1);
        string memory message = "A crumb after the doors open";
        _assertClosedBeforeFunding(player, message);
        _walletFunds(WALLET_ALLOCATION);

        // The exact rejected message can be retried immediately, with attempt id and nonce one.
        vm.prank(player);
        uint256 id = vault.attempt{value: PRICE}(message);
        assertEq(id, 1);
        assertEq(vault.getAttempt(id).player, player);
        assertEq(vault.getAttempt(id).message, message);
        assertEq(vault.getBatch(1).size, 1);
        assertEq(vault.getBatch(1).openedAt, block.timestamp);
        assertEq(vault.cooldownUntil(player), block.timestamp + 10 minutes);
        assertTrue(vault.usedMessage(keccak256(bytes(message))));
        assertEq(vault.messagePointer(1, 0), vm.computeCreateAddress(address(vault), 1));
        assertGt(vault.messagePointer(1, 0).code.length, 0);
        assertEq(vault.vaultFreeBalance(), WALLET_ALLOCATION);
        assertEq(token.balanceOf(TEAM), 0);
        assertEq(intake.requests(), 0);
        assertEq(vault.escrowedETH(), PRICE);
        _assertSolvent();
    }

    function testOracleAndBountyFundingAloneDoNotOpenTheVault() public {
        _allocate();
        imd.mint(address(this), 0.5 ether);
        imd.approve(address(vault), 0.5 ether);
        vault.fundOracle(0.5 ether);
        vault.fundOracle{value: 0.001 ether}();
        _assertClosedBeforeFunding(_player(1), "IMD and ETH are not BEG prizes");
        assertEq(vault.oracleTokenBudget(), 0.5 ether);
        assertEq(vault.oracleBudget(), 0.001 ether);
        assertEq(vault.totalClaimableETH(), 0);
        assertEq(vault.escrowedETH(), 0);
        assertEq(vault.jackpotBank(), 0);
        _assertSolvent();
    }

    function testFuzzAnyPositiveWalletFundingEnablesPlayAndTopUpsStayFree(uint256 rawAmount) public {
        _allocate();
        uint256 amount = bound(rawAmount, 1, WALLET_ALLOCATION);
        _walletFunds(amount);
        assertEq(vault.vaultFreeBalance(), amount);
        _attempt(_player(1), "The funding gate has no hidden minimum");
        assertEq(vault.totalClaimableTokens(), 0);
        assertEq(vault.vaultFreeBalance(), amount);
        _walletFunds(WALLET_ALLOCATION - amount);
        assertEq(vault.vaultFreeBalance(), WALLET_ALLOCATION);
        assertEq(vault.getBatch(1).size, 1);
        _assertSolvent();
    }

    function testWalletFundedBatchGradesRevealsAndTeamClaimsOnlyItsTenth() public {
        _allocate();
        _walletFunds(WALLET_ALLOCATION);
        imd.mint(address(this), 0.5 ether);
        imd.approve(address(vault), 0.5 ether);
        vault.fundOracle(0.5 ether);
        _batch(20);
        assertEq(vault.oracleTokenBudget(), 0);
        assertEq(imd.balanceOf(address(intake)), 0.5 ether);
        assertEq(vault.escrowedETH(), 0.1 ether);
        _grade(1, 100);
        (, uint128 teamCredit) = vault.claimable(TEAM);
        assertEq(teamCredit, 0.01 ether);
        assertEq(vault.jackpotBank(), 0.089 ether);
        assertEq(vault.oracleBudget(), 0.001 ether);
        assertEq(vault.escrowedETH(), 0);
        _reveal(1, keccak256("wallet-funded launch reveal"));
        uint256 beforeTeamBalance = TEAM.balance;
        vm.prank(TEAM);
        vault.claim();
        assertEq(TEAM.balance, beforeTeamBalance + 0.01 ether);
        (, uint128 factoryCredit) = vault.claimable(address(factory));
        assertEq(factoryCredit, 0);
        for (uint256 i = 1; i <= 20; ++i) {
            (uint128 tokens, uint128 eth) = vault.claimable(_player(i));
            if (tokens != 0 || eth != 0) {
                vm.prank(_player(i));
                vault.claim();
            }
        }
        vault.claim(); // keeper bounty belongs to the revealer
        assertEq(vault.totalClaimableTokens(), 0);
        assertEq(vault.totalClaimableETH(), 0);
        _assertSolvent();
    }

    function testFundedVaultWithoutIMDStillOffersFullTimeoutRefund() public {
        _allocate();
        _walletFunds(WALLET_ALLOCATION);
        address player = _player(1);
        _attempt(player, "A funded prize pool cannot pay the oracle's IMD fee");
        vm.warp(block.timestamp + 30 minutes);
        vm.expectRevert(BegVault.OracleUnfunded.selector);
        vault.closeBatch();
        vm.warp(block.timestamp + 24 hours);
        vault.expireBatch(1);
        vm.startPrank(player);
        vault.refund(1);
        vault.claim();
        vm.stopPrank();
        assertEq(player.balance, PRICE);
        assertEq(vault.vaultFreeBalance(), WALLET_ALLOCATION);
        assertEq(vault.totalClaimableETH(), 0);
        assertEq(vault.escrowedETH(), 0);
        assertEq(vault.jackpotBank(), 0);
        assertEq(intake.requests(), 0);
        _assertSolvent();
    }

    function _allocate() private {
        // Only a local distribution model: these test actors stand for the platform artifacts.
        vm.startPrank(address(factory));
        token.transfer(_player(100), 100_000_000 ether); // pool
        token.transfer(_player(101), 100_000_000 ether); // distributor
        token.transfer(TEAM, WALLET_ALLOCATION);
        vm.stopPrank();
    }

    function _walletFunds(uint256 amount) private {
        vm.prank(TEAM);
        token.transfer(address(vault), amount);
    }

    function _assertClosedBeforeFunding(address player, string memory message) private {
        uint256 vaultETH = address(vault).balance;
        vm.deal(player, PRICE);
        vm.prank(player);
        vm.expectRevert(BegVault.VaultEmpty.selector);
        vault.attempt{value: PRICE}(message);
        assertEq(player.balance, PRICE);
        assertEq(address(vault).balance, vaultETH);
        assertEq(vault.nextAttemptId(), 1);
        assertEq(vault.openBatchId(), 1);
        assertEq(vault.nextToClose(), 1);
        assertEq(vault.autoClosed(), 0);
        assertEq(vault.getBatch(1).size, 0);
        assertEq(vault.getBatch(1).openedAt, 0);
        assertEq(vault.cooldownUntil(player), 0);
        assertFalse(vault.usedMessage(keccak256(bytes(message))));
        assertEq(vm.computeCreateAddress(address(vault), 1).code.length, 0);
        assertEq(vault.escrowedETH(), 0);
        assertEq(vault.totalClaimableTokens(), 0);
    }
}
