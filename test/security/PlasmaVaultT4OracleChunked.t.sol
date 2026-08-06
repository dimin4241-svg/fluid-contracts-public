// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.21;

import {Test} from "forge-std/Test.sol";

interface IERC20Chunked {
    function decimals() external view returns (uint8);
}

interface IFluidDexChunked {
    function swapOut(bool swap0to1, uint256 amountOut, uint256 amountInMax, address to)
        external payable returns (uint256 amountIn);
}

interface IFluidOracleChunked {
    function getExchangeRateLiquidate() external view returns (uint256);
}

interface IFluidVaultChunked {
    function readFromStorage(bytes32 slot) external view returns (uint256);
}

interface IFluidFactoryChunked {
    function owner() external view returns (address);
}

contract PlasmaVaultT4OracleChunkedTest is Test {
    address internal constant FACTORY = 0x324c5Dc1fC42c7a4D43d92df1eBA58a54d13Bf2d;
    address internal constant VAULT = 0x6E0cDB09eb33cD3894C905E0DFF9289b95a86FFF;
    address internal constant ORACLE = 0x029E6fF2173ff6c9e61787Fa7A3cfF1117D957b6;
    address internal constant DEX = 0x080574D224E960c272e005aA03EFbe793f317640;
    address internal constant TOKEN0 = 0xb77E872A68C62CfC0dFb02C067Ecc3DA23B4bbf3;
    address internal constant TOKEN1 = 0xB8CE59FC3717ada4C02eaDF9682A9e934F625ebb;

    uint256 internal constant X19 = (1 << 19) - 1;
    uint256 internal constant X20 = (1 << 20) - 1;

    event ChunkMarket(
        uint256 indexed forkBlock,
        uint256 rateBefore,
        int256 topTick,
        uint256 chunkUnits,
        uint256 requestedChunks
    );

    event ChunkStep(
        bool indexed swap0to1,
        uint256 indexed chunkIndex,
        uint256 amountOut,
        bool success,
        uint256 amountIn,
        uint256 cumulativeOutput,
        uint256 cumulativeInput,
        uint256 rateCurrent,
        int256 rateDrift,
        uint256 absoluteDriftPpm,
        bool crossesOneVaultTick
    );

    event ChunkFinal(
        bool indexed swap0to1,
        uint256 chunkUnits,
        uint256 requestedChunks,
        uint256 successfulChunks,
        uint256 totalOutput,
        uint256 totalForwardInput,
        uint256 totalReverseInput,
        uint256 rateBefore,
        uint256 maximumRate,
        uint256 minimumRate,
        uint256 rateAfter,
        uint256 maximumAbsoluteDriftPpm,
        bool crossedOneVaultTick,
        bool allReverseSwapsSucceeded,
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

    function test_0to1_1m_x10() public { _probe(true, 1_000_000, 10); }
    function test_0to1_500k_x20() public { _probe(true, 500_000, 20); }
    function test_0to1_250k_x32() public { _probe(true, 250_000, 32); }

    function test_1to0_1m_x10() public { _probe(false, 1_000_000, 10); }
    function test_1to0_500k_x20() public { _probe(false, 500_000, 20); }
    function test_1to0_250k_x32() public { _probe(false, 250_000, 32); }

    function _probe(bool swap0to1, uint256 chunkUnits, uint256 requestedChunks) internal {
        require(requestedChunks <= 32, "too many chunks");

        IFluidOracleChunked oracle = IFluidOracleChunked(ORACLE);
        uint256 rateBefore = oracle.getExchangeRateLiquidate();
        int256 topTick = _topTick();
        emit ChunkMarket(block.number, rateBefore, topTick, chunkUnits, requestedChunks);

        address outputToken = swap0to1 ? TOKEN1 : TOKEN0;
        uint256 amountOut = chunkUnits * (10 ** uint256(IERC20Chunked(outputToken).decimals()));

        uint256[32] memory forwardInputs;
        uint256 successfulChunks;
        uint256 totalOutput;
        uint256 totalForwardInput;
        uint256 maximumRate = rateBefore;
        uint256 minimumRate = rateBefore;
        uint256 maximumAbsoluteDriftPpm;
        bool crossedOneTick;
        uint256 gasBefore = gasleft();

        for (uint256 i; i < requestedChunks; ++i) {
            (bool ok, bytes memory data) = DEX.call(
                abi.encodeWithSelector(
                    IFluidDexChunked.swapOut.selector,
                    swap0to1,
                    amountOut,
                    type(uint256).max,
                    address(this)
                )
            );

            uint256 rateCurrent = oracle.getExchangeRateLiquidate();
            int256 drift = int256(rateCurrent) - int256(rateBefore);
            uint256 absoluteDrift = drift >= 0 ? uint256(drift) : uint256(-drift);
            uint256 absoluteDriftPpm = (absoluteDrift * 1_000_000) / rateBefore;
            bool crosses = drift >= 0
                ? rateCurrent * 10_000 >= rateBefore * 10_015
                : rateBefore * 10_000 >= rateCurrent * 10_015;

            if (!ok || data.length < 32) {
                emit ChunkStep(
                    swap0to1,
                    i,
                    amountOut,
                    false,
                    0,
                    totalOutput,
                    totalForwardInput,
                    rateCurrent,
                    drift,
                    absoluteDriftPpm,
                    crosses
                );
                break;
            }

            uint256 amountIn = abi.decode(data, (uint256));
            forwardInputs[i] = amountIn;
            successfulChunks = i + 1;
            totalOutput += amountOut;
            totalForwardInput += amountIn;
            maximumRate = rateCurrent > maximumRate ? rateCurrent : maximumRate;
            minimumRate = rateCurrent < minimumRate ? rateCurrent : minimumRate;
            maximumAbsoluteDriftPpm = absoluteDriftPpm > maximumAbsoluteDriftPpm
                ? absoluteDriftPpm
                : maximumAbsoluteDriftPpm;
            crossedOneTick = crossedOneTick || crosses;

            emit ChunkStep(
                swap0to1,
                i,
                amountOut,
                true,
                amountIn,
                totalOutput,
                totalForwardInput,
                rateCurrent,
                drift,
                absoluteDriftPpm,
                crosses
            );
        }

        uint256 totalReverseInput;
        bool allReverseSucceeded = true;
        for (uint256 i = successfulChunks; i > 0; --i) {
            (bool ok, bytes memory data) = DEX.call(
                abi.encodeWithSelector(
                    IFluidDexChunked.swapOut.selector,
                    !swap0to1,
                    forwardInputs[i - 1],
                    type(uint256).max,
                    address(this)
                )
            );
            if (!ok || data.length < 32) {
                allReverseSucceeded = false;
                break;
            }
            totalReverseInput += abi.decode(data, (uint256));
        }

        uint256 rateAfter = oracle.getExchangeRateLiquidate();
        int256 roundTripNet = allReverseSucceeded
            ? int256(totalOutput) - int256(totalReverseInput)
            : type(int256).min;

        emit ChunkFinal(
            swap0to1,
            chunkUnits,
            requestedChunks,
            successfulChunks,
            totalOutput,
            totalForwardInput,
            totalReverseInput,
            rateBefore,
            maximumRate,
            minimumRate,
            rateAfter,
            maximumAbsoluteDriftPpm,
            crossedOneTick,
            allReverseSucceeded,
            roundTripNet,
            gasBefore - gasleft()
        );
    }

    function _topTick() internal returns (int256 topTick) {
        vm.prank(IFluidFactoryChunked(FACTORY).owner());
        uint256 vaultVariables = IFluidVaultChunked(VAULT).readFromStorage(bytes32(uint256(0)));
        uint256 encodedTopTick = (vaultVariables >> 2) & X20;
        if (encodedTopTick == 0) return type(int256).min;
        if ((encodedTopTick & 1) == 1) return int256((encodedTopTick >> 1) & X19);
        return -int256((encodedTopTick >> 1) & X19);
    }

    function _fundAndApprove(address token) internal {
        uint8 decimals_ = IERC20Chunked(token).decimals();
        deal(token, address(this), 100_000_000 * (10 ** uint256(decimals_)));
        (bool ok, bytes memory data) = token.call(
            abi.encodeWithSignature("approve(address,uint256)", DEX, type(uint256).max)
        );
        require(ok && (data.length == 0 || abi.decode(data, (bool))), "approve failed");
    }
}
