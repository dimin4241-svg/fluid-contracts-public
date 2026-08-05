#!/usr/bin/env python3
"""Read-only inspection of deployed Fluid pools with fee <= 0.005%.

Uses eth_call only and imports ABI/decoding helpers from inspect_zero_fee_pools.py.
"""
from __future__ import annotations

import json
import sys
from typing import Any

from web3 import Web3

from inspect_zero_fee_pools import (
    RPC_BY_NETWORK, FACTORY_ABI, DEX_ABI, DEX_VARIABLES2_SLOT, FEE_MASK,
    factory_address, token_meta, candidate_amounts, quote_swap_out,
)

MAX_FEE_RAW = 50  # raw 50 = 0.005%


def scan(network: str, rpc: str) -> list[dict[str, Any]]:
    w3 = Web3(Web3.HTTPProvider(rpc, request_kwargs={"timeout": 45}))
    if not w3.is_connected():
        raise RuntimeError("RPC unavailable")
    block = w3.eth.block_number
    factory = w3.eth.contract(address=factory_address(network), abi=FACTORY_ABI)
    total = int(factory.functions.totalDexes().call(block_identifier=block))
    rows: list[dict[str, Any]] = []
    for dex_id in range(1, total + 1):
        dex_address = Web3.to_checksum_address(factory.functions.getDexAddress(dex_id).call(block_identifier=block))
        if not w3.eth.get_code(dex_address, block_identifier=block):
            continue
        dex = w3.eth.contract(address=dex_address, abi=DEX_ABI)
        packed = int(dex.functions.readFromStorage(DEX_VARIABLES2_SLOT).call(block_identifier=block))
        fee = int((packed >> 2) & FEE_MASK)
        if fee == 0 or fee > MAX_FEE_RAW:
            continue
        cv = dex.functions.constantsView().call(block_identifier=block)
        cv2 = dex.functions.constantsView2().call(block_identifier=block)
        token0 = Web3.to_checksum_address(cv[5])
        token1 = Web3.to_checksum_address(cv[6])
        meta0 = token_meta(w3, token0, block)
        meta1 = token_meta(w3, token1, block)
        row: dict[str, Any] = {
            "network": network, "block": block, "dex_id": dex_id, "dex": dex_address,
            "liquidity": cv[1], "token0": token0, "token1": token1,
            "token0_meta": meta0, "token1_meta": meta1,
            "precision": {"t0_num": int(cv2[0]), "t0_den": int(cv2[1]), "t1_num": int(cv2[2]), "t1_den": int(cv2[3])},
            "fee_raw": fee, "fee_percent": fee / 10_000,
            "smart_collateral": bool(packed & 1), "smart_debt": bool(packed & 2),
            "paused": bool(packed >> 255), "revenue_cut_percent": int((packed >> 19) & 0x7F),
            "quotes_0_to_1": [], "quotes_1_to_0": [],
        }
        for direction, out_meta, num, den, key in [
            (True, meta1, int(cv2[2]), int(cv2[3]), "quotes_0_to_1"),
            (False, meta0, int(cv2[0]), int(cv2[1]), "quotes_1_to_0"),
        ]:
            for amount in candidate_amounts(out_meta.get("decimals"), num, den):
                result = quote_swap_out(w3, dex, direction, amount, block)
                result["amount_out"] = amount
                row[key].append(result)
                if result.get("ok"):
                    break
        rows.append(row)
    return rows


def main() -> int:
    rows: list[dict[str, Any]] = []
    errors: list[str] = []
    for network, rpc in RPC_BY_NETWORK.items():
        try:
            found = scan(network, rpc)
            rows.extend(found)
            print(f"[{network}] low_fee={len(found)}", file=sys.stderr)
        except Exception as exc:
            errors.append(f"{network}: {exc}")
            print(f"[{network}] ERROR {exc}", file=sys.stderr)
    active = [r for r in rows if (r["smart_collateral"] or r["smart_debt"]) and not r["paused"] and any(q.get("ok") for q in r["quotes_0_to_1"] + r["quotes_1_to_0"])]
    print(json.dumps({"rows": rows, "active": active, "errors": errors}, indent=2, default=str))
    print(f"SUMMARY low_fee={len(rows)} active={len(active)} errors={len(errors)}", file=sys.stderr)
    return 0 if rows else 3

if __name__ == "__main__":
    raise SystemExit(main())
