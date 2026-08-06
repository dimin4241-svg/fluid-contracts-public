// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.21;

import {Test} from "forge-std/Test.sol";
import {TickMath} from "contracts/libraries/tickMath.sol";

interface IHistoricalFactory {
    function owner() external view returns (address);
}

interface IHistoricalVault {
    function readFromStorage(bytes32 slot) external view returns (uint256);
    function updateExchangePrices(uint256 vaultVariables2)
        external
        view
        returns (uint256,uint256,uint256,uint256);
}

interface IHistoricalOracle {
    function getExchangeRateLiquidate() external view returns (uint256);
}

contract PlasmaVaultT4HistoricalLiquidationGapTest is Test {
    address internal constant FACTORY = 0x324c5Dc1fC42c7a4D43d92df1eBA58a54d13Bf2d;
    address internal constant VAULT = 0x6E0cDB09eb33cD3894C905E0DFF9289b95a86FFF;
    address internal constant ORACLE = 0x029E6fF2173ff6c9e61787Fa7A3cfF1117D957b6;
    uint256 internal constant END_BLOCK = 29_082_579;
    uint256 internal constant SAMPLES = 128;
    uint256 internal constant ZERO_RATIO = 1 << 96;
    bytes4 internal constant VAULT_ERROR = bytes4(keccak256("FluidVaultError(uint256)"));
    bytes4 internal constant LIQ_RESULT = bytes4(keccak256("FluidLiquidateResult(uint256,uint256)"));

    string internal rpcUrl;

    event HistoricalDeployment(uint256 firstCodeBlock, uint256 endBlock, uint256 sampleCount);
    event HistoricalSample(
        uint256 indexed blockNumber,
        int256 topTick,
        int256 liquidationTick,
        int256 tickGap,
        uint256 oracleRate,
        uint256 vaultSupplyExPrice,
        uint256 vaultBorrowExPrice,
        uint256 liquidationRatioX96,
        uint256 topRatioX96,
        uint256 requiredAdverseDropPpm,
        bytes4 simulationSelector,
        uint256 simulationErrorId,
        bool liquidatable
    );
    event HistoricalSampleFailure(uint256 indexed blockNumber, bytes4 selector, bytes32 reasonHash, uint256 reasonLength);
    event HistoricalNearest(
        uint256 indexed blockNumber,
        int256 topTick,
        int256 liquidationTick,
        int256 tickGap,
        uint256 requiredAdverseDropPpm,
        uint256 oracleRate,
        bool liquidatable
    );

    function setUp() public {
        rpcUrl = vm.envString("PLASMA_RPC_URL");
    }

    function _selector(bytes memory data) internal pure returns (bytes4 value) {
        if (data.length < 4) return bytes4(0);
        assembly ("memory-safe") { value := mload(add(data, 0x20)) }
    }

    function _errorId(bytes memory data) internal pure returns (uint256 value) {
        if (data.length < 36) return 0;
        assembly ("memory-safe") { value := mload(add(data, 0x24)) }
    }

    function _topTick(uint256 variables) internal pure returns (int256) {
        uint256 magnitude = (variables >> 3) & ((1 << 19) - 1);
        return (variables & 4) == 4 ? int256(magnitude) : -int256(magnitude);
    }

    function _firstCodeBlock() internal returns (uint256) {
        uint256 low = 1;
        uint256 high = END_BLOCK;
        vm.createSelectFork(rpcUrl, high);
        require(VAULT.code.length > 0, "vault absent at end block");
        while (low < high) {
            uint256 mid = (low + high) / 2;
            vm.createSelectFork(rpcUrl, mid);
            if (VAULT.code.length > 0) high = mid;
            else low = mid + 1;
        }
        return low;
    }

    function capture(uint256 blockNumber)
        external
        returns (
            int256 tickGap,
            uint256 requiredDropPpm,
            int256 topTick,
            int256 liquidationTick,
            uint256 oracleRate,
            bool liquidatable
        )
    {
        require(msg.sender == address(this), "self only");
        vm.createSelectFork(rpcUrl, blockNumber);
        require(VAULT.code.length > 0 && ORACLE.code.length > 0, "code absent");

        address factoryOwner = IHistoricalFactory(FACTORY).owner();
        vm.prank(factoryOwner);
        uint256 variables = IHistoricalVault(VAULT).readFromStorage(bytes32(uint256(0)));
        vm.prank(factoryOwner);
        uint256 variables2 = IHistoricalVault(VAULT).readFromStorage(bytes32(uint256(1)));

        (,,uint256 supplyExPrice,uint256 borrowExPrice) =
            IHistoricalVault(VAULT).updateExchangePrices(variables2);
        oracleRate = IHistoricalOracle(ORACLE).getExchangeRateLiquidate();
        uint256 debtPerCol = oracleRate * supplyExPrice / borrowExPrice;
        uint256 rawRatioX96 = debtPerCol * ZERO_RATIO / 1e27;
        uint256 threshold = (variables2 >> 42) & ((1 << 10) - 1);
        uint256 liquidationRatioX96 = rawRatioX96 * threshold / 1000;
        (liquidationTick,) = TickMath.getTickAtRatio(liquidationRatioX96);
        topTick = _topTick(variables);
        tickGap = liquidationTick - topTick;
        uint256 topRatioX96 = TickMath.getRatioAtTick(topTick);
        requiredDropPpm = liquidationRatioX96 > topRatioX96
            ? (liquidationRatioX96 - topRatioX96) * 1e6 / liquidationRatioX96
            : 0;

        (bool ok, bytes memory reason) = VAULT.call(
            abi.encodeWithSignature("simulateLiquidate(uint256,bool)", type(uint256).max, false)
        );
        require(!ok, "simulation unexpectedly succeeded");
        bytes4 selector = _selector(reason);
        uint256 errorId = selector == VAULT_ERROR ? _errorId(reason) : 0;
        liquidatable = selector == LIQ_RESULT && reason.length >= 68;

        emit HistoricalSample(
            blockNumber,
            topTick,
            liquidationTick,
            tickGap,
            oracleRate,
            supplyExPrice,
            borrowExPrice,
            liquidationRatioX96,
            topRatioX96,
            requiredDropPpm,
            selector,
            errorId,
            liquidatable
        );
    }

    function test_scanHistoricalLiquidationGap() public {
        uint256 first = _firstCodeBlock();
        emit HistoricalDeployment(first, END_BLOCK, SAMPLES);
        uint256 span = END_BLOCK - first;

        int256 nearestGap = type(int256).max;
        uint256 nearestRequired = type(uint256).max;
        uint256 nearestBlock;
        int256 nearestTop;
        int256 nearestLiquidation;
        uint256 nearestOracle;
        bool nearestLiquidatable;

        for (uint256 i; i < SAMPLES; ++i) {
            uint256 blockNumber = first + (span * i) / (SAMPLES - 1);
            try this.capture(blockNumber) returns (
                int256 gap,
                uint256 requiredDrop,
                int256 top,
                int256 liquidation,
                uint256 oracleRate,
                bool liquidatable
            ) {
                bool closer = gap < nearestGap || (gap == nearestGap && requiredDrop < nearestRequired);
                if (closer) {
                    nearestGap = gap;
                    nearestRequired = requiredDrop;
                    nearestBlock = blockNumber;
                    nearestTop = top;
                    nearestLiquidation = liquidation;
                    nearestOracle = oracleRate;
                    nearestLiquidatable = liquidatable;
                }
            } catch (bytes memory reason) {
                emit HistoricalSampleFailure(blockNumber, _selector(reason), keccak256(reason), reason.length);
            }
        }

        require(nearestBlock != 0, "no historical samples decoded");
        emit HistoricalNearest(
            nearestBlock,
            nearestTop,
            nearestLiquidation,
            nearestGap,
            nearestRequired,
            nearestOracle,
            nearestLiquidatable
        );
    }
}
