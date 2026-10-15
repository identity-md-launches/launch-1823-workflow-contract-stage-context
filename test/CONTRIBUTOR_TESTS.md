# Test coverage

The 15 original Solidity test files from the requested pinned commit are unchanged. The source
contribution added `WalletFunding.t.sol` with six regression tests. The independent test contribution
adds `LaunchTokenStateMachine.t.sol`, `IntakeFailureRecovery.t.sol` and `OracleWireProperties.t.sol`.
Fixtures use only local mocks and deterministic test attesters. No test reads or changes environment
variables, forks an RPC, or depends on ordering.

```sh
forge build
FOUNDRY_FUZZ_SEED=0xdcc836d76ca6fb8ae596bee3dd668d01ee958cb4d4685d348e4f3299776e6316 forge test
forge fmt --check
```

| Suite | Main coverage |
| --- | --- |
| `WalletFunding.t.sol` | Factory custody, explicit team recipient, wallet funding after allocation, unfunded rollback and immediate retry, positive/partial funding and top-ups, separate IMD/bounty assets, full lifecycle and unfunded-oracle refunds |
| `BegVault.t.sol` | Constructor/input validation, UTF-8 and message limits, cooldown/duplicates, late entry, close cursor, JSON body, oracle payment, timeout/refund boundaries and odds |
| `OracleCallback.t.sol` | Sender/request authentication, signature/domain/window/panel/type/count validation, replay, clamping and cold 200,000-gas full-batch delivery |
| `OracleConsumerConformance.t.sol` | Supplied protocol digest, canonical callback selector, independently generated signature and fresh vector-key signature |
| `RollAndClaim.t.sol` | Exact prize tiers, sequential accounting, rearming/tier forfeiture, failed payouts, reentrancy, gas bounds and payout conservation |
| `AdversarialLifecycle.t.sol` | Constructor bounds, payment rollback, exact deadlines, failed/duplicate oracle requests, tampered signatures, stale batches and prolonged outages |
| `RewardProperties.t.sol` | Odds monotonicity, multiple roles/batches, claim timing, forfeiture caps, rounding and bounded-price accounting |
| `SiteEventsAndMessages.t.sol` | Event payloads/order, fixed prompt and definitions, literal UTF-8/JSON round trips, message pointer derivation/skew and closed-message views |
| `ClaimGuard.t.sol` | Credits cleared before ETH interaction, guard on all mutating external entry points, refunds and later legitimate claims |
| `MessageJson.t.sol` | Independent UTF-8 decoder, ASCII masks, boundary scalars and escaped/unescaped round trips |
| `LaunchToken.t.sol`, `TokenAccountingProperties.t.sol` | Fixed supply, transfers, finite/infinite allowances, transfer failures/atomicity and absence of admin/mint powers |
| `DeploymentFloor.t.sol` | Supply unchanged by constructors, runtime/opcode limits and data-contract storage behavior |
| `NoDeadManPath.t.sol` | No sweep/pause after long inactivity; expired entries remain refundable |
| `VaultInvariant.t.sol` | Four invariants covering backed liabilities, cash conservation, credit sums and escrow |
| `IndependentLedgerInvariant.t.sol` | Three independent ledger/lifecycle invariants plus deterministic handler scenarios and withdrawal liveness |
| `LaunchTokenStateMachine.t.sol` | Six actors, independent balances and allowance matrix, randomized approvals/transfers/delegated spending, insufficient allowance/balance, zero-address rejection, revocation, finite/infinite self-transfers and full-supply consolidation after every campaign |
| `IntakeFailureRecovery.t.sol` | Quote outages, reverts after IMD payment, zero/reused IDs with external rollback, reentrant Intake calls, failed approval after funding transfer, zero funding to establish allowance, and one-shot failed delivery followed by complete timeout refunds |
| `OracleWireProperties.t.sol` | Authentically signed malformed array offsets/counts/types, trailing/truncated data, malformed and malleated signatures, and cold 200,000-gas callbacks across every batch size with boundary score words |

The default invariant suite runs 128 campaigns of depth 64. The independent-ledger and token-state
suites override this with 256 campaigns of depth 96. The token handler fails on unexpected reverts,
checks expected errors explicitly, and updates its model from call inputs rather than copying the
token's state. Its final consolidation proves all tokens remain transferable after each sequence.
Deterministic scenarios exercise finite and infinite delegated spending, self-transfers and rejected
operations even independently of random coverage. Fuzz tests use the configured per-test runs
(normally 256, with selected cases 64, 128 or 512) and the supplied seed.

Historical gas test names mentioning 250k are preserved along with their original assertions:
the escaped/Unicode thresholds are 300k, close thresholds 400k, and full paying reveal 1.5M.
They do not establish a universal production gas ceiling. Mock delivery tests explicitly cap
the callback at 200,000 gas.

Limits: these tests establish local behavior, not live address availability, semantic scoring
quality, resistance to validator/keeper manipulation, or execution by the production launch
factory. The wallet-allocation test uses a clearly marked local distribution model.

The new fault-injecting Intake is a local dependency model, not production Intake bytecode. Its
one-shot delivery marks a request completed before making the callback and does not retry a failed
delivery. Refund tests therefore wait until the vault's exact timeout, recover every entry in a
permuted order (including the automatically closed twentieth entry), and verify that spent IMD
remains spent while the entire player ETH payment is returned. Wire-format tests using the older
retryable mock isolate callback validation; they do not promise a production retry mechanism.

The added tests do not change source, ABI exports, launch settings or dependencies. No new defect
requiring a source change was reproduced by these tests; this is not a replacement for the separate
independent review of the documented custody, oracle and randomness assumptions.
