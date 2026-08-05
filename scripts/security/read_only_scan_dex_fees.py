#!/usr/bin/env python3
"""Read-only scan of deployed Fluid DEX pool fees.

No transactions are signed or broadcast. The script reads factory deployments,
enumerates deterministic DEX addresses, reads dexVariables2 storage through the
public readFromStorage(bytes32) helper, and extracts the 17-bit swap fee field.
"""

from __future__ import annotations

import json
import os
import pathlib
import sys
from dataclasses import dataclass

from web3 import Web3


ROOT = pathlib.Path(__file__).resolve().parents[2]

RPC_BY_NETWORK = {
    "mainnet": os.getenv("MAINNET_RPC_URL", "https://ethereum-rpc.publicnode.com"),
    "arbitrum": os.getenv("ARBITRUM_RPC_URL", "https://arbitrum-one-rpc.publicnode.com"),
    "base": os.getenv("BASE_RPC_URL", "https://base-rpc.publicnode.com"),
    "polygon": os.getenv("POLYGON_RPC_URL", "https://polygon-bor-rpc.publicnode.com"),
    "bnb": os.getenv("BNB_RPC_URL", "https://bsc-rpc.publicnode.com"),
    "plasma": os.getenv("PLASMA_RPC_URL", "https://rpc.plasma.to"),
}

FACTORY_ABI = [
    {
        "inputs": [],
        "name": "totalDexes",
        "outputs": [{"internalType": "uint256", "name": "", "type": "uint256"}],
        "stateMutability": "view",
        "type": "function",
    },
    {
        "inputs": [{"internalType": "uint256", "name": "dexId_", "type": "uint256"}],
        "name": "getDexAddress",
        "outputs": [{"internalType": "address", "name": "dex_", "type": "address"}],
        "stateMutability": "view",
        "type": "function",
    },
]

STORAGE_READ_ABI = [
    {
        "inputs": [{"internalType": "bytes32", "name": "slot_", "type": "bytes32"}],
        "name": "readFromStorage",
        "outputs": [{"internalType": "uint256", "name": "result_", "type": "uint256"}],
        "stateMutability": "view",
        "type": "function",
    }
]

# common/variables.sol: dexVariables is slot 0, dexVariables2 is slot 1.
DEX_VARIABLES_2_SLOT = (1).to_bytes(32, "big")
FEE_SHIFT = 2
FEE_MASK = (1 << 17) - 1


@dataclass
class Finding:
    network: str
    dex_id: int
    dex: str
    fee_raw: int

    @property
    def fee_percent(self) -> float:
        # 1% == 10,000
        return self.fee_raw / 10_000


def factory_address(network: str) -> str:
    deployment = ROOT / "deployments" / network / "DexFactory.json"
    data = json.loads(deployment.read_text())
    return Web3.to_checksum_address(data["address"])


def scan_network(network: str, rpc_url: str) -> list[Finding]:
    w3 = Web3(Web3.HTTPProvider(rpc_url, request_kwargs={"timeout": 30}))
    if not w3.is_connected():
        raise RuntimeError(f"RPC unavailable: {rpc_url}")

    factory = w3.eth.contract(address=factory_address(network), abi=FACTORY_ABI)
    total = factory.functions.totalDexes().call()
    findings: list[Finding] = []

    for dex_id in range(1, total + 1):
        dex = Web3.to_checksum_address(factory.functions.getDexAddress(dex_id).call())
        if not w3.eth.get_code(dex):
            continue
        reader = w3.eth.contract(address=dex, abi=STORAGE_READ_ABI)
        packed = int(reader.functions.readFromStorage(DEX_VARIABLES_2_SLOT).call())
        fee_raw = (packed >> FEE_SHIFT) & FEE_MASK
        findings.append(Finding(network, dex_id, dex, fee_raw))

    return findings


def main() -> int:
    all_findings: list[Finding] = []
    errors: list[str] = []

    for network, rpc_url in RPC_BY_NETWORK.items():
        try:
            findings = scan_network(network, rpc_url)
            all_findings.extend(findings)
            print(f"[{network}] scanned {len(findings)} DEX pools")
        except Exception as exc:  # continue so one flaky public RPC does not hide others
            errors.append(f"{network}: {exc}")
            print(f"[{network}] ERROR: {exc}", file=sys.stderr)

    print("network,dex_id,dex,fee_raw,fee_percent")
    for item in all_findings:
        print(f"{item.network},{item.dex_id},{item.dex},{item.fee_raw},{item.fee_percent:.8f}")

    zero_fee = [item for item in all_findings if item.fee_raw == 0]
    print(f"SUMMARY scanned={len(all_findings)} zero_fee={len(zero_fee)} errors={len(errors)}")
    for item in zero_fee:
        print(f"ZERO_FEE {item.network} dex_id={item.dex_id} dex={item.dex}")

    # A zero-fee pool is intentionally surfaced as a non-zero exit code so CI
    # draws attention to the exact-out rounding candidate.
    if zero_fee:
        return 2
    if not all_findings:
        return 3
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
