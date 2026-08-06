#!/usr/bin/env python3
from __future__ import annotations

import json
import os
import pathlib
from typing import Any

from eth_abi import decode, encode
from eth_utils import keccak, to_checksum_address
from web3 import Web3

RPCS = [
    os.environ.get("PLASMA_RPC_URL", ""),
    "https://rpc.plasma.to",
    "https://plasma-rpc.publicnode.com",
]
DEPLOYMENTS = pathlib.Path("deployments/plasma")


def selector(signature: str) -> bytes:
    return keccak(text=signature)[:4]


def load_address(name: str) -> str:
    data = json.loads((DEPLOYMENTS / name).read_text())
    return to_checksum_address(data["address"])


def connect() -> Web3:
    errors: list[str] = []
    for url in RPCS:
        if not url:
            continue
        try:
            w3 = Web3(Web3.HTTPProvider(url, request_kwargs={"timeout": 30}))
            if w3.is_connected():
                return w3
            errors.append(f"{url}: not connected")
        except Exception as exc:
            errors.append(f"{url}: {exc!r}")
    raise RuntimeError("; ".join(errors))


def call_raw(w3: Web3, to: str, signature: str, args: bytes = b"") -> bytes | None:
    try:
        out = w3.eth.call({"to": to, "data": selector(signature) + args})
        return bytes(out)
    except Exception:
        return None


def call_uint(w3: Web3, to: str, signature: str, args: bytes = b"") -> int | None:
    out = call_raw(w3, to, signature, args)
    if out is None or len(out) < 32:
        return None
    return int.from_bytes(out[-32:], "big")


def call_address(w3: Web3, to: str, signature: str) -> str | None:
    out = call_raw(w3, to, signature)
    if out is None or len(out) < 32:
        return None
    value = "0x" + out[-20:].hex()
    if int(value, 16) == 0:
        return None
    return to_checksum_address(value)


def main() -> int:
    w3 = connect()
    factory = load_address("VaultFactory.json")
    latest = w3.eth.block_number
    total = call_uint(w3, factory, "totalVaults()")
    if total is None:
        raise RuntimeError("totalVaults() failed")

    deployment_t4 = sorted(p.name for p in DEPLOYMENTS.glob("VaultT4*.json"))
    rows: list[dict[str, Any]] = []

    for vault_id in range(1, total + 1):
        encoded = encode(["uint256"], [vault_id])
        out = call_raw(w3, factory, "getVaultAddress(uint256)", encoded)
        if out is None or len(out) < 32:
            continue
        vault = to_checksum_address("0x" + out[-20:].hex())
        code = w3.eth.get_code(vault)
        if not code:
            continue

        reported_id = call_uint(w3, vault, "VAULT_ID()")
        supply = call_address(w3, vault, "SUPPLY()")
        borrow = call_address(w3, vault, "BORROW()")
        oracle = call_address(w3, vault, "ORACLE()")
        supply_token0 = call_address(w3, vault, "SUPPLY_TOKEN0()")
        supply_token1 = call_address(w3, vault, "SUPPLY_TOKEN1()")
        borrow_token0 = call_address(w3, vault, "BORROW_TOKEN0()")
        borrow_token1 = call_address(w3, vault, "BORROW_TOKEN1()")

        # T4 requires both smart-collateral and smart-debt endpoints. Probe the
        # distinctive two-token DEX methods rather than trusting file names.
        supply_is_dex = bool(supply and call_raw(w3, supply, "TOKEN_0()") is not None and call_raw(w3, supply, "TOKEN_1()") is not None)
        borrow_is_dex = bool(borrow and call_raw(w3, borrow, "TOKEN_0()") is not None and call_raw(w3, borrow, "TOKEN_1()") is not None)

        rows.append({
            "vault_id": vault_id,
            "reported_id": reported_id,
            "vault": vault,
            "supply": supply,
            "borrow": borrow,
            "oracle": oracle,
            "supply_token0": supply_token0,
            "supply_token1": supply_token1,
            "borrow_token0": borrow_token0,
            "borrow_token1": borrow_token1,
            "supply_is_dex": supply_is_dex,
            "borrow_is_dex": borrow_is_dex,
            "t4_candidate": supply_is_dex and borrow_is_dex,
        })

    result = {
        "chain_id": w3.eth.chain_id,
        "block": latest,
        "factory": factory,
        "total_vaults": total,
        "deployment_t4_files": deployment_t4,
        "t4_candidates": [r for r in rows if r["t4_candidate"]],
        "vaults": rows,
    }
    print(json.dumps(result, indent=2))
    pathlib.Path("plasma-vault-inventory.json").write_text(json.dumps(result, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
