# Security and operational assumptions

These are implementation notes for the separate independent review. Local passing tests do not
constitute an independent audit, protocol availability check or authorization to deploy.

## Trust and custody

- The factory holds the complete fixed token supply after construction. It distributes 80% to
  the launch wallet, which must transfer that allocation to the vault. The vault has no power
  to retrieve those tokens and no guarantee that the promised amount will arrive. Any positive
  token balance enables entries; a dust donation can therefore open play with tiny/zero prizes.
- `team_` is the explicit `$owner` beneficiary, not the factory or `tx.origin`. It receives only
  pull credits for its tenth of successfully graded escrow. It cannot configure or sweep funds.
- `fundOracle(uint256)` gives the fixed Intake unlimited spending allowance over donated IMD.
  The pinned implementation intentionally retains this behavior. A compromised Intake could
  drain that IMD. It receives no approval for BEG and no access to player ETH escrow.
- The oracle panel judges the messages and one signer authenticates the result. A signed score
  does not prove objective correctness or resistance to prompt injection/Sybil participation.
  Five seats and quorum three are the requested parameters. The Intake writer binds its request
  ID to the signed UUID/question; a relative window prevents precomputing the question hash.
- All protocol configuration is fixed. A moved Intake, retired action or lost signer can stop
  scoring permanently. Ungraded entries retain timeout refunds; prize pools, surplus donations,
  outstanding credits to unusable addresses and forced ETH have no administrative rescue path.

## Randomness and economic behavior retained from the pinned code

The roll uses a future blockhash with callback-time prevrandao. This is **not verifiable randomness**
and is influenceable by block producers and keeper scheduling. Missed windows forfeit tiers but
do not eliminate selective withholding: a later lower-tier outcome can improve on an earlier
Nothing outcome. Batch reveal order affects free prize balances and jackpot payouts. These are
material economic assumptions for the independent review; no replacement RNG was introduced.

Score zero still has nonzero prize odds. The oracle's injection-zero rule lowers odds; it does
not disqualify an entry. Duplicate detection is global and permanent, so mempool copying can
reserve another user's exact message first. Cooldown is address-based and provides no Sybil limit.

## Boundaries exercised locally

- Standard ERC-20 fixed supply, exact transfers, allowances and rejected mint/admin selectors.
- Constructor execution without dependency code, factory supply conservation, explicit recipient,
  bounded runtime and absence of `DELEGATECALL`, `CALLCODE` and `SELFDESTRUCT` in deployed artifacts.
- Invalid payments/messages/UTF-8, global duplicate reservations, cooldown and exact deadlines.
- Automatic/timed closes, stale batches, insufficient IMD, reverting Intake, zero/reused request
  IDs and rollback of the twentieth attempt, allowance transfers and request bookkeeping.
- Intake-only callback, pending local request, mainnet question chain, panel requirements, signed
  field tampering, wrong consumer domain, expiry/future issuance, score counts/types and replay.
  The protocol digest/signature vector and cold 20-entry callback run under 200,000 gas.
- Full entry refunds for open/pending timeouts, late callbacks, repeated/wrong-player refunds,
  repeated reveal/claims, missed blockhash windows and absence of a timed sweep path.
- Exact tier boundaries, sequential free-balance payouts, multiple jackpots, unclaimed earlier
  rewards, later donations, rounding, bounty exhaustion, overlapping roles and batches.
- Shared transient reentrancy protection on every mutating external entry point; claim clears
  credits before token/ETH interactions. Rejecting or reentering recipients cannot double-claim.
  A failed transfer rolls back both credits and transfers.
- Stateful accounting invariants and an independent cash-flow/lifecycle model, including final
  withdrawal liveness after random entries, donations, outages, expiries, refunds and reveals.

## Limits relevant to deployment and the frontend

1. Message data contracts and event history are public and permanent. `getAttempt()` returns
   message text only while its batch is open; this is not deletion of on-chain data.
2. Input is capped at 280 UTF-8 bytes and 400 escaped bytes, so some control-heavy messages
   shorter than 280 bytes are rejected. Frontends must precheck both limits and escape text on display.
3. There is no universal 250,000-gas entry ceiling. The inherited test names reference an older
   target, but escaped/Unicode paths allow 300,000 and automatic/timed closes allow 400,000 in
   the mocks. Real Intake gas differs; wallets must estimate. Callback stipend coverage is separate.
4. Per-batch loops are limited to 20; cursor advancement can scan multiple previously closed
   batches. Very large histories and adversarial close ordering deserve review. Packed timestamps
   are `uint32` (year-2106 horizon), first attempt IDs `uint32`, batch/roll IDs `uint40`, and
   auto-close skew `uint24`; the implementation is not an unbounded-lifetime ledger.
5. Monetary bounds assume the fixed standard BEG token and mainnet IMD, not arbitrary rebasing or
   malicious token substitutions. Prize credits use `uint128`; aggregate ETH fields use bounded
   checked arithmetic. The approved 0.005 ETH entry price is far below constructor limits.
6. No failure hook is registered. Failed/withheld/dropped oracle deliveries are recovered by
   timeout, not automatic refunds. Only players can request and claim their refunds.
7. The summary's `toleranceBps: 1000` is unsupported by the canonical body schema and omitted,
   as in the pinned source. The independent review must retain this disclosed protocol conflict.

## Remaining service responsibilities

Re-verify current mainnet integrations and price, review the final constructor arguments and
canonical manifest, and complete independent adversarial review before deployment and funding.
No deployment, transaction signing, live RPC fork, Slither or Mythril result is claimed here.
Tests exercise local mocks and the supplied independent signature vector, not live oracle behavior.
