// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.21;

import {Test} from "forge-std/Test.sol";

interface IERC20Opt {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
}

interface IDexOpt {
    function swapOut(bool, uint256, uint256, address) external returns (uint256);
}

contract PlasmaOptExecutor {
    IDexOpt immutable pool;
    address immutable gho;
    address immutable usdt;

    constructor(address pool_, address gho_, address usdt_) {
        pool = IDexOpt(pool_);
        gho = gho_;
        usdt = usdt_;
        require(IERC20Opt(gho_).approve(pool_, type(uint256).max), "GHO_APPROVE");
        require(IERC20Opt(usdt_).approve(pool_, type(uint256).max), "USDT_APPROVE");
    }

    function cycle(uint256 rounds, uint256 ghoOutEach)
        external
        returns (uint256 totalUsdtIn, uint256 reverseGhoIn, int256 usdtDelta, int256 ghoDelta)
    {
        uint256 usdtBefore = IERC20Opt(usdt).balanceOf(address(this));
        uint256 ghoBefore = IERC20Opt(gho).balanceOf(address(this));
        for (uint256 i; i < rounds; ++i) {
            totalUsdtIn += pool.swapOut(false, ghoOutEach, type(uint256).max, address(this));
        }
        reverseGhoIn = pool.swapOut(true, totalUsdtIn, type(uint256).max, address(this));
        usdtDelta = int256(IERC20Opt(usdt).balanceOf(address(this))) - int256(usdtBefore);
        ghoDelta = int256(IERC20Opt(gho).balanceOf(address(this))) - int256(ghoBefore);
    }
}

contract PlasmaGhoUsdtMicroSwapOptimizerTest is Test {
    address constant POOL = 0x080574D224E960c272e005aA03EFbe793f317640;
    address constant LIQUIDITY = 0x52Aa899454998Be5b000Ad077a46Bbe360F4e497;
    address constant GHO = 0xb77E872A68C62CfC0dFb02C067Ecc3DA23B4bbf3;
    address constant USDT0 = 0xB8CE59FC3717ada4C02eaDF9682A9e934F625ebb;

    event Candidate(
        uint256 amountOutEach,
        uint256 rounds,
        uint256 totalUsdtIn,
        uint256 reverseGhoIn,
        int256 usdtDelta,
        int256 ghoProfit,
        uint256 liquidityLoss,
        uint256 gasUsed,
        uint256 profitPerMillionGas
    );
    event Best(uint256 amountOutEach, int256 ghoProfit, uint256 gasUsed, uint256 profitPerMillionGas);

    function setUp() public {
        vm.createSelectFork(vm.envString("PLASMA_RPC_URL"));
    }

    function _amount(uint256 i) internal pure returns (uint256) {
        // Probe both sides of decimal-conversion/payment boundaries around the
        // currently strongest 0.000256 GHO exact-output micro-swap.
        uint256[25] memory a = [
            uint256(240000000000001), 244000000000001, 248000000000001,
            250000000000001, 252000000000001, 254000000000001,
            255000000000001, 255500000000001, 255900000000001,
            255990000000001, 255999000000001, 255999900000001,
            256000000000001, 256000100000001, 256001000000001,
            256010000000001, 256100000000001, 256500000000001,
            257000000000001, 258000000000001, 260000000000001,
            264000000000001, 272000000000001, 300000000000001,
            512000000000001
        ];
        return a[i];
    }

    function test_optimizeProfitPerGasAt128Rounds() public {
        uint256 bestAmount;
        int256 bestProfit;
        uint256 bestGas;
        uint256 bestRatio;

        for (uint256 i; i < 25; ++i) {
            uint256 snap = vm.snapshot();
            PlasmaOptExecutor executor = new PlasmaOptExecutor(POOL, GHO, USDT0);
            deal(USDT0, address(executor), 1_000_000_000_000);
            deal(GHO, address(executor), 1e30);
            uint256 liquidityBefore = IERC20Opt(GHO).balanceOf(LIQUIDITY);
            uint256 amount = _amount(i);
            uint256 gasBefore = gasleft();
            try executor.cycle(128, amount) returns (
                uint256 totalIn,
                uint256 reverseIn,
                int256 usdtDelta,
                int256 ghoProfit
            ) {
                uint256 gasUsed = gasBefore - gasleft();
                uint256 liquidityAfter = IERC20Opt(GHO).balanceOf(LIQUIDITY);
                uint256 loss = liquidityBefore > liquidityAfter ? liquidityBefore - liquidityAfter : 0;
                uint256 ratio = ghoProfit > 0 ? uint256(ghoProfit) * 1_000_000 / gasUsed : 0;
                emit Candidate(amount, 128, totalIn, reverseIn, usdtDelta, ghoProfit, loss, gasUsed, ratio);
                if (ratio > bestRatio) {
                    bestRatio = ratio;
                    bestAmount = amount;
                    bestProfit = ghoProfit;
                    bestGas = gasUsed;
                }
            } catch {}
            require(vm.revertTo(snap), "RESTORE");
        }

        emit Best(bestAmount, bestProfit, bestGas, bestRatio);
        assertGt(bestRatio, 0, "no profitable candidate");
    }
}
