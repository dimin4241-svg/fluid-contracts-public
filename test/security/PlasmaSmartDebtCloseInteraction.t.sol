// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.21;

import {Test} from "forge-std/Test.sol";
import {IFluidVault} from "../../contracts/protocols/vault/interfaces/iVault.sol";
import {IFluidVaultT4} from "../../contracts/protocols/vault/interfaces/iVaultT4.sol";

interface IERC20SmartDebtProbe {
    function balanceOf(address account) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function decimals() external view returns (uint8);
}

interface IERC721OwnerProbe {
    function ownerOf(uint256 tokenId) external view returns (address);
}

interface IFluidDexProbe {
    function readFromStorage(bytes32 slot) external view returns (uint256);
}

interface IFluidSmartLendingProbe {
    function DEX() external view returns (address);
    function TOKEN0() external view returns (address);
    function TOKEN1() external view returns (address);
    function deposit(uint256 token0Amt, uint256 token1Amt, uint256 minSharesAmt, address to)
        external
        payable
        returns (uint256 amount, uint256 shares);
}

contract PlasmaSmartDebtCloseInteractionTest is Test {
    address internal constant VAULT = 0x6E0cDB5C21B3C8E340e9C9210057035BAFA86FFF;
    address internal constant DEX = 0xbd5Dd095d9a6565C8222Bb36b5814953f1C46f71;

    // The two deployed Plasma fSL contracts present in the live Fluid registry.
    // The test selects fSL6 by requiring fSL.DEX() == the pinned DEX address.
    address internal constant FSL_CANDIDATE_A = 0x983107BB3dcb71f3A30176114D8a17c454A62514;
    address internal constant FSL_CANDIDATE_B = 0x4f0C96408aF08473051Ea3EA1FF3e4F288115A5A;

    uint256 internal constant MAX_TOKEN_FUNDING = 1e30;
    int256 internal constant MAX_PAYBACK = 1e24;

    uint256[] internal nftIds;
    address internal token0;
    address internal token1;
    address internal factory;
    address internal fsl6;

    struct CloseResult {
        uint256 shares;
        uint256 token0Cost;
        uint256 token1Cost;
    }

    struct ScenarioResult {
        uint256 estimateBefore0;
        uint256 estimateBefore1;
        uint256 estimateAfter0;
        uint256 estimateAfter1;
        uint256 combinedCost0;
        uint256 combinedCost1;
        int256 expectedDelta0;
        int256 expectedDelta1;
        int256 actualDelta0;
        int256 actualDelta1;
        int256 residual0;
        int256 residual1;
    }

    event DeploymentProof(
        uint256 forkBlock,
        uint256 chainId,
        address vault,
        address dex,
        address factory,
        address token0,
        address token1,
        address fsl6,
        uint8 token0Decimals,
        uint8 token1Decimals
    );

    event BaselineClose(
        uint256 indexed nftId,
        address indexed owner,
        uint256 debtShares,
        uint256 token0Cost,
        uint256 token1Cost,
        uint256 estimatorToken0,
        uint256 estimatorToken1,
        int256 estimatorResidual0,
        int256 estimatorResidual1
    );

    event InteractionProof(
        uint256 indexed nftId,
        uint8 indexed mode,
        uint256 perturbAmount,
        uint256 fslSharesMinted,
        uint256 debtShares,
        uint256 baselineCost0,
        uint256 baselineCost1,
        int256 perturbOnlyDelta0,
        int256 perturbOnlyDelta1,
        int256 combinedCloseDelta0,
        int256 combinedCloseDelta1,
        int256 interactionResidual0,
        int256 interactionResidual1,
        uint256 totalBorrowSharesPackedBefore,
        uint256 totalBorrowSharesPackedAfter
    );

    event MaximumResidual(uint256 maxAbsResidual0, uint256 maxAbsResidual1);

    function setUp() public {
        uint256 forkBlock = vm.envOr("PLASMA_FORK_BLOCK", uint256(12_386_164));
        vm.createSelectFork(vm.envString("PLASMA_RPC_URL"), forkBlock);

        assertEq(block.chainid, 9745, "unexpected chain");
        assertGt(VAULT.code.length, 0, "vault missing");
        assertGt(DEX.code.length, 0, "dex missing");

        IFluidVault.ConstantViews memory c = IFluidVault(VAULT).constantsView();
        assertEq(c.borrow, DEX, "vault is not connected to pinned DEX");
        assertEq(c.vaultType, 4, "not Vault T4");

        token0 = c.borrowToken.token0;
        token1 = c.borrowToken.token1;
        factory = c.factory;
        fsl6 = _discoverFsl6();

        assertEq(IFluidSmartLendingProbe(fsl6).TOKEN0(), token0, "fSL token0 mismatch");
        assertEq(IFluidSmartLendingProbe(fsl6).TOKEN1(), token1, "fSL token1 mismatch");
        assertEq(IERC20SmartDebtProbe(token0).decimals(), 6, "unexpected token0 decimals");
        assertEq(IERC20SmartDebtProbe(token1).decimals(), 6, "unexpected token1 decimals");

        nftIds.push(2770);
        nftIds.push(2887);
        nftIds.push(2869);
        nftIds.push(2725);

        emit DeploymentProof(
            block.number,
            block.chainid,
            VAULT,
            DEX,
            factory,
            token0,
            token1,
            fsl6,
            IERC20SmartDebtProbe(token0).decimals(),
            IERC20SmartDebtProbe(token1).decimals()
        );
    }

    function test_threeControlSmartDebtCloseInteraction() public {
        uint256 maxResidual0;
        uint256 maxResidual1;
        uint256[2] memory amounts = [uint256(1_000e6), uint256(10_000e6)];

        for (uint256 n; n < nftIds.length; ++n) {
            uint256 nftId = nftIds[n];

            uint256 baselineSnapshot = vm.snapshot();
            CloseResult memory baseline = _closePosition(nftId);
            assertTrue(vm.revertTo(baselineSnapshot), "baseline revert failed");

            (uint256 estimateBefore0, uint256 estimateBefore1) = _estimatePerfectPayback(baseline.shares);
            int256 baseEstimatorResidual0 = int256(baseline.token0Cost) - int256(estimateBefore0);
            int256 baseEstimatorResidual1 = int256(baseline.token1Cost) - int256(estimateBefore1);

            emit BaselineClose(
                nftId,
                IERC721OwnerProbe(factory).ownerOf(nftId),
                baseline.shares,
                baseline.token0Cost,
                baseline.token1Cost,
                estimateBefore0,
                estimateBefore1,
                baseEstimatorResidual0,
                baseEstimatorResidual1
            );

            // Baseline Vault close and direct DEX estimator should agree exactly or differ
            // only by the final per-token integer rounding boundary.
            assertLe(_abs(baseEstimatorResidual0), 2, "baseline token0 estimator mismatch");
            assertLe(_abs(baseEstimatorResidual1), 2, "baseline token1 estimator mismatch");

            for (uint8 mode; mode < 3; ++mode) {
                for (uint256 a; a < amounts.length; ++a) {
                    uint256 amount = amounts[a];
                    uint256 packedBefore = IFluidDexProbe(DEX).readFromStorage(bytes32(uint256(4)));

                    uint256 perturbOnlySnapshot = vm.snapshot();
                    uint256 mintedShares = _perturb(mode, amount);
                    (uint256 estimateAfter0, uint256 estimateAfter1) = _estimatePerfectPayback(baseline.shares);
                    uint256 packedAfter = IFluidDexProbe(DEX).readFromStorage(bytes32(uint256(4)));
                    assertTrue(vm.revertTo(perturbOnlySnapshot), "perturb-only revert failed");

                    uint256 combinedSnapshot = vm.snapshot();
                    uint256 mintedSharesCombined = _perturb(mode, amount);
                    CloseResult memory combined = _closePosition(nftId);
                    assertEq(mintedSharesCombined, mintedShares, "perturbation is not deterministic");
                    assertEq(combined.shares, baseline.shares, "position debt shares changed");
                    assertTrue(vm.revertTo(combinedSnapshot), "combined revert failed");

                    ScenarioResult memory s;
                    s.estimateBefore0 = estimateBefore0;
                    s.estimateBefore1 = estimateBefore1;
                    s.estimateAfter0 = estimateAfter0;
                    s.estimateAfter1 = estimateAfter1;
                    s.combinedCost0 = combined.token0Cost;
                    s.combinedCost1 = combined.token1Cost;
                    s.expectedDelta0 = int256(estimateAfter0) - int256(estimateBefore0);
                    s.expectedDelta1 = int256(estimateAfter1) - int256(estimateBefore1);
                    s.actualDelta0 = int256(combined.token0Cost) - int256(baseline.token0Cost);
                    s.actualDelta1 = int256(combined.token1Cost) - int256(baseline.token1Cost);
                    s.residual0 = s.actualDelta0 - s.expectedDelta0;
                    s.residual1 = s.actualDelta1 - s.expectedDelta1;

                    uint256 abs0 = _abs(s.residual0);
                    uint256 abs1 = _abs(s.residual1);
                    if (abs0 > maxResidual0) maxResidual0 = abs0;
                    if (abs1 > maxResidual1) maxResidual1 = abs1;

                    emit InteractionProof(
                        nftId,
                        mode,
                        amount,
                        mintedShares,
                        baseline.shares,
                        baseline.token0Cost,
                        baseline.token1Cost,
                        s.expectedDelta0,
                        s.expectedDelta1,
                        s.actualDelta0,
                        s.actualDelta1,
                        s.residual0,
                        s.residual1,
                        packedBefore,
                        packedAfter
                    );
                }
            }
        }

        emit MaximumResidual(maxResidual0, maxResidual1);
    }

    function _discoverFsl6() internal view returns (address) {
        if (_fslDex(FSL_CANDIDATE_A) == DEX) return FSL_CANDIDATE_A;
        if (_fslDex(FSL_CANDIDATE_B) == DEX) return FSL_CANDIDATE_B;
        revert("fSL6 not found");
    }

    function _fslDex(address candidate) internal view returns (address result) {
        if (candidate.code.length == 0) return address(0);
        (bool ok, bytes memory data) = candidate.staticcall(abi.encodeWithSignature("DEX()"));
        if (!ok || data.length != 32) return address(0);
        result = abi.decode(data, (address));
    }

    function _perturb(uint8 mode, uint256 amount) internal returns (uint256 sharesMinted) {
        address actor = address(uint160(uint256(keccak256(abi.encode("perturber", mode, amount)))));
        uint256 amount0 = mode == 0 || mode == 2 ? amount : 0;
        uint256 amount1 = mode == 1 || mode == 2 ? amount : 0;

        deal(token0, actor, amount0 + 1e12);
        deal(token1, actor, amount1 + 1e12);

        vm.startPrank(actor);
        _approve(token0, fsl6);
        _approve(token1, fsl6);
        (, sharesMinted) = IFluidSmartLendingProbe(fsl6).deposit(amount0, amount1, 0, actor);
        vm.stopPrank();

        assertGt(sharesMinted, 0, "zero perturbation shares");
    }

    function _closePosition(uint256 nftId) internal returns (CloseResult memory result) {
        address owner = IERC721OwnerProbe(factory).ownerOf(nftId);

        deal(token0, owner, MAX_TOKEN_FUNDING);
        deal(token1, owner, MAX_TOKEN_FUNDING);

        vm.startPrank(owner);
        _approve(token0, VAULT);
        _approve(token1, VAULT);

        uint256 before0 = IERC20SmartDebtProbe(token0).balanceOf(owner);
        uint256 before1 = IERC20SmartDebtProbe(token1).balanceOf(owner);

        (, int256[] memory r) = IFluidVaultT4(VAULT).operatePerfect(
            nftId,
            0,
            0,
            0,
            type(int256).min,
            -MAX_PAYBACK,
            -MAX_PAYBACK,
            owner
        );

        uint256 after0 = IERC20SmartDebtProbe(token0).balanceOf(owner);
        uint256 after1 = IERC20SmartDebtProbe(token1).balanceOf(owner);
        vm.stopPrank();

        assertEq(r.length, 6, "unexpected operatePerfect return length");
        assertLt(r[3], 0, "no debt shares burned");
        assertLt(r[4], 0, "no token0 payback");
        assertLt(r[5], 0, "no token1 payback");

        result.shares = uint256(-r[3]);
        result.token0Cost = before0 - after0;
        result.token1Cost = before1 - after1;

        assertEq(result.token0Cost, uint256(-r[4]), "token0 balance/return mismatch");
        assertEq(result.token1Cost, uint256(-r[5]), "token1 balance/return mismatch");
    }

    function _estimatePerfectPayback(uint256 shares) internal returns (uint256 token0Amt, uint256 token1Amt) {
        (bool ok, bytes memory data) = DEX.call(
            abi.encodeWithSignature(
                "paybackPerfect(uint256,uint256,uint256,bool)",
                shares,
                type(uint256).max,
                type(uint256).max,
                true
            )
        );
        assertFalse(ok, "estimate unexpectedly succeeded");
        require(data.length >= 68, "short estimate revert");
        assembly {
            token0Amt := mload(add(data, 36))
            token1Amt := mload(add(data, 68))
        }
    }

    function _approve(address token, address spender) internal {
        (bool ok, bytes memory data) = token.call(
            abi.encodeWithSelector(IERC20SmartDebtProbe.approve.selector, spender, type(uint256).max)
        );
        require(ok && (data.length == 0 || abi.decode(data, (bool))), "approve failed");
    }

    function _abs(int256 value) internal pure returns (uint256) {
        return value < 0 ? uint256(-value) : uint256(value);
    }
}
