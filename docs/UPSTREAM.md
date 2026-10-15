# Source provenance and change scope

The implementation, Foundry configuration, remappings, dependencies and original Solidity tests
come from [identity-md-launches/launch-1771-beg](https://github.com/identity-md-launches/launch-1771-beg/tree/c97ea8b9742a756ef19a451d2170870a2df32371),
commit `c97ea8b9742a756ef19a451d2170870a2df32371`, as requested by the approved workflow.
The source was imported as ordinary files, without a Git checkout, submodules, package install
hooks, upstream manifest or frontend. The upstream audit description is supplied by the requester;
this contribution does not claim an independent audit of its own.

## Differences for this launch

- `src/BegVault.sol`: corrected its NatSpec funding description from factory funding to launch
  wallet funding. Executable Solidity is unchanged. The pinned code already implements
  `VaultEmpty()` and accepts the BEG token address as a constructor argument.
- `src/LaunchToken.sol`, `src/OracleAttestation.sol`, `src/libraries/MessageJson.sol` and
  `src/interfaces/IIntake.sol`: unchanged, including BEG metadata, immutable signer and protocol ABI.
- `foundry.toml`, `remappings.txt`, all original Solidity tests and all vendored dependency files:
  unchanged. No test was removed or weakened.
- Added `test/WalletFunding.t.sol`: factory custody, allocation to the wallet, no state/payment
  after an unfunded rejection, retry after transfer, separate oracle/bounty funding, partial and
  subsequent funding, timeout refunds and the complete wallet-funded settlement path.
- Added current deployment/operation/ABI documentation and ABI export tooling. Replaced the
  imported test coverage note's obsolete seed and earlier-launch review history. Old upstream
  documentation is not treated as this launch's requirements or evidence.

`upstream-files.sha256` records SHA-256 of the imported original source, tests, dependencies and
Foundry configuration, before the documented NatSpec edit. It excludes Markdown documentation.
This allows review against the pinned baseline; the entry for `src/BegVault.sol` intentionally
describes the original file, not the file with the corrected comment.

## Offline dependencies

| Dependency | Version from pinned repository | Contents |
| --- | --- | --- |
| OpenZeppelin Contracts | 5.5.0 | Required Solidity import closure, `VERSION` and MIT license |
| forge-std | 1.9.7 | Solidity test library, `VERSION`, MIT and Apache licenses |

All dependency source files are preserved from the pinned repository and resolved locally by
`remappings.txt`. No binary compiler is vendored. The verifier supplies the pinned 0.8.26 compiler.

The `OracleAttestation` library matches the supplied canonical reference, excluding formatting
and comments. Its 15 fields, type string, answer encoding and EIP-712 domain remain exact.
The inherited consumer intentionally differs from the generic canonical base only in its
no-admin signer design: an immutable signer replaces storage plus an internal rotation hook.
The digest and independent protocol signature vector tests cover compatibility.

The workflow requests the existing blockhash/prevrandao roll, fixed configuration, panel and
refund mechanics. They are preserved even where generic references recommend owner-settable
oracle integrations or stronger randomness. See `SECURITY.md` for the resulting trust assumptions.
