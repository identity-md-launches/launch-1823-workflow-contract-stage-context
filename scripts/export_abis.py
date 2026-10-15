#!/usr/bin/env python3
"""Export the two deployable contract ABIs from a completed forge build (no dependencies)."""

import argparse
import json
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="fail if an export differs from the build")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    for contract in ("LaunchToken", "BegVault"):
        artifact = root / "out" / f"{contract}.sol" / f"{contract}.json"
        if not artifact.is_file():
            parser.error(f"Missing {artifact.relative_to(root)}; run forge build first")
        abi = json.loads(artifact.read_text())["abi"]
        output = root / "docs" / "abi" / f"{contract}.json"
        if args.check:
            if not output.is_file() or json.loads(output.read_text()) != abi:
                parser.error(f"Stale ABI: {output.relative_to(root)}; regenerate after forge build")
            print(f"Verified {output.relative_to(root)}")
        else:
            output.parent.mkdir(parents=True, exist_ok=True)
            output.write_text(json.dumps(abi, indent=2) + "\n")
            print(f"Exported {output.relative_to(root)}")


if __name__ == "__main__":
    main()
