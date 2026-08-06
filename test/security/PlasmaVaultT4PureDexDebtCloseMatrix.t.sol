// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.21;

import {Test} from "forge-std/Test.sol";

interface IERC20Matrix {
    function balanceOf(address account) external view returns (uint256);
}

interface IFactoryMatrix {
    function owner() external view returns (address);
    function ownerOf(uint256 nftId) external view returns (address);
}

interface IVaultMatrix {
    function operatePerfect(
        uint256 nftId,
        int256 perfectColShares,
        int256 colToken0MinMax,
        int256 colToken1MinMax,
        int256 perfectDebtShares,
        int256 debtToken0MinMax,
        int256 debtToken1MinMax,
        address to
    ) external payable returns (uint256, int256[] memory);

    function readFromStorage(bytes32 slot) external view returns (uint256);
}

interface IDexMatrix {
    function swapOut(bool swap0to1, uint256 amountOut, uint256 amountInMax, address to)
        external
        payable
        returns (uint256 amountIn);

    function readFromStorage(bytes32 slot) external view returns (uint256);
}

contract PlasmaVaultT4PureDexDebtCloseMatrixTest is Test {
    address internal constant FACTORY = 0x324c5Dc1fC42c7a4D43d92df1eBA58a54d13Bf2d;
    address internal constant VAULT = 0x6E0cDB09eb33cD3894C905E0DFF9289b95a86FFF;
    address internal constant RESOLVER = 0xA5C3E16523eeeDDcC34706b0E6bE88b4c6EA95cC;
    address internal constant DEX = 0x080574D224E960c272e005aA03EFbe793f317640;
    address internal constant LIQUIDITY = 0x52Aa899454998Be5b000Ad077a46Bbe360F4e497;
    address internal constant GHO = 0xb77E872A68C62CfC0dFb02C067Ecc3DA23B4bbf3;
    address internal constant USDT0 = 0xB8CE59FC3717ada4C02eaDF9682A9e934F625ebb;

    uint256 internal constant POSITION_DATA_SLOT = 3;
    uint256 internal constant GHO_FUNDING = 1e30;
    uint256 internal constant USDT0_FUNDING = 1e18;
    uint256 internal constant PPT = 1e12;
    uint256 internal constant PPM = 1e6;

    string internal rpcUrl;
    uint256 internal forkBlock;
    address internal swapper;

    struct Position {
        address owner;
        uint256 quotedShares;
    }

    struct CloseResult {
        uint256 spentGho;
        uint256 spentUsdt0;
        uint256 burnedShares;
        uint256 positionDataAfter;
    }

    struct PerturbResult {
        bool swap0to1;
        uint256 nominalOutput1e18;
        uint256 nominalRawOutput;
        uint256 actualRawOutput;
        uint256 rawInput;
        int256 actorDeltaGho;
        int256 actorDeltaUsdt0;
        int256 liquidityDeltaGho;
        int256 liquidityDeltaUsdt0;
        uint256 slot2Before;
        uint256 slot2After;
        uint256 slot4Before;
        uint256 slot4After;
        int256 nominalCost1e18;
    }

    struct InteractionResult {
        int256 deltaGho;
        int256 deltaUsdt0;
        int256 nominal1e18;
        int256 netPptOfBaseline;
        int256 ghoPptOfBaselineGho;
        int256 usdt0PptOfBaselineUsdt0;
        int256 perBurnedShare1e18;
        int256 savingVsPerturbPpm;
        int256 residualGho;
        int256 residualUsdt0;
    }

    event MatrixSurface(
        uint256 forkBlock,
        address indexed vault,
        address indexed dex,
        address liquidity,
        address gho,
        address usdt0
    );

    event MatrixBaseline(
        uint256 indexed nftId,
        address indexed owner,
        uint256 quotedShares,
        uint256 burnedShares,
        int256 quoteDrift,
        uint256 spentGho,
        uint256 spentUsdt0,
        uint256 nominalCloseCost1e18,
        uint256 positionDataAfter
    );

    event MatrixPerturb(
        bool indexed swap0to1,
        uint256 nominalOutput1e18,
        uint256 nominalRawOutput,
        uint256 actualRawOutput,
        uint256 outputRoundingLoss,
        uint256 rawInput,
        int256 actorDeltaGho,
        int256 actorDeltaUsdt0,
        int256 liquidityDeltaGho,
        int256 liquidityDeltaUsdt0,
        int256 nominalCost1e18,
        uint256 slot2Before,
        uint256 slot2After,
        uint256 slot4Before,
        uint256 slot4After
    );

    event MatrixInteraction(
        uint256 indexed nftId,
        bool indexed swap0to1,
        uint256 nominalOutput1e18,
        uint256 baselineBurnedShares,
        uint256 perturbedBurnedShares,
        int256 burnedShareDelta,
        uint256 baselineSpentGho,
        uint256 baselineSpentUsdt0,
        uint256 perturbedSpentGho,
        uint256 perturbedSpentUsdt0,
        int256 interactionGho,
        int256 interactionUsdt0,
        int256 interactionNominal1e18,
        int256 netPptOfBaseline,
        int256 ghoPptOfBaselineGho,
        int256 usdt0PptOfBaselineUsdt0,
        int256 interactionPerBurnedShare1e18,
        int256 savingVsPerturbPpm,
        int256 threeControlResidualGho,
        int256 threeControlResidualUsdt0
    );

    event MatrixScaleCheck(
        uint256 indexed nftId,
        bool indexed swap0to1,
        uint256 smallNominalOutput1e18,
        uint256 largeNominalOutput1e18,
        int256 smallInteractionNominal1e18,
        int256 largeInteractionNominal1e18,
        int256 expectedLargeAtLinearScale1e18,
        int256 scaleResidual1e18,
        int256 scaleResidualPptOfLargeBaseline
    );

    event MatrixPositionComparison(
        uint256 indexed referenceNftId,
        uint256 indexed comparedNftId,
        bool indexed swap0to1,
        uint256 nominalOutput1e18,
        int256 referenceNetPpt,
        int256 comparedNetPpt,
        int256 netPptDifference
    );

    function setUp() public {
        rpcUrl = vm.envString("PLASMA_RPC_URL");
        forkBlock = vm.envUint("PLASMA_FORK_BLOCK");
        swapper = makeAddr("matrix-pure-dex-swapper");
        vm.createSelectFork(rpcUrl, forkBlock);

        assertEq(block.chainid, 9745, "wrong chain");
        assertGt(FACTORY.code.length, 0, "factory missing");
        assertGt(VAULT.code.length, 0, "vault missing");
        assertGt(RESOLVER.code.length, 0, "resolver missing");
        assertGt(DEX.code.length, 0, "dex missing");
        assertGt(LIQUIDITY.code.length, 0, "liquidity missing");
        assertGt(GHO.code.length, 0, "GHO missing");
        assertGt(USDT0.code.length, 0, "USDT0 missing");
    }

    function _word(bytes memory data, uint256 index) internal pure returns (uint256 value) {
        require(data.length >= (index + 1) * 32, "word OOB");
        assembly ("memory-safe") {
            value := mload(add(add(data, 0x20), mul(index, 0x20)))
        }
    }

    function _position(uint256 nftId) internal view returns (Position memory p) {
        (bool ok, bytes memory data) = RESOLVER.staticcall(
            abi.encodeWithSignature("positionByNftId(uint256)", nftId)
        );
        require(ok && data.length >= 12 * 32, "resolver failed");
        require(_word(data, 0) == nftId, "resolver NFT mismatch");

        p.owner = address(uint160(_word(data, 1)));
        bool liquidated = _word(data, 2) != 0;
        bool supplyPosition = _word(data, 3) != 0;
        p.quotedShares = _word(data, 10);

        require(p.owner == IFactoryMatrix(FACTORY).ownerOf(nftId), "owner mismatch");
        require(!liquidated && !supplyPosition, "not active debt");
        require(p.quotedShares > 0, "zero debt quote");
    }

    function _approve(address token, address owner, address spender) internal {
        vm.prank(owner);
        (bool ok, bytes memory result) = token.call(
            abi.encodeWithSignature("approve(address,uint256)", spender, type(uint256).max)
        );
        require(ok && (result.length == 0 || abi.decode(result, (bool))), "approve failed");
    }

    function _delta(uint256 afterValue, uint256 beforeValue) internal pure returns (int256) {
        return afterValue >= beforeValue
            ? int256(afterValue - beforeValue)
            : -int256(beforeValue - afterValue);
    }

    function _abs(int256 value) internal pure returns (uint256) {
        return uint256(value >= 0 ? value : -value);
    }

    function _positionData(uint256 nftId) internal returns (uint256 value) {
        vm.prank(IFactoryMatrix(FACTORY).owner());
        value = IVaultMatrix(VAULT).readFromStorage(
            keccak256(abi.encode(nftId, POSITION_DATA_SLOT))
        );
    }

    function _close(uint256 nftId) internal returns (CloseResult memory r) {
        Position memory p = _position(nftId);
        deal(GHO, p.owner, GHO_FUNDING);
        deal(USDT0, p.owner, USDT0_FUNDING);
        _approve(GHO, p.owner, VAULT);
        _approve(USDT0, p.owner, VAULT);

        uint256 ghoBefore = IERC20Matrix(GHO).balanceOf(p.owner);
        uint256 usdt0Before = IERC20Matrix(USDT0).balanceOf(p.owner);

        vm.prank(p.owner);
        (, int256[] memory values) = IVaultMatrix(VAULT).operatePerfect(
            nftId,
            0,
            0,
            0,
            type(int256).min,
            -int256(GHO_FUNDING),
            -int256(USDT0_FUNDING),
            p.owner
        );

        require(values.length == 6, "bad operatePerfect result");
        require(values[3] < 0 && values[4] < 0 && values[5] < 0, "not full payback path");

        r.spentGho = ghoBefore - IERC20Matrix(GHO).balanceOf(p.owner);
        r.spentUsdt0 = usdt0Before - IERC20Matrix(USDT0).balanceOf(p.owner);
        r.burnedShares = uint256(-values[3]);
        r.positionDataAfter = _positionData(nftId);

        assertEq(r.spentGho, uint256(-values[4]), "GHO spend mismatch");
        assertEq(r.spentUsdt0, uint256(-values[5]), "USDT0 spend mismatch");
        assertEq(r.positionDataAfter & 1, 1, "debt remains after max payback");
    }

    function _perturb(bool swap0to1, uint256 nominalOutput1e18)
        internal
        returns (PerturbResult memory r)
    {
        r.swap0to1 = swap0to1;
        r.nominalOutput1e18 = nominalOutput1e18;
        r.nominalRawOutput = swap0to1 ? nominalOutput1e18 / 1e12 : nominalOutput1e18;
        require(r.nominalRawOutput > 0, "zero raw output");

        deal(GHO, swapper, GHO_FUNDING);
        deal(USDT0, swapper, USDT0_FUNDING);
        _approve(GHO, swapper, DEX);
        _approve(USDT0, swapper, DEX);

        uint256 actorGhoBefore = IERC20Matrix(GHO).balanceOf(swapper);
        uint256 actorUsdt0Before = IERC20Matrix(USDT0).balanceOf(swapper);
        uint256 liquidityGhoBefore = IERC20Matrix(GHO).balanceOf(LIQUIDITY);
        uint256 liquidityUsdt0Before = IERC20Matrix(USDT0).balanceOf(LIQUIDITY);
        r.slot2Before = IDexMatrix(DEX).readFromStorage(bytes32(uint256(2)));
        r.slot4Before = IDexMatrix(DEX).readFromStorage(bytes32(uint256(4)));

        vm.prank(swapper);
        r.rawInput = IDexMatrix(DEX).swapOut(
            swap0to1,
            r.nominalRawOutput,
            type(uint256).max,
            swapper
        );

        r.actorDeltaGho = _delta(IERC20Matrix(GHO).balanceOf(swapper), actorGhoBefore);
        r.actorDeltaUsdt0 = _delta(IERC20Matrix(USDT0).balanceOf(swapper), actorUsdt0Before);
        r.liquidityDeltaGho = _delta(
            IERC20Matrix(GHO).balanceOf(LIQUIDITY), liquidityGhoBefore
        );
        r.liquidityDeltaUsdt0 = _delta(
            IERC20Matrix(USDT0).balanceOf(LIQUIDITY), liquidityUsdt0Before
        );
        r.slot2After = IDexMatrix(DEX).readFromStorage(bytes32(uint256(2)));
        r.slot4After = IDexMatrix(DEX).readFromStorage(bytes32(uint256(4)));

        if (swap0to1) {
            require(r.actorDeltaGho < 0 && r.actorDeltaUsdt0 > 0, "wrong GHO->USDT0 deltas");
            assertEq(uint256(-r.actorDeltaGho), r.rawInput, "GHO input mismatch");
            r.actualRawOutput = uint256(r.actorDeltaUsdt0);
        } else {
            require(r.actorDeltaUsdt0 < 0 && r.actorDeltaGho > 0, "wrong USDT0->GHO deltas");
            assertEq(uint256(-r.actorDeltaUsdt0), r.rawInput, "USDT0 input mismatch");
            r.actualRawOutput = uint256(r.actorDeltaGho);
        }

        assertLe(r.actualRawOutput, r.nominalRawOutput, "output above nominal");
        r.nominalCost1e18 = -r.actorDeltaGho - r.actorDeltaUsdt0 * int256(1e12);
    }

    function _assertSamePerturb(PerturbResult memory a, PerturbResult memory b) internal pure {
        require(a.swap0to1 == b.swap0to1, "direction differs");
        require(a.nominalOutput1e18 == b.nominalOutput1e18, "nominal 1e18 output differs");
        require(a.nominalRawOutput == b.nominalRawOutput, "nominal raw output differs");
        require(a.actualRawOutput == b.actualRawOutput, "actual output differs");
        require(a.rawInput == b.rawInput, "raw input differs");
        require(a.actorDeltaGho == b.actorDeltaGho, "actor GHO delta differs");
        require(a.actorDeltaUsdt0 == b.actorDeltaUsdt0, "actor USDT0 delta differs");
        require(a.liquidityDeltaGho == b.liquidityDeltaGho, "liquidity GHO delta differs");
        require(a.liquidityDeltaUsdt0 == b.liquidityDeltaUsdt0, "liquidity USDT0 delta differs");
        require(a.slot2Before == b.slot2Before && a.slot2After == b.slot2After, "slot2 effect differs");
        require(a.slot4Before == b.slot4Before && a.slot4After == b.slot4After, "slot4 effect differs");
        require(a.nominalCost1e18 == b.nominalCost1e18, "perturb cost differs");
    }

    function _interaction(
        CloseResult memory baseline,
        PerturbResult memory perturbOnly,
        PerturbResult memory combinedPerturb,
        CloseResult memory combinedClose
    ) internal pure returns (InteractionResult memory r) {
        _assertSamePerturb(perturbOnly, combinedPerturb);

        r.deltaGho = _delta(combinedClose.spentGho, baseline.spentGho);
        r.deltaUsdt0 = _delta(combinedClose.spentUsdt0, baseline.spentUsdt0);
        r.nominal1e18 = r.deltaGho + r.deltaUsdt0 * int256(1e12);

        uint256 baselineNominal = baseline.spentGho + baseline.spentUsdt0 * 1e12;
        r.netPptOfBaseline = r.nominal1e18 * int256(PPT) / int256(baselineNominal);
        r.ghoPptOfBaselineGho = baseline.spentGho == 0
            ? int256(0)
            : r.deltaGho * int256(PPT) / int256(baseline.spentGho);
        r.usdt0PptOfBaselineUsdt0 = baseline.spentUsdt0 == 0
            ? int256(0)
            : r.deltaUsdt0 * int256(PPT) / int256(baseline.spentUsdt0);
        r.perBurnedShare1e18 = r.nominal1e18 * int256(1e18) / int256(baseline.burnedShares);

        if (r.nominal1e18 < 0 && perturbOnly.nominalCost1e18 > 0) {
            r.savingVsPerturbPpm = int256(_abs(r.nominal1e18)) * int256(PPM)
                / perturbOnly.nominalCost1e18;
        }

        int256 perturbCostGho = -perturbOnly.actorDeltaGho;
        int256 perturbCostUsdt0 = -perturbOnly.actorDeltaUsdt0;
        int256 combinedTotalGho = -combinedPerturb.actorDeltaGho + int256(combinedClose.spentGho);
        int256 combinedTotalUsdt0 = -combinedPerturb.actorDeltaUsdt0 + int256(combinedClose.spentUsdt0);
        r.residualGho = combinedTotalGho - int256(baseline.spentGho) - perturbCostGho;
        r.residualUsdt0 = combinedTotalUsdt0 - int256(baseline.spentUsdt0) - perturbCostUsdt0;

        require(r.residualGho == r.deltaGho, "GHO three-control mismatch");
        require(r.residualUsdt0 == r.deltaUsdt0, "USDT0 three-control mismatch");
    }

    function _freshClose(uint256 nftId) internal returns (Position memory p, CloseResult memory closeResult) {
        vm.createSelectFork(rpcUrl, forkBlock);
        p = _position(nftId);
        closeResult = _close(nftId);
    }

    function _freshPerturb(bool swap0to1, uint256 nominalOutput1e18)
        internal
        returns (PerturbResult memory result)
    {
        vm.createSelectFork(rpcUrl, forkBlock);
        result = _perturb(swap0to1, nominalOutput1e18);
    }

    function _freshCombined(uint256 nftId, bool swap0to1, uint256 nominalOutput1e18)
        internal
        returns (PerturbResult memory perturbResult, CloseResult memory closeResult)
    {
        vm.createSelectFork(rpcUrl, forkBlock);
        perturbResult = _perturb(swap0to1, nominalOutput1e18);
        closeResult = _close(nftId);
    }

    function test_fullPureDexDebtCloseMatrix() public {
        emit MatrixSurface(forkBlock, VAULT, DEX, LIQUIDITY, GHO, USDT0);

        uint256[4] memory targets = [uint256(2770), uint256(2887), uint256(2869), uint256(2725)];
        uint256[2] memory sizes = [uint256(10e18), uint256(100e18)];

        Position[4] memory positions;
        CloseResult[4] memory baselines;
        uint256[4] memory baselineNominals;

        for (uint256 targetIndex; targetIndex < targets.length; ++targetIndex) {
            (positions[targetIndex], baselines[targetIndex]) = _freshClose(targets[targetIndex]);
            baselineNominals[targetIndex] = baselines[targetIndex].spentGho
                + baselines[targetIndex].spentUsdt0 * 1e12;

            emit MatrixBaseline(
                targets[targetIndex],
                positions[targetIndex].owner,
                positions[targetIndex].quotedShares,
                baselines[targetIndex].burnedShares,
                int256(baselines[targetIndex].burnedShares) - int256(positions[targetIndex].quotedShares),
                baselines[targetIndex].spentGho,
                baselines[targetIndex].spentUsdt0,
                baselineNominals[targetIndex],
                baselines[targetIndex].positionDataAfter
            );
        }

        int256[4][2] memory smallInteractions;
        int256[4][2] memory smallNetPpt;

        for (uint256 direction; direction < 2; ++direction) {
            bool swap0to1 = direction == 0;

            for (uint256 sizeIndex; sizeIndex < sizes.length; ++sizeIndex) {
                PerturbResult memory perturbOnly = _freshPerturb(swap0to1, sizes[sizeIndex]);
                emit MatrixPerturb(
                    perturbOnly.swap0to1,
                    perturbOnly.nominalOutput1e18,
                    perturbOnly.nominalRawOutput,
                    perturbOnly.actualRawOutput,
                    perturbOnly.nominalRawOutput - perturbOnly.actualRawOutput,
                    perturbOnly.rawInput,
                    perturbOnly.actorDeltaGho,
                    perturbOnly.actorDeltaUsdt0,
                    perturbOnly.liquidityDeltaGho,
                    perturbOnly.liquidityDeltaUsdt0,
                    perturbOnly.nominalCost1e18,
                    perturbOnly.slot2Before,
                    perturbOnly.slot2After,
                    perturbOnly.slot4Before,
                    perturbOnly.slot4After
                );

                int256[4] memory currentNetPpt;

                for (uint256 targetIndex; targetIndex < targets.length; ++targetIndex) {
                    (PerturbResult memory combinedPerturb, CloseResult memory combinedClose) =
                        _freshCombined(targets[targetIndex], swap0to1, sizes[sizeIndex]);
                    InteractionResult memory interaction = _interaction(
                        baselines[targetIndex], perturbOnly, combinedPerturb, combinedClose
                    );
                    currentNetPpt[targetIndex] = interaction.netPptOfBaseline;

                    emit MatrixInteraction(
                        targets[targetIndex],
                        swap0to1,
                        sizes[sizeIndex],
                        baselines[targetIndex].burnedShares,
                        combinedClose.burnedShares,
                        int256(combinedClose.burnedShares) - int256(baselines[targetIndex].burnedShares),
                        baselines[targetIndex].spentGho,
                        baselines[targetIndex].spentUsdt0,
                        combinedClose.spentGho,
                        combinedClose.spentUsdt0,
                        interaction.deltaGho,
                        interaction.deltaUsdt0,
                        interaction.nominal1e18,
                        interaction.netPptOfBaseline,
                        interaction.ghoPptOfBaselineGho,
                        interaction.usdt0PptOfBaselineUsdt0,
                        interaction.perBurnedShare1e18,
                        interaction.savingVsPerturbPpm,
                        interaction.residualGho,
                        interaction.residualUsdt0
                    );

                    if (sizeIndex == 0) {
                        smallInteractions[direction][targetIndex] = interaction.nominal1e18;
                        smallNetPpt[direction][targetIndex] = interaction.netPptOfBaseline;
                    } else {
                        int256 expectedLinear = smallInteractions[direction][targetIndex] * 10;
                        int256 scaleResidual = interaction.nominal1e18 - expectedLinear;
                        emit MatrixScaleCheck(
                            targets[targetIndex],
                            swap0to1,
                            sizes[0],
                            sizes[1],
                            smallInteractions[direction][targetIndex],
                            interaction.nominal1e18,
                            expectedLinear,
                            scaleResidual,
                            scaleResidual * int256(PPT) / int256(baselineNominals[targetIndex])
                        );
                    }
                }

                for (uint256 targetIndex = 1; targetIndex < targets.length; ++targetIndex) {
                    emit MatrixPositionComparison(
                        targets[0],
                        targets[targetIndex],
                        swap0to1,
                        sizes[sizeIndex],
                        currentNetPpt[0],
                        currentNetPpt[targetIndex],
                        currentNetPpt[targetIndex] - currentNetPpt[0]
                    );
                }
            }
        }
    }
}
