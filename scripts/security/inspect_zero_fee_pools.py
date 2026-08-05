#!/usr/bin/env python3
"""Read-only production inspection of zero-fee Fluid DEX T1 pools.

The script performs eth_call only. It records a reproducible block number,
initialization/pause flags, pool tokens and decimals, and attempts exact-output
quotes by using Fluid's documented ADDRESS_DEAD revert-return mechanism.
No transaction is signed or broadcast.
"""
from __future__ import annotations

import json
import os
import pathlib
import re
import sys
from typing import Any

from eth_abi import decode
from eth_utils import keccak
from web3 import Web3

ROOT = pathlib.Path(__file__).resolve().parents[2]
DEAD = Web3.to_checksum_address("0x000000000000000000000000000000000000dEaD")
NATIVE = "0xeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"

RPC_BY_NETWORK = {
    "mainnet": os.getenv("MAINNET_RPC_URL", "https://ethereum-rpc.publicnode.com"),
    "arbitrum": os.getenv("ARBITRUM_RPC_URL", "https://arbitrum-one-rpc.publicnode.com"),
    "base": os.getenv("BASE_RPC_URL", "https://base-rpc.publicnode.com"),
    "polygon": os.getenv("POLYGON_RPC_URL", "https://polygon-bor-rpc.publicnode.com"),
    "bnb": os.getenv("BNB_RPC_URL", "https://bsc-rpc.publicnode.com"),
    "plasma": os.getenv("PLASMA_RPC_URL", "https://rpc.plasma.to"),
}

FACTORY_ABI = [
    {"inputs": [], "name": "totalDexes", "outputs": [{"type": "uint256"}], "stateMutability": "view", "type": "function"},
    {"inputs": [{"name": "dexId_", "type": "uint256"}], "name": "getDexAddress", "outputs": [{"type": "address"}], "stateMutability": "view", "type": "function"},
]

IMPLEMENTATIONS = {
    "name": "implementations",
    "type": "tuple",
    "components": [
        {"name": "shift", "type": "address"},
        {"name": "admin", "type": "address"},
        {"name": "colOperations", "type": "address"},
        {"name": "debtOperations", "type": "address"},
        {"name": "perfectOperationsAndSwapOut", "type": "address"},
    ],
}
CONSTANT_VIEWS = {
    "name": "constantsView_",
    "type": "tuple",
    "components": [
        {"name": "dexId", "type": "uint256"},
        {"name": "liquidity", "type": "address"},
        {"name": "factory", "type": "address"},
        IMPLEMENTATIONS,
        {"name": "deployerContract", "type": "address"},
        {"name": "token0", "type": "address"},
        {"name": "token1", "type": "address"},
        {"name": "supplyToken0Slot", "type": "bytes32"},
        {"name": "borrowToken0Slot", "type": "bytes32"},
        {"name": "supplyToken1Slot", "type": "bytes32"},
        {"name": "borrowToken1Slot", "type": "bytes32"},
        {"name": "exchangePriceToken0Slot", "type": "bytes32"},
        {"name": "exchangePriceToken1Slot", "type": "bytes32"},
        {"name": "oracleMapping", "type": "uint256"},
    ],
}
DEX_ABI = [
    {"inputs": [{"name": "slot_", "type": "bytes32"}], "name": "readFromStorage", "outputs": [{"type": "uint256"}], "stateMutability": "view", "type": "function"},
    {"inputs": [], "name": "constantsView", "outputs": [CONSTANT_VIEWS], "stateMutability": "view", "type": "function"},
    {"inputs": [], "name": "constantsView2", "outputs": [{"name": "v", "type": "tuple", "components": [
        {"name": "token0NumeratorPrecision", "type": "uint256"},
        {"name": "token0DenominatorPrecision", "type": "uint256"},
        {"name": "token1NumeratorPrecision", "type": "uint256"},
        {"name": "token1DenominatorPrecision", "type": "uint256"},
    ]}], "stateMutability": "view", "type": "function"},
    {"inputs": [
        {"name": "swap0to1_", "type": "bool"},
        {"name": "amountOut_", "type": "uint256"},
        {"name": "amountInMax_", "type": "uint256"},
        {"name": "to_", "type": "address"},
    ], "name": "swapOut", "outputs": [{"name": "amountIn_", "type": "uint256"}], "stateMutability": "payable", "type": "function"},
]
ERC20_ABI = [
    {"inputs": [], "name": "decimals", "outputs": [{"type": "uint8"}], "stateMutability": "view", "type": "function"},
    {"inputs": [], "name": "symbol", "outputs": [{"type": "string"}], "stateMutability": "view", "type": "function"},
]

DEX_VARIABLES2_SLOT = (1).to_bytes(32, "big")
FEE_MASK = (1 << 17) - 1
SWAP_RESULT_SELECTOR = "0x" + keccak(text="FluidDexSwapResult(uint256)")[:4].hex()


def factory_address(network: str) -> str:
    return Web3.to_checksum_address(json.loads((ROOT / "deployments" / network / "DexFactory.json").read_text())["address"])


def extract_revert_data(exc: BaseException) -> str | None:
    candidates: list[Any] = [getattr(exc, "data", None)]
    if getattr(exc, "args", None):
        candidates.extend(exc.args)
    def walk(v: Any) -> str | None:
        if isinstance(v, str):
            m = re.search(r"0x[0-9a-fA-F]{8,}", v)
            return m.group(0) if m else None
        if isinstance(v, dict):
            for key in ("data", "result", "return", "message"):
                if key in v:
                    got = walk(v[key])
                    if got:
                        return got
            for x in v.values():
                got = walk(x)
                if got:
                    return got
        if isinstance(v, (list, tuple)):
            for x in v:
                got = walk(x)
                if got:
                    return got
        return None
    for c in candidates:
        got = walk(c)
        if got:
            return got
    return None


def token_meta(w3: Web3, token: str, block: int) -> dict[str, Any]:
    if token.lower() == NATIVE:
        return {"symbol": "NATIVE", "decimals": 18, "has_code": False}
    has_code = bool(w3.eth.get_code(token, block_identifier=block))
    c = w3.eth.contract(address=token, abi=ERC20_ABI)
    try:
        decimals = int(c.functions.decimals().call(block_identifier=block))
    except Exception:
        decimals = None
    try:
        symbol = c.functions.symbol().call(block_identifier=block)
    except Exception:
        symbol = "UNKNOWN"
    return {"symbol": symbol, "decimals": decimals, "has_code": has_code}


def quote_swap_out(w3: Web3, dex: Any, direction: bool, amount_out: int, block: int) -> dict[str, Any]:
    data = dex.encode_abi("swapOut", args=[direction, amount_out, (1 << 256) - 1, DEAD])
    try:
        raw = w3.eth.call({"to": dex.address, "data": data}, block_identifier=block)
        return {"ok": True, "unexpected_return": raw.hex()}
    except Exception as exc:
        revert_data = extract_revert_data(exc)
        if revert_data and revert_data[:10].lower() == SWAP_RESULT_SELECTOR.lower() and len(revert_data) >= 74:
            amount_in = int.from_bytes(bytes.fromhex(revert_data[10:74]), "big")
            return {"ok": True, "amount_in": amount_in, "amount_out": amount_out}
        return {"ok": False, "selector": revert_data[:10] if revert_data else None, "error": str(exc)[:240]}


def candidate_amounts(decimals: int | None, numerator: int, denominator: int) -> list[int]:
    decimals = 18 if decimals is None else decimals
    # Core requires adjusted amount >= 1e6 and raw amount >= 100.
    min_adjusted_raw = (1_000_000 * denominator + numerator - 1) // numerator
    minimum = max(100, min_adjusted_raw)
    values = {minimum, minimum * 2, minimum * 10, minimum * 100, minimum * 1000}
    for exponent in range(max(0, decimals - 6), decimals + 1):
        values.add(10 ** exponent)
    return sorted(v for v in values if v > 0 and v < 2**128)


def scan_network(network: str, rpc: str) -> list[dict[str, Any]]:
    w3 = Web3(Web3.HTTPProvider(rpc, request_kwargs={"timeout": 45}))
    if not w3.is_connected():
        raise RuntimeError("RPC unavailable")
    block = w3.eth.block_number
    factory = w3.eth.contract(address=factory_address(network), abi=FACTORY_ABI)
    total = int(factory.functions.totalDexes().call(block_identifier=block))
    rows: list[dict[str, Any]] = []
    for dex_id in range(1, total + 1):
        address = Web3.to_checksum_address(factory.functions.getDexAddress(dex_id).call(block_identifier=block))
        if not w3.eth.get_code(address, block_identifier=block):
            continue
        dex = w3.eth.contract(address=address, abi=DEX_ABI)
        packed = int(dex.functions.readFromStorage(DEX_VARIABLES2_SLOT).call(block_identifier=block))
        fee = (packed >> 2) & FEE_MASK
        if fee != 0:
            continue
        cv = dex.functions.constantsView().call(block_identifier=block)
        cv2 = dex.functions.constantsView2().call(block_identifier=block)
        token0, token1 = Web3.to_checksum_address(cv[5]), Web3.to_checksum_address(cv[6])
        meta0, meta1 = token_meta(w3, token0, block), token_meta(w3, token1, block)
        row: dict[str, Any] = {
            "network": network, "block": block, "dex_id": dex_id, "dex": address,
            "liquidity": cv[1], "token0": token0, "token1": token1,
            "token0_meta": meta0, "token1_meta": meta1,
            "precision": {"t0_num": int(cv2[0]), "t0_den": int(cv2[1]), "t1_num": int(cv2[2]), "t1_den": int(cv2[3])},
            "fee_raw": fee, "smart_collateral": bool(packed & 1), "smart_debt": bool(packed & 2),
            "paused": bool(packed >> 255), "revenue_cut_percent": int((packed >> 19) & 0x7F),
            "quotes_0_to_1": [], "quotes_1_to_0": [],
        }
        for direction, out_meta, num, den, key in [
            (True, meta1, int(cv2[2]), int(cv2[3]), "quotes_0_to_1"),
            (False, meta0, int(cv2[0]), int(cv2[1]), "quotes_1_to_0"),
        ]:
            amounts = candidate_amounts(out_meta.get("decimals"), num, den)
            for amount in amounts:
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
            found = scan_network(network, rpc)
            rows.extend(found)
            print(f"[{network}] zero_fee={len(found)}", file=sys.stderr)
        except Exception as exc:
            errors.append(f"{network}: {exc}")
            print(f"[{network}] ERROR {exc}", file=sys.stderr)
    print(json.dumps({"rows": rows, "errors": errors}, indent=2, default=str))
    active = [r for r in rows if (r["smart_collateral"] or r["smart_debt"]) and not r["paused"] and any(q.get("ok") for q in r["quotes_0_to_1"] + r["quotes_1_to_0"])]
    print(f"SUMMARY zero_fee={len(rows)} quote_active={len(active)} errors={len(errors)}", file=sys.stderr)
    return 0 if rows else 3

if __name__ == "__main__":
    raise SystemExit(main())
