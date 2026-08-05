// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.21;

import {Test} from "forge-std/Test.sol";

interface IERC20ShareProbe {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
}

interface IFluidDexShareProbe {
    function swapOut(bool swap0to1, uint256 amountOut, uint256 amountInMax, address to)
        external payable returns (uint256 amountIn);

    function depositPerfect(
        uint256 shares,
        uint256 maxToken0Deposit,
        uint256 maxToken1Deposit,
        bool estimate
    ) external payable returns (uint256 token0Amt, uint256 token1Amt);

    function withdrawPerfect(
        uint256 shares,
        uint256 minToken0Withdraw,
        uint256 minToken1Withdraw,
        address to
    ) external returns (uint256 token0Amt, uint256 token1Amt);

    function borrowPerfect(
        uint256 shares,
        uint256 minToken0Borrow,
        uint256 minToken1Borrow,
        address to
    ) external returns (uint256 token0Amt, uint256 token1Amt);

    function paybackPerfect(
        uint256 shares,
        uint256 maxToken0Payback,
        uint256 maxToken1Payback,
        bool estimate
    ) external payable returns (uint256 token0Amt, uint256 token1Amt);
}

contract PlasmaShareProbeExecutor {
    address internal constant POOL = 0x080574D224E960c272e005aA03EFbe793f317640;
    address internal constant GHO = 0xb77E872A68C62CfC0dFb02C067Ecc3DA23B4bbf3;
    address internal constant USDT0 = 0xB8CE59FC3717ada4C02eaDF9682A9e934F625ebb;

    constructor() {
        require(IERC20ShareProbe(GHO).approve(POOL, type(uint256).max), "GHO_APPROVE");
        require(IERC20ShareProbe(USDT0).approve(POOL, type(uint256).max), "USDT_APPROVE");
    }

    function cycle(uint256 rounds, uint256 ghoOutEach)
        external returns (uint256 totalUsdtInput, uint256 reverseGhoInput)
    {
        for (uint256 i; i < rounds; ++i) {
            totalUsdtInput += IFluidDexShareProbe(POOL).swapOut(
                false, ghoOutEach, type(uint256).max, address(this)
            );
        }
        reverseGhoInput = IFluidDexShareProbe(POOL).swapOut(
            true, totalUsdtInput, type(uint256).max, address(this)
        );
    }
}

contract PlasmaShareAmplificationProbeTest is Test {
    address internal constant POOL = 0x080574D224E960c272e005aA03EFbe793f317640;
    address internal constant GHO = 0xb77E872A68C62CfC0dFb02C067Ecc3DA23B4bbf3;
    address internal constant USDT0 = 0xB8CE59FC3717ada4C02eaDF9682A9e934F625ebb;
    address internal constant LIVE_HOLDER = 0x8741B106e9738a6971AD07DABCFe95FF66337b51;
    address internal constant ADDRESS_DEAD = 0x000000000000000000000000000000000000dEaD;

    bytes4 internal constant PERFECT_OUTPUT_SELECTOR =
        bytes4(keccak256("FluidDexPerfectLiquidityOutput(uint256,uint256)"));

    uint256 internal constant ROUNDS = 128;
    uint256 internal constant GHO_OUT_EACH = 256_100_000_000_001;
    uint256 internal constant FUNDING = 1_000_000;

    struct Quote {
        bool ok;
        uint256 token0;
        uint256 token1;
    }

    event PerturbationResult(
        uint256 totalUsdtInput,
        uint256 reverseGhoInput,
        uint256 executorUsdtLoss,
        uint256 executorGhoGain
    );

    event CollateralQuoteResult(
        uint256 shares,
        uint256 preDepositValue,
        uint256 preWithdrawValue,
        uint256 postDepositValue,
        uint256 postWithdrawValue,
        int256 depositBeforeWithdrawAfterProfit
    );

    event DebtQuoteResult(
        uint256 shares,
        uint256 preBorrowValue,
        uint256 prePaybackValue,
        uint256 postBorrowValue,
        uint256 postPaybackValue,
        int256 borrowBeforePaybackAfterProfit
    );

    event AmplificationSummary(
        uint256 validCollateralSizes,
        uint256 validDebtSizes,
        int256 maxCollateralCrossStateProfit,
        int256 maxDebtCrossStateProfit
    );

    function setUp() public {
        vm.createSelectFork(vm.envString("PLASMA_RPC_URL"), vm.envUint("PLASMA_FORK_BLOCK"));
        assertEq(block.chainid, 9745, "unexpected chain");
    }

    function _decodePerfect(bytes memory data) internal pure returns (Quote memory q) {
        if (data.length != 68) return q;

        bytes4 selector;
        uint256 token0;
        uint256 token1;
        assembly {
            selector := mload(add(data, 0x20))
            token0 := mload(add(data, 0x24))
            token1 := mload(add(data, 0x44))
        }
        if (selector != PERFECT_OUTPUT_SELECTOR) return q;
        q = Quote({ok: true, token0: token0, token1: token1});
    }

    function _quote(bytes memory payload) internal returns (Quote memory q) {
        (bool success, bytes memory data) = POOL.call(payload);
        if (success) return q;
        return _decodePerfect(data);
    }

    function _depositQuote(uint256 shares) internal returns (Quote memory) {
        return _quote(
            abi.encodeWithSelector(
                IFluidDexShareProbe.depositPerfect.selector,
                shares,
                type(uint256).max,
                type(uint256).max,
                true
            )
        );
    }

    function _withdrawQuote(uint256 shares) internal returns (Quote memory) {
        return _quote(
            abi.encodeWithSelector(
                IFluidDexShareProbe.withdrawPerfect.selector,
                shares,
                0,
                0,
                ADDRESS_DEAD
            )
        );
    }

    function _borrowQuote(uint256 shares) internal returns (Quote memory) {
        return _quote(
            abi.encodeWithSelector(
                IFluidDexShareProbe.borrowPerfect.selector,
                shares,
                0,
                0,
                ADDRESS_DEAD
            )
        );
    }

    function _paybackQuote(uint256 shares) internal returns (Quote memory) {
        return _quote(
            abi.encodeWithSelector(
                IFluidDexShareProbe.paybackPerfect.selector,
                shares,
                type(uint256).max,
                type(uint256).max,
                true
            )
        );
    }

    // GHO has 18 decimals and USDT0 has 6. The pool is a stable pair, so this
    // normalizes both quote legs to 18-decimal parity units for amplification checks.
    function _parityValue(Quote memory q) internal pure returns (uint256) {
        return q.token0 + (q.token1 * 1e12);
    }

    function test_shareQuotes_doNotAmplifyExactOutputDustCycle() public {
        uint256[11] memory shareSizes;
        shareSizes[0] = 1e6;
        shareSizes[1] = 1e9;
        shareSizes[2] = 1e12;
        shareSizes[3] = 1e15;
        shareSizes[4] = 1e18;
        shareSizes[5] = 1e21;
        shareSizes[6] = 1e24;
        shareSizes[7] = 1e27;
        shareSizes[8] = 1e30;
        shareSizes[9] = 1e33;
        shareSizes[10] = 1e36;

        Quote[11] memory preDeposit;
        Quote[11] memory preWithdraw;
        Quote[11] memory preBorrow;
        Quote[11] memory prePayback;

        for (uint256 i; i < shareSizes.length; ++i) {
            preDeposit[i] = _depositQuote(shareSizes[i]);
            preWithdraw[i] = _withdrawQuote(shareSizes[i]);
            preBorrow[i] = _borrowQuote(shareSizes[i]);
            prePayback[i] = _paybackQuote(shareSizes[i]);
        }

        PlasmaShareProbeExecutor executor = new PlasmaShareProbeExecutor();
        vm.prank(LIVE_HOLDER);
        require(IERC20ShareProbe(USDT0).transfer(address(executor), FUNDING), "LIVE_TRANSFER");

        uint256 usdtBefore = IERC20ShareProbe(USDT0).balanceOf(address(executor));
        uint256 ghoBefore = IERC20ShareProbe(GHO).balanceOf(address(executor));
        (uint256 totalUsdtInput, uint256 reverseGhoInput) = executor.cycle(ROUNDS, GHO_OUT_EACH);
        uint256 usdtAfter = IERC20ShareProbe(USDT0).balanceOf(address(executor));
        uint256 ghoAfter = IERC20ShareProbe(GHO).balanceOf(address(executor));

        emit PerturbationResult(
            totalUsdtInput,
            reverseGhoInput,
            usdtBefore - usdtAfter,
            ghoAfter - ghoBefore
        );

        uint256 validCollateral;
        uint256 validDebt;
        int256 maxCollateralCrossStateProfit;
        int256 maxDebtCrossStateProfit;

        for (uint256 i; i < shareSizes.length; ++i) {
            Quote memory postDeposit = _depositQuote(shareSizes[i]);
            Quote memory postWithdraw = _withdrawQuote(shareSizes[i]);
            Quote memory postBorrow = _borrowQuote(shareSizes[i]);
            Quote memory postPayback = _paybackQuote(shareSizes[i]);

            if (
                preDeposit[i].ok && preWithdraw[i].ok &&
                postDeposit.ok && postWithdraw.ok
            ) {
                ++validCollateral;
                uint256 preDepositValue = _parityValue(preDeposit[i]);
                uint256 preWithdrawValue = _parityValue(preWithdraw[i]);
                uint256 postDepositValue = _parityValue(postDeposit);
                uint256 postWithdrawValue = _parityValue(postWithdraw);

                // Same-state mint then redeem remains protocol-favouring.
                assertGe(preDepositValue, preWithdrawValue, "pre collateral inversion");
                assertGe(postDepositValue, postWithdrawValue, "post collateral inversion");

                int256 crossProfit = int256(postWithdrawValue) - int256(preDepositValue);
                if (crossProfit > maxCollateralCrossStateProfit) {
                    maxCollateralCrossStateProfit = crossProfit;
                }
                emit CollateralQuoteResult(
                    shareSizes[i],
                    preDepositValue,
                    preWithdrawValue,
                    postDepositValue,
                    postWithdrawValue,
                    crossProfit
                );
            }

            if (
                preBorrow[i].ok && prePayback[i].ok &&
                postBorrow.ok && postPayback.ok
            ) {
                ++validDebt;
                uint256 preBorrowValue = _parityValue(preBorrow[i]);
                uint256 prePaybackValue = _parityValue(prePayback[i]);
                uint256 postBorrowValue = _parityValue(postBorrow);
                uint256 postPaybackValue = _parityValue(postPayback);

                // Same-state borrow then payback remains protocol-favouring.
                assertGe(prePaybackValue, preBorrowValue, "pre debt inversion");
                assertGe(postPaybackValue, postBorrowValue, "post debt inversion");

                int256 crossProfit = int256(preBorrowValue) - int256(postPaybackValue);
                if (crossProfit > maxDebtCrossStateProfit) {
                    maxDebtCrossStateProfit = crossProfit;
                }
                emit DebtQuoteResult(
                    shareSizes[i],
                    preBorrowValue,
                    prePaybackValue,
                    postBorrowValue,
                    postPaybackValue,
                    crossProfit
                );
            }
        }

        assertGt(validCollateral + validDebt, 0, "no valid share quote size");
        emit AmplificationSummary(
            validCollateral,
            validDebt,
            maxCollateralCrossStateProfit,
            maxDebtCrossStateProfit
        );
    }
}
