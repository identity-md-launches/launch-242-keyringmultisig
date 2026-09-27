#!/usr/bin/env python3
"""Export/check complete ABIs from `forge build` output using only the standard library."""

import argparse
import json
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="fail if an exported ABI differs")
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    stale = []
    for contract in ("LaunchToken", "KeyringMultisig"):
        artifact = root / "out" / f"{contract}.sol" / f"{contract}.json"
        if not artifact.is_file():
            parser.error(f"Missing {artifact.name}; run forge build first")
        abi = json.loads(artifact.read_text())["abi"]
        output = root / "docs" / "abi" / f"{contract}.json"
        content = json.dumps(abi, indent=2) + "\n"
        if args.check:
            if not output.is_file() or output.read_text() != content:
                stale.append(str(output.relative_to(root)))
        else:
            output.parent.mkdir(parents=True, exist_ok=True)
            output.write_text(content)
            print(f"Exported {output.relative_to(root)}")
    if stale:
        parser.exit(1, "ABIs need regeneration: " + ", ".join(stale) + "\n")
    if args.check:
        print("Both ABI exports match the build artifacts.")


if __name__ == "__main__":
    main()
