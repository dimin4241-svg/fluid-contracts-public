#!/usr/bin/env python3
from __future__ import annotations

import json
import os
import pathlib
from concurrent.futures import ThreadPoolExecutor, as_completed
from typing import Any

from eth_abi import encode
from eth_utils import keccak, to_checksum_address
from web3 import Web3

RPC_URL = os.environ.get("PLASMA_RPC_URL", "https://rpc.plasma.to")
DEPLOYMENTS = pathlib.Path("deployments/plasma")


def selector(signature: str) -> bytes:
    return keccak(text=signature)[:4]


def make_w3() -> Web3:
    return Web3(Web3.HTTPProvider(RPC_URL, request_kwargs={"timeout": 8}))


def load_address(name: str) -> str:
    return to_checksum_address(json.loads((DEPLOYMENTS / name).read_text())["address"])


def call_raw(w3: Web3, to: str, signature: str, args: bytes = b"") -> bytes | None:
    try:
        return bytes(w3.eth.call({"to": to, "data": selector(signature) + args}))
    except Exception:
        return None


def call_uint(w3: Web3, to: str, signature: str, args: bytes = b"") -> int | None:
    out = call_raw(w3, to, signature, args)
    return int.from_bytes(out[-32:], "big") if out and len(out) >= 32 else None


def call_address(w3: Web3, to: str, signature: str) -> str | None:
    out = call_raw(w3, to, signature)
    if not out or len(out) < 32 or int.from_bytes(out[-20:], "big") == 0:
        return None
    return to_checksum_address("0x" + out[-20:].hex())


def inspect(factory: str, vault_id: int) -> dict[str, Any] | None:
    w3 = make_w3()
    out = call_raw(w3, factory, "getVaultAddress(uint256)", encode(["uint256"], [vault_id]))
    if not out or len(out) < 32:
        return None
    vault = to_checksum_address("0x" + out[-20:].hex())
    if not w3.eth.get_code(vault):
        return None
    supply = call_address(w3, vault, "SUPPLY()")
    borrow = call_address(w3, vault, "BORROW()")
    supply_is_dex = bool(supply and call_raw(w3, supply, "TOKEN_0()") and call_raw(w3, supply, "TOKEN_1()"))
    borrow_is_dex = bool(borrow and call_raw(w3, borrow, "TOKEN_0()") and call_raw(w3, borrow, "TOKEN_1()"))
    return {
        "vault_id": vault_id,
        "reported_id": call_uint(w3, vault, "VAULT_ID()"),
        "vault": vault,
        "supply": supply,
        "borrow": borrow,
        "oracle": call_address(w3, vault, "ORACLE()"),
        "supply_token0": call_address(w3, vault, "SUPPLY_TOKEN0()"),
        "supply_token1": call_address(w3, vault, "SUPPLY_TOKEN1()"),
        "borrow_token0": call_address(w3, vault, "BORROW_TOKEN0()"),
        "borrow_token1": call_address(w3, vault, "BORROW_TOKEN1()"),
        "supply_is_dex": supply_is_dex,
        "borrow_is_dex": borrow_is_dex,
        "t4_candidate": supply_is_dex and borrow_is_dex,
    }


def main() -> int:
    w3 = make_w3()
    if not w3.is_connected():
        raise RuntimeError(f"RPC unavailable: {RPC_URL}")
    factory = load_address("VaultFactory.json")
    total = call_uint(w3, factory, "totalVaults()")
    if total is None:
        raise RuntimeError("totalVaults() failed")

    rows: list[dict[str, Any]] = []
    with ThreadPoolExecutor(max_workers=16) as pool:
        futures = [pool.submit(inspect, factory, i) for i in range(1, total + 1)]
        for future in as_completed(futures):
            row = future.result()
            if row:
                rows.append(row)
    rows.sort(key=lambda r: r["vault_id"])

    result = {
        "chain_id": w3.eth.chain_id,
        "block": w3.eth.block_number,
        "factory": factory,
        "total_vaults": total,
        "deployment_t4_files": sorted(p.name for p in DEPLOYMENTS.glob("VaultT4*.json")),
        "t4_candidates": [r for r in rows if r["t4_candidate"]],
        "vaults": rows,
    }
    text = json.dumps(result, indent=2)
    print(text)
    pathlib.Path("plasma-vault-inventory.json").write_text(text)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
