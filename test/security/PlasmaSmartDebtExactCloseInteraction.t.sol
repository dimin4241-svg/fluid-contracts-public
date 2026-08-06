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
        bytes32 dexSlot2After;
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
        uint256 spent0,
        uint256 spent1,
        int256 burnedShares,
        int256 returnedDebt0,
        int256 returnedDebt1,
        uint256 positionDataAfter
    );

    event ExactInteraction(
        uint256 indexed targetNft,
        uint256 indexed donorNft,
        uint256 perturbShares,
        uint256 baselineSpent0,
        uint256 baselineSpent1,
        uint256 perturbedSpent0,
        uint256 perturbedSpent1,
        int256 rawInteraction0,
        int256 rawInteraction1,
        uint256 perturbBorrowed0,
        uint256 perturbBorrowed1
    );

    function setUp() public {
        rpcUrl = vm.envString("PLASMA_RPC_URL");
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

    function _signedDelta(uint256 after_, uint256 before_) internal pure returns (int256) {
        return after_ >= before_ ? int256(after_ - before_) : -int256(before_ - after_);
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

        uint256 balance0Before = IERC20SmartDebtExact(c.borrowToken.token0).balanceOf(owner);
        uint256 balance1Before = IERC20SmartDebtExact(c.borrowToken.token1).balanceOf(owner);

        vm.prank(owner);
        (, int256[] memory r) = IPlasmaVaultT4SmartDebtExact(VAULT).operatePerfect(
            donorNft,
            0,
            0,
            0,
            int256(perturbShares),
            1,
            1,
            owner
        );

        assertEq(r.length, 6, "unexpected perturb return length");
        result.borrowed0 = IERC20SmartDebtExact(c.borrowToken.token0).balanceOf(owner) - balance0Before;
        result.borrowed1 = IERC20SmartDebtExact(c.borrowToken.token1).balanceOf(owner) - balance1Before;
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
        bytes32 slot2Before = vm.load(EXPECTED_SMART_DEBT_DEX, bytes32(uint256(2)));
        bytes32 slot4Before = vm.load(EXPECTED_SMART_DEBT_DEX, bytes32(uint256(4)));
        result = _borrowPerturb(c, donorNft, perturbShares);
        emit PerturbOnly(
            donorNft,
            perturbShares,
            result.borrowed0,
            result.borrowed1,
            result.mintedShares,
            slot2Before,
            result.dexSlot2After,
            slot4Before,
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
            closeResult.spent0,
            closeResult.spent1,
            closeResult.burnedShares,
            closeResult.returnedDebt0,
            closeResult.returnedDebt1,
            closeResult.positionDataAfter
        );
    }

    function _probe(uint256 targetNft, uint256 donorNft, uint256 perturbShares) internal {
        assertTrue(targetNft != donorNft, "target equals donor");

        CloseResult memory baseline = _runBaseline(targetNft);
        PerturbResult memory perturbOnly = _runPerturbOnly(donorNft, perturbShares);
        (PerturbResult memory combinedPerturb, CloseResult memory combined) =
            _runCombined(targetNft, donorNft, perturbShares);

        // The B and C perturb legs must be byte-for-byte identical before the target close.
        assertEq(combinedPerturb.borrowed0, perturbOnly.borrowed0, "non-identical perturb token0");
        assertEq(combinedPerturb.borrowed1, perturbOnly.borrowed1, "non-identical perturb token1");
        assertEq(combinedPerturb.mintedShares, perturbOnly.mintedShares, "non-identical perturb shares");
        assertEq(combinedPerturb.dexSlot2After, perturbOnly.dexSlot2After, "non-identical DEX slot2");
        assertEq(combinedPerturb.dexSlot4After, perturbOnly.dexSlot4After, "non-identical DEX slot4");

        emit ExactInteraction(
            targetNft,
            donorNft,
            perturbShares,
            baseline.spent0,
            baseline.spent1,
            combined.spent0,
            combined.spent1,
            _signedDelta(combined.spent0, baseline.spent0),
            _signedDelta(combined.spent1, baseline.spent1),
            perturbOnly.borrowed0,
            perturbOnly.borrowed1
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
