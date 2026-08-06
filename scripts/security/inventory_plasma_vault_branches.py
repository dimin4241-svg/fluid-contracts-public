#!/usr/bin/env python3
from __future__ import annotations

import json
import os
from typing import Any

import requests
from eth_utils import keccak

RPCS = [
    os.environ.get("PLASMA_RPC_URL", ""),
    "https://rpc.plasma.to",
    "https://plasma-rpc.publicnode.com",
]
FACTORY = "0x324c5Dc1fC42c7a4D43d92df1eBA58a54d13Bf2d"


def selector(signature: str) -> str:
    return "0x" + keccak(text=signature)[:4].hex()


def encode_uint(value: int) -> str:
    return value.to_bytes(32, "big").hex()


def rpc_call(method: str, params: list[Any]) -> Any:
    errors: list[str] = []
    for rpc in [x for x in RPCS if x]:
        try:
            response = requests.post(
                rpc,
                json={"jsonrpc": "2.0", "id": 1, "method": method, "params": params},
                timeout=30,
            )
            response.raise_for_status()
            body = response.json()
            if "error" in body:
                raise RuntimeError(str(body["error"]))
            return body["result"]
        except Exception as exc:
            errors.append(f"{rpc}: {exc!r}")
    raise RuntimeError("; ".join(errors))


def eth_call(to: str, data: str) -> str:
    return rpc_call("eth_call", [{"to": to, "data": data}, "latest"])


def call_uint(to: str, signature: str, args: str = "") -> int:
    return int(eth_call(to, selector(signature) + args), 16)


def call_address(to: str, signature: str, args: str = "") -> str:
    raw = eth_call(to, selector(signature) + args)
    return "0x" + raw[-40:]


def decode_dynamic_string(raw: str) -> str:
    data = bytes.fromhex(raw[2:])
    if len(data) == 32:
        return data.rstrip(b"\x00").decode("utf-8", errors="replace")
    if len(data) < 64:
        return ""
    offset = int.from_bytes(data[:32], "big")
    if offset + 32 > len(data):
        return ""
    length = int.from_bytes(data[offset : offset + 32], "big")
    return data[offset + 32 : offset + 32 + length].decode("utf-8", errors="replace")


def token_meta(token: str) -> dict[str, Any]:
    if int(token, 16) == 0:
        return {"address": token, "symbol": "NATIVE", "decimals": 18}
    symbol = "?"
    decimals = None
    try:
        symbol = decode_dynamic_string(eth_call(token, selector("symbol()")))
    except Exception:
        pass
    try:
        decimals = call_uint(token, "decimals()")
    except Exception:
        pass
    return {"address": token, "symbol": symbol, "decimals": decimals}


def decode_constants(raw: str) -> dict[str, Any]:
    data = bytes.fromhex(raw[2:])
    words = [data[i : i + 32] for i in range(0, len(data), 32)]
    if len(words) < 18:
        raise ValueError(f"constantsView returned only {len(words)} words")

    def addr(index: int) -> str:
        return "0x" + words[index][-20:].hex()

    return {
        "liquidity": addr(0),
        "factory": addr(1),
        "supply": addr(6),
        "borrow": addr(7),
        "supply_token0": addr(8),
        "supply_token1": addr(9),
        "borrow_token0": addr(10),
        "borrow_token1": addr(11),
        "vault_id": int.from_bytes(words[12], "big"),
        "vault_type": int.from_bytes(words[13], "big"),
    }


def main() -> None:
    latest = rpc_call("eth_getBlockByNumber", ["latest", False])
    total = call_uint(FACTORY, "totalVaults()")
    rows: list[dict[str, Any]] = []

    for vault_id in range(1, total + 1):
        address = call_address(FACTORY, "getVaultAddress(uint256)", encode_uint(vault_id))
        code = rpc_call("eth_getCode", [address, "latest"])
        if code == "0x":
            continue
        try:
            constants = decode_constants(eth_call(address, selector("constantsView()")))
            slot0 = call_uint(address, "readFromStorage(bytes32)", encode_uint(0))
        except Exception as exc:
            rows.append({"vault_id": vault_id, "address": address, "error": repr(exc)})
            continue

        branch_count = (slot0 >> 52) & ((1 << 30) - 1)
        current_branch = (slot0 >> 22) & ((1 << 30) - 1)
        position_count = (slot0 >> 210) & ((1 << 32) - 1)
        current_branch_liquidated = bool(slot0 & 2)

        row = {
            "vault_id": vault_id,
            "address": address,
            "type": constants["vault_type"],
            "positions": position_count,
            "branches": branch_count,
            "current_branch": current_branch,
            "current_branch_liquidated": current_branch_liquidated,
            "supply": token_meta(constants["supply_token0"]),
            "supply_token1": token_meta(constants["supply_token1"]),
            "borrow": token_meta(constants["borrow_token0"]),
            "borrow_token1": token_meta(constants["borrow_token1"]),
        }
        rows.append(row)

    t1 = [row for row in rows if row.get("type") == 1]
    cheap_t1 = [
        row
        for row in t1
        if (row.get("borrow") or {}).get("decimals", 0) >= 18
    ]
    output = {
        "chain_id": 9745,
        "block_number": int(latest["number"], 16),
        "block_gas_limit": int(latest["gasLimit"], 16),
        "factory": FACTORY,
        "total_vaults": total,
        "t1_count": len(t1),
        "t1_with_18_decimal_debt": len(cheap_t1),
        "t1_vaults": t1,
        "all_vaults": rows,
    }
    print(json.dumps(output, indent=2))


if __name__ == "__main__":
    main()
