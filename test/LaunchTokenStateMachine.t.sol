// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LaunchToken} from "src/LaunchToken.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

/// @dev Closed set of local test actors. The ledger is updated from requested amounts,
/// never copied from token balances or allowances. Every expected rejection checks its error.
contract LaunchTokenStateHandler is Test {
    uint256 public constant SUPPLY = 1_000_000_000 ether;
    uint256 public constant ACTORS = 6;
    LaunchToken public immutable token;
    address[6] public actors;
    uint256[6] public balances;
    uint256[6][6] public allowances;
    uint256 public transfers;
    uint256 public delegatedTransfers;
    uint256 public rejectedTransfers;

    constructor() {
        token = new LaunchToken();
        for (uint256 i; i < ACTORS; ++i) {
            actors[i] = address(uint160(uint256(keccak256(abi.encode("BEG state machine actor", i)))));
            uint256 allocation = i == 0 ? SUPPLY - (ACTORS - 1) * (SUPPLY / 8) : SUPPLY / 8;
            balances[i] = allocation;
            require(token.transfer(actors[i], allocation), "initial distribution failed");
        }
    }

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 rawAmount, uint8 edge) public {
        uint256 from = fromSeed % ACTORS;
        uint256 to = toSeed % ACTORS;
        uint256 amount = _amount(rawAmount, balances[from], edge);
        vm.prank(actors[from]);
        assertTrue(token.transfer(actors[to], amount));
        balances[from] -= amount;
        balances[to] += amount;
        ++transfers;
    }

    function approve(uint256 ownerSeed, uint256 spenderSeed, uint256 rawAmount, uint8 edge) public {
        uint256 amount = edge % 4 == 0 ? 0 : edge % 4 == 1 ? type(uint256).max : rawAmount;
        _approve(ownerSeed % ACTORS, spenderSeed % ACTORS, amount);
    }

    function transferFrom(
        uint256 ownerSeed,
        uint256 spenderSeed,
        uint256 toSeed,
        uint256 rawAmount,
        uint8 edge
    ) public {
        uint256 owner = ownerSeed % ACTORS;
        uint256 spender = spenderSeed % ACTORS;
        uint256 to = toSeed % ACTORS;
        uint256 allowance = allowances[owner][spender];
        uint256 available = balances[owner] < allowance ? balances[owner] : allowance;
        uint256 amount = _amount(rawAmount, available, edge);
        vm.prank(actors[spender]);
        assertTrue(token.transferFrom(actors[owner], actors[to], amount));
        if (allowance != type(uint256).max) allowances[owner][spender] -= amount;
        balances[owner] -= amount;
        balances[to] += amount;
        ++delegatedTransfers;
    }

    function exceedAllowance(uint256 ownerSeed, uint256 spenderSeed, uint256 rawAllowance) public {
        uint256 owner = ownerSeed % ACTORS;
        uint256 spender = spenderSeed % ACTORS;
        uint256 allowed = bound(rawAllowance, 0, SUPPLY);
        _approve(owner, spender, allowed);
        vm.prank(actors[spender]);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientAllowance.selector, actors[spender], allowed, allowed + 1
            )
        );
        token.transferFrom(actors[owner], actors[(owner + 1) % ACTORS], allowed + 1);
        ++rejectedTransfers;
    }

    function exceedBalance(uint256 ownerSeed, uint256 spenderSeed, bool infinite) public {
        uint256 owner = ownerSeed % ACTORS;
        uint256 spender = spenderSeed % ACTORS;
        uint256 requested = balances[owner] + 1;
        _approve(owner, spender, infinite ? type(uint256).max : requested);
        // The allowance is sufficient: failing later must undo its earlier decrement too.
        vm.prank(actors[spender]);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientBalance.selector, actors[owner], balances[owner], requested
            )
        );
        token.transferFrom(actors[owner], actors[(owner + 1) % ACTORS], requested);
        ++rejectedTransfers;
    }

    function revokeAndProbe(uint256 ownerSeed, uint256 spenderSeed) public {
        uint256 owner = ownerSeed % ACTORS;
        uint256 spender = spenderSeed % ACTORS;
        _approve(owner, spender, 0);
        vm.prank(actors[spender]);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, actors[spender], 0, 1)
        );
        token.transferFrom(actors[owner], actors[(owner + 1) % ACTORS], 1);
        ++rejectedTransfers;
    }

    function zeroAddressFailures(uint256 ownerSeed, uint256 spenderSeed, uint256 rawAmount) public {
        uint256 owner = ownerSeed % ACTORS;
        uint256 spender = spenderSeed % ACTORS;
        uint256 amount = bound(rawAmount, 0, balances[owner]);
        _approve(owner, spender, amount);
        vm.prank(actors[spender]);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transferFrom(actors[owner], address(0), amount);
        vm.prank(actors[owner]);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        token.approve(address(0), rawAmount);
        ++rejectedTransfers;
    }

    function assertSupplyAndBalances() public view {
        uint256 sum;
        for (uint256 i; i < ACTORS; ++i) {
            assertEq(token.balanceOf(actors[i]), balances[i], "balance differs from transfer ledger");
            sum += token.balanceOf(actors[i]);
        }
        assertEq(sum, SUPPLY, "transfers minted, burned, charged a fee or escaped the actor set");
        assertEq(token.totalSupply(), SUPPLY, "fixed launch supply changed");
        assertEq(token.balanceOf(address(this)), 0);
        assertEq(token.balanceOf(address(0)), 0);
    }

    function assertAllowances() public view {
        for (uint256 owner; owner < ACTORS; ++owner) {
            assertEq(token.allowance(actors[owner], address(0)), 0);
            for (uint256 spender; spender < ACTORS; ++spender) {
                assertEq(
                    token.allowance(actors[owner], actors[spender]),
                    allowances[owner][spender],
                    "approval, spending or revert changed the wrong allowance"
                );
            }
        }
    }

    function consolidate() external {
        for (uint256 i = 1; i < ACTORS; ++i) {
            transfer(i, 0, 0, 1); // Full balance, including zero after arbitrary previous calls.
        }
        assertSupplyAndBalances();
        assertAllowances();
        assertEq(token.balanceOf(actors[0]), SUPPLY, "some tokens became unspendable");
    }

    function _approve(uint256 owner, uint256 spender, uint256 amount) private {
        vm.prank(actors[owner]);
        assertTrue(token.approve(actors[spender], amount));
        allowances[owner][spender] = amount;
    }

    function _amount(uint256 raw, uint256 maximum, uint8 edge) private pure returns (uint256) {
        if (edge % 4 == 0) return 0;
        if (edge % 4 == 1) return maximum;
        if (edge % 4 == 2) return maximum == 0 ? 0 : 1;
        return bound(raw, 0, maximum);
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 96
/// forge-config: default.invariant.fail-on-revert = true
contract LaunchTokenStateMachineTest is Test {
    LaunchTokenStateHandler private handler;

    function setUp() public {
        handler = new LaunchTokenStateHandler();
        bytes4[] memory selectors = new bytes4[](7);
        selectors[0] = handler.transfer.selector;
        selectors[1] = handler.approve.selector;
        selectors[2] = handler.transferFrom.selector;
        selectors[3] = handler.exceedAllowance.selector;
        selectors[4] = handler.exceedBalance.selector;
        selectors[5] = handler.revokeAndProbe.selector;
        selectors[6] = handler.zeroAddressFailures.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    function invariantFixedSupplyAndIndependentBalances() public view {
        handler.assertSupplyAndBalances();
    }

    function invariantOnlyOwnerApprovalAndSuccessfulSpendingChangeAllowances() public view {
        handler.assertAllowances();
    }

    function afterInvariant() public {
        handler.consolidate();
    }

    function testHandlerExercisesFiniteInfiniteRevokedAndFailedSpending() public {
        handler.approve(0, 1, 7, 2);
        handler.transferFrom(0, 1, 2, 7, 3);
        assertEq(handler.allowances(0, 1), 0);
        handler.approve(2, 3, 0, 1);
        handler.transferFrom(2, 3, 2, 0, 1); // Full self-transfer still spends authorization.
        assertEq(handler.allowances(2, 3), type(uint256).max);
        handler.transferFrom(2, 3, 4, 0, 1);
        handler.revokeAndProbe(2, 3);
        handler.exceedBalance(4, 3, false);
        handler.exceedBalance(4, 3, true);
        handler.exceedAllowance(4, 3, 8);
        handler.zeroAddressFailures(4, 3, 1);
        handler.transfer(4, 4, 0, 1);
        handler.transfer(4, 5, 0, 0);
        handler.assertSupplyAndBalances();
        handler.assertAllowances();
        assertEq(handler.delegatedTransfers(), 3);
        assertEq(handler.rejectedTransfers(), 5);
        afterInvariant();
    }

    function testFiniteSelfTransferSpendsAllowanceEvenThoughBalanceDoesNotChange() public {
        uint256 beforeBalance = handler.balances(0);
        handler.approve(0, 1, 11, 2);
        handler.transferFrom(0, 1, 0, 11, 3);
        assertEq(handler.allowances(0, 1), 0);
        assertEq(handler.balances(0), beforeBalance);
        handler.assertSupplyAndBalances();
        handler.assertAllowances();
    }
}
