// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.21;

import {Test} from "forge-std/Test.sol";

interface IERC20Smoke {
    function balanceOf(address account) external view returns (uint256);
}

interface IFactorySmoke {
    function owner() external view returns (address);
    function ownerOf(uint256 nftId) external view returns (address);
}

interface IVaultSmoke {
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

interface IDexSmoke {
    function swapOut(bool swap0to1, uint256 amountOut, uint256 amountInMax, address to)
        external payable returns (uint256 amountIn);
    function readFromStorage(bytes32 slot) external view returns (uint256);
}

contract PlasmaVaultT4PureDexDebtCloseSmokeTest is Test {
    address internal constant FACTORY = 0x324c5Dc1fC42c7a4D43d92df1eBA58a54d13Bf2d;
    address internal constant VAULT = 0x6E0cDB09eb33cD3894C905E0DFF9289b95a86FFF;
    address internal constant RESOLVER = 0xA5C3E16523eeeDDcC34706b0E6bE88b4c6EA95cC;
    address internal constant DEX = 0x080574D224E960c272e005aA03EFbe793f317640;
    address internal constant LIQUIDITY = 0x607F4C5BB672230e8672085532f7e901544a7375;
    address internal constant GHO = 0xb77E0268e0f6f2E57B4a0869567B83b9Ca79C7A4;
    address internal constant USDT0 = 0xB8CE59FC3717ada4C02eaDF9682A9e934F625ebb;

    uint256 internal constant TARGET_NFT = 2770;
    uint256 internal constant PERTURB_USDT0_OUT = 100e6;
    uint256 internal constant POSITION_DATA_SLOT = 3;
    uint256 internal constant FUND_GHO = 1e30;
    uint256 internal constant FUND_USDT0 = 1e18;

    string internal rpcUrl;
    uint256 internal forkBlock;
    address internal actor;

    struct Position {
        address owner;
        uint256 borrowShares;
    }

    struct CloseResult {
        address owner;
        uint256 borrowShares;
        uint256 spentGho;
        uint256 spentUsdt0;
        int256 returnedShares;
        int256 returnedGho;
        int256 returnedUsdt0;
        uint256 positionDataAfter;
    }

    struct PerturbResult {
        uint256 amountInGho;
        int256 actorCostGho;
        int256 actorCostUsdt0;
        uint256 slot2Before;
        uint256 slot2After;
        uint256 slot4Before;
        uint256 slot4After;
        int256 liquidityDeltaGho;
        int256 liquidityDeltaUsdt0;
    }

    event SmokeSurface(
        uint256 blockNumber,
        address indexed vault,
        address indexed dex,
        address gho,
        address usdt0,
        uint256 targetNft
    );

    event SmokeBaseline(
        uint256 indexed nftId,
        address indexed owner,
        uint256 borrowShares,
        uint256 spentGho,
        uint256 spentUsdt0,
        int256 returnedShares,
        uint256 positionDataAfter
    );

    event SmokePerturb(
        uint256 usdt0Out,
        uint256 ghoIn,
        int256 actorCostGho,
        int256 actorCostUsdt0,
        uint256 slot2Before,
        uint256 slot2After,
        uint256 slot4Before,
        uint256 slot4After,
        int256 liquidityDeltaGho,
        int256 liquidityDeltaUsdt0
    );

    event SmokeInteraction(
        uint256 indexed nftId,
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
        actor = makeAddr("pure-dex-smoke-actor");
        vm.createSelectFork(rpcUrl, forkBlock);
        assertEq(block.chainid, 9745, "unexpected chain");
        assertGt(VAULT.code.length, 0, "missing vault");
        assertGt(DEX.code.length, 0, "missing DEX");
        assertGt(GHO.code.length, 0, "missing GHO");
        assertGt(USDT0.code.length, 0, "missing USDT0");
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
        p.owner = address(uint160(_word(data, 1)));
        bool liquidated = _word(data, 2) != 0;
        bool supplyPosition = _word(data, 3) != 0;
        p.borrowShares = _word(data, 10);
        require(p.owner == IFactorySmoke(FACTORY).ownerOf(nftId), "owner mismatch");
        require(!liquidated && !supplyPosition && p.borrowShares > 0, "not active debt");
    }

    function _approve(address token, address owner, address spender) internal {
        vm.prank(owner);
        (bool ok, bytes memory data) = token.call(
            abi.encodeWithSignature("approve(address,uint256)", spender, type(uint256).max)
        );
        require(ok && (data.length == 0 || abi.decode(data, (bool))), "approve failed");
    }

    function _signedChange(uint256 after_, uint256 before_) internal pure returns (int256) {
        return after_ >= before_ ? int256(after_ - before_) : -int256(before_ - after_);
    }

    function _signedCost(uint256 before_, uint256 after_) internal pure returns (int256) {
        return before_ >= after_ ? int256(before_ - after_) : -int256(after_ - before_);
    }

    function _readPositionData(uint256 nftId) internal returns (uint256 value) {
        address factoryOwner = IFactorySmoke(FACTORY).owner();
        vm.prank(factoryOwner);
        value = IVaultSmoke(VAULT).readFromStorage(
            keccak256(abi.encode(nftId, POSITION_DATA_SLOT))
        );
    }

    function _close(uint256 nftId) internal returns (CloseResult memory r) {
        Position memory p = _position(nftId);
        r.owner = p.owner;
        r.borrowShares = p.borrowShares;

        deal(GHO, p.owner, FUND_GHO);
        deal(USDT0, p.owner, FUND_USDT0);
        _approve(GHO, p.owner, VAULT);
        _approve(USDT0, p.owner, VAULT);

        uint256 ghoBefore = IERC20Smoke(GHO).balanceOf(p.owner);
        uint256 usdtBefore = IERC20Smoke(USDT0).balanceOf(p.owner);
        vm.prank(p.owner);
        (, int256[] memory values) = IVaultSmoke(VAULT).operatePerfect(
            nftId,
            0,
            0,
            0,
            type(int256).min,
            -int256(FUND_GHO),
            -int256(FUND_USDT0),
            p.owner
        );
        require(values.length == 6, "bad close return");

        r.spentGho = ghoBefore - IERC20Smoke(GHO).balanceOf(p.owner);
        r.spentUsdt0 = usdtBefore - IERC20Smoke(USDT0).balanceOf(p.owner);
        r.returnedShares = values[3];
        r.returnedGho = values[4];
        r.returnedUsdt0 = values[5];
        r.positionDataAfter = _readPositionData(nftId);

        assertEq(r.positionDataAfter & 1, 1, "debt remains");
        assertEq(uint256(-r.returnedShares), r.borrowShares, "not full close");
        assertEq(uint256(-r.returnedGho), r.spentGho, "GHO mismatch");
        assertEq(uint256(-r.returnedUsdt0), r.spentUsdt0, "USDT0 mismatch");
    }

    function _perturb() internal returns (PerturbResult memory r) {
        deal(GHO, actor, FUND_GHO);
        deal(USDT0, actor, FUND_USDT0);
        _approve(GHO, actor, DEX);
        _approve(USDT0, actor, DEX);

        uint256 actorGhoBefore = IERC20Smoke(GHO).balanceOf(actor);
        uint256 actorUsdtBefore = IERC20Smoke(USDT0).balanceOf(actor);
        uint256 liqGhoBefore = IERC20Smoke(GHO).balanceOf(LIQUIDITY);
        uint256 liqUsdtBefore = IERC20Smoke(USDT0).balanceOf(LIQUIDITY);
        r.slot2Before = IDexSmoke(DEX).readFromStorage(bytes32(uint256(2)));
        r.slot4Before = IDexSmoke(DEX).readFromStorage(bytes32(uint256(4)));

        vm.prank(actor);
        r.amountInGho = IDexSmoke(DEX).swapOut(
            true,
            PERTURB_USDT0_OUT,
            type(uint256).max,
            actor
        );

        r.actorCostGho = _signedCost(actorGhoBefore, IERC20Smoke(GHO).balanceOf(actor));
        r.actorCostUsdt0 = _signedCost(actorUsdtBefore, IERC20Smoke(USDT0).balanceOf(actor));
        r.slot2After = IDexSmoke(DEX).readFromStorage(bytes32(uint256(2)));
        r.slot4After = IDexSmoke(DEX).readFromStorage(bytes32(uint256(4)));
        r.liquidityDeltaGho = _signedChange(IERC20Smoke(GHO).balanceOf(LIQUIDITY), liqGhoBefore);
        r.liquidityDeltaUsdt0 = _signedChange(IERC20Smoke(USDT0).balanceOf(LIQUIDITY), liqUsdtBefore);

        assertEq(r.actorCostGho, int256(r.amountInGho), "perturb GHO mismatch");
        assertEq(r.actorCostUsdt0, -int256(PERTURB_USDT0_OUT), "perturb USDT0 mismatch");
    }

    function _samePerturb(PerturbResult memory a, PerturbResult memory b) internal pure {
        require(a.amountInGho == b.amountInGho, "input differs");
        require(a.actorCostGho == b.actorCostGho, "GHO cost differs");
        require(a.actorCostUsdt0 == b.actorCostUsdt0, "USDT0 cost differs");
        require(a.slot2Before == b.slot2Before && a.slot2After == b.slot2After, "slot2 differs");
        require(a.slot4Before == b.slot4Before && a.slot4After == b.slot4After, "slot4 differs");
        require(a.liquidityDeltaGho == b.liquidityDeltaGho, "liquidity GHO differs");
        require(a.liquidityDeltaUsdt0 == b.liquidityDeltaUsdt0, "liquidity USDT0 differs");
    }

    function test_pureDexDebtCloseSmoke() public {
        emit SmokeSurface(forkBlock, VAULT, DEX, GHO, USDT0, TARGET_NFT);

        vm.createSelectFork(rpcUrl, forkBlock);
        CloseResult memory baseline = _close(TARGET_NFT);
        emit SmokeBaseline(
            TARGET_NFT,
            baseline.owner,
            baseline.borrowShares,
            baseline.spentGho,
            baseline.spentUsdt0,
            baseline.returnedShares,
            baseline.positionDataAfter
        );

        vm.createSelectFork(rpcUrl, forkBlock);
        PerturbResult memory control = _perturb();
        emit SmokePerturb(
            PERTURB_USDT0_OUT,
            control.amountInGho,
            control.actorCostGho,
            control.actorCostUsdt0,
            control.slot2Before,
            control.slot2After,
            control.slot4Before,
            control.slot4After,
            control.liquidityDeltaGho,
            control.liquidityDeltaUsdt0
        );

        vm.createSelectFork(rpcUrl, forkBlock);
        PerturbResult memory combinedPerturb = _perturb();
        CloseResult memory afterPerturb = _close(TARGET_NFT);
        _samePerturb(control, combinedPerturb);
        assertEq(afterPerturb.borrowShares, baseline.borrowShares, "shares changed before close");

        int256 interactionGho = _signedChange(afterPerturb.spentGho, baseline.spentGho);
        int256 interactionUsdt0 = _signedChange(afterPerturb.spentUsdt0, baseline.spentUsdt0);
        int256 interactionNominal = interactionGho + interactionUsdt0 * 1e12;
        uint256 baselineNominal = baseline.spentGho + baseline.spentUsdt0 * 1e12;
        int256 ppm = (interactionNominal * 1_000_000) / int256(baselineNominal);
        int256 perShare = (interactionNominal * 1e18) / int256(baseline.borrowShares);

        int256 combinedCostGho = combinedPerturb.actorCostGho + int256(afterPerturb.spentGho);
        int256 combinedCostUsdt0 = combinedPerturb.actorCostUsdt0 + int256(afterPerturb.spentUsdt0);
        int256 residualGho = combinedCostGho - int256(baseline.spentGho) - control.actorCostGho;
        int256 residualUsdt0 = combinedCostUsdt0 - int256(baseline.spentUsdt0) - control.actorCostUsdt0;
        assertEq(residualGho, interactionGho, "GHO residual mismatch");
        assertEq(residualUsdt0, interactionUsdt0, "USDT0 residual mismatch");

        emit SmokeInteraction(
            TARGET_NFT,
            baseline.spentGho,
            baseline.spentUsdt0,
            afterPerturb.spentGho,
            afterPerturb.spentUsdt0,
            interactionGho,
            interactionUsdt0,
            interactionNominal,
            ppm,
            perShare,
            residualGho,
            residualUsdt0
        );
    }
}
