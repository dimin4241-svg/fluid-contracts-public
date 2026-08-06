#!/usr/bin/env python3
"""Discover the largest live fSL6 holder at an exact Plasma fork block."""

from __future__ import annotations

import json
import os
import sys
import time
import urllib.error
import urllib.request
from collections import defaultdict
from pathlib import Path
from typing import Any

RPC_URL = os.environ["PLASMA_RPC_URL"]
FORK_BLOCK = int(os.environ["PLASMA_FORK_BLOCK"])
WRAPPER = "0x983107BB3dcb71f3A30176114D8a17c454A62514"
TRANSFER_TOPIC = "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef"
ZERO = "0x0000000000000000000000000000000000000000"
DEAD = "0x000000000000000000000000000000000000dead"
BALANCE_OF_SELECTOR = "70a08231"
TOTAL_SUPPLY_SELECTOR = "18160ddd"
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
            with urllib.request.urlopen(request, timeout=45) as response:
                body = json.loads(response.read().decode())
            if "error" in body:
                raise RuntimeError(f"RPC {method} error: {body['error']}")
            return body["result"]
        except (urllib.error.URLError, TimeoutError, RuntimeError) as exc:
            if attempt + 1 == retries:
                raise
            time.sleep(0.5 * (2**attempt))
    raise AssertionError("unreachable")


def block_tag(block_number: int) -> str:
    return hex(block_number)


def code_exists(block_number: int) -> bool:
    return rpc("eth_getCode", [WRAPPER, block_tag(block_number)]) not in ("0x", "0x0")


def discover_creation_block() -> int:
    if not code_exists(FORK_BLOCK):
        raise RuntimeError(f"wrapper has no code at fork block {FORK_BLOCK}")

    low = 0
    high = FORK_BLOCK
    while low < high:
        middle = (low + high) // 2
        if code_exists(middle):
            high = middle
        else:
            low = middle + 1
    return low


def get_logs_recursive(start: int, end: int) -> list[dict[str, Any]]:
    try:
        return rpc(
            "eth_getLogs",
            [
                {
                    "address": WRAPPER,
                    "fromBlock": block_tag(start),
                    "toBlock": block_tag(end),
                    "topics": [TRANSFER_TOPIC],
                }
            ],
            retries=3,
        )
    except Exception:
        if start >= end:
            raise
        middle = (start + end) // 2
        return get_logs_recursive(start, middle) + get_logs_recursive(middle + 1, end)


def topic_address(topic: str) -> str:
    return "0x" + topic[-40:].lower()


def eth_call(data: str) -> int:
    result = rpc(
        "eth_call",
        [{"to": WRAPPER, "data": data}, block_tag(FORK_BLOCK)],
    )
    return int(result, 16)


def balance_of(account: str) -> int:
    return eth_call("0x" + BALANCE_OF_SELECTOR + account[2:].lower().rjust(64, "0"))


def main() -> None:
    EVIDENCE_PATH.parent.mkdir(parents=True, exist_ok=True)
    creation_block = discover_creation_block()
    print(f"wrapper creation block: {creation_block}")

    balances: defaultdict[str, int] = defaultdict(int)
    transfer_count = 0
    outer_chunk = 250_000

    for start in range(creation_block, FORK_BLOCK + 1, outer_chunk):
        end = min(start + outer_chunk - 1, FORK_BLOCK)
        logs = get_logs_recursive(start, end)
        transfer_count += len(logs)
        for log in logs:
            topics = log.get("topics", [])
            if len(topics) < 3:
                continue
            sender = topic_address(topics[1])
            recipient = topic_address(topics[2])
            value = int(log["data"], 16)
            if sender != ZERO:
                balances[sender] -= value
            if recipient != ZERO:
                balances[recipient] += value
        print(f"scanned {start}-{end}: {len(logs)} transfers")

    excluded = {ZERO, DEAD, WRAPPER.lower()}
    positive = [(address, amount) for address, amount in balances.items() if amount > 0 and address not in excluded]
    positive.sort(key=lambda item: item[1], reverse=True)
    if not positive:
        raise RuntimeError("no positive fSL6 holders reconstructed from Transfer logs")

    verified: list[dict[str, Any]] = []
    for address, reconstructed in positive[:50]:
        live = balance_of(address)
        if live > 0:
            verified.append(
                {
                    "address": address,
                    "reconstructed_balance": str(reconstructed),
                    "live_balance": str(live),
                }
            )

    verified.sort(key=lambda item: int(item["live_balance"]), reverse=True)
    if not verified:
        raise RuntimeError("no holder retained a positive balance at the selected fork block")

    total_supply = eth_call("0x" + TOTAL_SUPPLY_SELECTOR)
    holder = verified[0]["address"]
    holder_balance = int(verified[0]["live_balance"])

    if holder_balance <= 0 or holder_balance > total_supply:
        raise RuntimeError("invalid discovered holder balance")

    evidence = {
        "fork_block": FORK_BLOCK,
        "wrapper": WRAPPER,
        "creation_block": creation_block,
        "transfer_count": transfer_count,
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
        env_file.write(f"FSL_CREATION_BLOCK={creation_block}\n")

    print(
        "HolderInventory("
        f"forkBlock={FORK_BLOCK}, creationBlock={creation_block}, transfers={transfer_count}, "
        f"holder={holder}, holderBalance={holder_balance}, totalSupply={total_supply}, "
        f"holderPpm={(holder_balance * 1_000_000) // total_supply})"
    )


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        print(f"holder discovery failed: {exc}", file=sys.stderr)
        raise
