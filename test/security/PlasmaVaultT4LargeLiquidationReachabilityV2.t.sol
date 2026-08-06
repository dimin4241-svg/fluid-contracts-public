// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.21;

import {PlasmaVaultT4LiquidationSurfaceProbeTest} from "./PlasmaVaultT4LiquidationSurfaceProbe.t.sol";

interface IFactoryLargeReachability {
    function owner() external view returns (address);
}

interface IVaultLargeReachability {
    function readFromStorage(bytes32 slot) external view returns (uint256);
}

interface IDexLargeReachability {
    function readFromStorage(bytes32 slot) external view returns (uint256);
}

interface IOracleLargeReachability {
    function getExchangeRateLiquidate() external view returns (uint256);
    function getExchangeRateOperate() external view returns (uint256);
}

contract PlasmaVaultT4LargeLiquidationReachabilityV2Test is PlasmaVaultT4LiquidationSurfaceProbeTest {
    address internal constant ORACLE = 0x029E6fF2173ff6c9e61787Fa7A3cfF1117D957b6;

    event LargeV2Config(
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

    event LargeV2Reachability(
        bool indexed swap0to1,
        uint256 nominalOutput1e18,
        bool success,
        bytes4 revertSelector,
        bytes32 revertHash,
        uint256 revertLength
    );

    event LargeV2Flow(
        bool indexed swap0to1,
        uint256 nominalOutput1e18,
        uint256 nominalRawOutput,
        uint256 actualRawOutput,
        uint256 rawInput,
        int256 actorDeltaGho,
        int256 actorDeltaUsdt0,
        int256 nominalCost1e18
    );

    event LargeV2Oracle(
        bool indexed swap0to1,
        uint256 nominalOutput1e18,
        uint256 liquidateBefore,
        uint256 liquidateAfter,
        int256 liquidateDelta,
        int256 liquidateDeltaPpm,
        uint256 operateBefore,
        uint256 operateAfter,
        int256 operateDelta,
        int256 operateDeltaPpm
    );

    event LargeV2Liquidation(
        bool indexed swap0to1,
        uint256 nominalOutput1e18,
        bytes4 selector,
        bool expectedResult,
        uint256 colLiquidated,
        uint256 debtLiquidated,
        uint256 errorId,
        bytes32 revertHash
    );

    event LargeV2VaultStorage(
        bool indexed swap0to1,
        uint256 nominalOutput1e18,
        uint256 vaultVariablesBefore,
        uint256 vaultVariablesAfter,
        uint256 vaultVariables2Before,
        uint256 vaultVariables2After
    );

    event LargeV2DexStorage(
        bool indexed swap0to1,
        uint256 nominalOutput1e18,
        uint256 dexVariablesBefore,
        uint256 dexVariablesAfter,
        uint256 dexVariables2Before,
        uint256 dexVariables2After
    );

    function _vaultSlotLarge(uint256 slot) internal returns (uint256 value) {
        vm.prank(IFactoryLargeReachability(FACTORY).owner());
        value = IVaultLargeReachability(VAULT).readFromStorage(bytes32(slot));
    }

    function _dexSlotLarge(uint256 slot) internal view returns (uint256 value) {
        value = IDexLargeReachability(DEX).readFromStorage(bytes32(slot));
    }

    function _topTickLarge(uint256 variables) internal pure returns (int256) {
        uint256 magnitude = (variables >> 3) & ((1 << 19) - 1);
        return (variables & 4) == 4 ? int256(magnitude) : -int256(magnitude);
    }

    function executeLargeV2(bool swap0to1, uint256 size) external {
        require(msg.sender == address(this), "self only");

        uint256 liquidateBefore = IOracleLargeReachability(ORACLE).getExchangeRateLiquidate();
        uint256 operateBefore = IOracleLargeReachability(ORACLE).getExchangeRateOperate();
        uint256 vault0Before = _vaultSlotLarge(0);
        uint256 vault1Before = _vaultSlotLarge(1);
        uint256 dex0Before = _dexSlotLarge(0);
        uint256 dex1Before = _dexSlotLarge(1);

        PerturbResult memory perturb = _perturb(swap0to1, size);

        uint256 liquidateAfter = IOracleLargeReachability(ORACLE).getExchangeRateLiquidate();
        uint256 operateAfter = IOracleLargeReachability(ORACLE).getExchangeRateOperate();
        uint256 vault0After = _vaultSlotLarge(0);
        uint256 vault1After = _vaultSlotLarge(1);
        uint256 dex0After = _dexSlotLarge(0);
        uint256 dex1After = _dexSlotLarge(1);
        Simulation memory sim = _simulate(false);

        emit LargeV2Flow(
            swap0to1,
            size,
            perturb.nominalRawOutput,
            perturb.actualRawOutput,
            perturb.rawInput,
            perturb.actorDeltaGho,
            perturb.actorDeltaUsdt0,
            perturb.nominalCost1e18
        );

        int256 liquidateDelta = _delta(liquidateAfter, liquidateBefore);
        int256 operateDelta = _delta(operateAfter, operateBefore);
        emit LargeV2Oracle(
            swap0to1,
            size,
            liquidateBefore,
            liquidateAfter,
            liquidateDelta,
            liquidateDelta * int256(1e6) / int256(liquidateBefore),
            operateBefore,
            operateAfter,
            operateDelta,
            operateDelta * int256(1e6) / int256(operateBefore)
        );

        emit LargeV2Liquidation(
            swap0to1,
            size,
            sim.selector,
            sim.expectedResult,
            sim.colLiquidated,
            sim.debtLiquidated,
            sim.errorId,
            sim.revertHash
        );

        emit LargeV2VaultStorage(
            swap0to1,
            size,
            vault0Before,
            vault0After,
            vault1Before,
            vault1After
        );
        emit LargeV2DexStorage(
            swap0to1,
            size,
            dex0Before,
            dex0After,
            dex1Before,
            dex1After
        );
    }

    function test_largeLiquidationReachabilityV2() public {
        vm.createSelectFork(rpcUrl, forkBlock);
        uint256 vault0 = _vaultSlotLarge(0);
        uint256 vault1 = _vaultSlotLarge(1);
        emit LargeV2Config(
            forkBlock,
            VAULT,
            DEX,
            ORACLE,
            _topTickLarge(vault0),
            (vault1 >> 42) & ((1 << 10) - 1),
            (vault1 >> 52) & ((1 << 10) - 1),
            (vault1 >> 72) & ((1 << 10) - 1),
            IOracleLargeReachability(ORACLE).getExchangeRateLiquidate()
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
                (bool ok, bytes memory reason) = address(this).call(
                    abi.encodeCall(this.executeLargeV2, (swap0to1, sizes[i]))
                );
                emit LargeV2Reachability(
                    swap0to1,
                    sizes[i],
                    ok,
                    ok ? bytes4(0) : _selector(reason),
                    ok ? bytes32(0) : keccak256(reason),
                    ok ? 0 : reason.length
                );
            }
        }
    }
}
