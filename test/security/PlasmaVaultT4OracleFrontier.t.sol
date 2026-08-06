// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.21;

import {Test} from "forge-std/Test.sol";

interface IERC20Frontier {
    function decimals() external view returns (uint8);
}

interface IFluidDexFrontier {
    function swapOut(bool swap0to1, uint256 amountOut, uint256 amountInMax, address to)
        external payable returns (uint256 amountIn);
}

interface IFluidOracleFrontier {
    function getExchangeRateLiquidate() external view returns (uint256);
}

interface IFluidVaultFrontier {
    function readFromStorage(bytes32 slot) external view returns (uint256);
}

interface IFluidFactoryFrontier {
    function owner() external view returns (address);
}

contract PlasmaVaultT4OracleFrontierTest is Test {
    address internal constant FACTORY = 0x324c5Dc1fC42c7a4D43d92df1eBA58a54d13Bf2d;
    address internal constant VAULT = 0x6E0cDB09eb33cD3894C905E0DFF9289b95a86FFF;
    address internal constant ORACLE = 0x029E6fF2173ff6c9e61787Fa7A3cfF1117D957b6;
    address internal constant DEX = 0x080574D224E960c272e005aA03EFbe793f317640;
    address internal constant TOKEN0 = 0xb77E872A68C62CfC0dFb02C067Ecc3DA23B4bbf3;
    address internal constant TOKEN1 = 0xB8CE59FC3717ada4C02eaDF9682A9e934F625ebb;

    uint256 internal constant X19 = (1 << 19) - 1;
    uint256 internal constant X20 = (1 << 20) - 1;
    uint256 internal constant X32 = (1 << 32) - 1;

    event MarketState(
        uint256 indexed forkBlock,
        uint256 liquidationRate,
        int256 topTick,
        uint256 totalPositions
    );

    event FrontierResult(
        bool indexed swap0to1,
        uint256 indexed unitsOut,
        bool firstSwapSuccess,
        bool reverseSwapSuccess,
        uint256 amountOut,
        uint256 firstAmountIn,
        uint256 reverseAmountIn,
        uint256 rateBefore,
        uint256 rateDuring,
        uint256 rateAfter,
        int256 rateDrift,
        uint256 absoluteDriftPpm,
        bool crossesOneVaultTick,
        int256 roundTripNetOutputToken,
        uint256 gasUsed
    );

    function setUp() public {
        vm.createSelectFork(vm.envString("PLASMA_RPC_URL"), vm.envUint("PLASMA_FORK_BLOCK"));
        assertEq(block.chainid, 9745, "unexpected chain");
        assertGt(VAULT.code.length, 0, "vault missing");
        assertGt(ORACLE.code.length, 0, "oracle missing");
        assertGt(DEX.code.length, 0, "dex missing");
        _fundAndApprove(TOKEN0);
        _fundAndApprove(TOKEN1);
    }

    function test_0to1_1m() public { _probe(true, 1_000_000); }
    function test_0to1_5m() public { _probe(true, 5_000_000); }
    function test_0to1_10m() public { _probe(true, 10_000_000); }
    function test_0to1_25m() public { _probe(true, 25_000_000); }
    function test_0to1_50m() public { _probe(true, 50_000_000); }

    function test_1to0_1m() public { _probe(false, 1_000_000); }
    function test_1to0_5m() public { _probe(false, 5_000_000); }
    function test_1to0_10m() public { _probe(false, 10_000_000); }
    function test_1to0_25m() public { _probe(false, 25_000_000); }
    function test_1to0_50m() public { _probe(false, 50_000_000); }

    function _probe(bool swap0to1, uint256 unitsOut) internal {
        IFluidOracleFrontier oracle = IFluidOracleFrontier(ORACLE);
        uint256 rateBefore = oracle.getExchangeRateLiquidate();
        (int256 topTick, uint256 totalPositions) = _marketState();
        emit MarketState(block.number, rateBefore, topTick, totalPositions);

        address outputToken = swap0to1 ? TOKEN1 : TOKEN0;
        uint256 amountOut = unitsOut * (10 ** uint256(IERC20Frontier(outputToken).decimals()));

        uint256 gasBefore = gasleft();
        (bool firstOk, bytes memory firstData) = DEX.call(
            abi.encodeWithSelector(
                IFluidDexFrontier.swapOut.selector,
                swap0to1,
                amountOut,
                type(uint256).max,
                address(this)
            )
        );

        if (!firstOk || firstData.length < 32) {
            emit FrontierResult(
                swap0to1,
                unitsOut,
                false,
                false,
                amountOut,
                0,
                0,
                rateBefore,
                rateBefore,
                rateBefore,
                0,
                0,
                false,
                0,
                gasBefore - gasleft()
            );
            return;
        }

        uint256 firstAmountIn = abi.decode(firstData, (uint256));
        uint256 rateDuring = oracle.getExchangeRateLiquidate();
        int256 drift = int256(rateDuring) - int256(rateBefore);
        uint256 absoluteDrift = drift >= 0 ? uint256(drift) : uint256(-drift);
        uint256 absoluteDriftPpm = (absoluteDrift * 1_000_000) / rateBefore;
        bool crossesOneTick = drift >= 0
            ? rateDuring * 10_000 >= rateBefore * 10_015
            : rateBefore * 10_000 >= rateDuring * 10_015;

        (bool reverseOk, bytes memory reverseData) = DEX.call(
            abi.encodeWithSelector(
                IFluidDexFrontier.swapOut.selector,
                !swap0to1,
                firstAmountIn,
                type(uint256).max,
                address(this)
            )
        );
        uint256 reverseAmountIn = reverseOk && reverseData.length >= 32
            ? abi.decode(reverseData, (uint256))
            : 0;
        uint256 rateAfter = oracle.getExchangeRateLiquidate();
        int256 roundTripNet = reverseOk
            ? int256(amountOut) - int256(reverseAmountIn)
            : type(int256).min;

        emit FrontierResult(
            swap0to1,
            unitsOut,
            true,
            reverseOk,
            amountOut,
            firstAmountIn,
            reverseAmountIn,
            rateBefore,
            rateDuring,
            rateAfter,
            drift,
            absoluteDriftPpm,
            crossesOneTick,
            roundTripNet,
            gasBefore - gasleft()
        );
    }

    function _marketState() internal returns (int256 topTick, uint256 totalPositions) {
        vm.prank(IFluidFactoryFrontier(FACTORY).owner());
        uint256 vaultVariables = IFluidVaultFrontier(VAULT).readFromStorage(bytes32(uint256(0)));
        uint256 encodedTopTick = (vaultVariables >> 2) & X20;
        if (encodedTopTick == 0) {
            topTick = type(int256).min;
        } else if ((encodedTopTick & 1) == 1) {
            topTick = int256((encodedTopTick >> 1) & X19);
        } else {
            topTick = -int256((encodedTopTick >> 1) & X19);
        }
        totalPositions = (vaultVariables >> 210) & X32;
    }

    function _fundAndApprove(address token) internal {
        uint8 decimals_ = IERC20Frontier(token).decimals();
        deal(token, address(this), 100_000_000 * (10 ** uint256(decimals_)));
        (bool ok, bytes memory data) = token.call(
            abi.encodeWithSignature("approve(address,uint256)", DEX, type(uint256).max)
        );
        require(ok && (data.length == 0 || abi.decode(data, (bool))), "approve failed");
    }
}
