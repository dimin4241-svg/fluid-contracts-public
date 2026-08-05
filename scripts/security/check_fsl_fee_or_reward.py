#!/usr/bin/env python3
from __future__ import annotations

import json
import sys
import time
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
    return (
        f"https://api.routescan.io/v2/network/mainnet/evm/{chain_id}/etherscan/api"
        f"?module=proxy&action=eth_call&to={address}&data={SELECTOR}&tag=latest"
    )


def read_routescan(session: requests.Session, url: str) -> tuple[str, str]:
    last_error = ""
    for attempt in range(3):
        try:
            response = session.get(url, timeout=30)
            response.raise_for_status()
            payload = response.json()
            result = payload.get("result")
            if isinstance(result, str) and result.startswith("0x"):
                return result, "routescan"
            last_error = f"invalid payload: {payload}"
        except Exception as exc:
            last_error = repr(exc)
        time.sleep(1 + attempt)
    raise RuntimeError(last_error)


def read_rpc(session: requests.Session, chain_id: int, address: str) -> tuple[str, str]:
    errors: list[str] = []
    payload = {
        "jsonrpc": "2.0",
        "id": 1,
        "method": "eth_call",
        "params": [{"to": address, "data": SELECTOR}, "latest"],
    }
    for rpc in FALLBACK_RPCS.get(chain_id, []):
        try:
            response = session.post(rpc, json=payload, timeout=30)
            response.raise_for_status()
            body = response.json()
            result = body.get("result")
            if isinstance(result, str) and result.startswith("0x"):
                return result, rpc
            errors.append(f"{rpc}: {body}")
        except Exception as exc:
            errors.append(f"{rpc}: {exc!r}")
    raise RuntimeError("; ".join(errors))


def main() -> int:
    session = requests.Session()
    session.headers.update({"User-Agent": "fluid-fsl-rate-watch/1.1"})
    checked_at = datetime.now(timezone.utc).isoformat()
    rows: list[dict[str, Any]] = []
    failures: list[dict[str, str]] = []

    for network, chain_id, address in TARGETS:
        url = routescan_url(chain_id, address)
        try:
            result, source = read_routescan(session, url)
        except Exception as first_error:
            try:
                result, source = read_rpc(session, chain_id, address)
            except Exception as fallback_error:
                failures.append({
                    "network": network,
                    "chain_id": str(chain_id),
                    "address": address,
                    "routescan_url": url,
                    "error": f"routescan={first_error}; fallback={fallback_error}",
                })
                continue

        raw = decode_int32(result)
        rows.append({
            "network": network,
            "chain_id": chain_id,
            "address": address,
            "routescan_url": url,
            "source": source,
            "result": result,
            "raw_int32": raw,
            "annual_percent": raw / 10000,
            "checked_at_utc": checked_at,
        })

    output = {
        "checked_at_utc": checked_at,
        "target_count": len(TARGETS),
        "success_count": len(rows),
        "failure_count": len(failures),
        "nonzero": [row for row in rows if row["raw_int32"] != 0],
        "results": rows,
        "failures": failures,
    }
    print(json.dumps(output, indent=2))

    if failures:
        print(f"ERROR: {len(failures)} targets could not be confirmed", file=sys.stderr)
        return 2
    return 10 if output["nonzero"] else 0


if __name__ == "__main__":
    raise SystemExit(main())
