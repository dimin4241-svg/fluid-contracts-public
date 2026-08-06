// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.21;

import {Test} from "forge-std/Test.sol";

interface IERC20DebtProbe {
    function balanceOf(address account) external view returns (uint256);
}

interface IPlasmaVaultFactoryDebtProbe {
    function owner() external view returns (address);
    function ownerOf(uint256 nftId) external view returns (address);
}

interface IPlasmaVaultT4DebtProbe {
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

contract PlasmaVaultT4DebtShareInteractionTest is Test {
    address internal constant FACTORY = 0x324c5Dc1fC42c7a4D43d92df1eBA58a54d13Bf2d;
    address internal constant VAULT = 0x6E0cDB09eb33cD3894C905E0DFF9289b95a86FFF;
    address internal constant SMART_DEBT_DEX = 0x080574D224E960c272e005aA03EFbe793f317640;
    address internal constant TOKEN0 = 0xb77E872A68C62CfC0dFb02C067Ecc3DA23B4bbf3;
    address internal constant TOKEN1 = 0xB8CE59FC3717ada4C02eaDF9682A9e934F625ebb;

    uint256 internal constant VAULT_POSITION_DATA_SLOT = 3;
    uint256 internal constant REPAY_FUNDING = 1e24;
    int256 internal constant REPAY_LIMIT = -1e24;

    string internal rpcUrl;
    uint256 internal forkBlock;

    struct CloseResult {
        uint256 spent0;
        uint256 spent1;
        int256 returnedDebtShares;
        int256 returnedDebt0;
        int256 returnedDebt1;
        uint256 positionDataAfter;
    }

    struct PerturbResult {
        uint256 borrowed0;
        uint256 borrowed1;
        int256 returnedDebtShares;
        int256 returnedDebt0;
        int256 returnedDebt1;
    }

    event ProbeMetadata(
        uint256 forkBlock,
        address indexed vault,
        address indexed smartDebtDex,
        address token0,
        address token1
    );

    event CloseScenario(
        uint256 indexed targetNft,
        uint256 indexed donorNft,
        uint256 perturbShares,
        bool perturbed,
        uint256 spent0,
        uint256 spent1,
        int256 returnedDebtShares,
        int256 returnedDebt0,
        int256 returnedDebt1,
        uint256 positionDataAfter
    );

    event DebtShareInteraction(
        uint256 indexed targetNft,
        uint256 indexed donorNft,
        uint256 perturbShares,
        uint256 perturbBorrowed0,
        uint256 perturbBorrowed1,
        uint256 baselineSpent0,
        uint256 baselineSpent1,
        uint256 combinedSpent0,
        uint256 combinedSpent1,
        int256 interaction0,
        int256 interaction1
    );

    function setUp() public {
        rpcUrl = vm.envString("PLASMA_RPC_URL");
        forkBlock = vm.envUint("PLASMA_FORK_BLOCK");
        vm.createSelectFork(rpcUrl, forkBlock);
        assertEq(block.chainid, 9745, "unexpected chain");
        assertGt(VAULT.code.length, 0, "missing live vault");
        assertGt(SMART_DEBT_DEX.code.length, 0, "missing live debt DEX");
    }

    function _safeApprove(address token, address spender, uint256 amount) internal {
        (bool ok, bytes memory data) = token.call(
            abi.encodeWithSignature("approve(address,uint256)", spender, amount)
        );
        require(ok && (data.length == 0 || abi.decode(data, (bool))), "APPROVE_FAILED");
    }

    function _signedDelta(uint256 after_, uint256 before_) internal pure returns (int256) {
        if (after_ >= before_) return int256(after_ - before_);
        return -int256(before_ - after_);
    }

    function _readPositionData(uint256 nftId) internal returns (uint256 positionData) {
        address factoryOwner = IPlasmaVaultFactoryDebtProbe(FACTORY).owner();
        vm.prank(factoryOwner);
        positionData = IPlasmaVaultT4DebtProbe(VAULT).readFromStorage(
            keccak256(abi.encode(nftId, VAULT_POSITION_DATA_SLOT))
        );
    }

    function _prepareRepayer(uint256 nftId) internal returns (address positionOwner) {
        positionOwner = IPlasmaVaultFactoryDebtProbe(FACTORY).ownerOf(nftId);
        assertTrue(positionOwner != address(0), "missing position owner");
        deal(TOKEN0, positionOwner, REPAY_FUNDING, true);
        deal(TOKEN1, positionOwner, REPAY_FUNDING, true);
        vm.startPrank(positionOwner);
        _safeApprove(TOKEN0, VAULT, type(uint256).max);
        _safeApprove(TOKEN1, VAULT, type(uint256).max);
        vm.stopPrank();
    }

    function _fullPayback(uint256 nftId) internal returns (CloseResult memory result) {
        address positionOwner = _prepareRepayer(nftId);
        uint256 balance0Before = IERC20DebtProbe(TOKEN0).balanceOf(positionOwner);
        uint256 balance1Before = IERC20DebtProbe(TOKEN1).balanceOf(positionOwner);

        vm.prank(positionOwner);
        (, int256[] memory r) = IPlasmaVaultT4DebtProbe(VAULT).operatePerfect(
            nftId,
            0,
            0,
            0,
            type(int256).min,
            REPAY_LIMIT,
            REPAY_LIMIT,
            positionOwner
        );

        assertEq(r.length, 6, "unexpected operatePerfect return length");
        result.spent0 = balance0Before - IERC20DebtProbe(TOKEN0).balanceOf(positionOwner);
        result.spent1 = balance1Before - IERC20DebtProbe(TOKEN1).balanceOf(positionOwner);
        result.returnedDebtShares = r[3];
        result.returnedDebt0 = r[4];
        result.returnedDebt1 = r[5];
        result.positionDataAfter = _readPositionData(nftId);

        assertEq(result.positionDataAfter & 1, 1, "target still has debt after max payback");
        assertLt(result.returnedDebtShares, 0, "max payback did not burn debt shares");
        assertEq(uint256(-result.returnedDebt0), result.spent0, "token0 spend mismatch");
        assertEq(uint256(-result.returnedDebt1), result.spent1, "token1 spend mismatch");
    }

    function _borrowPerfect(uint256 donorNft, uint256 perfectDebtShares)
        internal
        returns (PerturbResult memory result)
    {
        address donorOwner = IPlasmaVaultFactoryDebtProbe(FACTORY).ownerOf(donorNft);
        assertTrue(donorOwner != address(0), "missing donor owner");
        uint256 balance0Before = IERC20DebtProbe(TOKEN0).balanceOf(donorOwner);
        uint256 balance1Before = IERC20DebtProbe(TOKEN1).balanceOf(donorOwner);

        vm.prank(donorOwner);
        (, int256[] memory r) = IPlasmaVaultT4DebtProbe(VAULT).operatePerfect(
            donorNft,
            0,
            0,
            0,
            int256(perfectDebtShares),
            1,
            1,
            donorOwner
        );

        assertEq(r.length, 6, "unexpected perturb return length");
        result.borrowed0 = IERC20DebtProbe(TOKEN0).balanceOf(donorOwner) - balance0Before;
        result.borrowed1 = IERC20DebtProbe(TOKEN1).balanceOf(donorOwner) - balance1Before;
        result.returnedDebtShares = r[3];
        result.returnedDebt0 = r[4];
        result.returnedDebt1 = r[5];

        assertEq(uint256(result.returnedDebtShares), perfectDebtShares, "unexpected shares minted");
        assertEq(uint256(result.returnedDebt0), result.borrowed0, "token0 borrow mismatch");
        assertEq(uint256(result.returnedDebt1), result.borrowed1, "token1 borrow mismatch");
        assertGt(result.borrowed0, 0, "zero token0 perturb");
        assertGt(result.borrowed1, 0, "zero token1 perturb");
    }

    function _runBaseline(uint256 targetNft, uint256 donorNft, uint256 perturbShares)
        internal
        returns (CloseResult memory baseline)
    {
        vm.createSelectFork(rpcUrl, forkBlock);
        baseline = _fullPayback(targetNft);
        emit CloseScenario(
            targetNft,
            donorNft,
            perturbShares,
            false,
            baseline.spent0,
            baseline.spent1,
            baseline.returnedDebtShares,
            baseline.returnedDebt0,
            baseline.returnedDebt1,
            baseline.positionDataAfter
        );
    }

    function _runCombined(uint256 targetNft, uint256 donorNft, uint256 perturbShares)
        internal
        returns (PerturbResult memory perturb, CloseResult memory combined)
    {
        vm.createSelectFork(rpcUrl, forkBlock);
        perturb = _borrowPerfect(donorNft, perturbShares);
        combined = _fullPayback(targetNft);
        emit CloseScenario(
            targetNft,
            donorNft,
            perturbShares,
            true,
            combined.spent0,
            combined.spent1,
            combined.returnedDebtShares,
            combined.returnedDebt0,
            combined.returnedDebt1,
            combined.positionDataAfter
        );
    }

    function _probe(uint256 targetNft, uint256 donorNft, uint256 perturbShares) internal {
        assertTrue(targetNft != donorNft, "target equals donor");
        CloseResult memory baseline = _runBaseline(targetNft, donorNft, perturbShares);
        (PerturbResult memory perturb, CloseResult memory combined) =
            _runCombined(targetNft, donorNft, perturbShares);

        emit DebtShareInteraction(
            targetNft,
            donorNft,
            perturbShares,
            perturb.borrowed0,
            perturb.borrowed1,
            baseline.spent0,
            baseline.spent1,
            combined.spent0,
            combined.spent1,
            _signedDelta(combined.spent0, baseline.spent0),
            _signedDelta(combined.spent1, baseline.spent1)
        );
    }

    function test_liveDebtShareInteraction() public {
        emit ProbeMetadata(block.number, VAULT, SMART_DEBT_DEX, TOKEN0, TOKEN1);

        uint256[4] memory targets = [uint256(2864), uint256(1871), uint256(2770), uint256(2887)];
        uint256[3] memory perturbSizes = [uint256(1e18), uint256(1e19), uint256(1e20)];

        for (uint256 i; i < targets.length; ++i) {
            uint256 donorNft = targets[i] == 2887 ? 2770 : 2887;
            for (uint256 j; j < perturbSizes.length; ++j) {
                _probe(targets[i], donorNft, perturbSizes[j]);
            }
        }
    }
}
