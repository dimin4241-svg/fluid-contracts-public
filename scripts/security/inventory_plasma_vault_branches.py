#!/usr/bin/env python3
from __future__ import annotations

import json
import os
from typing import Any

import requests
from eth_utils import keccak

RPCS = [os.environ.get("PLASMA_RPC_URL", ""), "https://rpc.plasma.to", "https://plasma-rpc.publicnode.com"]
FACTORY = "0x324c5Dc1fC42c7a4D43d92df1eBA58a54d13Bf2d"


def selector(signature: str) -> str:
    return "0x" + keccak(text=signature)[:4].hex()


def encode_uint(value: int) -> str:
    return value.to_bytes(32, "big").hex()


def rpc_call(method: str, params: list[Any]) -> Any:
    errors: list[str] = []
    for rpc in [x for x in RPCS if x]:
        try:
            response = requests.post(rpc, json={"jsonrpc": "2.0", "id": 1, "method": method, "params": params}, timeout=30)
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
    return "0x" + eth_call(to, selector(signature) + args)[-40:]


def decode_dynamic_string(raw: str) -> str:
    data = bytes.fromhex(raw[2:])
    if len(data) == 32:
        return data.rstrip(b"\x00").decode("utf-8", errors="replace")
    if len(data) < 64:
        return ""
    offset = int.from_bytes(data[:32], "big")
    length = int.from_bytes(data[offset : offset + 32], "big")
    return data[offset + 32 : offset + 32 + length].decode("utf-8", errors="replace")


def token_meta(token: str) -> dict[str, Any]:
    if int(token, 16) == 0:
        return {"address": token, "symbol": "NATIVE", "decimals": 18}
    try:
        symbol = decode_dynamic_string(eth_call(token, selector("symbol()")))
    except Exception:
        symbol = "?"
    try:
        decimals = call_uint(token, "decimals()")
    except Exception:
        decimals = None
    return {"address": token, "symbol": symbol, "decimals": decimals}


def split_words(raw: str) -> list[bytes]:
    data = bytes.fromhex(raw[2:])
    return [data[i : i + 32] for i in range(0, len(data), 32)]


def addr(words: list[bytes], index: int) -> str:
    return "0x" + words[index][-20:].hex()


def oracle_rates(oracle: str) -> dict[str, Any]:
    try:
        operate = call_uint(oracle, "getExchangeRateOperate()")
        liquidate = call_uint(oracle, "getExchangeRateLiquidate()")
        spread_bps = ((operate - liquidate) * 10_000) / operate if operate else None
        return {"address": oracle, "operate": operate, "liquidate": liquidate, "operate_minus_liquidate_bps": spread_bps}
    except Exception as exc:
        return {"address": oracle, "error": repr(exc)}


def decode_vault(address: str, vault_id: int) -> dict[str, Any]:
    words = split_words(eth_call(address, selector("constantsView()")))
    slot0 = call_uint(address, "readFromStorage(bytes32)", encode_uint(0))
    slot1 = call_uint(address, "readFromStorage(bytes32)", encode_uint(1))
    common = {
        "vault_id": vault_id,
        "address": address,
        "positions": (slot0 >> 210) & ((1 << 32) - 1),
        "branches": (slot0 >> 52) & ((1 << 30) - 1),
        "current_branch": (slot0 >> 22) & ((1 << 30) - 1),
        "current_branch_liquidated": bool(slot0 & 2),
    }
    if len(words) == 13:  # Vault T1 ConstantViews
        oracle = "0x" + ((slot1 >> 96) & ((1 << 160) - 1)).to_bytes(20, "big").hex()
        return {
            **common,
            "type": 1,
            "supply": token_meta(addr(words, 6)),
            "borrow": token_meta(addr(words, 7)),
            "oracle": oracle_rates(oracle),
        }
    if len(words) >= 18:
        return {
            **common,
            "type": int.from_bytes(words[13], "big"),
            "supply": token_meta(addr(words, 8)),
            "supply_token1": token_meta(addr(words, 9)),
            "borrow": token_meta(addr(words, 10)),
            "borrow_token1": token_meta(addr(words, 11)),
        }
    raise ValueError(f"unexpected constantsView word count {len(words)}")


def main() -> None:
    latest = rpc_call("eth_getBlockByNumber", ["latest", False])
    total = call_uint(FACTORY, "totalVaults()")
    rows: list[dict[str, Any]] = []
    for vault_id in range(1, total + 1):
        address = call_address(FACTORY, "getVaultAddress(uint256)", encode_uint(vault_id))
        try:
            rows.append(decode_vault(address, vault_id))
        except Exception as exc:
            rows.append({"vault_id": vault_id, "address": address, "error": repr(exc)})

    t1 = [row for row in rows if row.get("type") == 1]
    spreads = [row for row in t1 if ((row.get("oracle") or {}).get("operate_minus_liquidate_bps") or 0) > 0]
    output = {
        "chain_id": 9745,
        "block_number": int(latest["number"], 16),
        "block_gas_limit": int(latest["gasLimit"], 16),
        "factory": FACTORY,
        "total_vaults": total,
        "t1_count": len(t1),
        "t1_positive_oracle_spread_count": len(spreads),
        "t1_positive_oracle_spreads": spreads,
        "t1_vaults": t1,
        "all_vaults": rows,
    }
    print(json.dumps(output, indent=2))


if __name__ == "__main__":
    main()
