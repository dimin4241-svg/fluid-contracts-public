// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.21;

import {Test} from "forge-std/Test.sol";

interface IERC20MatrixV2 {
    function balanceOf(address account) external view returns (uint256);
}

interface IFactoryMatrixV2 {
    function owner() external view returns (address);
    function ownerOf(uint256 nftId) external view returns (address);
}

interface IVaultMatrixV2 {
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

interface IDexMatrixV2 {
    function swapOut(bool swap0to1, uint256 amountOut, uint256 amountInMax, address to)
        external payable returns (uint256 amountIn);
    function readFromStorage(bytes32 slot) external view returns (uint256);
}

contract PlasmaVaultT4PureDexDebtCloseMatrixV2Test is Test {
    address constant FACTORY = 0x324c5Dc1fC42c7a4D43d92df1eBA58a54d13Bf2d;
    address constant VAULT = 0x6E0cDB09eb33cD3894C905E0DFF9289b95a86FFF;
    address constant RESOLVER = 0xA5C3E16523eeeDDcC34706b0E6bE88b4c6EA95cC;
    address constant DEX = 0x080574D224E960c272e005aA03EFbe793f317640;
    address constant LIQUIDITY = 0x52Aa899454998Be5b000Ad077a46Bbe360F4e497;
    address constant GHO = 0xb77E872A68C62CfC0dFb02C067Ecc3DA23B4bbf3;
    address constant USDT0 = 0xB8CE59FC3717ada4C02eaDF9682A9e934F625ebb;

    uint256 constant POSITION_DATA_SLOT = 3;
    uint256 constant FUND_GHO = 1e30;
    uint256 constant FUND_USDT0 = 1e18;
    int256 constant PPT = 1e12;
    int256 constant PPM = 1e6;

    string rpcUrl;
    uint256 forkBlock;
    address swapper;

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
        int256 netPpt;
        int256 ghoPpt;
        int256 usdt0Ppt;
        int256 perShare1e18;
        int256 savingVsPerturbPpm;
        int256 residualGho;
        int256 residualUsdt0;
    }

    event MatrixV2Surface(
        uint256 forkBlock,
        address indexed vault,
        address indexed dex,
        address liquidity,
        address gho,
        address usdt0
    );

    event MatrixV2Baseline(
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

    event MatrixV2PerturbFlow(
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
        int256 nominalCost1e18
    );

    event MatrixV2PerturbStorage(
        bool indexed swap0to1,
        uint256 nominalOutput1e18,
        uint256 slot2Before,
        uint256 slot2After,
        uint256 slot4Before,
        uint256 slot4After
    );

    event MatrixV2InteractionAmounts(
        uint256 indexed nftId,
        bool indexed swap0to1,
        uint256 nominalOutput1e18,
        uint256 baselineSpentGho,
        uint256 baselineSpentUsdt0,
        uint256 perturbedSpentGho,
        uint256 perturbedSpentUsdt0,
        int256 interactionGho,
        int256 interactionUsdt0
    );

    event MatrixV2InteractionShares(
        uint256 indexed nftId,
        bool indexed swap0to1,
        uint256 nominalOutput1e18,
        uint256 baselineBurnedShares,
        uint256 perturbedBurnedShares,
        int256 burnedShareDelta
    );

    event MatrixV2InteractionMetrics(
        uint256 indexed nftId,
        bool indexed swap0to1,
        uint256 nominalOutput1e18,
        int256 interactionNominal1e18,
        int256 netPptOfBaseline,
        int256 ghoPptOfBaselineGho,
        int256 usdt0PptOfBaselineUsdt0,
        int256 interactionPerBurnedShare1e18,
        int256 savingVsPerturbPpm
    );

    event MatrixV2Residual(
        uint256 indexed nftId,
        bool indexed swap0to1,
        uint256 nominalOutput1e18,
        int256 residualGho,
        int256 residualUsdt0
    );

    event MatrixV2Scale(
        uint256 indexed nftId,
        bool indexed swap0to1,
        int256 smallInteraction1e18,
        int256 largeInteraction1e18,
        int256 expectedLargeLinear1e18,
        int256 scaleResidual1e18,
        int256 scaleResidualPptOfBaseline
    );

    event MatrixV2PositionComparison(
        uint256 indexed referenceNftId,
        uint256 indexed comparedNftId,
        bool indexed swap0to1,
        uint256 nominalOutput1e18,
        int256 referenceNetPpt,
        int256 comparedNetPpt,
        int256 differencePpt
    );

    function setUp() public {
        rpcUrl = vm.envString("PLASMA_RPC_URL");
        forkBlock = vm.envUint("PLASMA_FORK_BLOCK");
        swapper = makeAddr("matrix-v2-swapper");
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
        require(p.owner == IFactoryMatrixV2(FACTORY).ownerOf(nftId), "owner mismatch");
        require(_word(data, 2) == 0 && _word(data, 3) == 0, "not active debt");
        p.quotedShares = _word(data, 10);
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

    function _abs(int256 value) internal pure returns (int256) {
        return value >= 0 ? value : -value;
    }

    function _positionData(uint256 nftId) internal returns (uint256 value) {
        vm.prank(IFactoryMatrixV2(FACTORY).owner());
        value = IVaultMatrixV2(VAULT).readFromStorage(
            keccak256(abi.encode(nftId, POSITION_DATA_SLOT))
        );
    }

    function _close(uint256 nftId) internal returns (CloseResult memory r) {
        Position memory p = _position(nftId);
        deal(GHO, p.owner, FUND_GHO);
        deal(USDT0, p.owner, FUND_USDT0);
        _approve(GHO, p.owner, VAULT);
        _approve(USDT0, p.owner, VAULT);

        uint256 ghoBefore = IERC20MatrixV2(GHO).balanceOf(p.owner);
        uint256 usdt0Before = IERC20MatrixV2(USDT0).balanceOf(p.owner);
        vm.prank(p.owner);
        (, int256[] memory values) = IVaultMatrixV2(VAULT).operatePerfect(
            nftId,
            0,
            0,
            0,
            type(int256).min,
            -int256(FUND_GHO),
            -int256(FUND_USDT0),
            p.owner
        );
        require(values.length == 6, "bad close result");
        require(values[3] < 0 && values[4] < 0 && values[5] < 0, "not payback path");

        r.spentGho = ghoBefore - IERC20MatrixV2(GHO).balanceOf(p.owner);
        r.spentUsdt0 = usdt0Before - IERC20MatrixV2(USDT0).balanceOf(p.owner);
        r.burnedShares = uint256(-values[3]);
        r.positionDataAfter = _positionData(nftId);
        assertEq(r.spentGho, uint256(-values[4]), "GHO mismatch");
        assertEq(r.spentUsdt0, uint256(-values[5]), "USDT0 mismatch");
        assertEq(r.positionDataAfter & 1, 1, "debt remains");
    }

    function _perturb(bool swap0to1, uint256 nominalOutput1e18)
        internal returns (PerturbResult memory r)
    {
        r.swap0to1 = swap0to1;
        r.nominalOutput1e18 = nominalOutput1e18;
        r.nominalRawOutput = swap0to1 ? nominalOutput1e18 / 1e12 : nominalOutput1e18;
        require(r.nominalRawOutput > 0, "zero output");

        deal(GHO, swapper, FUND_GHO);
        deal(USDT0, swapper, FUND_USDT0);
        _approve(GHO, swapper, DEX);
        _approve(USDT0, swapper, DEX);

        uint256 actorGhoBefore = IERC20MatrixV2(GHO).balanceOf(swapper);
        uint256 actorUsdt0Before = IERC20MatrixV2(USDT0).balanceOf(swapper);
        uint256 liquidityGhoBefore = IERC20MatrixV2(GHO).balanceOf(LIQUIDITY);
        uint256 liquidityUsdt0Before = IERC20MatrixV2(USDT0).balanceOf(LIQUIDITY);
        r.slot2Before = IDexMatrixV2(DEX).readFromStorage(bytes32(uint256(2)));
        r.slot4Before = IDexMatrixV2(DEX).readFromStorage(bytes32(uint256(4)));

        vm.prank(swapper);
        r.rawInput = IDexMatrixV2(DEX).swapOut(
            swap0to1, r.nominalRawOutput, type(uint256).max, swapper
        );

        r.actorDeltaGho = _delta(IERC20MatrixV2(GHO).balanceOf(swapper), actorGhoBefore);
        r.actorDeltaUsdt0 = _delta(IERC20MatrixV2(USDT0).balanceOf(swapper), actorUsdt0Before);
        r.liquidityDeltaGho = _delta(
            IERC20MatrixV2(GHO).balanceOf(LIQUIDITY), liquidityGhoBefore
        );
        r.liquidityDeltaUsdt0 = _delta(
            IERC20MatrixV2(USDT0).balanceOf(LIQUIDITY), liquidityUsdt0Before
        );
        r.slot2After = IDexMatrixV2(DEX).readFromStorage(bytes32(uint256(2)));
        r.slot4After = IDexMatrixV2(DEX).readFromStorage(bytes32(uint256(4)));

        if (swap0to1) {
            require(r.actorDeltaGho < 0 && r.actorDeltaUsdt0 > 0, "wrong 0to1 deltas");
            assertEq(uint256(-r.actorDeltaGho), r.rawInput, "GHO input mismatch");
            r.actualRawOutput = uint256(r.actorDeltaUsdt0);
        } else {
            require(r.actorDeltaUsdt0 < 0 && r.actorDeltaGho > 0, "wrong 1to0 deltas");
            assertEq(uint256(-r.actorDeltaUsdt0), r.rawInput, "USDT0 input mismatch");
            r.actualRawOutput = uint256(r.actorDeltaGho);
        }
        assertLe(r.actualRawOutput, r.nominalRawOutput, "actual above nominal");
        r.nominalCost1e18 = -r.actorDeltaGho - r.actorDeltaUsdt0 * int256(1e12);
    }

    function _samePerturb(PerturbResult memory a, PerturbResult memory b) internal pure {
        require(a.swap0to1 == b.swap0to1, "direction differs");
        require(a.nominalOutput1e18 == b.nominalOutput1e18, "nominal differs");
        require(a.nominalRawOutput == b.nominalRawOutput, "raw nominal differs");
        require(a.actualRawOutput == b.actualRawOutput, "actual differs");
        require(a.rawInput == b.rawInput, "input differs");
        require(a.actorDeltaGho == b.actorDeltaGho, "actor GHO differs");
        require(a.actorDeltaUsdt0 == b.actorDeltaUsdt0, "actor USDT0 differs");
        require(a.liquidityDeltaGho == b.liquidityDeltaGho, "liquidity GHO differs");
        require(a.liquidityDeltaUsdt0 == b.liquidityDeltaUsdt0, "liquidity USDT0 differs");
        require(a.slot2Before == b.slot2Before && a.slot2After == b.slot2After, "slot2 differs");
        require(a.slot4Before == b.slot4Before && a.slot4After == b.slot4After, "slot4 differs");
        require(a.nominalCost1e18 == b.nominalCost1e18, "cost differs");
    }

    function _interaction(
        CloseResult memory baseline,
        PerturbResult memory perturbOnly,
        PerturbResult memory combinedPerturb,
        CloseResult memory combinedClose
    ) internal pure returns (InteractionResult memory r) {
        _samePerturb(perturbOnly, combinedPerturb);
        r.deltaGho = _delta(combinedClose.spentGho, baseline.spentGho);
        r.deltaUsdt0 = _delta(combinedClose.spentUsdt0, baseline.spentUsdt0);
        r.nominal1e18 = r.deltaGho + r.deltaUsdt0 * int256(1e12);

        uint256 baselineNominal = baseline.spentGho + baseline.spentUsdt0 * 1e12;
        r.netPpt = r.nominal1e18 * PPT / int256(baselineNominal);
        r.ghoPpt = baseline.spentGho == 0 ? int256(0) : r.deltaGho * PPT / int256(baseline.spentGho);
        r.usdt0Ppt = baseline.spentUsdt0 == 0 ? int256(0) : r.deltaUsdt0 * PPT / int256(baseline.spentUsdt0);
        r.perShare1e18 = r.nominal1e18 * int256(1e18) / int256(baseline.burnedShares);
        if (r.nominal1e18 < 0 && perturbOnly.nominalCost1e18 > 0) {
            r.savingVsPerturbPpm = _abs(r.nominal1e18) * PPM / perturbOnly.nominalCost1e18;
        }

        int256 perturbCostGho = -perturbOnly.actorDeltaGho;
        int256 perturbCostUsdt0 = -perturbOnly.actorDeltaUsdt0;
        int256 combinedTotalGho = -combinedPerturb.actorDeltaGho + int256(combinedClose.spentGho);
        int256 combinedTotalUsdt0 = -combinedPerturb.actorDeltaUsdt0 + int256(combinedClose.spentUsdt0);
        r.residualGho = combinedTotalGho - int256(baseline.spentGho) - perturbCostGho;
        r.residualUsdt0 = combinedTotalUsdt0 - int256(baseline.spentUsdt0) - perturbCostUsdt0;
        require(r.residualGho == r.deltaGho, "GHO residual mismatch");
        require(r.residualUsdt0 == r.deltaUsdt0, "USDT0 residual mismatch");
    }

    function _emitPerturb(PerturbResult memory p) internal {
        emit MatrixV2PerturbFlow(
            p.swap0to1,
            p.nominalOutput1e18,
            p.nominalRawOutput,
            p.actualRawOutput,
            p.nominalRawOutput - p.actualRawOutput,
            p.rawInput,
            p.actorDeltaGho,
            p.actorDeltaUsdt0,
            p.liquidityDeltaGho,
            p.liquidityDeltaUsdt0,
            p.nominalCost1e18
        );
        emit MatrixV2PerturbStorage(
            p.swap0to1,
            p.nominalOutput1e18,
            p.slot2Before,
            p.slot2After,
            p.slot4Before,
            p.slot4After
        );
    }

    function _emitInteraction(
        uint256 nftId,
        PerturbResult memory perturb,
        CloseResult memory baseline,
        CloseResult memory combined,
        InteractionResult memory interaction
    ) internal {
        emit MatrixV2InteractionAmounts(
            nftId,
            perturb.swap0to1,
            perturb.nominalOutput1e18,
            baseline.spentGho,
            baseline.spentUsdt0,
            combined.spentGho,
            combined.spentUsdt0,
            interaction.deltaGho,
            interaction.deltaUsdt0
        );
        emit MatrixV2InteractionShares(
            nftId,
            perturb.swap0to1,
            perturb.nominalOutput1e18,
            baseline.burnedShares,
            combined.burnedShares,
            int256(combined.burnedShares) - int256(baseline.burnedShares)
        );
        emit MatrixV2InteractionMetrics(
            nftId,
            perturb.swap0to1,
            perturb.nominalOutput1e18,
            interaction.nominal1e18,
            interaction.netPpt,
            interaction.ghoPpt,
            interaction.usdt0Ppt,
            interaction.perShare1e18,
            interaction.savingVsPerturbPpm
        );
        emit MatrixV2Residual(
            nftId,
            perturb.swap0to1,
            perturb.nominalOutput1e18,
            interaction.residualGho,
            interaction.residualUsdt0
        );
    }

    function _freshClose(uint256 nftId) internal returns (Position memory p, CloseResult memory c) {
        vm.createSelectFork(rpcUrl, forkBlock);
        p = _position(nftId);
        c = _close(nftId);
    }

    function _freshPerturb(bool swap0to1, uint256 size)
        internal returns (PerturbResult memory p)
    {
        vm.createSelectFork(rpcUrl, forkBlock);
        p = _perturb(swap0to1, size);
    }

    function _freshCombined(uint256 nftId, bool swap0to1, uint256 size)
        internal returns (PerturbResult memory p, CloseResult memory c)
    {
        vm.createSelectFork(rpcUrl, forkBlock);
        p = _perturb(swap0to1, size);
        c = _close(nftId);
    }

    function _runCase(
        bool swap0to1,
        uint256 size,
        uint256[4] memory targets,
        CloseResult[4] memory baselines
    ) internal returns (int256[4] memory nominalInteractions) {
        PerturbResult memory perturbOnly = _freshPerturb(swap0to1, size);
        _emitPerturb(perturbOnly);
        int256[4] memory netPpts;

        for (uint256 i; i < targets.length; ++i) {
            (PerturbResult memory combinedPerturb, CloseResult memory combinedClose) =
                _freshCombined(targets[i], swap0to1, size);
            InteractionResult memory interaction = _interaction(
                baselines[i], perturbOnly, combinedPerturb, combinedClose
            );
            nominalInteractions[i] = interaction.nominal1e18;
            netPpts[i] = interaction.netPpt;
            _emitInteraction(targets[i], perturbOnly, baselines[i], combinedClose, interaction);
        }

        for (uint256 i = 1; i < targets.length; ++i) {
            emit MatrixV2PositionComparison(
                targets[0],
                targets[i],
                swap0to1,
                size,
                netPpts[0],
                netPpts[i],
                netPpts[i] - netPpts[0]
            );
        }
    }

    function test_fullMatrixV2() public {
        emit MatrixV2Surface(forkBlock, VAULT, DEX, LIQUIDITY, GHO, USDT0);
        uint256[4] memory targets = [uint256(2770), uint256(2887), uint256(2869), uint256(2725)];
        CloseResult[4] memory baselines;
        uint256[4] memory baselineNominals;

        for (uint256 i; i < targets.length; ++i) {
            Position memory p;
            (p, baselines[i]) = _freshClose(targets[i]);
            baselineNominals[i] = baselines[i].spentGho + baselines[i].spentUsdt0 * 1e12;
            emit MatrixV2Baseline(
                targets[i],
                p.owner,
                p.quotedShares,
                baselines[i].burnedShares,
                int256(baselines[i].burnedShares) - int256(p.quotedShares),
                baselines[i].spentGho,
                baselines[i].spentUsdt0,
                baselineNominals[i],
                baselines[i].positionDataAfter
            );
        }

        for (uint256 direction; direction < 2; ++direction) {
            bool swap0to1 = direction == 0;
            int256[4] memory small = _runCase(swap0to1, 10e18, targets, baselines);
            int256[4] memory large = _runCase(swap0to1, 100e18, targets, baselines);

            for (uint256 i; i < targets.length; ++i) {
                int256 expectedLinear = small[i] * 10;
                int256 residual = large[i] - expectedLinear;
                emit MatrixV2Scale(
                    targets[i],
                    swap0to1,
                    small[i],
                    large[i],
                    expectedLinear,
                    residual,
                    residual * PPT / int256(baselineNominals[i])
                );
            }
        }
    }
}
