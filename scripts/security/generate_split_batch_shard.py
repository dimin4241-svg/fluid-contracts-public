#!/usr/bin/env python3
"""Generate a bounded DEX-ID shard of the exhaustive split-batch test."""
from __future__ import annotations

import argparse
import json
import pathlib

from generate_all_active_roundtrip_test import enumerate_pools
from generate_all_active_split_batch_test import generate_solidity


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--network", required=True)
    parser.add_argument("--rpc", required=True)
    parser.add_argument("--dex-min", type=int, required=True)
    parser.add_argument("--dex-max", type=int, required=True)
    parser.add_argument("--solidity-out", required=True)
    parser.add_argument("--metadata-out", required=True)
    args = parser.parse_args()

    block, pools, skipped = enumerate_pools(args.network, args.rpc)
    included = [p for p in pools if args.dex_min <= int(p["dex_id"]) <= args.dex_max]
    skipped_outside = [p for p in pools if p not in included]

    solidity_out = pathlib.Path(args.solidity_out)
    metadata_out = pathlib.Path(args.metadata_out)
    solidity_out.parent.mkdir(parents=True, exist_ok=True)
    metadata_out.parent.mkdir(parents=True, exist_ok=True)
    solidity_out.write_text(
        generate_solidity(args.network, block, included), encoding="utf-8"
    )
    metadata_out.write_text(
        json.dumps(
            {
                "network": args.network,
                "block": block,
                "dex_min": args.dex_min,
                "dex_max": args.dex_max,
                "included": included,
                "skipped_native_or_metadata": skipped,
                "outside_shard": skipped_outside,
            },
            indent=2,
            default=str,
        ),
        encoding="utf-8",
    )
    print(
        f"GENERATED_SPLIT_SHARD network={args.network} block={block} "
        f"range={args.dex_min}-{args.dex_max} included={len(included)}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
