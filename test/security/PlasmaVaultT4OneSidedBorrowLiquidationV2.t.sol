// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.21;

import "./PlasmaVaultT4OneSidedBorrowLiquidation.t.sol";

contract PlasmaVaultT4OneSidedBorrowLiquidationV2Test is PlasmaVaultT4OneSidedBorrowLiquidationTest {
    uint256 internal constant FEASIBLE_COL_GHO = 2_000_000e18;
    uint256 internal constant FEASIBLE_COL_USDT0 = 2_000_000e6;

    event FeasibleCase(
        bool indexed borrowGho,
        uint256 requestedAmount1e18,
        bool success,
        bytes4 revertSelector,
        uint256 errorId,
        bytes32 revertHash
    );
    event FeasibleDeposit(
        bool indexed borrowGho,
        uint256 requestedAmount1e18,
        uint256 indexed nftId,
        int256 collateralShares,
        uint256 oracleBefore,
        uint256 oracleAfter,
        int256 oracleDeltaPpm,
        int256 topTick,
        bool liquidatableBeforeBorrow
    );
    event FeasibleBorrow(
        bool indexed borrowGho,
        uint256 requestedAmount1e18,
        uint256 indexed nftId,
        int256 debtShares,
        uint256 receivedGho,
        uint256 receivedUsdt0,
        uint256 oracleBefore,
        uint256 oracleAfter,
        int256 oracleDeltaPpm,
        int256 topTick
    );
    event FeasibleLiquidation(
        bool indexed borrowGho,
        uint256 requestedAmount1e18,
        uint256 indexed nftId,
        bytes4 selector,
        bool expectedResult,
        uint256 colLiquidated,
        uint256 debtLiquidated,
        uint256 errorId,
        bool eligibilityChanged
    );

    function _errorIdLocal(bytes memory data) internal pure returns (uint256 value) {
        if (data.length < 36) return 0;
        assembly ("memory-safe") { value := mload(add(data, 0x24)) }
    }

    function executeFeasibleCase(bool borrowGho, uint256 requestedAmount1e18) external {
        require(msg.sender == address(this), "self only");
        deal(GHO, BORROWER, FEASIBLE_COL_GHO);
        deal(USDT0, BORROWER, FEASIBLE_COL_USDT0);
        _approveBorrower(GHO);
        _approveBorrower(USDT0);

        uint256 oracleBeforeDeposit = IOracleOneSidedBorrow(ORACLE).getExchangeRateLiquidate();
        vm.prank(BORROWER);
        (uint256 nftId, int256 colShares, int256 initialDebtShares) = IVaultOneSidedBorrow(VAULT).operate(
            0,
            int256(FEASIBLE_COL_GHO),
            int256(FEASIBLE_COL_USDT0),
            1,
            0,
            0,
            0,
            BORROWER
        );
        require(initialDebtShares == 0, "initial debt");
        uint256 oracleAfterDeposit = IOracleOneSidedBorrow(ORACLE).getExchangeRateLiquidate();
        Simulation memory beforeBorrow = _simulate(false);
        emit FeasibleDeposit(
            borrowGho,
            requestedAmount1e18,
            nftId,
            colShares,
            oracleBeforeDeposit,
            oracleAfterDeposit,
            _delta(oracleAfterDeposit, oracleBeforeDeposit) * int256(1e6) / int256(oracleBeforeDeposit),
            _vaultTopTick(),
            beforeBorrow.expectedResult
        );

        uint256 ghoBefore = IERC20OneSidedBorrow(GHO).balanceOf(BORROWER);
        uint256 usdtBefore = IERC20OneSidedBorrow(USDT0).balanceOf(BORROWER);
        vm.prank(BORROWER);
        (, int256 noColShares, int256 debtShares) = IVaultOneSidedBorrow(VAULT).operate(
            nftId,
            0,
            0,
            0,
            borrowGho ? int256(requestedAmount1e18) : int256(0),
            borrowGho ? int256(0) : int256(requestedAmount1e18 / 1e12),
            1,
            BORROWER
        );
        require(noColShares == 0 && debtShares > 0, "borrow failed");
        uint256 oracleAfterBorrow = IOracleOneSidedBorrow(ORACLE).getExchangeRateLiquidate();
        emit FeasibleBorrow(
            borrowGho,
            requestedAmount1e18,
            nftId,
            debtShares,
            IERC20OneSidedBorrow(GHO).balanceOf(BORROWER) - ghoBefore,
            IERC20OneSidedBorrow(USDT0).balanceOf(BORROWER) - usdtBefore,
            oracleAfterDeposit,
            oracleAfterBorrow,
            _delta(oracleAfterBorrow, oracleAfterDeposit) * int256(1e6) / int256(oracleAfterDeposit),
            _vaultTopTick()
        );
        Simulation memory afterBorrow = _simulate(false);
        emit FeasibleLiquidation(
            borrowGho,
            requestedAmount1e18,
            nftId,
            afterBorrow.selector,
            afterBorrow.expectedResult,
            afterBorrow.colLiquidated,
            afterBorrow.debtLiquidated,
            afterBorrow.errorId,
            beforeBorrow.expectedResult != afterBorrow.expectedResult
        );
    }

    function test_feasibleOneSidedBorrowLiquidation() public {
        uint256[4] memory sizes = [
            uint256(100_000e18),
            uint256(500_000e18),
            uint256(1_000_000e18),
            uint256(1_500_000e18)
        ];
        for (uint256 direction; direction < 2; ++direction) {
            bool borrowGho = direction == 0;
            for (uint256 i; i < sizes.length; ++i) {
                vm.createSelectFork(rpcUrl, forkBlock);
                (bool ok, bytes memory reason) = address(this).call(
                    abi.encodeCall(this.executeFeasibleCase, (borrowGho, sizes[i]))
                );
                emit FeasibleCase(
                    borrowGho,
                    sizes[i],
                    ok,
                    ok ? bytes4(0) : _selector(reason),
                    ok ? 0 : _errorIdLocal(reason),
                    ok ? bytes32(0) : keccak256(reason)
                );
            }
        }
    }
}
