#!/usr/bin/env python3
"""Generate a Foundry fork test that searches every active non-native Fluid DEX
pool on one network for closed exact-output rounding extraction cycles.

The generated test never broadcasts a transaction. It runs against a local
Foundry fork and restores pool state after every attempted route.
"""
from __future__ import annotations

import argparse
import json
import pathlib
import sys
from typing import Any

from web3 import Web3

ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts" / "security"))

from inspect_zero_fee_pools import (  # noqa: E402
    DEX_ABI,
    DEX_VARIABLES2_SLOT,
    FACTORY_ABI,
    FEE_MASK,
    NATIVE,
    factory_address,
    token_meta,
)


def enumerate_pools(network: str, rpc: str) -> tuple[int, list[dict[str, Any]], list[dict[str, Any]]]:
    w3 = Web3(Web3.HTTPProvider(rpc, request_kwargs={"timeout": 60}))
    if not w3.is_connected():
        raise RuntimeError(f"RPC unavailable for {network}")

    block = w3.eth.block_number
    factory = w3.eth.contract(address=factory_address(network), abi=FACTORY_ABI)
    total = int(factory.functions.totalDexes().call(block_identifier=block))
    included: list[dict[str, Any]] = []
    skipped: list[dict[str, Any]] = []

    for dex_id in range(1, total + 1):
        dex_address = Web3.to_checksum_address(
            factory.functions.getDexAddress(dex_id).call(block_identifier=block)
        )
        if not w3.eth.get_code(dex_address, block_identifier=block):
            continue

        dex = w3.eth.contract(address=dex_address, abi=DEX_ABI)
        packed = int(dex.functions.readFromStorage(DEX_VARIABLES2_SLOT).call(block_identifier=block))
        active_collateral = bool(packed & 1)
        active_debt = bool(packed & 2)
        paused = bool(packed >> 255)
        if paused or not (active_collateral or active_debt):
            continue

        cv = dex.functions.constantsView().call(block_identifier=block)
        cv2 = dex.functions.constantsView2().call(block_identifier=block)
        token0 = Web3.to_checksum_address(cv[5])
        token1 = Web3.to_checksum_address(cv[6])
        meta0 = token_meta(w3, token0, block)
        meta1 = token_meta(w3, token1, block)

        row = {
            "network": network,
            "block": block,
            "dex_id": dex_id,
            "dex": dex_address,
            "liquidity": Web3.to_checksum_address(cv[1]),
            "token0": token0,
            "token1": token1,
            "token0_meta": meta0,
            "token1_meta": meta1,
            "t0_num": int(cv2[0]),
            "t0_den": int(cv2[1]),
            "t1_num": int(cv2[2]),
            "t1_den": int(cv2[3]),
            "fee_raw": int((packed >> 2) & FEE_MASK),
            "smart_collateral": active_collateral,
            "smart_debt": active_debt,
        }

        reason = None
        if token0.lower() == NATIVE or token1.lower() == NATIVE:
            reason = "native-token-pool"
        elif meta0.get("decimals") is None or meta1.get("decimals") is None:
            reason = "unknown-decimals"
        elif not meta0.get("has_code") or not meta1.get("has_code"):
            reason = "token-without-code"

        if reason:
            row["skip_reason"] = reason
            skipped.append(row)
        else:
            included.append(row)

    return block, included, skipped


def addr(value: str) -> str:
    return value.lower()


def generate_solidity(network: str, block: int, pools: list[dict[str, Any]]) -> str:
    assignments: list[str] = []
    for i, p in enumerate(pools):
        assignments.append(
            "        pools[{i}] = PoolConfig({{"
            "dexId: {dex_id}, pool: address({pool}), liquidity: address({liquidity}), "
            "token0: address({token0}), token1: address({token1}), "
            "dec0: {dec0}, dec1: {dec1}, "
            "t0Num: {t0_num}, t0Den: {t0_den}, t1Num: {t1_num}, t1Den: {t1_den}, "
            "feeRaw: {fee_raw}}});".format(
                i=i,
                dex_id=p["dex_id"],
                pool=addr(p["dex"]),
                liquidity=addr(p["liquidity"]),
                token0=addr(p["token0"]),
                token1=addr(p["token1"]),
                dec0=int(p["token0_meta"]["decimals"]),
                dec1=int(p["token1_meta"]["decimals"]),
                t0_num=p["t0_num"],
                t0_den=p["t0_den"],
                t1_num=p["t1_num"],
                t1_den=p["t1_den"],
                fee_raw=p["fee_raw"],
            )
        )

    return f'''// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.21;

import {{ Test }} from "forge-std/Test.sol";

// Generated for {network} at discovery block {block}.
// Pool state itself is read from the latest block selected by RPC_URL at test time.
interface IERC20RoundTrip {{
    function balanceOf(address account) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
}}

interface IFluidDexRoundTrip {{
    function swapOut(bool swap0to1, uint256 amountOut, uint256 amountInMax, address to)
        external payable returns (uint256 amountIn);
}}

contract RoundTripExecutor {{
    address internal immutable pool;
    address internal immutable token0;
    address internal immutable token1;

    constructor(address pool_, address token0_, address token1_) {{
        pool = pool_;
        token0 = token0_;
        token1 = token1_;
        _approve(token0_, pool_);
        _approve(token1_, pool_);
    }}

    function _approve(address token, address spender) private {{
        (bool ok, bytes memory data) = token.call(
            abi.encodeWithSelector(IERC20RoundTrip.approve.selector, spender, type(uint256).max)
        );
        require(ok && (data.length == 0 || abi.decode(data, (bool))), "APPROVE_FAILED");
    }}

    function oneRound(bool forward0to1, uint256 amountOut)
        external
        returns (
            uint256 forwardInput,
            uint256 reverseInput,
            int256 delta0,
            int256 delta1
        )
    {{
        uint256 before0 = IERC20RoundTrip(token0).balanceOf(address(this));
        uint256 before1 = IERC20RoundTrip(token1).balanceOf(address(this));
        if (forward0to1) {{
            forwardInput = IFluidDexRoundTrip(pool).swapOut(
                true, amountOut, type(uint256).max, address(this)
            );
            reverseInput = IFluidDexRoundTrip(pool).swapOut(
                false, forwardInput, type(uint256).max, address(this)
            );
        }} else {{
            forwardInput = IFluidDexRoundTrip(pool).swapOut(
                false, amountOut, type(uint256).max, address(this)
            );
            reverseInput = IFluidDexRoundTrip(pool).swapOut(
                true, forwardInput, type(uint256).max, address(this)
            );
        }}
        delta0 = int256(IERC20RoundTrip(token0).balanceOf(address(this))) - int256(before0);
        delta1 = int256(IERC20RoundTrip(token1).balanceOf(address(this))) - int256(before1);
    }}
}}

contract GeneratedAllActiveRoundTripSearch is Test {{
    struct PoolConfig {{
        uint256 dexId;
        address pool;
        address liquidity;
        address token0;
        address token1;
        uint8 dec0;
        uint8 dec1;
        uint256 t0Num;
        uint256 t0Den;
        uint256 t1Num;
        uint256 t1Den;
        uint256 feeRaw;
    }}

    struct Best {{
        bool found;
        uint256 amountOut;
        uint256 forwardInput;
        uint256 reverseInput;
        int256 inputDelta;
        int256 profit;
        uint256 gasUsed;
        uint256 successfulCalls;
    }}

    event PoolBest(
        uint256 indexed dexId,
        address indexed pool,
        address indexed profitToken,
        bool forward0to1,
        uint256 feeRaw,
        uint256 amountOut,
        uint256 forwardInput,
        uint256 reverseInput,
        int256 inputDelta,
        int256 profit,
        uint256 liquidityLoss,
        uint256 gasUsed,
        uint256 successfulCalls
    );

    event PoolNoClosedProfit(
        uint256 indexed dexId,
        address indexed pool,
        bool forward0to1,
        uint256 feeRaw,
        uint256 successfulCalls
    );

    event PoolSetupFailure(
        uint256 indexed dexId,
        address indexed pool,
        bytes4 selector,
        uint256 errorId
    );

    event NetworkSummary(
        uint256 poolCount,
        uint256 setupFailures,
        uint256 profitableDirections,
        uint256 profitablePools
    );

    function setUp() public {{
        vm.createSelectFork(vm.envString("RPC_URL"));
    }}

    function _pools() internal pure returns (PoolConfig[] memory pools) {{
        pools = new PoolConfig[]({len(pools)});
{chr(10).join(assignments)}
    }}

    function _minimumRaw(uint256 numerator, uint256 denominator)
        internal pure returns (uint256 value)
    {{
        value = (1_000_000 * denominator + numerator - 1) / numerator;
        if (value < 100) value = 100;
    }}

    function _candidate(uint256 minimum, uint256 i) internal pure returns (uint256) {{
        if (i < 64) return minimum + i;
        uint256[10] memory multipliers = [
            uint256(2), 3, 4, 5, 8, 16, 32, 64, 256, 1024
        ];
        return minimum * multipliers[i - 64] + 1;
    }}

    function _funding(uint8 decimals_) internal pure returns (uint256) {{
        uint256 exponent = uint256(decimals_) + 10;
        if (exponent > 30) exponent = 30;
        return 10 ** exponent;
    }}

    function _decode(bytes memory reason) internal pure returns (bytes4 selector, uint256 errorId) {{
        if (reason.length >= 4) {{
            assembly {{ selector := mload(add(reason, 32)) }}
        }}
        if (reason.length >= 36) {{
            assembly {{ errorId := mload(add(reason, 36)) }}
        }}
    }}

    function _searchDirection(
        PoolConfig memory p,
        RoundTripExecutor executor,
        bool forward0to1
    ) internal returns (Best memory best) {{
        uint256 minimum = forward0to1
            ? _minimumRaw(p.t1Num, p.t1Den)
            : _minimumRaw(p.t0Num, p.t0Den);
        uint256 baseSnapshot = vm.snapshot();

        for (uint256 i; i < 74; ++i) {{
            uint256 amountOut = _candidate(minimum, i);
            uint256 gasBefore = gasleft();
            try executor.oneRound(forward0to1, amountOut) returns (
                uint256 forwardInput,
                uint256 reverseInput,
                int256 delta0,
                int256 delta1
            ) {{
                ++best.successfulCalls;
                int256 inputDelta = forward0to1 ? delta0 : delta1;
                int256 profit = forward0to1 ? delta1 : delta0;
                if (inputDelta == 0 && profit > best.profit) {{
                    best.found = profit > 0;
                    best.amountOut = amountOut;
                    best.forwardInput = forwardInput;
                    best.reverseInput = reverseInput;
                    best.inputDelta = inputDelta;
                    best.profit = profit;
                    best.gasUsed = gasBefore - gasleft();
                }}
            }} catch {{}}
            require(vm.revertTo(baseSnapshot), "CANDIDATE_RESTORE_FAILED");
            baseSnapshot = vm.snapshot();
        }}
    }}

    function _emitBest(
        PoolConfig memory p,
        RoundTripExecutor executor,
        bool forward0to1,
        Best memory best
    ) internal {{
        if (!best.found) {{
            emit PoolNoClosedProfit(
                p.dexId, p.pool, forward0to1, p.feeRaw, best.successfulCalls
            );
            return;
        }}

        uint256 snapshot = vm.snapshot();
        address profitToken = forward0to1 ? p.token1 : p.token0;
        uint256 liquidityBefore = IERC20RoundTrip(profitToken).balanceOf(p.liquidity);
        uint256 gasBefore = gasleft();
        uint256 forwardInput;
        uint256 reverseInput;
        int256 delta0;
        int256 delta1;
        bool reproduced;

        try executor.oneRound(forward0to1, best.amountOut) returns (
            uint256 f,
            uint256 r,
            int256 d0,
            int256 d1
        ) {{
            forwardInput = f;
            reverseInput = r;
            delta0 = d0;
            delta1 = d1;
            reproduced = true;
        }} catch {{}}

        uint256 gasUsed = gasBefore - gasleft();
        uint256 liquidityAfter = IERC20RoundTrip(profitToken).balanceOf(p.liquidity);
        uint256 liquidityLoss = liquidityBefore > liquidityAfter
            ? liquidityBefore - liquidityAfter
            : 0;
        require(vm.revertTo(snapshot), "PROOF_RESTORE_FAILED");

        if (!reproduced) {{
            emit PoolNoClosedProfit(
                p.dexId, p.pool, forward0to1, p.feeRaw, best.successfulCalls
            );
            return;
        }}

        int256 inputDelta = forward0to1 ? delta0 : delta1;
        int256 profit = forward0to1 ? delta1 : delta0;
        emit PoolBest(
            p.dexId,
            p.pool,
            profitToken,
            forward0to1,
            p.feeRaw,
            best.amountOut,
            forwardInput,
            reverseInput,
            inputDelta,
            profit,
            liquidityLoss,
            gasUsed,
            best.successfulCalls
        );
    }}

    function scanPool(PoolConfig calldata p)
        external returns (bool profitable0to1, bool profitable1to0)
    {{
        require(msg.sender == address(this), "SELF_ONLY");
        RoundTripExecutor executor = new RoundTripExecutor(p.pool, p.token0, p.token1);
        deal(p.token0, address(executor), _funding(p.dec0));
        deal(p.token1, address(executor), _funding(p.dec1));

        Best memory best0to1 = _searchDirection(p, executor, true);
        Best memory best1to0 = _searchDirection(p, executor, false);
        profitable0to1 = best0to1.found;
        profitable1to0 = best1to0.found;
        _emitBest(p, executor, true, best0to1);
        _emitBest(p, executor, false, best1to0);
    }}

    function test_allActivePoolsSingleCycleSearch() public {{
        PoolConfig[] memory pools = _pools();
        uint256 setupFailures;
        uint256 profitableDirections;
        uint256 profitablePools;

        for (uint256 i; i < pools.length; ++i) {{
            try this.scanPool(pools[i]) returns (bool p0, bool p1) {{
                if (p0) ++profitableDirections;
                if (p1) ++profitableDirections;
                if (p0 || p1) ++profitablePools;
            }} catch (bytes memory reason) {{
                ++setupFailures;
                (bytes4 selector, uint256 errorId) = _decode(reason);
                emit PoolSetupFailure(pools[i].dexId, pools[i].pool, selector, errorId);
            }}
        }}

        emit NetworkSummary(
            pools.length, setupFailures, profitableDirections, profitablePools
        );
    }}
}}
'''


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--network", required=True)
    parser.add_argument("--rpc", required=True)
    parser.add_argument("--solidity-out", required=True)
    parser.add_argument("--metadata-out", required=True)
    args = parser.parse_args()

    block, pools, skipped = enumerate_pools(args.network, args.rpc)
    pathlib.Path(args.solidity_out).parent.mkdir(parents=True, exist_ok=True)
    pathlib.Path(args.metadata_out).parent.mkdir(parents=True, exist_ok=True)
    pathlib.Path(args.solidity_out).write_text(
        generate_solidity(args.network, block, pools), encoding="utf-8"
    )
    pathlib.Path(args.metadata_out).write_text(
        json.dumps(
            {
                "network": args.network,
                "block": block,
                "included": pools,
                "skipped": skipped,
            },
            indent=2,
            default=str,
        ),
        encoding="utf-8",
    )
    print(
        f"GENERATED network={args.network} block={block} "
        f"included={len(pools)} skipped={len(skipped)}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
