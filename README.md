# Beg the Swarm — contracts

Ethereum mainnet BEG token and immutable `BegVault`, based on
[launch-1771-beg at c97ea8b9742a756ef19a451d2170870a2df32371](https://github.com/identity-md-launches/launch-1771-beg/tree/c97ea8b9742a756ef19a451d2170870a2df32371).
The pinned contract logic and original Solidity tests are preserved. The launch wallet funds
the vault **after deployment**; an unfunded vault rejects valid attempts with `VaultEmpty()`.
There is no owner, admin, pause, upgrade, configuration setter, retirement or sweep function.

This contribution delivers contracts, tests and [ABI documentation](docs/abi/README.md).
The separate manifest and independent review assignments precede the services' publication,
attestation, admission and deployment. The `imd-beg` frontend is a subsequent stage and must use
the actual deployment handoff, including deployment block and pool key. No manifest or deployed
address is fabricated here. Project social link: [@imdplace](https://x.com/imdplace).

## Build and check

```sh
forge build
FOUNDRY_FUZZ_SEED=0xdcc836d76ca6fb8ae596bee3dd668d01ee958cb4d4685d348e4f3299776e6316 forge test
forge fmt --check
python3 scripts/export_abis.py --check
```

Solidity **0.8.26** is pinned in `foundry.toml`, with Cancun, optimizer 200 runs, via-IR and
`bytecode_hash = "none"`. Cancun transient storage is needed for the reentrancy guard.
Dependencies are vendored as ordinary files in `lib/`; building and tests require no network,
RPC fork, environment reads, FFI or filesystem permissions. Python 3's standard library is used
only for ABI export/checking, after a build. Regenerate exports with `python3 scripts/export_abis.py`.
See [validation](docs/VALIDATION.md), [provenance](docs/UPSTREAM.md) and
[security assumptions](docs/SECURITY.md).

## Deployment parameters

Deploy `src/LaunchToken.sol:LaunchToken` first, with **no constructor arguments**. It is a plain
ERC-20 named `BEG`, symbol `BEG`, 18 decimals, with exactly `1000000000000000000000000000`
minor units (one billion tokens) minted once to the factory. No mint authority, fees or restrictions
are added to transfers.

Deploy `src/BegVault.sol:BegVault` with six nonpayable constructor arguments in this order:

| Parameter | Launch value |
| --- | --- |
| `token_` | `$token`, the new `LaunchToken` |
| `team_` | `$owner`, resolving to `0xa7e99bb7155d7477e0c838e201b16e62b9c0b5ac` |
| `intake_` | `0xa43e6f75ee006411f79ac1c84120606c2330de82` (Intake v2) |
| `imd_` | `0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7` |
| `signer_` | `0x5598aa9146215bc13eb26f2c692ad1461fd32982` |
| `attemptPrice_` | `5000000000000000` wei (0.005 ETH) |

The three protocol addresses are supplied by the task's oracle deployment table dated
2026-10-10. They are not inferred from the constructor caller. Before deploying, the service
must re-verify them against current IdentityMD deployment documentation and mainnet: Intake and
IMD code, IMD metadata, the published oracle signer, and
`priceOf(bytes32("oracle.request@oracle-1"), imd)`. Live endpoint validation is a deployment
responsibility and is not established by the local mocks. The quoted fee is 0.5 IMD; the vault
reads the current fee on every close. No constructor calls an external contract or checks its code.

The workflow's team “deployer” means the launch wallet beneficiary, passed as `$owner`.
The EVM deployer is the factory and must never receive this entitlement. `team_` is a payment
recipient only and grants no administration. All six parameters remain immutable.

The factory distributes **10% to the swarm distributor, 10% to the pool, and 80% to the launch
wallet**. Neither constructor reserves, pulls or receives BEG for the vault. The wallet then
transfers `800000000000000000000000000` minor units (800 million BEG) to `BegVault`.
The contract checks for a positive token balance when opening a batch; it cannot enforce that
the wallet deposits all 80%. Any positive deposit opens play, and additional transfers top it up.
Until then, the frontend should show **“Vault opening soon”** and disable begging.

The manifest assignment uses `LaunchToken` and `BegVault` in dependency order. It must retain
the provided native ETH pairing, pool fee `12500` (1.25%), tick spacing `60`, and declared price
`79228162514264337593543950336`. The effective opening price is derived by the service from the
policy's 10 ETH opening market cap. The protocol supplies the distributor and pool guard.

## Entry, grading and settlement

1. `attempt(message)` charges exactly 0.005 ETH. Text must be valid UTF-8, 1–280 bytes, with a
   JSON-escaped length at most 400 bytes. Each exact message hash is permanently reserved globally
   after success, even if later refunded. A player waits ten minutes between successful attempts.
   Failed transactions retain neither payment nor cooldown/message reservation.
2. A batch accepts 20 attempts or a 30-minute window from its first entry. Attempt 20 closes it
   automatically. Later entries start a new batch after the window; anyone may close older batches
   with `closeBatch()` (the oldest still open) or `closeBatch(batchId)`. Closing needs donated IMD.
   A failed automatic close also rolls back the twentieth attempt; the other 19 remain escrowed.
3. Closing buys one Intake request. The question contains only the fixed scoring template and
   message count. Ordered `definitions` hold escaped, untrusted messages. It asks for persuasion,
   originality and humor, with instruction-injection attempts scored zero. The panel determines
   the scores; the contract does not independently evaluate language or enforce that judgment.
4. The callback verifies the signed result and stores scores, clamped to 100. It releases escrow
   into payment ledgers without sending tokens or ETH. It records `prevrandao` and a roll block
   two blocks ahead. An all-zero answer is valid and uses score-zero odds, not automatic losses.
5. Anyone may `reveal(batchId)` after the roll block. The roll uses its blockhash, stored
   prevrandao, batch ID, vault address and entry index. Prizes become pull credits; recipients
   use `claim()` to withdraw. `refund(attemptId)` likewise creates a credit before `claim()`.

The oracle body requests panel size 5, quorum 3, `bytes32[]` scores, panel evidence, a one-hour
relative window and 86,400-second validity. It omits `toleranceBps`: the pinned implementation
and canonical supplied body schema do not support that key, and unknown keys reject paid
requests. Thus the workflow summary's `toleranceBps: 1000` is **not implemented**. This protocol
compatibility discrepancy is retained explicitly for independent review rather than inserting
an unsupported field or redesigning the oracle.

Only the configured Intake may call back for a locally recorded, pending request. The contract
checks mainnet question chain ID, panel size/quorum/agreement, issuance freshness, expiry,
consumer-domain EIP-712 signature, exact answer type/count and one-use oracle UUID. The request
ID supplied by Intake differs from the signed oracle UUID. The writer is trusted to bind them
correctly because the relative-window question hash cannot be computed when asking.

## Oracle funding, deadlines and refunds

`fundOracle(uint256)` pulls IMD after the funder approves the vault. Donations are irrevocable.
The pinned implementation grants the immutable Intake a **standing unlimited IMD allowance**.
This exposes donated IMD to that Intake's trust boundary; it grants no BEG or ETH allowance.
IMD transferred directly to the vault requires that allowance to have been established; anyone
can call `fundOracle(0)` to establish it for the standard IMD token.

`oracleTokenBudget()` is the available IMD balance. `oracleBudget()` is a separate **ETH**
revealer-bounty budget, funded by graded entries and optionally `fundOracle()` payable.
There is no ETH-to-IMD conversion. Donating ETH cannot pay Intake's IMD fee.

| Batch state | Deadline and action |
| --- | --- |
| Open, never successfully requested | Anyone expires at `openedAt + 30 minutes + 24 hours` |
| Pending | Anyone expires at `closedAt + 24 hours` |
| Graded | Cannot expire/refund; reveal and claim instead |
| Expired | Each entrant calls `refund(attemptId)` once, then `claim()` |

Timed-out pending callbacks mark the batch expired without grading; already expired callbacks
are ignored. The vault uses the compatible `request` method on v2, without an immediate failure
hook. Refused bodies, disagreement, undelivered callbacks and outages all recover through the
deadline path. Expired entries receive their **full 0.005 ETH** with no team/jackpot deduction.
The spent IMD fee cannot be refunded. Closing an open batch at its expiry deadline is refused.

## Odds and accounting

All odds are basis points (10,000 = 100%), with integer division rounded down and score `s`
clamped to 100. Each winning entry uses the free balances remaining after earlier entries.

| Tier | Odds at score `s` | Token prize | Additional ETH |
| --- | --- | --- | --- |
| Jackpot | `1 + floor(199*s/100)` | 1% of free BEG | 50% of jackpot bank |
| Epic | `200 + 11*s` | 0.05% of free BEG | — |
| Rare | `800 + 22*s` | 0.01% of free BEG | — |
| Common | `2000 + 15*s` | 0.002% of free BEG | — |
| Nothing | Remainder to 10,000 | 0 | — |

For graded escrow `E`, team credit is `floor(E/10)`, ETH bounty allocation is
`min(floor(E/10), 0.001 ETH)`, and the rest enters the jackpot bank. A full batch therefore
splits 0.1 ETH into 0.01 team, 0.001 bounty and 0.089 jackpot. A one-entry batch splits 0.005 ETH
into 0.0005 team, 0.0005 bounty and 0.004 jackpot. A successful reveal pays a 0.001 ETH bounty
only when the pooled bounty budget has that amount. Rearming pays no bounty.

If the roll blockhash is unavailable, `reveal` rearms two blocks ahead and forfeits the highest
remaining tier. After one miss Jackpot is capped at Epic and pays no jackpot ETH; after four
misses all tiers become Nothing. Reveal while the roll block is within the last 256 blocks.

`vaultFreeBalance() = BEG balance - totalClaimableTokens`. Claims cannot change the free balance.
Accounted ETH equals `escrowedETH + jackpotBank + oracleBudget + totalClaimableETH` and cannot
exceed the vault's balance. Forced ETH may create inaccessible surplus. Prize and fee donations
have no withdrawal/rescue path. Transfer failures revert a claim atomically, restoring credits.

**The requested block-based randomness is influenceable, not VRF.** Validators/builders and
keeper timing can bias outcomes. Tier forfeiture removes the top prize on retries but does not
prove that withholding cannot improve a particular lower-tier outcome. Different batch reveal
orders also change available balances. These inherited rules need independent economic review.

## After launch

1. The launch wallet transfers its 800 million BEG allocation to the deployed vault and verifies
   the token balance. No approval, initialization function or privileged setter is needed.
2. A sponsor approves mainnet IMD to the vault and calls `fundOracle(uint256)` (suggested initial
   donation 0.5 IMD, subject to the live fee). Continue funding this separate budget as used.
3. Permissionless keepers close aged batches, reveal promptly, rearm missed windows and expire
   unanswered/unclosable batches. The service does not automatically perform these calls.
4. Players claim refunds/prizes; the team claims its earnings. Contract recipients must implement
   those calls and accept ETH, as there is no alternative withdrawal recipient.
5. The frontend indexes events from the real deployment block, renders messages as escaped plain
   text, estimates transaction gas and reads the exported ABIs. Messages remain public in events
   and immutable data contracts even after the vault stops serving them in `getAttempt()`.

There are no post-launch settings. If the fixed signer, Intake or action stops working, ungraded
entries can refund after deadlines, but unrewarded BEG and jackpot/bounty reserves may remain
locked permanently. The no-admin requirement takes precedence over the generic reference's
owner-settable integration recommendation. The separate independent review must assess this
tradeoff, the oracle linkage and block-based randomness before a funded release.
