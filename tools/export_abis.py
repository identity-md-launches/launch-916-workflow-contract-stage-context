#!/usr/bin/env python3
"""Export compiled ABI arrays without RPC, extra dependencies, or environment reads."""
import argparse
import json
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="Fail if committed exports differ")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    for name in ("Swarmlings", "SwarmlingsHook", "DN404Mirror"):
        artifact = root / "out" / f"{name}.sol" / f"{name}.json"
        abi = json.loads(artifact.read_text())["abi"]
        expected = json.dumps(abi, indent=2) + "\n"
        output = root / "docs" / "abi" / f"{name}.json"
        if args.check:
            if not output.exists() or output.read_text() != expected:
                raise SystemExit(f"ABI differs: {output}; build and regenerate exports")
        else:
            output.parent.mkdir(parents=True, exist_ok=True)
            output.write_text(expected)
        print(f"{name}: {len(abi)} ABI entries {'checked' if args.check else 'exported'}")


if __name__ == "__main__":
    main()
