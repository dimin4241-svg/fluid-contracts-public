// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.21;

import {Test} from "forge-std/Test.sol";

interface IERC20SmartDebtExact {
    function balanceOf(address account) external view returns (uint256);
}

interface IPlasmaVaultFactorySmartDebtExact {
    function owner() external view returns (address);
    function ownerOf(uint256 nftId) external view returns (address);
}

interface IPlasmaVaultT4SmartDebtExact {
    struct Tokens {
        address token0;
        address token1;
    }

    struct ConstantViews {
        address liquidity;
        address factory;
        address operateImplementation;
        address adminImplementation;
        address secondaryImplementation;
        address deployer;
        address supply;
        address borrow;
        Tokens supplyToken;
        Tokens borrowToken;
        uint256 vaultId;
        uint256 vaultType;
        bytes32 supplyExchangePriceSlot;
        bytes32 borrowExchangePriceSlot;
        bytes32 userSupplySlot;
        bytes32 userBorrowSlot;
    }

    function constantsView() external view returns (ConstantViews memory);

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

/// @notice Three-control fork experiment on the exact live Plasma Smart Debt surface.
/// No NFT, position or debt-share storage is created or changed with cheatcodes.
/// deal() is used only to provide ordinary repayment tokens to the real NFT owner.
contract PlasmaSmartDebtExactCloseInteractionTest is Test {
    uint256 internal constant EXACT_FORK_BLOCK = 12_386_164;
    address internal constant VAULT = 0x6e0cdb5c21b3c8e340e9c9210057035bafa86fff;
    address internal constant EXPECTED_SMART_DEBT_DEX = 0xbd5dd095d9a6565c8222bb36b5814953f1c46f71;

    uint256 internal constant VAULT_POSITION_DATA_SLOT = 3;
    uint256 internal constant REPAY_FUNDING = 1e30;
    int256 internal constant REPAY_LIMIT = -1e30;

    string internal rpcUrl;
    address internal perturbReceiver;

    struct CloseResult {
        uint256 spent0;
        uint256 spent1;
        int256 burnedShares;
        int256 returnedDebt0;
        int256 returnedDebt1;
        uint256 positionDataAfter;
    }

    struct PerturbResult {
        uint256 borrowed0;
        uint256 borrowed1;
        int256 mintedShares;
        int256 returnedDebt0;
        int256 returnedDebt1;
        bytes32 dexSlot2Before;
        bytes32 dexSlot2After;
        bytes32 dexSlot4Before;
        bytes32 dexSlot4After;
    }

    event ExactSurface(
        uint256 forkBlock,
        address indexed vault,
        address indexed factory,
        address indexed smartDebtDex,
        address debtToken0,
        address debtToken1,
        uint256 vaultId,
        uint256 vaultType
    );

    event BaselineClose(
        uint256 indexed targetNft,
        uint256 spent0,
        uint256 spent1,
        int256 burnedShares,
        int256 returnedDebt0,
        int256 returnedDebt1,
        uint256 positionDataAfter
    );

    event PerturbOnly(
        uint256 indexed donorNft,
        uint256 perturbShares,
        uint256 borrowed0,
        uint256 borrowed1,
        int256 mintedShares,
        bytes32 dexSlot2Before,
        bytes32 dexSlot2After,
        bytes32 dexSlot4Before,
        bytes32 dexSlot4After
    );

    event CombinedClose(
        uint256 indexed targetNft,
        uint256 indexed donorNft,
        uint256 perturbShares,
        uint256 borrowed0,
        uint256 borrowed1,
        uint256 spent0,
        uint256 spent1,
        int256 burnedShares,
        int256 returnedDebt0,
        int256 returnedDebt1,
        uint256 positionDataAfter
    );

    event ExactThreeControlResidual(
        uint256 indexed targetNft,
        uint256 indexed donorNft,
        uint256 perturbShares,
        int256 baselineNet0,
        int256 baselineNet1,
        int256 perturbOnlyNet0,
        int256 perturbOnlyNet1,
        int256 combinedNet0,
        int256 combinedNet1,
        int256 residual0,
        int256 residual1,
        int256 closeCostDelta0,
        int256 closeCostDelta1
    );

    function setUp() public {
        rpcUrl = vm.envString("PLASMA_RPC_URL");
        perturbReceiver = makeAddr("smart-debt-perturb-receiver");
        uint256 suppliedBlock = vm.envOr("PLASMA_FORK_BLOCK", EXACT_FORK_BLOCK);
        assertEq(suppliedBlock, EXACT_FORK_BLOCK, "wrong fork block");
        _freshFork();
    }

    function _freshFork() internal {
        vm.createSelectFork(rpcUrl, EXACT_FORK_BLOCK);
        assertEq(block.chainid, 9745, "unexpected chain");
        assertEq(block.number, EXACT_FORK_BLOCK, "fork drift");
        assertGt(VAULT.code.length, 0, "exact vault has no code");
        assertGt(EXPECTED_SMART_DEBT_DEX.code.length, 0, "exact debt DEX has no code");
    }

    function _constants()
        internal
        view
        returns (IPlasmaVaultT4SmartDebtExact.ConstantViews memory c)
    {
        c = IPlasmaVaultT4SmartDebtExact(VAULT).constantsView();
        assertEq(c.borrow, EXPECTED_SMART_DEBT_DEX, "wrong Smart Debt DEX");
        assertTrue(c.borrowToken.token0 != address(0), "missing debt token0");
        assertTrue(c.borrowToken.token1 != address(0), "missing debt token1");
        assertGt(c.factory.code.length, 0, "missing vault factory");
    }

    function _safeApprove(address token, address spender, uint256 amount) internal {
        (bool ok, bytes memory data) =
            token.call(abi.encodeWithSignature("approve(address,uint256)", spender, amount));
        require(ok && (data.length == 0 || abi.decode(data, (bool))), "APPROVE_FAILED");
    }

    function _toInt(uint256 value) internal pure returns (int256) {
        require(value <= uint256(type(int256).max), "int256 overflow");
        return int256(value);
    }

    function _signedDelta(uint256 after_, uint256 before_) internal pure returns (int256) {
        return after_ >= before_ ? _toInt(after_ - before_) : -_toInt(before_ - after_);
    }

    function _positionData(
        IPlasmaVaultT4SmartDebtExact.ConstantViews memory c,
        uint256 nftId
    ) internal returns (uint256 value) {
        address factoryOwner = IPlasmaVaultFactorySmartDebtExact(c.factory).owner();
        vm.prank(factoryOwner);
        value = IPlasmaVaultT4SmartDebtExact(VAULT).readFromStorage(
            keccak256(abi.encode(nftId, VAULT_POSITION_DATA_SLOT))
        );
    }

    function _prepareOwner(
        IPlasmaVaultT4SmartDebtExact.ConstantViews memory c,
        uint256 nftId
    ) internal returns (address owner) {
        owner = IPlasmaVaultFactorySmartDebtExact(c.factory).ownerOf(nftId);
        assertTrue(owner != address(0), "missing real NFT owner");
        deal(owner, 100 ether);
        deal(c.borrowToken.token0, owner, REPAY_FUNDING, true);
        deal(c.borrowToken.token1, owner, REPAY_FUNDING, true);
        vm.startPrank(owner);
        _safeApprove(c.borrowToken.token0, VAULT, type(uint256).max);
        _safeApprove(c.borrowToken.token1, VAULT, type(uint256).max);
        vm.stopPrank();
    }

    function _fullClose(
        IPlasmaVaultT4SmartDebtExact.ConstantViews memory c,
        uint256 nftId
    ) internal returns (CloseResult memory result) {
        uint256 beforePosition = _positionData(c, nftId);
        assertTrue(beforePosition != 0 && (beforePosition & 1) == 0, "target has no live debt");

        address owner = _prepareOwner(c, nftId);
        uint256 balance0Before = IERC20SmartDebtExact(c.borrowToken.token0).balanceOf(owner);
        uint256 balance1Before = IERC20SmartDebtExact(c.borrowToken.token1).balanceOf(owner);

        vm.prank(owner);
        (, int256[] memory r) = IPlasmaVaultT4SmartDebtExact(VAULT).operatePerfect(
            nftId,
            0,
            0,
            0,
            type(int256).min,
            REPAY_LIMIT,
            REPAY_LIMIT,
            owner
        );

        assertEq(r.length, 6, "unexpected operatePerfect return length");
        uint256 balance0After = IERC20SmartDebtExact(c.borrowToken.token0).balanceOf(owner);
        uint256 balance1After = IERC20SmartDebtExact(c.borrowToken.token1).balanceOf(owner);
        result.spent0 = balance0Before - balance0After;
        result.spent1 = balance1Before - balance1After;
        result.burnedShares = r[3];
        result.returnedDebt0 = r[4];
        result.returnedDebt1 = r[5];
        result.positionDataAfter = _positionData(c, nftId);

        assertEq(result.positionDataAfter & 1, 1, "full close left live debt");
        assertLt(result.burnedShares, 0, "full close did not burn shares");
        assertLe(result.returnedDebt0, 0, "token0 close returned positive amount");
        assertLe(result.returnedDebt1, 0, "token1 close returned positive amount");
        assertEq(uint256(-result.returnedDebt0), result.spent0, "token0 close mismatch");
        assertEq(uint256(-result.returnedDebt1), result.spent1, "token1 close mismatch");
    }

    function _borrowPerturb(
        IPlasmaVaultT4SmartDebtExact.ConstantViews memory c,
        uint256 donorNft,
        uint256 perturbShares
    ) internal returns (PerturbResult memory result) {
        uint256 donorPosition = _positionData(c, donorNft);
        assertTrue(donorPosition != 0 && (donorPosition & 1) == 0, "donor has no live debt");

        address owner = IPlasmaVaultFactorySmartDebtExact(c.factory).ownerOf(donorNft);
        assertTrue(owner != address(0), "missing donor owner");
        deal(owner, 100 ether);

        uint256 balance0Before =
            IERC20SmartDebtExact(c.borrowToken.token0).balanceOf(perturbReceiver);
        uint256 balance1Before =
            IERC20SmartDebtExact(c.borrowToken.token1).balanceOf(perturbReceiver);
        result.dexSlot2Before = vm.load(EXPECTED_SMART_DEBT_DEX, bytes32(uint256(2)));
        result.dexSlot4Before = vm.load(EXPECTED_SMART_DEBT_DEX, bytes32(uint256(4)));

        vm.prank(owner);
        (, int256[] memory r) = IPlasmaVaultT4SmartDebtExact(VAULT).operatePerfect(
            donorNft,
            0,
            0,
            0,
            int256(perturbShares),
            1,
            1,
            perturbReceiver
        );

        assertEq(r.length, 6, "unexpected perturb return length");
        result.borrowed0 =
            IERC20SmartDebtExact(c.borrowToken.token0).balanceOf(perturbReceiver) - balance0Before;
        result.borrowed1 =
            IERC20SmartDebtExact(c.borrowToken.token1).balanceOf(perturbReceiver) - balance1Before;
        result.mintedShares = r[3];
        result.returnedDebt0 = r[4];
        result.returnedDebt1 = r[5];
        result.dexSlot2After = vm.load(EXPECTED_SMART_DEBT_DEX, bytes32(uint256(2)));
        result.dexSlot4After = vm.load(EXPECTED_SMART_DEBT_DEX, bytes32(uint256(4)));

        assertEq(uint256(result.mintedShares), perturbShares, "wrong perturb share count");
        assertEq(uint256(result.returnedDebt0), result.borrowed0, "token0 perturb mismatch");
        assertEq(uint256(result.returnedDebt1), result.borrowed1, "token1 perturb mismatch");
        assertGt(result.borrowed0 + result.borrowed1, 0, "zero perturb output");
    }

    function _runBaseline(uint256 targetNft) internal returns (CloseResult memory result) {
        _freshFork();
        IPlasmaVaultT4SmartDebtExact.ConstantViews memory c = _constants();
        result = _fullClose(c, targetNft);
        emit BaselineClose(
            targetNft,
            result.spent0,
            result.spent1,
            result.burnedShares,
            result.returnedDebt0,
            result.returnedDebt1,
            result.positionDataAfter
        );
    }

    function _runPerturbOnly(uint256 donorNft, uint256 perturbShares)
        internal
        returns (PerturbResult memory result)
    {
        _freshFork();
        IPlasmaVaultT4SmartDebtExact.ConstantViews memory c = _constants();
        result = _borrowPerturb(c, donorNft, perturbShares);
        emit PerturbOnly(
            donorNft,
            perturbShares,
            result.borrowed0,
            result.borrowed1,
            result.mintedShares,
            result.dexSlot2Before,
            result.dexSlot2After,
            result.dexSlot4Before,
            result.dexSlot4After
        );
    }

    function _runCombined(uint256 targetNft, uint256 donorNft, uint256 perturbShares)
        internal
        returns (PerturbResult memory perturb, CloseResult memory closeResult)
    {
        _freshFork();
        IPlasmaVaultT4SmartDebtExact.ConstantViews memory c = _constants();
        perturb = _borrowPerturb(c, donorNft, perturbShares);
        closeResult = _fullClose(c, targetNft);
        emit CombinedClose(
            targetNft,
            donorNft,
            perturbShares,
            perturb.borrowed0,
            perturb.borrowed1,
            closeResult.spent0,
            closeResult.spent1,
            closeResult.burnedShares,
            closeResult.returnedDebt0,
            closeResult.returnedDebt1,
            closeResult.positionDataAfter
        );
    }

    function _assertSamePerturb(
        PerturbResult memory control,
        PerturbResult memory combined
    ) internal pure {
        require(combined.borrowed0 == control.borrowed0, "non-identical perturb token0");
        require(combined.borrowed1 == control.borrowed1, "non-identical perturb token1");
        require(combined.mintedShares == control.mintedShares, "non-identical perturb shares");
        require(combined.returnedDebt0 == control.returnedDebt0, "non-identical perturb return0");
        require(combined.returnedDebt1 == control.returnedDebt1, "non-identical perturb return1");
        require(combined.dexSlot2Before == control.dexSlot2Before, "non-identical DEX slot2 before");
        require(combined.dexSlot2After == control.dexSlot2After, "non-identical DEX slot2 after");
        require(combined.dexSlot4Before == control.dexSlot4Before, "non-identical DEX slot4 before");
        require(combined.dexSlot4After == control.dexSlot4After, "non-identical DEX slot4 after");
    }

    function _probe(uint256 targetNft, uint256 donorNft, uint256 perturbShares) internal {
        assertTrue(targetNft != donorNft, "target equals donor");

        CloseResult memory baseline = _runBaseline(targetNft);
        PerturbResult memory perturbOnly = _runPerturbOnly(donorNft, perturbShares);
        (PerturbResult memory combinedPerturb, CloseResult memory combinedClose) =
            _runCombined(targetNft, donorNft, perturbShares);

        _assertSamePerturb(perturbOnly, combinedPerturb);
        assertEq(combinedClose.burnedShares, baseline.burnedShares, "target debt shares changed");

        int256 baselineNet0 = -_toInt(baseline.spent0);
        int256 baselineNet1 = -_toInt(baseline.spent1);
        int256 perturbOnlyNet0 = _toInt(perturbOnly.borrowed0);
        int256 perturbOnlyNet1 = _toInt(perturbOnly.borrowed1);
        int256 combinedNet0 = _toInt(combinedPerturb.borrowed0) - _toInt(combinedClose.spent0);
        int256 combinedNet1 = _toInt(combinedPerturb.borrowed1) - _toInt(combinedClose.spent1);

        int256 residual0 = combinedNet0 - baselineNet0 - perturbOnlyNet0;
        int256 residual1 = combinedNet1 - baselineNet1 - perturbOnlyNet1;
        int256 closeCostDelta0 = _signedDelta(combinedClose.spent0, baseline.spent0);
        int256 closeCostDelta1 = _signedDelta(combinedClose.spent1, baseline.spent1);

        // With identical perturb legs, the explicit three-arm residual is exactly
        // the negative change in target close cost. It is intentionally not
        // constrained to zero: a non-zero value is the interaction under test.
        assertEq(residual0, -closeCostDelta0, "token0 residual algebra mismatch");
        assertEq(residual1, -closeCostDelta1, "token1 residual algebra mismatch");

        emit ExactThreeControlResidual(
            targetNft,
            donorNft,
            perturbShares,
            baselineNet0,
            baselineNet1,
            perturbOnlyNet0,
            perturbOnlyNet1,
            combinedNet0,
            combinedNet1,
            residual0,
            residual1,
            closeCostDelta0,
            closeCostDelta1
        );
    }

    function test_exactThreeControlInteraction() public {
        IPlasmaVaultT4SmartDebtExact.ConstantViews memory c = _constants();
        emit ExactSurface(
            block.number,
            VAULT,
            c.factory,
            c.borrow,
            c.borrowToken.token0,
            c.borrowToken.token1,
            c.vaultId,
            c.vaultType
        );

        uint256[4] memory targets = [uint256(2770), uint256(2887), uint256(2869), uint256(2725)];
        uint256[4] memory donors = [uint256(2887), uint256(2770), uint256(2887), uint256(2770)];
        uint256[2] memory perturbSizes = [uint256(1e18), uint256(1e19)];

        for (uint256 i; i < targets.length; ++i) {
            for (uint256 j; j < perturbSizes.length; ++j) {
                _probe(targets[i], donors[i], perturbSizes[j]);
            }
        }
    }
}
