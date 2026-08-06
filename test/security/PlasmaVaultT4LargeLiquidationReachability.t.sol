// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.21;

import {PlasmaVaultT4LiquidationSurfaceProbeTest} from "./PlasmaVaultT4LiquidationSurfaceProbe.t.sol";

interface IFluidLiquidationOracleProbe {
    function getExchangeRateLiquidate() external view returns (uint256);
    function getExchangeRateOperate() external view returns (uint256);
}

contract PlasmaVaultT4LargeLiquidationReachabilityTest is PlasmaVaultT4LiquidationSurfaceProbeTest {
    address internal constant ORACLE = 0x029E6fF2173ff6c9e61787Fa7A3cfF1117D957b6;

    struct LargeCaseResult {
        PerturbResult perturb;
        Simulation simulation;
        uint256 oracleLiquidateBefore;
        uint256 oracleLiquidateAfter;
        uint256 oracleOperateBefore;
        uint256 oracleOperateAfter;
        uint256 vaultVariablesBefore;
        uint256 vaultVariablesAfter;
        uint256 vaultVariables2Before;
        uint256 vaultVariables2After;
        uint256 dexVariablesBefore;
        uint256 dexVariablesAfter;
        uint256 dexVariables2Before;
        uint256 dexVariables2After;
    }

    event LargeReachabilityConfig(
        uint256 forkBlock,
        address indexed vault,
        address indexed dex,
        address oracle,
        int256 topTick,
        uint256 liquidationThreshold,
        uint256 liquidationMaxLimit,
        uint256 liquidationPenalty,
        uint256 oracleLiquidateRate
    );

    event LargeSwapReachability(
        bool indexed swap0to1,
        uint256 nominalOutput1e18,
        bool success,
        bytes4 revertSelector,
        bytes32 revertHash,
        uint256 revertLength
    );

    event LargeSwapFlow(
        bool indexed swap0to1,
        uint256 nominalOutput1e18,
        uint256 nominalRawOutput,
        uint256 actualRawOutput,
        uint256 rawInput,
        int256 actorDeltaGho,
        int256 actorDeltaUsdt0,
        int256 nominalCost1e18
    );

    event LargeOracleMovement(
        bool indexed swap0to1,
        uint256 nominalOutput1e18,
        uint256 liquidateRateBefore,
        uint256 liquidateRateAfter,
        int256 liquidateRateDelta,
        int256 liquidateRateDeltaPpm,
        uint256 operateRateBefore,
        uint256 operateRateAfter,
        int256 operateRateDelta,
        int256 operateRateDeltaPpm
    );

    event LargeLiquidationResult(
        bool indexed swap0to1,
        uint256 nominalOutput1e18,
        bytes4 selector,
        bool expectedResult,
        uint256 colLiquidated,
        uint256 debtLiquidated,
        uint256 errorId,
        bytes32 revertHash
    );

    event LargeStorageMovement(
        bool indexed swap0to1,
        uint256 nominalOutput1e18,
        uint256 vaultVariablesBefore,
        uint256 vaultVariablesAfter,
        uint256 vaultVariables2Before,
        uint256 vaultVariables2After,
        uint256 dexVariablesBefore,
        uint256 dexVariablesAfter,
        uint256 dexVariables2Before,
        uint256 dexVariables2After
    );

    function _vaultSlot(uint256 slot) internal returns (uint256 value) {
        vm.prank(IFactoryMatrixV2(FACTORY).owner());
        value = IVaultMatrixV2(VAULT).readFromStorage(bytes32(slot));
    }

    function _topTick(uint256 vaultVariables_) internal pure returns (int256 tick) {
        uint256 magnitude = (vaultVariables_ >> 3) & ((1 << 19) - 1);
        tick = (vaultVariables_ & 4) == 4 ? int256(magnitude) : -int256(magnitude);
    }

    function executeLargeCase(bool swap0to1, uint256 nominalOutput1e18)
        external
        returns (LargeCaseResult memory result)
    {
        require(msg.sender == address(this), "self only");
        result.oracleLiquidateBefore = IFluidLiquidationOracleProbe(ORACLE).getExchangeRateLiquidate();
        result.oracleOperateBefore = IFluidLiquidationOracleProbe(ORACLE).getExchangeRateOperate();
        result.vaultVariablesBefore = _vaultSlot(0);
        result.vaultVariables2Before = _vaultSlot(1);
        result.dexVariablesBefore = IDexMatrixV2(DEX).readFromStorage(bytes32(uint256(0)));
        result.dexVariables2Before = IDexMatrixV2(DEX).readFromStorage(bytes32(uint256(1)));

        result.perturb = _perturb(swap0to1, nominalOutput1e18);

        result.oracleLiquidateAfter = IFluidLiquidationOracleProbe(ORACLE).getExchangeRateLiquidate();
        result.oracleOperateAfter = IFluidLiquidationOracleProbe(ORACLE).getExchangeRateOperate();
        result.vaultVariablesAfter = _vaultSlot(0);
        result.vaultVariables2After = _vaultSlot(1);
        result.dexVariablesAfter = IDexMatrixV2(DEX).readFromStorage(bytes32(uint256(0)));
        result.dexVariables2After = IDexMatrixV2(DEX).readFromStorage(bytes32(uint256(1)));
        result.simulation = _simulate(false);
    }

    function _emitLargeCase(
        bool swap0to1,
        uint256 size,
        LargeCaseResult memory result
    ) internal {
        emit LargeSwapFlow(
            swap0to1,
            size,
            result.perturb.nominalRawOutput,
            result.perturb.actualRawOutput,
            result.perturb.rawInput,
            result.perturb.actorDeltaGho,
            result.perturb.actorDeltaUsdt0,
            result.perturb.nominalCost1e18
        );

        int256 liquidateDelta = _delta(result.oracleLiquidateAfter, result.oracleLiquidateBefore);
        int256 operateDelta = _delta(result.oracleOperateAfter, result.oracleOperateBefore);
        emit LargeOracleMovement(
            swap0to1,
            size,
            result.oracleLiquidateBefore,
            result.oracleLiquidateAfter,
            liquidateDelta,
            liquidateDelta * int256(1e6) / int256(result.oracleLiquidateBefore),
            result.oracleOperateBefore,
            result.oracleOperateAfter,
            operateDelta,
            operateDelta * int256(1e6) / int256(result.oracleOperateBefore)
        );

        emit LargeLiquidationResult(
            swap0to1,
            size,
            result.simulation.selector,
            result.simulation.expectedResult,
            result.simulation.colLiquidated,
            result.simulation.debtLiquidated,
            result.simulation.errorId,
            result.simulation.revertHash
        );

        emit LargeStorageMovement(
            swap0to1,
            size,
            result.vaultVariablesBefore,
            result.vaultVariablesAfter,
            result.vaultVariables2Before,
            result.vaultVariables2After,
            result.dexVariablesBefore,
            result.dexVariablesAfter,
            result.dexVariables2Before,
            result.dexVariables2After
        );
    }

    function test_largeSwapLiquidationReachability() public {
        vm.createSelectFork(rpcUrl, forkBlock);
        uint256 vaultVariables_ = _vaultSlot(0);
        uint256 vaultVariables2_ = _vaultSlot(1);
        emit LargeReachabilityConfig(
            forkBlock,
            VAULT,
            DEX,
            ORACLE,
            _topTick(vaultVariables_),
            (vaultVariables2_ >> 42) & ((1 << 10) - 1),
            (vaultVariables2_ >> 52) & ((1 << 10) - 1),
            (vaultVariables2_ >> 72) & ((1 << 10) - 1),
            IFluidLiquidationOracleProbe(ORACLE).getExchangeRateLiquidate()
        );

        uint256[4] memory sizes = [
            uint256(100_000e18),
            uint256(500_000e18),
            uint256(1_000_000e18),
            uint256(2_000_000e18)
        ];

        for (uint256 direction; direction < 2; ++direction) {
            bool swap0to1 = direction == 0;
            for (uint256 i; i < sizes.length; ++i) {
                vm.createSelectFork(rpcUrl, forkBlock);
                try this.executeLargeCase(swap0to1, sizes[i]) returns (LargeCaseResult memory result) {
                    emit LargeSwapReachability(
                        swap0to1,
                        sizes[i],
                        true,
                        bytes4(0),
                        bytes32(0),
                        0
                    );
                    _emitLargeCase(swap0to1, sizes[i], result);
                } catch (bytes memory reason) {
                    emit LargeSwapReachability(
                        swap0to1,
                        sizes[i],
                        false,
                        _selector(reason),
                        keccak256(reason),
                        reason.length
                    );
                }
            }
        }
    }
}
