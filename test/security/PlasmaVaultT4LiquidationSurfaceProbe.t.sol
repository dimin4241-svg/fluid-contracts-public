// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.21;

import {PlasmaVaultT4PureDexDebtCloseMatrixV2Test} from "./PlasmaVaultT4PureDexDebtCloseMatrixV2.t.sol";

contract PlasmaVaultT4LiquidationSurfaceProbeTest is PlasmaVaultT4PureDexDebtCloseMatrixV2Test {
    bytes4 internal constant LIQUIDATE_RESULT_SELECTOR =
        bytes4(keccak256("FluidLiquidateResult(uint256,uint256)"));
    bytes4 internal constant VAULT_ERROR_SELECTOR =
        bytes4(keccak256("FluidVaultError(uint256)"));

    struct Simulation {
        bool expectedResult;
        bytes4 selector;
        uint256 colLiquidated;
        uint256 debtLiquidated;
        uint256 errorId;
        bytes32 revertHash;
        uint256 revertLength;
    }

    event LiquidationProbeSurface(
        uint256 forkBlock,
        address indexed vault,
        address indexed dex,
        bytes4 liquidateResultSelector,
        bytes4 vaultErrorSelector
    );

    event LiquidationSimulation(
        bool indexed perturbed,
        bool indexed swap0to1,
        uint256 nominalOutput1e18,
        bool absorb,
        bytes4 selector,
        bool expectedResult,
        uint256 colLiquidated,
        uint256 debtLiquidated,
        uint256 errorId,
        bytes32 revertHash,
        uint256 revertLength
    );

    event LiquidationPerturbControl(
        bool indexed swap0to1,
        uint256 nominalOutput1e18,
        uint256 nominalRawOutput,
        uint256 actualRawOutput,
        uint256 rawInput,
        int256 actorDeltaGho,
        int256 actorDeltaUsdt0,
        int256 nominalCost1e18,
        int256 liquidityDeltaGho,
        int256 liquidityDeltaUsdt0
    );

    event LiquidationInteraction(
        bool indexed swap0to1,
        uint256 nominalOutput1e18,
        bool absorb,
        int256 colLiquidatedDelta,
        int256 debtLiquidatedDelta,
        int256 debtDeltaPpmOfBaseline,
        int256 colDeltaPpmOfBaseline,
        bool eligibilityChanged,
        bool selectorChanged
    );

    function _selector(bytes memory data) internal pure returns (bytes4 value) {
        if (data.length < 4) return bytes4(0);
        assembly ("memory-safe") {
            value := mload(add(data, 0x20))
        }
    }

    function _wordAfterSelector(bytes memory data, uint256 index)
        internal
        pure
        returns (uint256 value)
    {
        require(data.length >= 4 + ((index + 1) * 32), "short revert data");
        assembly ("memory-safe") {
            value := mload(add(add(data, 0x24), mul(index, 0x20)))
        }
    }

    function _simulate(bool absorb) internal returns (Simulation memory result) {
        (bool ok, bytes memory data) = VAULT.call(
            abi.encodeWithSignature(
                "simulateLiquidate(uint256,bool)",
                type(uint256).max,
                absorb
            )
        );
        require(!ok, "simulateLiquidate unexpectedly succeeded");

        result.selector = _selector(data);
        result.revertHash = keccak256(data);
        result.revertLength = data.length;

        if (result.selector == LIQUIDATE_RESULT_SELECTOR && data.length >= 68) {
            result.expectedResult = true;
            result.colLiquidated = _wordAfterSelector(data, 0);
            result.debtLiquidated = _wordAfterSelector(data, 1);
        } else if (result.selector == VAULT_ERROR_SELECTOR && data.length >= 36) {
            result.errorId = _wordAfterSelector(data, 0);
        }
    }

    function _emitSimulation(
        bool perturbed,
        bool swap0to1,
        uint256 size,
        bool absorb,
        Simulation memory result
    ) internal {
        emit LiquidationSimulation(
            perturbed,
            swap0to1,
            size,
            absorb,
            result.selector,
            result.expectedResult,
            result.colLiquidated,
            result.debtLiquidated,
            result.errorId,
            result.revertHash,
            result.revertLength
        );
    }

    function _emitInteraction(
        bool swap0to1,
        uint256 size,
        bool absorb,
        Simulation memory baseline,
        Simulation memory perturbed
    ) internal {
        int256 colDelta = _delta(perturbed.colLiquidated, baseline.colLiquidated);
        int256 debtDelta = _delta(perturbed.debtLiquidated, baseline.debtLiquidated);
        int256 debtPpm = baseline.debtLiquidated == 0
            ? int256(0)
            : debtDelta * int256(1e6) / int256(baseline.debtLiquidated);
        int256 colPpm = baseline.colLiquidated == 0
            ? int256(0)
            : colDelta * int256(1e6) / int256(baseline.colLiquidated);

        emit LiquidationInteraction(
            swap0to1,
            size,
            absorb,
            colDelta,
            debtDelta,
            debtPpm,
            colPpm,
            baseline.expectedResult != perturbed.expectedResult,
            baseline.selector != perturbed.selector
        );
    }

    function test_liquidationSurfaceUnderPureDexPerturb() public {
        emit LiquidationProbeSurface(
            forkBlock,
            VAULT,
            DEX,
            LIQUIDATE_RESULT_SELECTOR,
            VAULT_ERROR_SELECTOR
        );

        vm.createSelectFork(rpcUrl, forkBlock);
        Simulation memory baselineNormal = _simulate(false);
        _emitSimulation(false, false, 0, false, baselineNormal);

        vm.createSelectFork(rpcUrl, forkBlock);
        Simulation memory baselineAbsorb = _simulate(true);
        _emitSimulation(false, false, 0, true, baselineAbsorb);

        uint256[3] memory sizes = [uint256(100e18), uint256(1_000e18), uint256(10_000e18)];
        for (uint256 direction; direction < 2; ++direction) {
            bool swap0to1 = direction == 0;
            for (uint256 sizeIndex; sizeIndex < sizes.length; ++sizeIndex) {
                vm.createSelectFork(rpcUrl, forkBlock);
                PerturbResult memory perturb = _perturb(swap0to1, sizes[sizeIndex]);
                emit LiquidationPerturbControl(
                    swap0to1,
                    sizes[sizeIndex],
                    perturb.nominalRawOutput,
                    perturb.actualRawOutput,
                    perturb.rawInput,
                    perturb.actorDeltaGho,
                    perturb.actorDeltaUsdt0,
                    perturb.nominalCost1e18,
                    perturb.liquidityDeltaGho,
                    perturb.liquidityDeltaUsdt0
                );
                Simulation memory perturbedNormal = _simulate(false);
                _emitSimulation(true, swap0to1, sizes[sizeIndex], false, perturbedNormal);
                _emitInteraction(
                    swap0to1,
                    sizes[sizeIndex],
                    false,
                    baselineNormal,
                    perturbedNormal
                );

                vm.createSelectFork(rpcUrl, forkBlock);
                _perturb(swap0to1, sizes[sizeIndex]);
                Simulation memory perturbedAbsorb = _simulate(true);
                _emitSimulation(true, swap0to1, sizes[sizeIndex], true, perturbedAbsorb);
                _emitInteraction(
                    swap0to1,
                    sizes[sizeIndex],
                    true,
                    baselineAbsorb,
                    perturbedAbsorb
                );
            }
        }
    }
}
