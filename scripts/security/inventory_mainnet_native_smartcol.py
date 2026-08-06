#!/usr/bin/env python3
from __future__ import annotations

import json
import requests
from eth_utils import keccak

RPCS = ["https://ethereum-rpc.publicnode.com", "https://rpc.ankr.com/eth"]
FACTORY = "0x324c5Dc1fC42c7a4D43d92df1eBA58a54d13Bf2d"
NATIVE = "0xeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"


def sel(sig: str) -> str:
    return "0x" + keccak(text=sig)[:4].hex()


def enc(n: int) -> str:
    return n.to_bytes(32, "big").hex()


def rpc(method: str, params: list):
    errors = []
    for url in RPCS:
        try:
            r = requests.post(url, json={"jsonrpc":"2.0","id":1,"method":method,"params":params}, timeout=30)
            r.raise_for_status()
            body = r.json()
            if "error" in body:
                raise RuntimeError(body["error"])
            return body["result"]
        except Exception as exc:
            errors.append(f"{url}: {exc!r}")
    raise RuntimeError("; ".join(errors))


def call(to: str, data: str) -> str:
    return rpc("eth_call", [{"to": to, "data": data}, "latest"])


def uint_call(to: str, sig: str, args: str = "") -> int:
    return int(call(to, sel(sig) + args), 16)


def addr_call(to: str, sig: str, args: str = "") -> str:
    return "0x" + call(to, sel(sig) + args)[-40:]


def words(raw: str) -> list[bytes]:
    b = bytes.fromhex(raw[2:])
    return [b[i:i+32] for i in range(0, len(b), 32)]


def addr(ws: list[bytes], i: int) -> str:
    return "0x" + ws[i][-20:].hex()


def main() -> None:
    latest = rpc("eth_getBlockByNumber", ["latest", False])
    total = uint_call(FACTORY, "totalVaults()")
    matches = []
    smartcol = []
    errors = []

    for vault_id in range(1, total + 1):
        try:
            vault = addr_call(FACTORY, "getVaultAddress(uint256)", enc(vault_id))
            slot0 = uint_call(vault, "readFromStorage(bytes32)", enc(0))
            slot1 = uint_call(vault, "readFromStorage(bytes32)", enc(1))
            oracle = "0x" + ((slot1 >> 96) & ((1 << 160) - 1)).to_bytes(20, "big").hex()

            # All current SmartCol oracle families expose dexSmartColOracleData();
            # the first ABI word is the referenced DEX pool.
            data = words(call(oracle, sel("dexSmartColOracleData()")))
            if not data:
                continue
            dex = addr(data, 0)
            consts = words(call(dex, sel("constantsView()")))
            if len(consts) < 11:
                continue
            token0, token1 = addr(consts, 9), addr(consts, 10)
            vconsts = words(call(vault, sel("constantsView()")))
            vault_type = int.from_bytes(vconsts[13], "big") if len(vconsts) > 13 else 1
            row = {
                "vault_id": vault_id,
                "vault": vault,
                "vault_type": vault_type,
                "positions": (slot0 >> 210) & ((1 << 32) - 1),
                "branches": (slot0 >> 52) & ((1 << 30) - 1),
                "oracle": oracle,
                "dex": dex,
                "token0": token0,
                "token1": token1,
                "native_is_token0": token0.lower() == NATIVE,
                "native_is_token1": token1.lower() == NATIVE,
            }
            smartcol.append(row)
            if row["native_is_token0"] or row["native_is_token1"]:
                matches.append(row)
        except Exception as exc:
            # Most vaults are not SmartCol-oracle vaults; only keep unexpected diagnostics compactly.
            if "execution reverted" not in str(exc).lower():
                errors.append({"vault_id": vault_id, "error": repr(exc)})

    print(json.dumps({
        "chain_id": 1,
        "block": int(latest["number"], 16),
        "block_gas_limit": int(latest["gasLimit"], 16),
        "factory_total_vaults": total,
        "smartcol_oracle_vault_count": len(smartcol),
        "native_smartcol_vault_count": len(matches),
        "native_token0_count": sum(1 for x in matches if x["native_is_token0"]),
        "native_token1_count": sum(1 for x in matches if x["native_is_token1"]),
        "native_smartcol_vaults": matches,
        "all_smartcol_vaults": smartcol,
        "diagnostics": errors[:20],
    }, indent=2))


if __name__ == "__main__":
    main()
