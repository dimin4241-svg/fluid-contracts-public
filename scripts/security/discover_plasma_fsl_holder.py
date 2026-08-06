#!/usr/bin/env python3
"""Discover and RPC-verify a live fSL6 holder at an exact Plasma fork block."""

from __future__ import annotations

import json
import os
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any

RPC_URL = os.environ["PLASMA_RPC_URL"]
FORK_BLOCK = int(os.environ["PLASMA_FORK_BLOCK"])
WRAPPER = "0x983107BB3dcb71f3A30176114D8a17c454A62514"
ZERO = "0x0000000000000000000000000000000000000000"
DEAD = "0x000000000000000000000000000000000000dead"
BALANCE_OF_SELECTOR = "70a08231"
TOTAL_SUPPLY_SELECTOR = "18160ddd"
ROUTESCAN_HOLDERS_URL = (
    "https://api.routescan.io/v2/network/mainnet/evm/9745/erc20/"
    f"{WRAPPER}/holders?limit=100"
)
EVIDENCE_PATH = Path("evidence-smart-lending-share-interaction/holder-inventory.json")
GITHUB_ENV = Path(os.environ["GITHUB_ENV"])

_request_id = 0


def rpc(method: str, params: list[Any], retries: int = 5) -> Any:
    global _request_id
    _request_id += 1
    payload = json.dumps(
        {"jsonrpc": "2.0", "id": _request_id, "method": method, "params": params}
    ).encode()
    request = urllib.request.Request(
        RPC_URL,
        data=payload,
        headers={"Content-Type": "application/json", "User-Agent": "fluid-security-probe"},
    )

    for attempt in range(retries):
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                body = json.loads(response.read().decode())
            if "error" in body:
                raise RuntimeError(f"RPC {method} error: {body['error']}")
            return body["result"]
        except (urllib.error.URLError, TimeoutError, RuntimeError):
            if attempt + 1 == retries:
                raise
            time.sleep(0.5 * (2**attempt))
    raise AssertionError("unreachable")


def get_json(url: str, retries: int = 5) -> dict[str, Any]:
    request = urllib.request.Request(
        url,
        headers={"Accept": "application/json", "User-Agent": "fluid-security-probe"},
    )
    for attempt in range(retries):
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                return json.loads(response.read().decode())
        except (urllib.error.URLError, TimeoutError, json.JSONDecodeError):
            if attempt + 1 == retries:
                raise
            time.sleep(0.5 * (2**attempt))
    raise AssertionError("unreachable")


def eth_call(data: str) -> int:
    result = rpc(
        "eth_call",
        [{"to": WRAPPER, "data": data}, hex(FORK_BLOCK)],
    )
    return int(result, 16)


def balance_of(account: str) -> int:
    return eth_call("0x" + BALANCE_OF_SELECTOR + account[2:].lower().rjust(64, "0"))


def main() -> None:
    EVIDENCE_PATH.parent.mkdir(parents=True, exist_ok=True)

    indexed = get_json(ROUTESCAN_HOLDERS_URL)
    items = indexed.get("items")
    if not isinstance(items, list) or not items:
        raise RuntimeError(f"Routescan returned no holder items: {indexed}")

    excluded = {ZERO, DEAD, WRAPPER.lower()}
    verified: list[dict[str, Any]] = []

    for item in items:
        address = str(item.get("address", "")).lower()
        if len(address) != 42 or address in excluded:
            continue
        indexed_balance = int(item.get("balance", "0"))
        exact_fork_balance = balance_of(address)
        if exact_fork_balance > 0:
            verified.append(
                {
                    "address": address,
                    "routescan_balance": str(indexed_balance),
                    "fork_balance": str(exact_fork_balance),
                    "routescan_percentage": item.get("percentage"),
                }
            )

    verified.sort(key=lambda item: int(item["fork_balance"]), reverse=True)
    if not verified:
        raise RuntimeError("no Routescan holder retained a positive balance at the fork block")

    total_supply = eth_call("0x" + TOTAL_SUPPLY_SELECTOR)
    holder = verified[0]["address"]
    holder_balance = int(verified[0]["fork_balance"])

    if holder_balance <= 0 or holder_balance > total_supply:
        raise RuntimeError("invalid discovered holder balance")

    evidence = {
        "source": "Routescan ERC20 holders, verified by Plasma eth_call at exact fork block",
        "routescan_url": ROUTESCAN_HOLDERS_URL,
        "fork_block": FORK_BLOCK,
        "wrapper": WRAPPER,
        "routescan_items": len(items),
        "total_supply": str(total_supply),
        "selected_holder": holder,
        "selected_holder_balance": str(holder_balance),
        "selected_holder_ppm_of_supply": (holder_balance * 1_000_000) // total_supply,
        "top_verified_holders": verified[:20],
    }
    EVIDENCE_PATH.write_text(json.dumps(evidence, indent=2) + "\n")

    with GITHUB_ENV.open("a") as env_file:
        env_file.write(f"FSL_HOLDER={holder}\n")
        env_file.write(f"FSL_HOLDER_BALANCE={holder_balance}\n")

    print(
        "HolderInventory("
        f"forkBlock={FORK_BLOCK}, source=Routescan+RPC, indexedItems={len(items)}, "
        f"holder={holder}, holderBalance={holder_balance}, totalSupply={total_supply}, "
        f"holderPpm={(holder_balance * 1_000_000) // total_supply})"
    )


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        print(f"holder discovery failed: {exc}", file=sys.stderr)
        raise
