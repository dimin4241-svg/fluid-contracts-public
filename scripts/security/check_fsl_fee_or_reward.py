#!/usr/bin/env python3
from __future__ import annotations

import concurrent.futures
import json
import sys
from datetime import datetime, timezone
from typing import Any

import requests

SELECTOR = "0xe47a882d"
TARGETS = [
    ("Base", 8453, "0x4563134183e45D9502015db14B263E31781099bB"),
    ("Base", 8453, "0x983107BB3dcb71f3A30176114D8a17c454A62514"),
    ("Base", 8453, "0x3F6f85e3EDD95Db7f5D33b287D748dfEA64d92a6"),
    ("Base", 8453, "0x4f0C96408aF08473051Ea3EA1FF3e4F288115A5A"),
    ("Plasma", 9745, "0x983107BB3dcb71f3A30176114D8a17c454A62514"),
    ("Plasma", 9745, "0x4f0C96408aF08473051Ea3EA1FF3e4F288115A5A"),
    ("Polygon", 137, "0xa779B6736385930145F4856226Cd3E3691B72458"),
    ("Polygon", 137, "0x4563134183e45D9502015db14B263E31781099bB"),
    ("Polygon", 137, "0x3F6f85e3EDD95Db7f5D33b287D748dfEA64d92a6"),
    ("Polygon", 137, "0x4f0C96408aF08473051Ea3EA1FF3e4F288115A5A"),
    ("Arbitrum", 42161, "0x82C53239c4CFC89A8E55A691422af24c18A944b1"),
    ("Arbitrum", 42161, "0x1F0bFd9862ae58208d26db0d80797974434EC013"),
    ("Arbitrum", 42161, "0xdC1dF9E55f3B7EBD4F19001b294d1e537320BC2E"),
    ("Ethereum", 1, "0xb210249Bc59FE77D29eb5F0e566D60CB2B010EF1"),
    ("Ethereum", 1, "0x9b1f75ea07723F331996831f6d04AD4900d1A3B3"),
    ("Ethereum", 1, "0xD2245ee5C3099d65a3d0fdCecA0f71Cc4aA8f0FF"),
    ("Ethereum", 1, "0x44aE65F0d82E339c31c3Db9d4f82aB4D5d2B06B2"),
    ("Ethereum", 1, "0x10705D774fBE0a3802d7a915E23F6f2c109Fd77f"),
    ("Ethereum", 1, "0x7cA3814E21E96758d27e4e07B8d021DE70fC4Db6"),
    ("Ethereum", 1, "0x6Ee1e0FC4435571AABd95ecd441dE93C804d7f70"),
    ("Ethereum", 1, "0xe3eA95fBd0B27D3fF27e04a43aa5C4361376597c"),
]
FALLBACK_RPCS = {
    1: ["https://ethereum-rpc.publicnode.com", "https://rpc.ankr.com/eth"],
    8453: ["https://base-rpc.publicnode.com", "https://mainnet.base.org"],
    137: ["https://polygon-bor-rpc.publicnode.com", "https://polygon-rpc.com"],
    42161: ["https://arbitrum-one-rpc.publicnode.com", "https://arb1.arbitrum.io/rpc"],
    9745: ["https://rpc.plasma.to", "https://plasma-rpc.publicnode.com"],
}


def decode_int32(result: str) -> int:
    value = int(result, 16) & 0xFFFFFFFF
    return value - (1 << 32) if value & 0x80000000 else value


def routescan_url(chain_id: int, address: str) -> str:
    return (f"https://api.routescan.io/v2/network/mainnet/evm/{chain_id}/etherscan/api"
            f"?module=proxy&action=eth_call&to={address}&data={SELECTOR}&tag=latest")


def valid_result(payload: Any) -> str | None:
    if isinstance(payload, dict):
        result = payload.get("result")
        if isinstance(result, str) and result.startswith("0x") and len(result) >= 3:
            return result
    return None


def check_target(target: tuple[str, int, str], checked_at: str) -> dict[str, Any]:
    network, chain_id, address = target
    url = routescan_url(chain_id, address)
    errors: list[str] = []
    headers = {"User-Agent": "fluid-fsl-rate-watch/1.1"}

    try:
        response = requests.get(url, headers=headers, timeout=15)
        response.raise_for_status()
        result = valid_result(response.json())
        if result is not None:
            raw = decode_int32(result)
            return {"ok": True, "network": network, "chain_id": chain_id, "address": address,
                    "routescan_url": url, "source": "routescan", "result": result,
                    "raw_int32": raw, "annual_percent": raw / 10000,
                    "checked_at_utc": checked_at}
        errors.append(f"routescan invalid payload: {response.text[:500]}")
    except Exception as exc:
        errors.append(f"routescan: {exc!r}")

    payload = {"jsonrpc": "2.0", "id": 1, "method": "eth_call",
               "params": [{"to": address, "data": SELECTOR}, "latest"]}
    for rpc in FALLBACK_RPCS.get(chain_id, []):
        try:
            response = requests.post(rpc, json=payload, headers=headers, timeout=15)
            response.raise_for_status()
            result = valid_result(response.json())
            if result is not None:
                raw = decode_int32(result)
                return {"ok": True, "network": network, "chain_id": chain_id, "address": address,
                        "routescan_url": url, "source": rpc, "result": result,
                        "raw_int32": raw, "annual_percent": raw / 10000,
                        "checked_at_utc": checked_at, "routescan_error": errors[0]}
            errors.append(f"{rpc} invalid payload: {response.text[:500]}")
        except Exception as exc:
            errors.append(f"{rpc}: {exc!r}")

    return {"ok": False, "network": network, "chain_id": chain_id, "address": address,
            "routescan_url": url, "error": "; ".join(errors)}


def main() -> int:
    checked_at = datetime.now(timezone.utc).isoformat()
    with concurrent.futures.ThreadPoolExecutor(max_workers=len(TARGETS)) as executor:
        checked = list(executor.map(lambda t: check_target(t, checked_at), TARGETS))
    rows = [row for row in checked if row["ok"]]
    failures = [row for row in checked if not row["ok"]]
    output = {"checked_at_utc": checked_at, "target_count": len(TARGETS),
              "success_count": len(rows), "failure_count": len(failures),
              "nonzero": [row for row in rows if row["raw_int32"] != 0],
              "results": rows, "failures": failures}
    print(json.dumps(output, indent=2))
    if failures:
        print(f"ERROR: {len(failures)} targets could not be confirmed", file=sys.stderr)
        return 2
    return 10 if output["nonzero"] else 0


if __name__ == "__main__":
    raise SystemExit(main())
