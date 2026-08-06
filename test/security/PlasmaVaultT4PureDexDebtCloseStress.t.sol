// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.21;

import {PlasmaVaultT4PureDexDebtCloseMatrixV2Test, IDexMatrixV2} from "./PlasmaVaultT4PureDexDebtCloseMatrixV2.t.sol";

contract PlasmaVaultT4PureDexDebtCloseStressTest is PlasmaVaultT4PureDexDebtCloseMatrixV2Test {
    event StressCoverage(
        uint256 totalBorrowShares,
        uint256 coveredBorrowShares,
        uint256 uncoveredBorrowShares,
        uint256 coveragePpt
    );

    event StressPosition(
        uint256 indexed nftId,
        uint256 nominalOutput1e18,
        int256 interactionNominal1e18,
        int256 netPptOfBaseline,
        int256 recoveryPpmOfPerturbCost
    );

    event StressAggregate(
        uint256 nominalOutput1e18,
        int256 perturbCost1e18,
        int256 aggregateInteraction1e18,
        int256 aggregateRecoveryPpm,
        int256 attackerNetCostAfterDebtRecovery1e18
    );

    event StressProportionality(
        uint256 indexed nftId,
        uint256 nominalOutput1e18,
        int256 actualDeltaGho,
        int256 predictedDeltaGho,
        int256 residualGho,
        int256 actualDeltaUsdt0,
        int256 predictedDeltaUsdt0,
        int256 residualUsdt0
    );

    function _predictSigned(uint256 amount, int256 referenceDelta, uint256 referenceAmount)
        internal
        pure
        returns (int256)
    {
        return int256(amount) * referenceDelta / int256(referenceAmount);
    }

    function test_largePerturbAggregateRecovery() public {
        uint256[4] memory targets = [uint256(2770), uint256(2887), uint256(2869), uint256(2725)];
        uint256[3] memory sizes = [uint256(100e18), uint256(1_000e18), uint256(10_000e18)];
        CloseResult[4] memory baselines;
        uint256 coveredShares;

        for (uint256 i; i < targets.length; ++i) {
            Position memory ignored;
            (ignored, baselines[i]) = _freshClose(targets[i]);
            coveredShares += baselines[i].burnedShares;
        }

        vm.createSelectFork(rpcUrl, forkBlock);
        uint256 slot4 = IDexMatrixV2(DEX).readFromStorage(bytes32(uint256(4)));
        uint256 totalBorrowShares = uint256(uint128(slot4));
        require(totalBorrowShares >= coveredShares, "covered shares exceed DEX total");
        emit StressCoverage(
            totalBorrowShares,
            coveredShares,
            totalBorrowShares - coveredShares,
            coveredShares * 1e12 / totalBorrowShares
        );

        for (uint256 sizeIndex; sizeIndex < sizes.length; ++sizeIndex) {
            PerturbResult memory perturbOnly = _freshPerturb(true, sizes[sizeIndex]);
            require(perturbOnly.nominalCost1e18 > 0, "perturb unexpectedly profitable");

            InteractionResult[4] memory interactions;
            int256 aggregateInteraction;

            for (uint256 i; i < targets.length; ++i) {
                (PerturbResult memory combinedPerturb, CloseResult memory combinedClose) =
                    _freshCombined(targets[i], true, sizes[sizeIndex]);
                interactions[i] = _interaction(
                    baselines[i], perturbOnly, combinedPerturb, combinedClose
                );
                aggregateInteraction += interactions[i].nominal1e18;

                int256 positionRecoveryPpm = interactions[i].nominal1e18 < 0
                    ? _abs(interactions[i].nominal1e18) * PPM / perturbOnly.nominalCost1e18
                    : int256(0);
                emit StressPosition(
                    targets[i],
                    sizes[sizeIndex],
                    interactions[i].nominal1e18,
                    interactions[i].netPpt,
                    positionRecoveryPpm
                );
            }

            int256 aggregateRecoveryPpm = aggregateInteraction < 0
                ? _abs(aggregateInteraction) * PPM / perturbOnly.nominalCost1e18
                : int256(0);
            int256 netCost = perturbOnly.nominalCost1e18 + aggregateInteraction;
            emit StressAggregate(
                sizes[sizeIndex],
                perturbOnly.nominalCost1e18,
                aggregateInteraction,
                aggregateRecoveryPpm,
                netCost
            );

            uint256 referenceIndex = 3;
            for (uint256 i; i < targets.length; ++i) {
                int256 predictedGho = _predictSigned(
                    baselines[i].spentGho,
                    interactions[referenceIndex].deltaGho,
                    baselines[referenceIndex].spentGho
                );
                int256 predictedUsdt0 = _predictSigned(
                    baselines[i].spentUsdt0,
                    interactions[referenceIndex].deltaUsdt0,
                    baselines[referenceIndex].spentUsdt0
                );
                emit StressProportionality(
                    targets[i],
                    sizes[sizeIndex],
                    interactions[i].deltaGho,
                    predictedGho,
                    interactions[i].deltaGho - predictedGho,
                    interactions[i].deltaUsdt0,
                    predictedUsdt0,
                    interactions[i].deltaUsdt0 - predictedUsdt0
                );
            }
        }
    }
}
