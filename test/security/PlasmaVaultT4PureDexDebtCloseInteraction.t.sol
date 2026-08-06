// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.21;

import {Test} from "forge-std/Test.sol";

interface IERC20PureDexClose {
    function balanceOf(address account) external view returns (uint256);
}

interface IFactoryPureDexClose {
    function owner() external view returns (address);
    function ownerOf(uint256 nftId) external view returns (address);
}

interface IVaultPureDexClose {
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

interface IDexPurePerturb {
    function swapOut(bool swap0to1, uint256 amountOut, uint256 amountInMax, address to)
        external
        payable
        returns (uint256 amountIn);

    function readFromStorage(bytes32 slot) external view returns (uint256);
}

contract PlasmaVaultT4PureDexDebtCloseInteractionTest is Test {
    address internal constant FACTORY = 0x324c5Dc1fC42c7a4D43d92df1eBA58a54d13Bf2d;
    address internal constant VAULT = 0x6E0cDB09eb33cD3894C905E0DFF9289b95a86FFF;
    address internal constant RESOLVER = 0xA5C3E16523eeeDDcC34706b0E6bE88b4c6EA95cC;
    address internal constant DEX = 0x080574D224E960c272e005aA03EFbe793f317640;
    address internal constant LIQUIDITY = 0x607F4C5BB672230e8672085532f7e901544a7375;
    address internal constant GHO = 0xb77E0268e0f6f2E57B4a0869567B83b9Ca79C7A4;
    address internal constant USDT0 = 0xB8CE59FC3717ada4C02eaDF9682A9e934F625ebb;

    uint256 internal constant VAULT_POSITION_DATA_SLOT = 3;
    uint256 internal constant GHO_FUNDING = 1e30;
    uint256 internal constant USDT0_FUNDING = 1e18;
    int256 internal constant MAX_GHO_PAYBACK = -1e30;
    int256 internal constant MAX_USDT0_PAYBACK = -1e18;

    string internal rpcUrl;
    uint256 internal forkBlock;
    address internal perturbActor;

    struct Position {
        uint256 nftId;
        address owner;
        bool isLiquidated;
        bool isSupplyPosition;
        uint256 supplyShares;
        uint256 borrowShares;
        uint256 dustBorrow;
    }

    struct CloseResult {
        uint256 spent0;
        uint256 spent1;
        int256 returnedDebtShares;
        int256 returnedDebt0;
        int256 returnedDebt1;
        uint256 borrowSharesBefore;
        uint256 positionDataAfter;
    }

    struct PerturbResult {
        bool swap0to1;
        uint256 nominalOutput1e18;
        uint256 rawAmountOut;
        uint256 rawAmountIn;
        int256 actorCost0;
        int256 actorCost1;
        uint256 dexSlot2Before;
        uint256 dexSlot2After;
        uint256 dexSlot4Before;
        uint256 dexSlot4After;
        int256 liquidityDelta0;
        int256 liquidityDelta1;
    }

    event Surface(
        uint256 forkBlock,
        address indexed vault,
        address indexed dex,
        address token0,
        address token1,
        address liquidity
    );

    event BaselineClose(
        uint256 indexed nftId,
        address indexed owner,
        uint256 borrowShares,
        uint256 spentGho,
        uint256 spentUsdt0,
        int256 returnedDebtShares,
        int256 returnedDebt0,
        int256 returnedDebt1,
        uint256 positionDataAfter
    );

    event PerturbControl(
        bool indexed swap0to1,
        uint256 nominalOutput1e18,
        uint256 rawAmountOut,
        uint256 rawAmountIn,
        int256 actorCostGho,
        int256 actorCostUsdt0,
        uint256 dexSlot2Before,
        uint256 dexSlot2After,
        uint256 dexSlot4Before,
        uint256 dexSlot4After,
        int256 liquidityDeltaGho,
        int256 liquidityDeltaUsdt0
    );

    event DebtCloseInteraction(
        uint256 indexed nftId,
        bool indexed swap0to1,
        uint256 nominalOutput1e18,
        uint256 borrowShares,
        uint256 baselineSpentGho,
        uint256 baselineSpentUsdt0,
        uint256 afterPerturbSpentGho,
        uint256 afterPerturbSpentUsdt0,
        int256 interactionGho,
        int256 interactionUsdt0,
        int256 interactionNominal1e18,
        int256 interactionPpmOfBaseline,
        int256 interactionPerBorrowShare1e18,
        int256 threeControlResidualGho,
        int256 threeControlResidualUsdt0
    );

    function setUp() public {
        rpcUrl = vm.envString("PLASMA_RPC_URL");
        forkBlock = vm.envUint("PLASMA_FORK_BLOCK");
        perturbActor = makeAddr("pure-dex-perturb-actor");
        vm.createSelectFork(rpcUrl, forkBlock);
        assertEq(block.chainid, 9745, "unexpected chain");
        assertGt(FACTORY.code.length, 0, "missing factory");
        assertGt(VAULT.code.length, 0, "missing vault");
        assertGt(DEX.code.length, 0, "missing DEX");
        assertGt(GHO.code.length, 0, "missing GHO");
        assertGt(USDT0.code.length, 0, "missing USDT0");
    }

    function _word(bytes memory data, uint256 index) internal pure returns (uint256 value) {
        require(data.length >= (index + 1) * 32, "word out of bounds");
        assembly ("memory-safe") {
            value := mload(add(add(data, 0x20), mul(index, 0x20)))
        }
    }

    function _position(uint256 nftId) internal view returns (Position memory p) {
        (bool ok, bytes memory data) = RESOLVER.staticcall(
            abi.encodeWithSignature("positionByNftId(uint256)", nftId)
        );
        require(ok, "resolver position call failed");
        require(data.length >= 12 * 32, "short resolver response");

        p.nftId = _word(data, 0);
        p.owner = address(uint160(_word(data, 1)));
        p.isLiquidated = _word(data, 2) != 0;
        p.isSupplyPosition = _word(data, 3) != 0;
        p.supplyShares = _word(data, 9);
        p.borrowShares = _word(data, 10);
        p.dustBorrow = _word(data, 11);

        require(p.nftId == nftId, "resolver nft mismatch");
        require(p.owner == IFactoryPureDexClose(FACTORY).ownerOf(nftId), "owner mismatch");
        require(!p.isLiquidated && !p.isSupplyPosition, "not active debt position");
        require(p.borrowShares > 0, "zero borrow shares");
    }

    function _approveAs(address token, address owner, address spender) internal {
        vm.prank(owner);
        (bool ok, bytes memory data) = token.call(
            abi.encodeWithSignature("approve(address,uint256)", spender, type(uint256).max)
        );
        require(ok && (data.length == 0 || abi.decode(data, (bool))), "APPROVE_FAILED");
    }

    function _signedChange(uint256 after_, uint256 before_) internal pure returns (int256) {
        return after_ >= before_ ? int256(after_ - before_) : -int256(before_ - after_);
    }

    function _signedCost(uint256 before_, uint256 after_) internal pure returns (int256) {
        return before_ >= after_ ? int256(before_ - after_) : -int256(after_ - before_);
    }

    function _signedDiff(uint256 after_, uint256 before_) internal pure returns (int256) {
        return after_ >= before_ ? int256(after_ - before_) : -int256(before_ - after_);
    }

    function _readPositionData(uint256 nftId) internal returns (uint256 positionData) {
        address factoryOwner = IFactoryPureDexClose(FACTORY).owner();
        vm.prank(factoryOwner);
        positionData = IVaultPureDexClose(VAULT).readFromStorage(
            keccak256(abi.encode(nftId, VAULT_POSITION_DATA_SLOT))
        );
    }

    function _fullClose(uint256 nftId) internal returns (CloseResult memory result) {
        Position memory p = _position(nftId);
        result.borrowSharesBefore = p.borrowShares;

        deal(GHO, p.owner, GHO_FUNDING);
        deal(USDT0, p.owner, USDT0_FUNDING);
        _approveAs(GHO, p.owner, VAULT);
        _approveAs(USDT0, p.owner, VAULT);

        uint256 before0 = IERC20PureDexClose(GHO).balanceOf(p.owner);
        uint256 before1 = IERC20PureDexClose(USDT0).balanceOf(p.owner);

        vm.prank(p.owner);
        (, int256[] memory r) = IVaultPureDexClose(VAULT).operatePerfect(
            nftId,
            0,
            0,
            0,
            type(int256).min,
            MAX_GHO_PAYBACK,
            MAX_USDT0_PAYBACK,
            p.owner
        );

        require(r.length == 6, "unexpected operatePerfect result");
        result.spent0 = before0 - IERC20PureDexClose(GHO).balanceOf(p.owner);
        result.spent1 = before1 - IERC20PureDexClose(USDT0).balanceOf(p.owner);
        result.returnedDebtShares = r[3];
        result.returnedDebt0 = r[4];
        result.returnedDebt1 = r[5];
        result.positionDataAfter = _readPositionData(nftId);

        assertEq(result.positionDataAfter & 1, 1, "debt remains after max payback");
        assertLt(result.returnedDebtShares, 0, "no debt shares burned");
        assertEq(uint256(-result.returnedDebtShares), result.borrowSharesBefore, "not full share burn");
        assertEq(uint256(-result.returnedDebt0), result.spent0, "GHO spend mismatch");
        assertEq(uint256(-result.returnedDebt1), result.spent1, "USDT0 spend mismatch");
    }

    function _applyPerturb(bool swap0to1, uint256 nominalOutput1e18)
        internal
        returns (PerturbResult memory result)
    {
        result.swap0to1 = swap0to1;
        result.nominalOutput1e18 = nominalOutput1e18;
        result.rawAmountOut = swap0to1 ? nominalOutput1e18 / 1e12 : nominalOutput1e18;
        require(result.rawAmountOut > 0, "zero perturb amount");

        deal(GHO, perturbActor, GHO_FUNDING);
        deal(USDT0, perturbActor, USDT0_FUNDING);
        _approveAs(GHO, perturbActor, DEX);
        _approveAs(USDT0, perturbActor, DEX);

        uint256 actor0Before = IERC20PureDexClose(GHO).balanceOf(perturbActor);
        uint256 actor1Before = IERC20PureDexClose(USDT0).balanceOf(perturbActor);
        uint256 liquidity0Before = IERC20PureDexClose(GHO).balanceOf(LIQUIDITY);
        uint256 liquidity1Before = IERC20PureDexClose(USDT0).balanceOf(LIQUIDITY);
        result.dexSlot2Before = IDexPurePerturb(DEX).readFromStorage(bytes32(uint256(2)));
        result.dexSlot4Before = IDexPurePerturb(DEX).readFromStorage(bytes32(uint256(4)));

        vm.prank(perturbActor);
        result.rawAmountIn = IDexPurePerturb(DEX).swapOut(
            swap0to1,
            result.rawAmountOut,
            type(uint256).max,
            perturbActor
        );

        uint256 actor0After = IERC20PureDexClose(GHO).balanceOf(perturbActor);
        uint256 actor1After = IERC20PureDexClose(USDT0).balanceOf(perturbActor);
        result.actorCost0 = _signedCost(actor0Before, actor0After);
        result.actorCost1 = _signedCost(actor1Before, actor1After);
        result.dexSlot2After = IDexPurePerturb(DEX).readFromStorage(bytes32(uint256(2)));
        result.dexSlot4After = IDexPurePerturb(DEX).readFromStorage(bytes32(uint256(4)));
        result.liquidityDelta0 = _signedChange(
            IERC20PureDexClose(GHO).balanceOf(LIQUIDITY), liquidity0Before
        );
        result.liquidityDelta1 = _signedChange(
            IERC20PureDexClose(USDT0).balanceOf(LIQUIDITY), liquidity1Before
        );

        if (swap0to1) {
            assertEq(result.actorCost0, int256(result.rawAmountIn), "GHO input mismatch");
            assertEq(result.actorCost1, -int256(result.rawAmountOut), "USDT0 output mismatch");
        } else {
            assertEq(result.actorCost1, int256(result.rawAmountIn), "USDT0 input mismatch");
            assertEq(result.actorCost0, -int256(result.rawAmountOut), "GHO output mismatch");
        }
    }

    function _assertSamePerturb(PerturbResult memory a, PerturbResult memory b) internal pure {
        require(a.swap0to1 == b.swap0to1, "direction differs");
        require(a.nominalOutput1e18 == b.nominalOutput1e18, "nominal output differs");
        require(a.rawAmountOut == b.rawAmountOut, "output differs");
        require(a.rawAmountIn == b.rawAmountIn, "input differs");
        require(a.actorCost0 == b.actorCost0, "actor GHO cost differs");
        require(a.actorCost1 == b.actorCost1, "actor USDT0 cost differs");
        require(a.dexSlot2Before == b.dexSlot2Before, "slot2 baseline differs");
        require(a.dexSlot2After == b.dexSlot2After, "slot2 result differs");
        require(a.dexSlot4Before == b.dexSlot4Before, "slot4 baseline differs");
        require(a.dexSlot4After == b.dexSlot4After, "slot4 result differs");
        require(a.liquidityDelta0 == b.liquidityDelta0, "liquidity GHO delta differs");
        require(a.liquidityDelta1 == b.liquidityDelta1, "liquidity USDT0 delta differs");
    }

    function _freshBaseline(uint256 nftId) internal returns (CloseResult memory close) {
        vm.createSelectFork(rpcUrl, forkBlock);
        close = _fullClose(nftId);
    }

    function _freshPerturb(bool swap0to1, uint256 nominalOutput1e18)
        internal
        returns (PerturbResult memory perturb)
    {
        vm.createSelectFork(rpcUrl, forkBlock);
        perturb = _applyPerturb(swap0to1, nominalOutput1e18);
    }

    function _freshCombined(uint256 nftId, bool swap0to1, uint256 nominalOutput1e18)
        internal
        returns (PerturbResult memory perturb, CloseResult memory close)
    {
        vm.createSelectFork(rpcUrl, forkBlock);
        perturb = _applyPerturb(swap0to1, nominalOutput1e18);
        close = _fullClose(nftId);
    }

    function _emitInteraction(
        uint256 nftId,
        CloseResult memory baseline,
        PerturbResult memory controlPerturb,
        PerturbResult memory combinedPerturb,
        CloseResult memory afterPerturb
    ) internal {
        _assertSamePerturb(controlPerturb, combinedPerturb);
        assertEq(afterPerturb.borrowSharesBefore, baseline.borrowSharesBefore, "position shares changed before close");

        int256 interaction0 = _signedDiff(afterPerturb.spent0, baseline.spent0);
        int256 interaction1 = _signedDiff(afterPerturb.spent1, baseline.spent1);
        int256 nominalInteraction = interaction0 + interaction1 * 1e12;
        uint256 baselineNominal = baseline.spent0 + baseline.spent1 * 1e12;
        int256 interactionPpm = baselineNominal == 0
            ? int256(0)
            : (nominalInteraction * 1_000_000) / int256(baselineNominal);
        int256 perShare = (nominalInteraction * 1e18) / int256(baseline.borrowSharesBefore);

        int256 combinedTotalCost0 = combinedPerturb.actorCost0 + int256(afterPerturb.spent0);
        int256 combinedTotalCost1 = combinedPerturb.actorCost1 + int256(afterPerturb.spent1);
        int256 residual0 = combinedTotalCost0 - int256(baseline.spent0) - controlPerturb.actorCost0;
        int256 residual1 = combinedTotalCost1 - int256(baseline.spent1) - controlPerturb.actorCost1;
        assertEq(residual0, interaction0, "three-control GHO residual mismatch");
        assertEq(residual1, interaction1, "three-control USDT0 residual mismatch");

        emit DebtCloseInteraction(
            nftId,
            controlPerturb.swap0to1,
            controlPerturb.nominalOutput1e18,
            baseline.borrowSharesBefore,
            baseline.spent0,
            baseline.spent1,
            afterPerturb.spent0,
            afterPerturb.spent1,
            interaction0,
            interaction1,
            nominalInteraction,
            interactionPpm,
            perShare,
            residual0,
            residual1
        );
    }

    function test_pureDexPerturbThreeControls() public {
        emit Surface(forkBlock, VAULT, DEX, GHO, USDT0, LIQUIDITY);

        uint256[4] memory targets = [uint256(2770), uint256(2887), uint256(2869), uint256(2725)];
        uint256[2] memory perturbNominal = [uint256(100e18), uint256(1_000e18)];

        CloseResult[4] memory baselines;
        for (uint256 i; i < targets.length; ++i) {
            baselines[i] = _freshBaseline(targets[i]);
            Position memory p = _position(targets[i]);
            emit BaselineClose(
                targets[i],
                p.owner,
                baselines[i].borrowSharesBefore,
                baselines[i].spent0,
                baselines[i].spent1,
                baselines[i].returnedDebtShares,
                baselines[i].returnedDebt0,
                baselines[i].returnedDebt1,
                baselines[i].positionDataAfter
            );
        }

        for (uint256 direction; direction < 2; ++direction) {
            bool swap0to1 = direction == 0;
            for (uint256 sizeIndex; sizeIndex < perturbNominal.length; ++sizeIndex) {
                PerturbResult memory control = _freshPerturb(swap0to1, perturbNominal[sizeIndex]);
                emit PerturbControl(
                    control.swap0to1,
                    control.nominalOutput1e18,
                    control.rawAmountOut,
                    control.rawAmountIn,
                    control.actorCost0,
                    control.actorCost1,
                    control.dexSlot2Before,
                    control.dexSlot2After,
                    control.dexSlot4Before,
                    control.dexSlot4After,
                    control.liquidityDelta0,
                    control.liquidityDelta1
                );

                for (uint256 targetIndex; targetIndex < targets.length; ++targetIndex) {
                    (PerturbResult memory combinedPerturb, CloseResult memory afterPerturb) =
                        _freshCombined(targets[targetIndex], swap0to1, perturbNominal[sizeIndex]);
                    _emitInteraction(
                        targets[targetIndex],
                        baselines[targetIndex],
                        control,
                        combinedPerturb,
                        afterPerturb
                    );
                }
            }
        }
    }
}
