// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.21;

import {Test} from "forge-std/Test.sol";

interface IERC20ExactResidual {
    function balanceOf(address account) external view returns (uint256);
}

interface IFactoryExactResidual {
    function owner() external view returns (address);
    function ownerOf(uint256 nftId) external view returns (address);
}

interface IVaultExactResidual {
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

/// @notice Temporary Windows-run wrapper for the exact three-control Smart Debt proof.
/// It uses only real NFT positions and never writes debt shares or position storage.
contract PlasmaVaultT4OneSidedBorrowLiquidationV2Test is Test {
    uint256 internal constant EXACT_FORK_BLOCK = 12_386_164;
    address internal constant VAULT = 0x6e0cdb5c21b3c8e340e9c9210057035bafa86fff;
    address internal constant SMART_DEBT_DEX = 0xbd5dd095d9a6565c8222bb36b5814953f1c46f71;
    uint256 internal constant POSITION_SLOT = 3;
    uint256 internal constant REPAY_FUNDING = 1e30;
    int256 internal constant REPAY_LIMIT = -1e30;

    string internal rpcUrl;
    address internal perturbReceiver;

    struct CloseResult {
        uint256 spent0;
        uint256 spent1;
        int256 burnedShares;
        int256 returned0;
        int256 returned1;
        uint256 positionAfter;
    }

    struct PerturbResult {
        uint256 borrowed0;
        uint256 borrowed1;
        int256 mintedShares;
        int256 returned0;
        int256 returned1;
        bytes32 slot2Before;
        bytes32 slot2After;
        bytes32 slot4Before;
        bytes32 slot4After;
    }

    event FeasibleDeposit(
        uint256 forkBlock,
        address indexed vault,
        address indexed factory,
        address indexed smartDebtDex,
        address debtToken0,
        address debtToken1
    );

    event FeasibleBorrow(
        uint256 indexed donorNft,
        uint256 perturbShares,
        uint256 borrowed0,
        uint256 borrowed1,
        int256 mintedShares,
        bytes32 slot2Before,
        bytes32 slot2After,
        bytes32 slot4Before,
        bytes32 slot4After
    );

    event FeasibleCase(
        uint256 indexed targetNft,
        uint256 indexed donorNft,
        uint256 perturbShares,
        uint256 baselineSpent0,
        uint256 baselineSpent1,
        uint256 combinedSpent0,
        uint256 combinedSpent1,
        int256 residual0,
        int256 residual1,
        int256 closeCostDelta0,
        int256 closeCostDelta1
    );

    function setUp() public {
        rpcUrl = vm.envString("PLASMA_RPC_URL");
        perturbReceiver = makeAddr("exact-smart-debt-perturb-receiver");
        _freshFork();
    }

    function _freshFork() internal {
        vm.createSelectFork(rpcUrl, EXACT_FORK_BLOCK);
        assertEq(block.chainid, 9745, "unexpected chain");
        assertEq(block.number, EXACT_FORK_BLOCK, "fork drift");
        assertGt(VAULT.code.length, 0, "vault has no code");
        assertGt(SMART_DEBT_DEX.code.length, 0, "DEX has no code");
    }

    function _constants() internal view returns (IVaultExactResidual.ConstantViews memory c) {
        c = IVaultExactResidual(VAULT).constantsView();
        assertEq(c.borrow, SMART_DEBT_DEX, "wrong Smart Debt DEX");
        assertTrue(c.borrowToken.token0 != address(0), "missing debt token0");
        assertTrue(c.borrowToken.token1 != address(0), "missing debt token1");
        assertGt(c.factory.code.length, 0, "missing factory");
    }

    function _safeApprove(address token, uint256 amount) internal {
        (bool ok, bytes memory data) = token.call(
            abi.encodeWithSignature("approve(address,uint256)", VAULT, amount)
        );
        require(ok && (data.length == 0 || abi.decode(data, (bool))), "APPROVE_FAILED");
    }

    function _toInt(uint256 value) internal pure returns (int256) {
        require(value <= uint256(type(int256).max), "int256 overflow");
        return int256(value);
    }

    function _signedDelta(uint256 after_, uint256 before_) internal pure returns (int256) {
        return after_ >= before_ ? _toInt(after_ - before_) : -_toInt(before_ - after_);
    }

    function _position(IVaultExactResidual.ConstantViews memory c, uint256 nftId)
        internal
        returns (uint256 value)
    {
        address factoryOwner = IFactoryExactResidual(c.factory).owner();
        vm.prank(factoryOwner);
        value = IVaultExactResidual(VAULT).readFromStorage(
            keccak256(abi.encode(nftId, POSITION_SLOT))
        );
    }

    function _prepareOwner(IVaultExactResidual.ConstantViews memory c, uint256 nftId)
        internal
        returns (address owner)
    {
        owner = IFactoryExactResidual(c.factory).ownerOf(nftId);
        assertTrue(owner != address(0), "missing owner");
        deal(owner, 100 ether);
        deal(c.borrowToken.token0, owner, REPAY_FUNDING, true);
        deal(c.borrowToken.token1, owner, REPAY_FUNDING, true);
        vm.startPrank(owner);
        _safeApprove(c.borrowToken.token0, type(uint256).max);
        _safeApprove(c.borrowToken.token1, type(uint256).max);
        vm.stopPrank();
    }

    function _fullClose(IVaultExactResidual.ConstantViews memory c, uint256 nftId)
        internal
        returns (CloseResult memory result)
    {
        uint256 beforePosition = _position(c, nftId);
        assertTrue(beforePosition != 0 && (beforePosition & 1) == 0, "target has no live debt");

        address owner = _prepareOwner(c, nftId);
        uint256 balance0Before = IERC20ExactResidual(c.borrowToken.token0).balanceOf(owner);
        uint256 balance1Before = IERC20ExactResidual(c.borrowToken.token1).balanceOf(owner);

        vm.prank(owner);
        (, int256[] memory r) = IVaultExactResidual(VAULT).operatePerfect(
            nftId,
            0,
            0,
            0,
            type(int256).min,
            REPAY_LIMIT,
            REPAY_LIMIT,
            owner
        );

        assertEq(r.length, 6, "unexpected close return length");
        uint256 balance0After = IERC20ExactResidual(c.borrowToken.token0).balanceOf(owner);
        uint256 balance1After = IERC20ExactResidual(c.borrowToken.token1).balanceOf(owner);
        result.spent0 = balance0Before - balance0After;
        result.spent1 = balance1Before - balance1After;
        result.burnedShares = r[3];
        result.returned0 = r[4];
        result.returned1 = r[5];
        result.positionAfter = _position(c, nftId);

        assertEq(result.positionAfter & 1, 1, "full close left live debt");
        assertLt(result.burnedShares, 0, "full close did not burn shares");
        assertLe(result.returned0, 0, "close token0 positive");
        assertLe(result.returned1, 0, "close token1 positive");
        assertEq(uint256(-result.returned0), result.spent0, "close token0 mismatch");
        assertEq(uint256(-result.returned1), result.spent1, "close token1 mismatch");
    }

    function _perturb(
        IVaultExactResidual.ConstantViews memory c,
        uint256 donorNft,
        uint256 perturbShares
    ) internal returns (PerturbResult memory result) {
        uint256 donorPosition = _position(c, donorNft);
        assertTrue(donorPosition != 0 && (donorPosition & 1) == 0, "donor has no live debt");

        address owner = IFactoryExactResidual(c.factory).ownerOf(donorNft);
        assertTrue(owner != address(0), "missing donor owner");
        deal(owner, 100 ether);

        uint256 balance0Before = IERC20ExactResidual(c.borrowToken.token0).balanceOf(perturbReceiver);
        uint256 balance1Before = IERC20ExactResidual(c.borrowToken.token1).balanceOf(perturbReceiver);
        result.slot2Before = vm.load(SMART_DEBT_DEX, bytes32(uint256(2)));
        result.slot4Before = vm.load(SMART_DEBT_DEX, bytes32(uint256(4)));

        vm.prank(owner);
        (, int256[] memory r) = IVaultExactResidual(VAULT).operatePerfect(
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
        result.borrowed0 = IERC20ExactResidual(c.borrowToken.token0).balanceOf(perturbReceiver) - balance0Before;
        result.borrowed1 = IERC20ExactResidual(c.borrowToken.token1).balanceOf(perturbReceiver) - balance1Before;
        result.mintedShares = r[3];
        result.returned0 = r[4];
        result.returned1 = r[5];
        result.slot2After = vm.load(SMART_DEBT_DEX, bytes32(uint256(2)));
        result.slot4After = vm.load(SMART_DEBT_DEX, bytes32(uint256(4)));

        assertEq(uint256(result.mintedShares), perturbShares, "wrong perturb shares");
        assertEq(uint256(result.returned0), result.borrowed0, "perturb token0 mismatch");
        assertEq(uint256(result.returned1), result.borrowed1, "perturb token1 mismatch");
        assertGt(result.borrowed0 + result.borrowed1, 0, "zero perturb output");
    }

    function _baseline(uint256 targetNft) internal returns (CloseResult memory result) {
        _freshFork();
        result = _fullClose(_constants(), targetNft);
    }

    function _perturbOnly(uint256 donorNft, uint256 perturbShares)
        internal
        returns (PerturbResult memory result)
    {
        _freshFork();
        result = _perturb(_constants(), donorNft, perturbShares);
        emit FeasibleBorrow(
            donorNft,
            perturbShares,
            result.borrowed0,
            result.borrowed1,
            result.mintedShares,
            result.slot2Before,
            result.slot2After,
            result.slot4Before,
            result.slot4After
        );
    }

    function _combined(uint256 targetNft, uint256 donorNft, uint256 perturbShares)
        internal
        returns (PerturbResult memory perturbResult, CloseResult memory closeResult)
    {
        _freshFork();
        IVaultExactResidual.ConstantViews memory c = _constants();
        perturbResult = _perturb(c, donorNft, perturbShares);
        closeResult = _fullClose(c, targetNft);
    }

    function _assertSame(PerturbResult memory a, PerturbResult memory b) internal pure {
        require(a.borrowed0 == b.borrowed0, "different perturb token0");
        require(a.borrowed1 == b.borrowed1, "different perturb token1");
        require(a.mintedShares == b.mintedShares, "different perturb shares");
        require(a.returned0 == b.returned0, "different perturb return0");
        require(a.returned1 == b.returned1, "different perturb return1");
        require(a.slot2Before == b.slot2Before, "different slot2 before");
        require(a.slot2After == b.slot2After, "different slot2 after");
        require(a.slot4Before == b.slot4Before, "different slot4 before");
        require(a.slot4After == b.slot4After, "different slot4 after");
    }

    function _probe(uint256 targetNft, uint256 donorNft, uint256 perturbShares) internal {
        assertTrue(targetNft != donorNft, "target equals donor");
        CloseResult memory baseline = _baseline(targetNft);
        PerturbResult memory perturbOnly = _perturbOnly(donorNft, perturbShares);
        (PerturbResult memory combinedPerturb, CloseResult memory combinedClose) =
            _combined(targetNft, donorNft, perturbShares);

        _assertSame(perturbOnly, combinedPerturb);
        assertEq(combinedClose.burnedShares, baseline.burnedShares, "target shares changed");

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

        assertEq(residual0, -closeCostDelta0, "token0 residual algebra mismatch");
        assertEq(residual1, -closeCostDelta1, "token1 residual algebra mismatch");

        emit FeasibleCase(
            targetNft,
            donorNft,
            perturbShares,
            baseline.spent0,
            baseline.spent1,
            combinedClose.spent0,
            combinedClose.spent1,
            residual0,
            residual1,
            closeCostDelta0,
            closeCostDelta1
        );
    }

    function test_feasibleOneSidedBorrowLiquidation() public {
        IVaultExactResidual.ConstantViews memory c = _constants();
        emit FeasibleDeposit(
            block.number,
            VAULT,
            c.factory,
            c.borrow,
            c.borrowToken.token0,
            c.borrowToken.token1
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
