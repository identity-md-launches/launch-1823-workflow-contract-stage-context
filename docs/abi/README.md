# Contract interfaces

`LaunchToken.json` and `BegVault.json` are standard Solidity ABI arrays, including constructors,
functions, events and custom errors. They are exported from the pinned compiler's artifacts:

```sh
forge build
python3 scripts/export_abis.py
python3 scripts/export_abis.py --check
```

The only deployable application is `BegVault`; library functions are internal. Neither an oracle
mock, a test deployment probe, nor the protocol's factory/guard/distributor is a launch artifact.
The frontend reads contract addresses, chain ID, deployment block and pool key from the service's
real deployment handoff. The ABI files contain no guessed deployment addresses.

## User and keeper writes

| Signature | Caller/payment | Behavior |
| --- | --- | --- |
| `attempt(string)` → `uint256` | Anyone; exactly `ATTEMPT_PRICE` ETH | Submit text and return attempt ID; twentieth entry also closes |
| `closeBatch()` | Anyone | Request grading for `nextToClose` once its window ends |
| `closeBatch(uint256)` | Anyone | Request grading for a particular aged open batch |
| `reveal(uint256)` | Anyone | Settle a graded batch after `rollBlock`, or rearm a missed hash window |
| `expireBatch(uint256)` | Anyone | Expire an open/pending batch once its deadline passes |
| `refund(uint256)` | That attempt's player | Credit its full entry ETH after expiry; call `claim()` next |
| `claim()` | Credit holder | Transfer all caller token/ETH credits; no recipient argument |
| `fundOracle(uint256)` | Anyone with IMD allowance | Pull IMD donation and establish Intake allowance |
| `fundOracle()` | Anyone; payable | Donate ETH to the separate revealer-bounty budget |

Select overloaded signatures explicitly in clients. There is no receive/fallback handler for a
plain ETH transfer. Fund BEG through the token's standard `transfer(vault, amount)`.

## Reads and indexing

| Read | Meaning |
| --- | --- |
| `token`, `imd`, `intake`, `team`, `oracleSigner`, `ATTEMPT_PRICE` | Immutable launch configuration |
| `nextAttemptId() - 1` | Total successful attempts |
| `openBatchId()`, `nextToClose()` | Current entry batch and oldest open close cursor |
| `getBatch(id)` | `BatchView` tuple, described below |
| `getAttempt(id)` | `AttemptView` tuple, described below |
| `vaultFreeBalance()`, `totalClaimableTokens()` | Available and reserved BEG minor units |
| `jackpotBank()`, `oracleBudget()`, `escrowedETH()`, `totalClaimableETH()` | Distinct ETH ledgers in wei |
| `oracleTokenBudget()` | IMD minor units available for requests |
| `claimable(player)` | `(uint128 tokens, uint128 eth)` aggregate pull credits |
| `cooldownUntil(player)` | Next allowed timestamp; equality is allowed |
| `usedMessage(keccak256(utf8Bytes))` | Permanent exact-byte global duplicate check |
| `oddsFor(score)` | `(jackpot, epic, rare, common, nothing)` in basis points |
| `questionBatch(intakeId)` | Matching batch ID, or zero if unknown |
| `consumed(oracleUUID)` | Whether the signed UUID has settled |

`BatchView` field order is `firstAttemptId, firstNonce, openedAt, closedAt, rollBlock, size,
status, missedWindows, lastPlayer, prevrandao, scores, seed`. `openedAt` is returned only while
Open; `closedAt` for other states is the stored `since` value. For an expired *unclosed* batch,
that value is its opening time, not a real close time. Preserve event history for both timestamps.
Twenty scores are packed in a `uint160`, index zero in the lowest byte.

`AttemptView` field order is `player, batchId, index, score, tier, refunded, tokenAmount,
ethAmount, message`. Payout fields remain historical after claim and must not be displayed as
currently claimable. The default tier is Nothing before reveal; consult the batch state first.
An empty current batch can be queried before its first attempt. Batch zero/future IDs and unknown
attempts revert. `messagePointer(batchId,index)` is a data helper, not an existence check.

| Enum | Integer values |
| --- | --- |
| `Status` | Open 0, Pending 1, Graded 2, Revealed 3, Expired 4 |
| `Tier` | Nothing 0, Common 1, Rare 2, Epic 3, Jackpot 4 |

Index `AttemptSubmitted` for literal message history, `BatchClosed` for Intake IDs,
`BatchGraded` for ordered scores, `Rolled` for payouts/tier, `RollRearmed` for the new block and
tier cap, `BatchExpired`, `Refunded` and `Claimed` for lifecycle/payment state. `OracleFunded`
includes the asset: IMD means oracle fees, address zero means native ETH bounty funding.
Read `Transfer` events on `LaunchToken` for vault funding. Closed messages are omitted from the
view but are never erased from events or immutable data contracts. Render all text as plain text.

## Oracle ABI

The callback selector is derived from this exact signature:

```text
onOracleResult(bytes32,(bytes32,uint256,bytes32,uint8,bytes,uint256,uint64,uint64,bytes32,bytes32,uint16,uint16,uint16,uint64,uint64),bytes)
```

The attestation tuple is `requestId, chainId, questionHash, answerType, answer, figure,
fromBlock, toBlock, blockHash, panelJobId, panelSize, quorum, agreed, issuedAt, expiresAt`.
The first callback argument is Intake's ID; the tuple's `requestId` is the oracle UUID.
`answerType=5` and `answer=abi.encode(bytes32[])`, one unsigned score word per entry.

The EIP-712 domain is name `IdentityMD Oracle`, version `2`, current consumer chain ID,
verifying contract **BegVault's address**, never Intake. `attestationDigest` exposes the digest;
`eip712Domain` exposes the standard domain fields. The callback accepts no cross-chain delivery.

## Human-readable errors

The ABI is the authoritative selector source. Suggested UI messages for all vault/application
errors are below; wallet rejection/network failure should be handled separately.

| Error | User-facing meaning |
| --- | --- |
| `VaultEmpty` | Vault opening soon; BEG funding has not arrived. |
| `WrongPayment` | Send exactly the displayed entry price (or a supported bounty donation). |
| `InvalidMessageLength` | Use 1–280 UTF-8 bytes. |
| `InvalidUTF8` | The message contains invalid text encoding. |
| `BodyTooLarge` | This message needs too many JSON escapes; shorten control characters or quotes. |
| `DuplicateMessage` | This exact message has already been used. |
| `CooldownActive(until)` | Wait until the displayed time before begging again. |
| `BatchNotReady` | This batch is empty, closed or still accepting entries. |
| `BatchTimedOut` | Expire this batch; its request deadline has passed. |
| `OracleUnfunded` | The oracle request could not be paid or accepted; check IMD funding and service status. |
| `UnknownBatch` / `UnknownAttempt` | Refresh; that batch or attempt does not exist. |
| `InvalidBatchState` | This action is unavailable in the batch's current state. |
| `TooEarly` | Wait for the displayed reveal block or expiry time. |
| `NotPlayer` | Only the submitting wallet can refund this attempt. |
| `AlreadyRefunded` | This entry was already refunded; check claimable ETH. |
| `NothingToClaim` | This wallet has no outstanding claim credit. |
| `ETHTransferFailed` | Your receiving contract rejected ETH; the claim credit is preserved. |
| `ReentrancyGuardReentrantCall` | A nested contract action was rejected; credits are preserved. |
| `NotIntake` | Only the configured oracle Intake may deliver grades. |
| `InvalidQuestionId` | The oracle request ID is missing, unknown or reused. |
| `InvalidPanel` | The oracle result does not meet the required panel agreement. |
| `WrongChain` | The oracle answered for a different question chain. |
| `StaleAnswer` | The result predates this request. |
| `AttestationExpired` / `AttestationNotYetValid` | The signed result is outside its time window. |
| `BadSignature` | The oracle signature cannot be verified for this vault. |
| `AlreadyConsumed` | This signed oracle result was already used. |
| `WrongAnswerType` / `WrongScoreCount` | The oracle result has the wrong score format or length. |
| `InvalidConfiguration` / `ZeroSigner` | Deployment parameters are invalid. |
| `MessageStoreFailed` | Message storage failed; no entry payment was retained. |
| `MalformedEscape` | Stored message decoding failed; refresh and report the error. |
| `SafeERC20FailedOperation` | A token transfer or approval failed; the transaction was reverted. |
| `StringTooLong` / `InvalidShortString` | An internal library encoding error occurred. |

LaunchToken follows OpenZeppelin's standard ERC-20 errors: `ERC20InsufficientBalance`,
`ERC20InsufficientAllowance`, `ERC20InvalidSender`, `ERC20InvalidReceiver`,
`ERC20InvalidApprover`, and `ERC20InvalidSpender`. Display insufficient balance/allowance
or an invalid sender/recipient/approval address as appropriate. Unexpected errors should show a
generic failure with the decoded name; never assume a failed transaction spent the entry fee.
