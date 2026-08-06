// SPDX-License-Identifier: MIT
pragma solidity 0.8.21;

import "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/interfaces/IERC20.sol";

interface IProbeOracle {
    function dexOracleData()
        external view
        returns (address dexPool, bool quoteInToken0, address liquidity, uint256 multiplier, uint256 divisor);
    function getExchangeRateOperate() external view returns (uint256);
}

interface IProbeDex {
    struct Implementations { address shift; address admin; address colOperations; address debtOperations; address perfectOperationsAndSwapOut; }
    struct ConstantViews {
        uint256 dexId; address liquidity; address factory; Implementations implementations; address deployerContract;
        address token0; address token1; bytes32 supplyToken0Slot; bytes32 borrowToken0Slot;
        bytes32 supplyToken1Slot; bytes32 borrowToken1Slot; bytes32 exchangePriceToken0Slot;
        bytes32 exchangePriceToken1Slot; uint256 oracleMapping;
    }
    function constantsView() external view returns (ConstantViews memory);
    function deposit(uint256 token0Amt, uint256 token1Amt, uint256 minShares, bool estimate)
        external payable returns (uint256 shares);
    function withdrawPerfect(uint256 shares, uint256 minToken0, uint256 minToken1, address to)
        external returns (uint256 token0Amt, uint256 token1Amt);
}

contract NativeToken0WithdrawOracleProbe is Test {
    address internal constant ORACLE = 0x6B6B9F740A82b00E6bBC3c98FCA9aeF50bcE91EB;
    address internal constant NATIVE = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    IProbeOracle internal oracle = IProbeOracle(ORACLE);
    IProbeDex internal dex;
    address internal token1;
    bool internal recording;
    uint256 internal callbackRate;
    uint256 internal callbackValue;

    function setUp() public {
        vm.createSelectFork("https://ethereum-rpc.publicnode.com", 25_694_849);
        (address dexAddress, , , , ) = oracle.dexOracleData();
        dex = IProbeDex(dexAddress);
        IProbeDex.ConstantViews memory c = dex.constantsView();
        assertEq(c.dexId, 43, "unexpected DEX id");
        assertEq(c.token0, NATIVE, "native must be token0 / first withdrawal");
        token1 = c.token1;
        IERC20(token1).approve(address(dex), type(uint256).max);
    }

    function test_withdrawCallbackRateAcrossDepositSizes() public {
        uint256[5] memory deposits = [uint256(1 ether), 5 ether, 10 ether, 25 ether, 50 ether];
        uint256 successes;
        uint256 bestInflation;

        for (uint256 i; i < deposits.length; ++i) {
            uint256 snapshot = vm.snapshot();
            vm.deal(address(this), deposits[i] * 2);
            deal(token1, address(this), deposits[i] * 2);

            try this.executeDepositWithdraw(deposits[i]) returns (
                uint256 shares,
                uint256 normalRate,
                uint256 rateDuringCallback,
                uint256 finalRate,
                uint256 ethOut,
                uint256 token1Out
            ) {
                ++successes;
                uint256 inflation = rateDuringCallback > normalRate
                    ? ((rateDuringCallback - normalRate) * 1e18) / normalRate
                    : 0;
                if (inflation > bestInflation) bestInflation = inflation;

                emit log_named_uint("deposit each token raw", deposits[i]);
                emit log_named_uint("minted SmartCol shares", shares);
                emit log_named_uint("normal oracle rate", normalRate);
                emit log_named_uint("callback oracle rate", rateDuringCallback);
                emit log_named_uint("final oracle rate", finalRate);
                emit log_named_uint("callback inflation 1e18", inflation);
                emit log_named_uint("ETH withdrawn", ethOut);
                emit log_named_uint("osETH withdrawn", token1Out);
            } catch (bytes memory reason) {
                emit log_named_uint("reverted deposit size", deposits[i]);
                emit log_named_bytes("revert data", reason);
            }
            assertTrue(vm.revertTo(snapshot), "snapshot restore failed");
        }

        assertGt(successes, 0, "no deposit/withdraw size executed");
        emit log_named_uint("best callback inflation 1e18", bestInflation);
    }

    function executeDepositWithdraw(uint256 amountEach)
        external
        returns (
            uint256 shares,
            uint256 normalRate,
            uint256 rateDuringCallback,
            uint256 finalRate,
            uint256 ethOut,
            uint256 token1Out
        )
    {
        require(msg.sender == address(this), "self only");
        shares = dex.deposit{ value: amountEach }(amountEach, amountEach, 0, false);

        // Liquidity withdrawal limits for fresh deposits expand over time; this models an existing LP holder.
        vm.warp(block.timestamp + 2 hours);
        normalRate = oracle.getExchangeRateOperate();

        recording = true;
        callbackRate = 0;
        callbackValue = 0;
        (ethOut, token1Out) = dex.withdrawPerfect((shares * 9) / 10, 0, 0, address(this));
        recording = false;

        rateDuringCallback = callbackRate;
        assertGt(rateDuringCallback, 0, "ETH callback not reached");
        assertEq(callbackValue, ethOut, "callback ETH mismatch");
        finalRate = oracle.getExchangeRateOperate();
    }

    receive() external payable {
        if (recording) {
            callbackRate = oracle.getExchangeRateOperate();
            callbackValue += msg.value;
        }
    }
}
