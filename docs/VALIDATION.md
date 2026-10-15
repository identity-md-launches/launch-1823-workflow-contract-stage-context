# Local validation record

Validated on 2026-10-15 using Foundry 1.8.3 and the project's pinned Solidity 0.8.26.
These are contributor checks, not independent verification or a security audit.

| Check | Result |
| --- | --- |
| `forge build` | Passed with the inherited compiler/lint warnings |
| Original pinned suite with the supplied fuzz seed | 119 passed, 0 failed, 0 skipped |
| New `WalletFundingTest` suite | 6 passed, 0 failed, 0 skipped; funding fuzz case ran 256 inputs |
| Final complete `forge test` | 125 passed, 0 failed, 0 skipped across 16 suites |
| `forge fmt --check` | Passed |
| `python3 scripts/export_abis.py --check` | Both exports match the build artifacts |
| Original-file checksum comparison | All preserved Solidity tests/dependencies/config match; only the documented `BegVault` NatSpec correction differs |
| Artifact runtime/link/opcode check | Both deployable artifacts fit EIP-170, contain no external library links and pass the forbidden-opcode scan |
| ABI error documentation comparison | All exported custom errors have documented meanings |

Exact test command:

```sh
FOUNDRY_FUZZ_SEED=0xdcc836d76ca6fb8ae596bee3dd668d01ee958cb4d4685d348e4f3299776e6316 forge test
```

Final Foundry summary:

```text
Ran 16 test suites in 149.85s (163.13s CPU time): 125 tests passed, 0 failed, 0 skipped (125 total tests)
```

The suites include the seven stateful accounting/lifecycle invariants, protocol conformance vector,
cold 200,000-gas oracle deliveries, reentrancy and transfer-failure cases, and the new wallet-funded
launch regressions. Configuration and individual test campaign counts are described in
[`test/CONTRIBUTOR_TESTS.md`](../test/CONTRIBUTOR_TESTS.md).

| Artifact | Runtime bytes | EIP-170 maximum |
| --- | ---: | ---: |
| `LaunchToken` | 1,502 | 24,576 |
| `BegVault` | 19,754 | 24,576 |

The preserved suite has an unused local-variable compiler warning in `BegVaultBase.sol`.
Foundry also reports lint warnings for timestamp comparisons, narrowing casts, events after
external calls and library implementation patterns. The tests and explicit review notes address
the relevant behavior; warnings have not been globally suppressed or represented as an audit.

No tests require RPC access, a funded wallet, private key, environment-variable lookup/mutation,
FFI or filesystem permissions. All test attesters are local fixtures. No live endpoint, factory
deployment, transaction broadcast, Slither/Mythril analysis, independent contributor review or
service attestation is claimed. Mainnet integration re-verification and review of the separately
generated manifest remain service/review responsibilities.
