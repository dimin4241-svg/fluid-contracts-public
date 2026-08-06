// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.21;

import {Test} from "forge-std/Test.sol";

interface IERC20V2 {
    function balanceOf(address account) external view returns (uint256);
}

interface IFactoryV2 {
    function owner() external view returns (address);
    function ownerOf(uint256 nftId) external view returns (address);
}

interface IVaultV2 {
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

interface IDexV2 {
    function swapOut(bool swap0to1, uint256 amountOut, uint256 amountInMax, address to)
        external
        payable
        returns (uint256 amountIn);

    function readFromStorage(bytes32 slot) external view returns (uint256);
}

contract PlasmaVaultT4PureDexDebtCloseSmokeV2Test is Test {
    address internal constant FACTORY = 0x324c5Dc1fC42c7a4D43d92df1eBA58a54d13Bf2d;
    address internal constant VAULT = 0x6E0cDB09eb33cD3894C905E0DFF9289b95a86FFF;
    address internal constant RESOLVER = 0xA5C3E16523eeeDDcC34706b0E6bE88b4c6EA95cC;
    address internal constant DEX = 0x080574D224E960c272e005aA03EFbe793f317640;
    address internal constant LIQUIDITY = 0x52Aa899454998Be5b000Ad077a46Bbe360F4e497;
    address internal constant GHO = 0xb77E872A68C62CfC0dFb02C067Ecc3DA23B4bbf3;
    address internal constant USDT0 = 0xB8CE59FC3717ada4C02eaDF9682A9e934F625ebb;

    uint256 internal constant NFT = 2770;
    uint256 internal constant USDT0_OUT = 100e6;
    uint256 internal constant POSITION_DATA_SLOT = 3;
    uint256 internal constant GHO_FUNDING = 1e30;
    uint256 internal constant USDT0_FUNDING = 1e18;

    string internal rpcUrl;
    uint256 internal forkBlock;
    address internal swapper;

    struct Position {
        address owner;
        uint256 borrowShares;
    }

    struct Close {
        uint256 spentGho;
        uint256 spentUsdt0;
        uint256 burnedShares;
        uint256 positionDataAfter;
    }

    struct Perturb {
        uint256 ghoIn;
        int256 swapperDeltaGho;
        int256 swapperDeltaUsdt0;
        int256 liquidityDeltaGho;
        int256 liquidityDeltaUsdt0;
        uint256 slot2Before;
        uint256 slot2After;
        uint256 slot4Before;
        uint256 slot4After;
    }

    event SurfaceV2(
        uint256 forkBlock,
        address indexed vault,
        address indexed dex,
        address liquidity,
        address gho,
        address usdt0,
        uint256 nftId
    );

    event BaselineV2(
        uint256 indexed nftId,
        uint256 borrowShares,
        uint256 spentGho,
        uint256 spentUsdt0,
        uint256 positionDataAfter
    );

    event PerturbV2(
        uint256 usdt0Out,
        uint256 ghoIn,
        int256 swapperDeltaGho,
        int256 swapperDeltaUsdt0,
        int256 liquidityDeltaGho,
        int256 liquidityDeltaUsdt0,
        uint256 slot2Before,
        uint256 slot2After,
        uint256 slot4Before,
        uint256 slot4After
    );

    event InteractionV2(
        uint256 indexed nftId,
        uint256 borrowShares,
        uint256 baselineSpentGho,
        uint256 baselineSpentUsdt0,
        uint256 perturbedSpentGho,
        uint256 perturbedSpentUsdt0,
        int256 interactionGho,
        int256 interactionUsdt0,
        int256 interactionNominal1e18,
        int256 interactionPpm,
        int256 interactionPerBorrowShare1e18,
        int256 threeControlResidualGho,
        int256 threeControlResidualUsdt0
    );

    function setUp() public {
        rpcUrl = vm.envString("PLASMA_RPC_URL");
        forkBlock = vm.envUint("PLASMA_FORK_BLOCK");
        swapper = makeAddr("pure-dex-v2-swapper");
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
        (bool ok, bytes memory data) = RESOLVER.staticcall(
            abi.encodeWithSignature("positionByNftId(uint256)", nftId)
        );
        require(ok && data.length >= 12 * 32, "resolver failed");

        uint256 returnedNft = _word(data, 0);
        p.owner = address(uint160(_word(data, 1)));
        bool liquidated = _word(data, 2) != 0;
        bool supplyPosition = _word(data, 3) != 0;
        p.borrowShares = _word(data, 10);

        require(returnedNft == nftId, "nft mismatch");
        require(p.owner == IFactoryV2(FACTORY).ownerOf(nftId), "owner mismatch");
        require(!liquidated && !supplyPosition, "not active debt");
        require(p.borrowShares > 0, "zero debt shares");
    }

    function _approve(address token, address owner, address spender) internal {
        vm.prank(owner);
        (bool ok, bytes memory data) = token.call(
            abi.encodeWithSignature("approve(address,uint256)", spender, type(uint256).max)
        );
        require(ok && (data.length == 0 || abi.decode(data, (bool))), "approve failed");
    }

    function _change(uint256 afterValue, uint256 beforeValue) internal pure returns (int256) {
        return afterValue >= beforeValue
            ? int256(afterValue - beforeValue)
            : -int256(beforeValue - afterValue);
    }

    function _positionData(uint256 nftId) internal returns (uint256 value) {
        address factoryOwner = IFactoryV2(FACTORY).owner();
        vm.prank(factoryOwner);
        value = IVaultV2(VAULT).readFromStorage(
            keccak256(abi.encode(nftId, POSITION_DATA_SLOT))
        );
    }

    function _close(uint256 nftId) internal returns (Close memory result) {
        Position memory p = _position(nftId);
        deal(GHO, p.owner, GHO_FUNDING);
        deal(USDT0, p.owner, USDT0_FUNDING);
        _approve(GHO, p.owner, VAULT);
        _approve(USDT0, p.owner, VAULT);

        uint256 ghoBefore = IERC20V2(GHO).balanceOf(p.owner);
        uint256 usdt0Before = IERC20V2(USDT0).balanceOf(p.owner);

        vm.prank(p.owner);
        (, int256[] memory values) = IVaultV2(VAULT).operatePerfect(
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
        require(values[3] < 0 && values[4] < 0 && values[5] < 0, "not a payback");

        result.spentGho = ghoBefore - IERC20V2(GHO).balanceOf(p.owner);
        result.spentUsdt0 = usdt0Before - IERC20V2(USDT0).balanceOf(p.owner);
        result.burnedShares = uint256(-values[3]);
        result.positionDataAfter = _positionData(nftId);

        assertEq(result.burnedShares, p.borrowShares, "partial share burn");
        assertEq(result.spentGho, uint256(-values[4]), "GHO spend mismatch");
        assertEq(result.spentUsdt0, uint256(-values[5]), "USDT0 spend mismatch");
        assertEq(result.positionDataAfter & 1, 1, "debt remains");
    }

    function _perturb() internal returns (Perturb memory result) {
        deal(GHO, swapper, GHO_FUNDING);
        deal(USDT0, swapper, USDT0_FUNDING);
        _approve(GHO, swapper, DEX);
        _approve(USDT0, swapper, DEX);

        uint256 swapperGhoBefore = IERC20V2(GHO).balanceOf(swapper);
        uint256 swapperUsdt0Before = IERC20V2(USDT0).balanceOf(swapper);
        uint256 liquidityGhoBefore = IERC20V2(GHO).balanceOf(LIQUIDITY);
        uint256 liquidityUsdt0Before = IERC20V2(USDT0).balanceOf(LIQUIDITY);
        result.slot2Before = IDexV2(DEX).readFromStorage(bytes32(uint256(2)));
        result.slot4Before = IDexV2(DEX).readFromStorage(bytes32(uint256(4)));

        vm.prank(swapper);
        result.ghoIn = IDexV2(DEX).swapOut(true, USDT0_OUT, type(uint256).max, swapper);

        result.swapperDeltaGho = _change(IERC20V2(GHO).balanceOf(swapper), swapperGhoBefore);
        result.swapperDeltaUsdt0 = _change(IERC20V2(USDT0).balanceOf(swapper), swapperUsdt0Before);
        result.liquidityDeltaGho = _change(IERC20V2(GHO).balanceOf(LIQUIDITY), liquidityGhoBefore);
        result.liquidityDeltaUsdt0 = _change(IERC20V2(USDT0).balanceOf(LIQUIDITY), liquidityUsdt0Before);
        result.slot2After = IDexV2(DEX).readFromStorage(bytes32(uint256(2)));
        result.slot4After = IDexV2(DEX).readFromStorage(bytes32(uint256(4)));

        assertEq(result.swapperDeltaGho, -int256(result.ghoIn), "swapper GHO delta mismatch");
        assertEq(result.swapperDeltaUsdt0, int256(USDT0_OUT), "swapper USDT0 delta mismatch");
    }

    function _assertSamePerturb(Perturb memory a, Perturb memory b) internal pure {
        require(a.ghoIn == b.ghoIn, "different swap input");
        require(a.swapperDeltaGho == b.swapperDeltaGho, "different swapper GHO delta");
        require(a.swapperDeltaUsdt0 == b.swapperDeltaUsdt0, "different swapper USDT0 delta");
        require(a.liquidityDeltaGho == b.liquidityDeltaGho, "different liquidity GHO delta");
        require(a.liquidityDeltaUsdt0 == b.liquidityDeltaUsdt0, "different liquidity USDT0 delta");
        require(a.slot2Before == b.slot2Before && a.slot2After == b.slot2After, "different slot2 effect");
        require(a.slot4Before == b.slot4Before && a.slot4After == b.slot4After, "different slot4 effect");
    }

    function test_threeIndependentControlsV2() public {
        emit SurfaceV2(forkBlock, VAULT, DEX, LIQUIDITY, GHO, USDT0, NFT);

        vm.createSelectFork(rpcUrl, forkBlock);
        Position memory initial = _position(NFT);
        Close memory baseline = _close(NFT);
        emit BaselineV2(
            NFT,
            initial.borrowShares,
            baseline.spentGho,
            baseline.spentUsdt0,
            baseline.positionDataAfter
        );

        vm.createSelectFork(rpcUrl, forkBlock);
        Perturb memory perturbOnly = _perturb();
        emit PerturbV2(
            USDT0_OUT,
            perturbOnly.ghoIn,
            perturbOnly.swapperDeltaGho,
            perturbOnly.swapperDeltaUsdt0,
            perturbOnly.liquidityDeltaGho,
            perturbOnly.liquidityDeltaUsdt0,
            perturbOnly.slot2Before,
            perturbOnly.slot2After,
            perturbOnly.slot4Before,
            perturbOnly.slot4After
        );

        vm.createSelectFork(rpcUrl, forkBlock);
        Perturb memory combinedPerturb = _perturb();
        Close memory perturbedClose = _close(NFT);
        _assertSamePerturb(perturbOnly, combinedPerturb);
        assertEq(perturbedClose.burnedShares, initial.borrowShares, "combined close not full");

        int256 interactionGho = _change(perturbedClose.spentGho, baseline.spentGho);
        int256 interactionUsdt0 = _change(perturbedClose.spentUsdt0, baseline.spentUsdt0);
        int256 interactionNominal = interactionGho + interactionUsdt0 * 1e12;
        uint256 baselineNominal = baseline.spentGho + baseline.spentUsdt0 * 1e12;
        int256 interactionPpm = (interactionNominal * 1_000_000) / int256(baselineNominal);
        int256 interactionPerShare = (interactionNominal * 1e18) / int256(initial.borrowShares);

        int256 perturbCostGho = -perturbOnly.swapperDeltaGho;
        int256 perturbCostUsdt0 = -perturbOnly.swapperDeltaUsdt0;
        int256 combinedCostGho = -combinedPerturb.swapperDeltaGho + int256(perturbedClose.spentGho);
        int256 combinedCostUsdt0 = -combinedPerturb.swapperDeltaUsdt0 + int256(perturbedClose.spentUsdt0);
        int256 residualGho = combinedCostGho - int256(baseline.spentGho) - perturbCostGho;
        int256 residualUsdt0 = combinedCostUsdt0 - int256(baseline.spentUsdt0) - perturbCostUsdt0;

        assertEq(residualGho, interactionGho, "GHO three-control mismatch");
        assertEq(residualUsdt0, interactionUsdt0, "USDT0 three-control mismatch");

        emit InteractionV2(
            NFT,
            initial.borrowShares,
            baseline.spentGho,
            baseline.spentUsdt0,
            perturbedClose.spentGho,
            perturbedClose.spentUsdt0,
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
