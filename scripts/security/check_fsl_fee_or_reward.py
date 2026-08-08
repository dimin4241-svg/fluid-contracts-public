#!/usr/bin/env python3
from __future__ import annotations

import concurrent.futures
import json
import sys
import time
from datetime import datetime, timezone

import requests

SELECTOR = "0xe47a882d"

TARGETS = [
    ("Base", 8453, "0x4563134183e45D9502015db14B263E31781099bB", "https://api.routescan.io/v2/network/mainnet/evm/8453/etherscan/api?action=eth_call&data=0xe47a882d&module=proxy&tag=latest&to=0x4563134183e45D9502015db14B263E31781099bB"),
    ("Base", 8453, "0x983107BB3dcb71f3A30176114D8a17c454A62514", "https://api.routescan.io/v2/network/mainnet/evm/8453/etherscan/api?action=eth_call&data=0xe47a882d&module=proxy&tag=latest&to=0x983107BB3dcb71f3A30176114D8a17c454A62514"),
    ("Base", 8453, "0x3F6f85e3EDD95Db7f5D33b287D748dfEA64d92a6", "https://api.routescan.io/v2/network/mainnet/evm/8453/etherscan/api?action=eth_call&data=0xe47a882d&module=proxy&tag=latest&to=0x3F6f85e3EDD95Db7f5D33b287D748dfEA64d92a6"),
    ("Base", 8453, "0x4f0C96408aF08473051Ea3EA1FF3e4F288115A5A", "https://api.routescan.io/v2/network/mainnet/evm/8453/etherscan/api?action=eth_call&data=0xe47a882d&module=proxy&tag=latest&to=0x4f0C96408aF08473051Ea3EA1FF3e4F288115A5A"),
    ("Plasma", 9745, "0x983107BB3dcb71f3A30176114D8a17c454A62514", "https://api.routescan.io/v2/network/mainnet/evm/9745/etherscan/api?action=eth_call&data=0xe47a882d&module=proxy&tag=latest&to=0x983107BB3dcb71f3A30176114D8a17c454A62514"),
    ("Plasma", 9745, "0x4f0C96408aF08473051Ea3EA1FF3e4F288115A5A", "https://api.routescan.io/v2/network/mainnet/evm/9745/etherscan/api?action=eth_call&data=0xe47a882d&module=proxy&tag=latest&to=0x4f0C96408aF08473051Ea3EA1FF3e4F288115A5A"),
    ("Polygon", 137, "0xa779B6736385930145F4856226Cd3E3691B72458", "https://api.routescan.io/v2/network/mainnet/evm/137/etherscan/api?action=eth_call&data=0xe47a882d&module=proxy&tag=latest&to=0xa779B6736385930145F4856226Cd3E3691B72458"),
    ("Polygon", 137, "0x4563134183e45D9502015db14B263E31781099bB", "https://api.routescan.io/v2/network/mainnet/evm/137/etherscan/api?action=eth_call&data=0xe47a882d&module=proxy&tag=latest&to=0x4563134183e45D9502015db14B263E31781099bB"),
    ("Polygon", 137, "0x3F6f85e3EDD95Db7f5D33b287D748dfEA64d92a6", "https://api.routescan.io/v2/network/mainnet/evm/137/etherscan/api?action=eth_call&data=0xe47a882d&module=proxy&tag=latest&to=0x3F6f85e3EDD95Db7f5D33b287D748dfEA64d92a6"),
    ("Polygon", 137, "0x4f0C96408aF08473051Ea3EA1FF3e4F288115A5A", "https://api.routescan.io/v2/network/mainnet/evm/137/etherscan/api?action=eth_call&data=0xe47a882d&module=proxy&tag=latest&to=0x4f0C96408aF08473051Ea3EA1FF3e4F288115A5A"),
    ("Arbitrum", 42161, "0x82C53239c4CFC89A8E55A691422af24c18A944b1", "https://api.routescan.io/v2/network/mainnet/evm/42161/etherscan/api?action=eth_call&data=0xe47a882d&module=proxy&tag=latest&to=0x82C53239c4CFC89A8E55A691422af24c18A944b1"),
    ("Arbitrum", 42161, "0x1F0bFd9862ae58208d26db0d80797974434EC013", "https://api.routescan.io/v2/network/mainnet/evm/42161/etherscan/api?action=eth_call&data=0xe47a882d&module=proxy&tag=latest&to=0x1F0bFd9862ae58208d26db0d80797974434EC013"),
    ("Arbitrum", 42161, "0xdC1dF9E55f3B7EBD4F19001b294d1e537320BC2E", "https://api.routescan.io/v2/network/mainnet/evm/42161/etherscan/api?action=eth_call&data=0xe47a882d&module=proxy&tag=latest&to=0xdC1dF9E55f3B7EBD4F19001b294d1e537320BC2E"),
    ("Ethereum", 1, "0xb210249Bc59FE77D29eb5F0e566D60CB2B010EF1", "https://api.routescan.io/v2/network/mainnet/evm/1/etherscan/api?action=eth_call&data=0xe47a882d&module=proxy&tag=latest&to=0xb210249Bc59FE77D29eb5F0e566D60CB2B010EF1"),
    ("Ethereum", 1, "0x9b1f75ea07723F331996831f6d04AD4900d1A3B3", "https://api.routescan.io/v2/network/mainnet/evm/1/etherscan/api?action=eth_call&data=0xe47a882d&module=proxy&tag=latest&to=0x9b1f75ea07723F331996831f6d04AD4900d1A3B3"),
    ("Ethereum", 1, "0xD2245ee5C3099d65a3d0fdCecA0f71Cc4aA8f0FF", "https://api.routescan.io/v2/network/mainnet/evm/1/etherscan/api?action=eth_call&data=0xe47a882d&module=proxy&tag=latest&to=0xD2245ee5C3099d65a3d0fdCecA0f71Cc4aA8f0FF"),
    ("Ethereum", 1, "0x44aE65F0d82E339c31c3Db9d4f82aB4D5d2B06B2", "https://api.routescan.io/v2/network/mainnet/evm/1/etherscan/api?action=eth_call&data=0xe47a882d&module=proxy&tag=latest&to=0x44aE65F0d82E339c31c3Db9d4f82aB4D5d2B06B2"),
    ("Ethereum", 1, "0x10705D774fBE0a3802d7a915E23F6f2c109Fd77f", "https://api.routescan.io/v2/network/mainnet/evm/1/etherscan/api?action=eth_call&data=0xe47a882d&module=proxy&tag=latest&to=0x10705D774fBE0a3802d7a915E23F6f2c109Fd77f"),
    ("Ethereum", 1, "0x7cA3814E21E96758d27e4e07B8d021DE70fC4Db6", "https://api.routescan.io/v2/network/mainnet/evm/1/etherscan/api?action=eth_call&data=0xe47a882d&module=proxy&tag=latest&to=0x7cA3814E21E96758d27e4e07B8d021DE70fC4Db6"),
    ("Ethereum", 1, "0x6Ee1e0FC4435571AABd95ecd441dE93C804d7f70", "https://api.routescan.io/v2/network/mainnet/evm/1/etherscan/api?action=eth_call&data=0xe47a882d&module=proxy&tag=latest&to=0x6Ee1e0FC4435571AABd95ecd441dE93C804d7f70"),
    ("Ethereum", 1, "0xe3eA95fBd0B27D3fF27e04a43aa5C4361376597c", "https://api.routescan.io/v2/network/mainnet/evm/1/etherscan/api?action=eth_call&data=0xe47a882d&module=proxy&tag=latest&to=0xe3eA95fBd0B27D3fF27e04a43aa5C4361376597c"),
]

FALLBACK_RPCS = {
    1: ["https://ethereum-rpc.publicnode.com", "https://eth.llamarpc.com", "https://rpc.ankr.com/eth"],
    8453: ["https://base-rpc.publicnode.com", "https://mainnet.base.org"],
    137: ["https://polygon-bor-rpc.publicnode.com", "https://polygon-rpc.com"],
    42161: ["https://arbitrum-one-rpc.publicnode.com", "https://arb1.arbitrum.io/rpc"],
    9745: ["https://rpc.plasma.to", "https://plasma.drpc.org"],
}

TIMEOUT = 8
PRIMARY_ATTEMPTS = 2


def decode_int32(result: str) -> int:
    value = int(result, 16) & 0xFFFFFFFF
    return value - (1 << 32) if value & 0x80000000 else value


def valid_result(body: object) -> str:
    if not isinstance(body, dict):
        raise RuntimeError(f"non-object payload: {body!r}")
    result = body.get("result")
    if not isinstance(result, str) or not result.startswith("0x"):
        raise RuntimeError(f"invalid payload: {body}")
    int(result, 16)
    return result


def routescan_call(url: str) -> str:
    last = None
    for attempt in range(PRIMARY_ATTEMPTS):
        try:
            r = requests.get(url, timeout=TIMEOUT, headers={"User-Agent": "fluid-fsl-rate-watch/3.0"})
            r.raise_for_status()
            return valid_result(r.json())
        except Exception as exc:
            last = exc
            if attempt + 1 < PRIMARY_ATTEMPTS:
                time.sleep(0.75)
    raise RuntimeError(str(last))


def rpc_call(rpc: str, address: str) -> str:
    payload = {"jsonrpc": "2.0", "id": 1, "method": "eth_call", "params": [{"to": address, "data": SELECTOR}, "latest"]}
    r = requests.post(rpc, json=payload, timeout=TIMEOUT, headers={"User-Agent": "fluid-fsl-rate-watch/3.0"})
    r.raise_for_status()
    return valid_result(r.json())


def fallback_call(chain_id: int, address: str, exclude: set[str] | None = None) -> tuple[str, str]:
    errors = []
    exclude = exclude or set()
    for rpc in FALLBACK_RPCS.get(chain_id, []):
        if rpc in exclude:
            continue
        try:
            return rpc_call(rpc, address), rpc
        except Exception as exc:
            errors.append(f"{rpc}: {exc}")
    raise RuntimeError("; ".join(errors))


def check_one(target: tuple[str, int, str, str], checked_at: str) -> tuple[dict | None, dict | None]:
    network, chain_id, address, url = target
    primary_result = None
    source = "routescan"
    source_rpc = None
    routescan_error = None
    try:
        try:
            primary_result = routescan_call(url)
        except Exception as exc:
            routescan_error = str(exc)
            primary_result, source_rpc = fallback_call(chain_id, address)
            source = f"fallback:{source_rpc}"

        raw = decode_int32(primary_result)
        independent = None
        if raw != 0:
            exclude = {source_rpc} if source_rpc else set()
            second_result, second_rpc = fallback_call(chain_id, address, exclude=exclude)
            second_raw = decode_int32(second_result)
            independent = {"rpc": second_rpc, "result": second_result, "raw_int32": second_raw}
            if second_raw != raw:
                raise RuntimeError(f"nonzero mismatch primary={primary_result} raw={raw} independent={independent}")

        row = {
            "network": network,
            "chain_id": chain_id,
            "address": address,
            "canonical_routescan_url": url,
            "source": source,
            "routescan_error": routescan_error,
            "result": primary_result,
            "raw_int32": raw,
            "annual_percent": raw / 10000,
            "checked_at_utc": checked_at,
            "confirmed": True,
            "independent_confirmation": independent,
        }
        return row, None
    except Exception as exc:
        return None, {
            "network": network,
            "chain_id": chain_id,
            "address": address,
            "canonical_routescan_url": url,
            "error": str(exc),
        }


def main() -> int:
    checked_at = datetime.now(timezone.utc).isoformat()
    rows: list[dict] = []
    failures: list[dict] = []

    with concurrent.futures.ThreadPoolExecutor(max_workers=len(TARGETS)) as pool:
        futures = [pool.submit(check_one, target, checked_at) for target in TARGETS]
        for future in futures:
            row, failure = future.result()
            if row is not None:
                rows.append(row)
            if failure is not None:
                failures.append(failure)

    order = {(network, chain_id, address): i for i, (network, chain_id, address, _) in enumerate(TARGETS)}
    rows.sort(key=lambda r: order[(r["network"], r["chain_id"], r["address"])])
    failures.sort(key=lambda r: order[(r["network"], r["chain_id"], r["address"])])
    nonzero = [r for r in rows if r["raw_int32"] != 0 and r["confirmed"]]

    output = {
        "checked_at_utc": checked_at,
        "target_count": len(TARGETS),
        "success_count": len(rows),
        "failure_count": len(failures),
        "nonzero": nonzero,
        "results": rows,
        "failures": failures,
    }
    with open("fsl_fee_or_reward_results.json", "w", encoding="utf-8") as f:
        json.dump(output, f, indent=2)
    print(json.dumps(output, indent=2))

    if failures:
        return 2
    return 10 if nonzero else 0


if __name__ == "__main__":
    raise SystemExit(main())

# automation refresh marker: 2026-08-08T07:53Z
