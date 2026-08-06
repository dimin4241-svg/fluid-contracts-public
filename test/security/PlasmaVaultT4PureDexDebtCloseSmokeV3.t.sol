// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.21;

import {Test} from "forge-std/Test.sol";

interface IERC20V3 {
    function balanceOf(address account) external view returns (uint256);
}

interface IFactoryV3 {
    function owner() external view returns (address);
    function ownerOf(uint256 nftId) external view returns (address);
}

interface IVaultV3 {
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

interface IDexV3 {
    function swapOut(bool swap0to1, uint256 amountOut, uint256 amountInMax, address to)
        external payable returns (uint256 amountIn);
    function readFromStorage(bytes32 slot) external view returns (uint256);
}

contract PlasmaVaultT4PureDexDebtCloseSmokeV3Test is Test {
    address constant FACTORY = 0x324c5Dc1fC42c7a4D43d92df1eBA58a54d13Bf2d;
    address constant VAULT = 0x6E0cDB09eb33cD3894C905E0DFF9289b95a86FFF;
    address constant RESOLVER = 0xA5C3E16523eeeDDcC34706b0E6bE88b4c6EA95cC;
    address constant DEX = 0x080574D224E960c272e005aA03EFbe793f317640;
    address constant LIQUIDITY = 0x52Aa899454998Be5b000Ad077a46Bbe360F4e497;
    address constant GHO = 0xb77E872A68C62CfC0dFb02C067Ecc3DA23B4bbf3;
    address constant USDT0 = 0xB8CE59FC3717ada4C02eaDF9682A9e934F625ebb;

    uint256 constant NFT = 2770;
    uint256 constant NOMINAL_USDT0_OUT = 100e6;
    uint256 constant POSITION_DATA_SLOT = 3;
    uint256 constant FUND_GHO = 1e30;
    uint256 constant FUND_USDT0 = 1e18;

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
        uint256 nominalUsdt0Out;
        uint256 actualUsdt0Out;
        uint256 ghoIn;
        int256 swapperGhoDelta;
        int256 swapperUsdt0Delta;
        int256 liquidityGhoDelta;
        int256 liquidityUsdt0Delta;
        uint256 slot2Before;
        uint256 slot2After;
        uint256 slot4Before;
        uint256 slot4After;
    }

    event SurfaceV3(uint256 blockNumber, address vault, address dex, address liquidity, address token0, address token1);
    event BaselineV3(
        uint256 indexed nftId,
        uint256 quotedShares,
        uint256 burnedShares,
        int256 quoteDrift,
        uint256 spentGho,
        uint256 spentUsdt0,
        uint256 positionDataAfter
    );
    event PerturbV3(
        uint256 nominalUsdt0Out,
        uint256 actualUsdt0Out,
        uint256 outputRoundingLoss,
        uint256 ghoIn,
        int256 swapperGhoDelta,
        int256 swapperUsdt0Delta,
        int256 liquidityGhoDelta,
        int256 liquidityUsdt0Delta,
        uint256 slot2Before,
        uint256 slot2After,
        uint256 slot4Before,
        uint256 slot4After
    );
    event InteractionV3(
        uint256 indexed nftId,
        uint256 burnedShares,
        uint256 baselineSpentGho,
        uint256 baselineSpentUsdt0,
        uint256 perturbedSpentGho,
        uint256 perturbedSpentUsdt0,
        int256 interactionGho,
        int256 interactionUsdt0,
        int256 interactionNominal1e18,
        int256 interactionPpm,
        int256 interactionPerBurnedShare1e18,
        int256 threeControlResidualGho,
        int256 threeControlResidualUsdt0
    );

    function setUp() public {
        rpcUrl = vm.envString("PLASMA_RPC_URL");
        forkBlock = vm.envUint("PLASMA_FORK_BLOCK");
        swapper = makeAddr("v3-swapper");
        vm.createSelectFork(rpcUrl, forkBlock);
        assertEq(block.chainid, 9745, "wrong chain");
        assertGt(VAULT.code.length, 0, "vault missing");
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
        (bool ok, bytes memory data) = RESOLVER.staticcall(abi.encodeWithSignature("positionByNftId(uint256)", nftId));
        require(ok && data.length >= 12 * 32, "resolver failed");
        require(_word(data, 0) == nftId, "nft mismatch");
        p.owner = address(uint160(_word(data, 1)));
        require(p.owner == IFactoryV3(FACTORY).ownerOf(nftId), "owner mismatch");
        require(_word(data, 2) == 0 && _word(data, 3) == 0, "not active debt");
        p.quotedShares = _word(data, 10);
        require(p.quotedShares > 0, "zero debt quote");
    }

    function _approve(address token, address owner, address spender) internal {
        vm.prank(owner);
        (bool ok, bytes memory result) = token.call(abi.encodeWithSignature("approve(address,uint256)", spender, type(uint256).max));
        require(ok && (result.length == 0 || abi.decode(result, (bool))), "approve failed");
    }

    function _delta(uint256 afterValue, uint256 beforeValue) internal pure returns (int256) {
        return afterValue >= beforeValue ? int256(afterValue - beforeValue) : -int256(beforeValue - afterValue);
    }

    function _positionData(uint256 nftId) internal returns (uint256 value) {
        vm.prank(IFactoryV3(FACTORY).owner());
        value = IVaultV3(VAULT).readFromStorage(keccak256(abi.encode(nftId, POSITION_DATA_SLOT)));
    }

    function _close(uint256 nftId) internal returns (CloseResult memory r) {
        Position memory p = _position(nftId);
        deal(GHO, p.owner, FUND_GHO);
        deal(USDT0, p.owner, FUND_USDT0);
        _approve(GHO, p.owner, VAULT);
        _approve(USDT0, p.owner, VAULT);

        uint256 ghoBefore = IERC20V3(GHO).balanceOf(p.owner);
        uint256 usdt0Before = IERC20V3(USDT0).balanceOf(p.owner);
        vm.prank(p.owner);
        (, int256[] memory values) = IVaultV3(VAULT).operatePerfect(
            nftId, 0, 0, 0, type(int256).min, -int256(FUND_GHO), -int256(FUND_USDT0), p.owner
        );
        require(values.length == 6 && values[3] < 0 && values[4] < 0 && values[5] < 0, "bad payback result");

        r.spentGho = ghoBefore - IERC20V3(GHO).balanceOf(p.owner);
        r.spentUsdt0 = usdt0Before - IERC20V3(USDT0).balanceOf(p.owner);
        r.burnedShares = uint256(-values[3]);
        r.positionDataAfter = _positionData(nftId);
        assertEq(r.spentGho, uint256(-values[4]), "GHO spend mismatch");
        assertEq(r.spentUsdt0, uint256(-values[5]), "USDT0 spend mismatch");
        assertEq(r.positionDataAfter & 1, 1, "debt remains");
    }

    function _perturb() internal returns (PerturbResult memory r) {
        r.nominalUsdt0Out = NOMINAL_USDT0_OUT;
        deal(GHO, swapper, FUND_GHO);
        deal(USDT0, swapper, FUND_USDT0);
        _approve(GHO, swapper, DEX);
        _approve(USDT0, swapper, DEX);

        uint256 swapperGhoBefore = IERC20V3(GHO).balanceOf(swapper);
        uint256 swapperUsdt0Before = IERC20V3(USDT0).balanceOf(swapper);
        uint256 liquidityGhoBefore = IERC20V3(GHO).balanceOf(LIQUIDITY);
        uint256 liquidityUsdt0Before = IERC20V3(USDT0).balanceOf(LIQUIDITY);
        r.slot2Before = IDexV3(DEX).readFromStorage(bytes32(uint256(2)));
        r.slot4Before = IDexV3(DEX).readFromStorage(bytes32(uint256(4)));

        vm.prank(swapper);
        r.ghoIn = IDexV3(DEX).swapOut(true, NOMINAL_USDT0_OUT, type(uint256).max, swapper);

        r.swapperGhoDelta = _delta(IERC20V3(GHO).balanceOf(swapper), swapperGhoBefore);
        r.swapperUsdt0Delta = _delta(IERC20V3(USDT0).balanceOf(swapper), swapperUsdt0Before);
        r.liquidityGhoDelta = _delta(IERC20V3(GHO).balanceOf(LIQUIDITY), liquidityGhoBefore);
        r.liquidityUsdt0Delta = _delta(IERC20V3(USDT0).balanceOf(LIQUIDITY), liquidityUsdt0Before);
        r.slot2After = IDexV3(DEX).readFromStorage(bytes32(uint256(2)));
        r.slot4After = IDexV3(DEX).readFromStorage(bytes32(uint256(4)));

        require(r.swapperUsdt0Delta > 0, "no output received");
        r.actualUsdt0Out = uint256(r.swapperUsdt0Delta);
        assertEq(r.swapperGhoDelta, -int256(r.ghoIn), "GHO input mismatch");
        assertLe(r.actualUsdt0Out, r.nominalUsdt0Out, "output above nominal");
        assertLe(r.nominalUsdt0Out - r.actualUsdt0Out, 1, "unexpected output rounding");
    }

    function _assertSamePerturb(PerturbResult memory a, PerturbResult memory b) internal pure {
        require(a.nominalUsdt0Out == b.nominalUsdt0Out, "nominal differs");
        require(a.actualUsdt0Out == b.actualUsdt0Out, "actual output differs");
        require(a.ghoIn == b.ghoIn, "input differs");
        require(a.swapperGhoDelta == b.swapperGhoDelta, "swapper GHO differs");
        require(a.swapperUsdt0Delta == b.swapperUsdt0Delta, "swapper USDT0 differs");
        require(a.liquidityGhoDelta == b.liquidityGhoDelta, "liquidity GHO differs");
        require(a.liquidityUsdt0Delta == b.liquidityUsdt0Delta, "liquidity USDT0 differs");
        require(a.slot2Before == b.slot2Before && a.slot2After == b.slot2After, "slot2 differs");
        require(a.slot4Before == b.slot4Before && a.slot4After == b.slot4After, "slot4 differs");
    }

    function test_threeIndependentControlsV3() public {
        emit SurfaceV3(forkBlock, VAULT, DEX, LIQUIDITY, GHO, USDT0);

        vm.createSelectFork(rpcUrl, forkBlock);
        Position memory quoted = _position(NFT);
        CloseResult memory baseline = _close(NFT);
        emit BaselineV3(
            NFT,
            quoted.quotedShares,
            baseline.burnedShares,
            int256(baseline.burnedShares) - int256(quoted.quotedShares),
            baseline.spentGho,
            baseline.spentUsdt0,
            baseline.positionDataAfter
        );

        vm.createSelectFork(rpcUrl, forkBlock);
        PerturbResult memory perturbOnly = _perturb();
        emit PerturbV3(
            perturbOnly.nominalUsdt0Out,
            perturbOnly.actualUsdt0Out,
            perturbOnly.nominalUsdt0Out - perturbOnly.actualUsdt0Out,
            perturbOnly.ghoIn,
            perturbOnly.swapperGhoDelta,
            perturbOnly.swapperUsdt0Delta,
            perturbOnly.liquidityGhoDelta,
            perturbOnly.liquidityUsdt0Delta,
            perturbOnly.slot2Before,
            perturbOnly.slot2After,
            perturbOnly.slot4Before,
            perturbOnly.slot4After
        );

        vm.createSelectFork(rpcUrl, forkBlock);
        PerturbResult memory combinedPerturb = _perturb();
        CloseResult memory combinedClose = _close(NFT);
        _assertSamePerturb(perturbOnly, combinedPerturb);

        int256 interactionGho = _delta(combinedClose.spentGho, baseline.spentGho);
        int256 interactionUsdt0 = _delta(combinedClose.spentUsdt0, baseline.spentUsdt0);
        int256 interactionNominal = interactionGho + interactionUsdt0 * 1e12;
        uint256 baselineNominal = baseline.spentGho + baseline.spentUsdt0 * 1e12;
        int256 interactionPpm = interactionNominal * 1_000_000 / int256(baselineNominal);
        int256 interactionPerShare = interactionNominal * 1e18 / int256(baseline.burnedShares);

        int256 perturbCostGho = -perturbOnly.swapperGhoDelta;
        int256 perturbCostUsdt0 = -perturbOnly.swapperUsdt0Delta;
        int256 combinedTotalGho = -combinedPerturb.swapperGhoDelta + int256(combinedClose.spentGho);
        int256 combinedTotalUsdt0 = -combinedPerturb.swapperUsdt0Delta + int256(combinedClose.spentUsdt0);
        int256 residualGho = combinedTotalGho - int256(baseline.spentGho) - perturbCostGho;
        int256 residualUsdt0 = combinedTotalUsdt0 - int256(baseline.spentUsdt0) - perturbCostUsdt0;
        assertEq(residualGho, interactionGho, "GHO three-control mismatch");
        assertEq(residualUsdt0, interactionUsdt0, "USDT0 three-control mismatch");

        emit InteractionV3(
            NFT,
            baseline.burnedShares,
            baseline.spentGho,
            baseline.spentUsdt0,
            combinedClose.spentGho,
            combinedClose.spentUsdt0,
            interactionGho,
            interactionUsdt0,
            interactionNominal,
            interactionPpm,
            interactionPerShare,
            residualGho,
            residualUsdt0
        );
    }
}
