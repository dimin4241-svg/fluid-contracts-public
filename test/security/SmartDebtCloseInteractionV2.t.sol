// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.21;

import {Test} from "forge-std/Test.sol";

interface IVaultViewsV2 {
    struct Tokens { address token0; address token1; }
    struct Constants {
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
    function constantsView() external view returns (Constants memory);
}

interface IVaultT4OperateV2 {
    function operatePerfect(
        uint256 nftId,
        int256 perfectColShares,
        int256 colToken0MinMax,
        int256 colToken1MinMax,
        int256 perfectDebtShares,
        int256 debtToken0MinMax,
        int256 debtToken1MinMax,
        address to
    ) external payable returns (uint256 nftIdResult, int256[] memory results);
}

interface IERC20V2 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function decimals() external view returns (uint8);
}

interface IERC721OwnerV2 { function ownerOf(uint256) external view returns (address); }
interface IDexStorageV2 { function readFromStorage(bytes32) external view returns (uint256); }

interface ISmartLendingV2 {
    function DEX() external view returns (address);
    function TOKEN0() external view returns (address);
    function TOKEN1() external view returns (address);
    function deposit(uint256, uint256, uint256, address)
        external payable returns (uint256 amount, uint256 shares);
}

contract SmartDebtCloseInteractionV2Test is Test {
    bytes4 internal constant PERFECT_OUTPUT = bytes4(keccak256("FluidDexPerfectLiquidityOutput(uint256,uint256)"));
    uint256 internal constant BORROW_SHARES_SLOT = 4;
    uint256 internal constant FUNDING = 1e30;
    int256 internal constant MAX_PAYBACK = 1e24;

    address internal vault;
    address internal dex;
    address internal factory;
    address internal token0;
    address internal token1;
    address internal fsl;

    uint256 internal maxResidual0;
    uint256 internal maxResidual1;

    struct CloseResult {
        uint256 shares;
        uint256 cost0;
        uint256 cost1;
    }

    event DeploymentProof(
        uint256 chainId,
        uint256 forkBlock,
        address vault,
        address dex,
        address factory,
        address token0,
        address token1,
        address fsl,
        uint256 vaultId
    );

    event BaselineProof(
        uint256 indexed nftId,
        address indexed owner,
        uint256 shares,
        uint256 close0,
        uint256 close1,
        uint256 estimate0,
        uint256 estimate1,
        int256 residual0,
        int256 residual1
    );

    event PerturbControl(
        uint256 indexed nftId,
        uint8 indexed mode,
        uint256 amount,
        uint256 fslShares,
        uint256 debtShares,
        uint256 totalBorrowSharesBefore,
        uint256 totalBorrowSharesAfter
    );

    event InteractionProof(
        uint256 indexed nftId,
        uint8 indexed mode,
        uint256 amount,
        int256 expectedDelta0,
        int256 expectedDelta1,
        int256 actualDelta0,
        int256 actualDelta1,
        int256 residual0,
        int256 residual1
    );

    event MaximumResidual(uint256 token0BaseUnits, uint256 token1BaseUnits);

    function setUp() public {
        uint256 forkBlock = vm.envUint("FORK_BLOCK");
        string memory rpc = vm.envString("RPC_URL");
        uint256 expectedChain = vm.envUint("EXPECTED_CHAIN_ID");

        vault = vm.envAddress("TARGET_VAULT");
        dex = vm.envAddress("TARGET_DEX");

        vm.createSelectFork(rpc, forkBlock);
        assertEq(block.chainid, expectedChain, "wrong chain");
        assertGt(vault.code.length, 0, "vault has no code");
        assertGt(dex.code.length, 0, "dex has no code");

        IVaultViewsV2.Constants memory c = IVaultViewsV2(vault).constantsView();
        assertEq(c.borrow, dex, "vault borrow source != target DEX");
        assertEq(c.vaultType, 4, "target is not Vault T4");

        factory = c.factory;
        token0 = c.borrowToken.token0;
        token1 = c.borrowToken.token1;
        fsl = _discoverFsl(vm.envAddress("FSL_CANDIDATE_A"), vm.envAddress("FSL_CANDIDATE_B"));

        assertEq(ISmartLendingV2(fsl).TOKEN0(), token0, "fSL token0 mismatch");
        assertEq(ISmartLendingV2(fsl).TOKEN1(), token1, "fSL token1 mismatch");
        assertEq(IERC20V2(token0).decimals(), 6, "token0 must be 6 decimals");
        assertEq(IERC20V2(token1).decimals(), 6, "token1 must be 6 decimals");

        emit DeploymentProof(
            block.chainid, block.number, vault, dex, factory, token0, token1, fsl, c.vaultId
        );
    }

    function test_threeControlInteractionMatrix() public {
        _runNft(2770);
        _runNft(2887);
        _runNft(2869);
        _runNft(2725);
        emit MaximumResidual(maxResidual0, maxResidual1);
    }

    function _runNft(uint256 nftId) internal {
        uint256 snapshot = vm.snapshot();
        CloseResult memory baseline = _close(nftId);
        assertTrue(vm.revertTo(snapshot), "baseline state restore failed");

        (uint256 estimate0, uint256 estimate1) = _estimate(baseline.shares);
        int256 baseResidual0 = int256(baseline.cost0) - int256(estimate0);
        int256 baseResidual1 = int256(baseline.cost1) - int256(estimate1);

        emit BaselineProof(
            nftId,
            IERC721OwnerV2(factory).ownerOf(nftId),
            baseline.shares,
            baseline.cost0,
            baseline.cost1,
            estimate0,
            estimate1,
            baseResidual0,
            baseResidual1
        );

        assertLe(_abs(baseResidual0), 2, "token0 baseline estimator mismatch");
        assertLe(_abs(baseResidual1), 2, "token1 baseline estimator mismatch");

        _runAmountSet(nftId, baseline, estimate0, estimate1, 0);
        _runAmountSet(nftId, baseline, estimate0, estimate1, 1);
        _runAmountSet(nftId, baseline, estimate0, estimate1, 2);
    }

    function _runAmountSet(
        uint256 nftId,
        CloseResult memory baseline,
        uint256 estimate0,
        uint256 estimate1,
        uint8 mode
    ) internal {
        _runScenario(nftId, baseline, estimate0, estimate1, mode, 1_000e6);
        _runScenario(nftId, baseline, estimate0, estimate1, mode, 10_000e6);
    }

    function _runScenario(
        uint256 nftId,
        CloseResult memory baseline,
        uint256 estimateBefore0,
        uint256 estimateBefore1,
        uint8 mode,
        uint256 amount
    ) internal {
        uint256 packedBefore = IDexStorageV2(dex).readFromStorage(bytes32(BORROW_SHARES_SLOT));

        uint256 perturbSnapshot = vm.snapshot();
        uint256 minted = _perturb(mode, amount);
        (uint256 estimateAfter0, uint256 estimateAfter1) = _estimate(baseline.shares);
        uint256 packedAfter = IDexStorageV2(dex).readFromStorage(bytes32(BORROW_SHARES_SLOT));
        assertTrue(vm.revertTo(perturbSnapshot), "perturb state restore failed");

        uint256 combinedSnapshot = vm.snapshot();
        uint256 mintedAgain = _perturb(mode, amount);
        CloseResult memory combined = _close(nftId);
        assertTrue(vm.revertTo(combinedSnapshot), "combined state restore failed");

        assertEq(mintedAgain, minted, "perturbation not deterministic");
        assertEq(combined.shares, baseline.shares, "NFT debt shares changed");

        emit PerturbControl(
            nftId,
            mode,
            amount,
            minted,
            baseline.shares,
            packedBefore & type(uint128).max,
            packedAfter & type(uint128).max
        );

        int256 expected0 = int256(estimateAfter0) - int256(estimateBefore0);
        int256 expected1 = int256(estimateAfter1) - int256(estimateBefore1);
        int256 actual0 = int256(combined.cost0) - int256(baseline.cost0);
        int256 actual1 = int256(combined.cost1) - int256(baseline.cost1);
        int256 residual0 = actual0 - expected0;
        int256 residual1 = actual1 - expected1;

        _recordResidual(residual0, residual1);
        emit InteractionProof(
            nftId, mode, amount, expected0, expected1, actual0, actual1, residual0, residual1
        );
    }

    function _close(uint256 nftId) internal returns (CloseResult memory out) {
        address owner = IERC721OwnerV2(factory).ownerOf(nftId);
        deal(token0, owner, FUNDING);
        deal(token1, owner, FUNDING);

        vm.startPrank(owner);
        _approve(token0, vault);
        _approve(token1, vault);
        uint256 before0 = IERC20V2(token0).balanceOf(owner);
        uint256 before1 = IERC20V2(token1).balanceOf(owner);

        (, int256[] memory result) = IVaultT4OperateV2(vault).operatePerfect(
            nftId,
            0,
            0,
            0,
            type(int256).min,
            -MAX_PAYBACK,
            -MAX_PAYBACK,
            owner
        );

        uint256 after0 = IERC20V2(token0).balanceOf(owner);
        uint256 after1 = IERC20V2(token1).balanceOf(owner);
        vm.stopPrank();

        assertEq(result.length, 6, "unexpected Vault result length");
        assertLt(result[3], 0, "zero debt shares burned");
        assertLt(result[4], 0, "zero token0 repaid");
        assertLt(result[5], 0, "zero token1 repaid");

        out.shares = uint256(-result[3]);
        out.cost0 = before0 - after0;
        out.cost1 = before1 - after1;
        assertLe(_distance(out.cost0, uint256(-result[4])), 2, "token0 return/balance mismatch");
        assertLe(_distance(out.cost1, uint256(-result[5])), 2, "token1 return/balance mismatch");
    }

    function _perturb(uint8 mode, uint256 amount) internal returns (uint256 shares) {
        address actor = address(uint160(uint256(keccak256(abi.encode(mode, amount, "smart-debt")))));
        uint256 amount0 = mode == 0 || mode == 2 ? amount : 0;
        uint256 amount1 = mode == 1 || mode == 2 ? amount : 0;

        deal(token0, actor, amount0 + 1e12);
        deal(token1, actor, amount1 + 1e12);
        vm.startPrank(actor);
        _approve(token0, fsl);
        _approve(token1, fsl);
        (, shares) = ISmartLendingV2(fsl).deposit(amount0, amount1, 0, actor);
        vm.stopPrank();
        assertGt(shares, 0, "perturb minted zero fSL shares");
    }

    function _estimate(uint256 shares) internal returns (uint256 amount0, uint256 amount1) {
        (bool ok, bytes memory data) = dex.call(
            abi.encodeWithSignature(
                "paybackPerfect(uint256,uint256,uint256,bool)",
                shares,
                type(uint256).max,
                type(uint256).max,
                true
            )
        );
        assertFalse(ok, "estimate call did not revert");
        require(data.length >= 68, "short estimator revert");

        bytes4 selector;
        assembly ("memory-safe") {
            selector := mload(add(data, 0x20))
            amount0 := mload(add(data, 0x24))
            amount1 := mload(add(data, 0x44))
        }
        assertEq(selector, PERFECT_OUTPUT, "unexpected estimator error");
    }

    function _discoverFsl(address a, address b) internal view returns (address) {
        if (_fslDex(a) == dex) return a;
        if (_fslDex(b) == dex) return b;
        revert("no candidate fSL points to target DEX");
    }

    function _fslDex(address candidate) internal view returns (address result) {
        if (candidate.code.length == 0) return address(0);
        (bool ok, bytes memory data) = candidate.staticcall(abi.encodeWithSignature("DEX()"));
        if (!ok || data.length != 32) return address(0);
        result = abi.decode(data, (address));
    }

    function _approve(address token, address spender) internal {
        (bool ok, bytes memory data) = token.call(
            abi.encodeWithSelector(IERC20V2.approve.selector, spender, type(uint256).max)
        );
        require(ok && (data.length == 0 || abi.decode(data, (bool))), "approve failed");
    }

    function _recordResidual(int256 residual0, int256 residual1) internal {
        uint256 abs0 = _abs(residual0);
        uint256 abs1 = _abs(residual1);
        if (abs0 > maxResidual0) maxResidual0 = abs0;
        if (abs1 > maxResidual1) maxResidual1 = abs1;
    }

    function _abs(int256 value) internal pure returns (uint256) {
        return value < 0 ? uint256(-value) : uint256(value);
    }

    function _distance(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a - b : b - a;
    }
}
