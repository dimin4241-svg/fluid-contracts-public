// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.21;

import {PlasmaVaultT4LiquidationSurfaceProbeTest} from "./PlasmaVaultT4LiquidationSurfaceProbe.t.sol";

interface IERC20OneSidedBorrow {
    function balanceOf(address account) external view returns (uint256);
}

interface IVaultOneSidedBorrow {
    function operate(
        uint256 nftId,
        int256 newColToken0,
        int256 newColToken1,
        int256 colSharesMinMax,
        int256 newDebtToken0,
        int256 newDebtToken1,
        int256 debtSharesMinMax,
        address to
    ) external payable returns (uint256,int256,int256);
    function readFromStorage(bytes32 slot) external view returns (uint256);
}

interface IFactoryOneSidedBorrow {
    function owner() external view returns (address);
    function ownerOf(uint256 nftId) external view returns (address);
}

interface IOracleOneSidedBorrow {
    function getExchangeRateLiquidate() external view returns (uint256);
}

contract PlasmaVaultT4OneSidedBorrowLiquidationTest is PlasmaVaultT4LiquidationSurfaceProbeTest {
    address internal constant ORACLE = 0x029E6fF2173ff6c9e61787Fa7A3cfF1117D957b6;
    address internal constant BORROWER = 0x111111111111111111111111111111111111B077;
    uint256 internal constant COL_GHO = 20_000_000e18;
    uint256 internal constant COL_USDT0 = 20_000_000e6;

    event OneSidedCaseReachability(
        bool indexed borrowGho,
        uint256 requestedAmount1e18,
        bool success,
        bytes4 revertSelector,
        bytes32 revertHash,
        uint256 revertLength
    );

    event OneSidedDepositControl(
        bool indexed borrowGho,
        uint256 requestedAmount1e18,
        uint256 indexed nftId,
        int256 collateralSharesMinted,
        uint256 oracleBefore,
        uint256 oracleAfterDeposit,
        int256 oracleDepositDelta,
        int256 oracleDepositDeltaPpm,
        int256 topTickAfterDeposit,
        bytes4 simulationSelector,
        uint256 simulationErrorId,
        bool liquidatable
    );

    event OneSidedBorrowFlow(
        bool indexed borrowGho,
        uint256 requestedAmount1e18,
        uint256 indexed nftId,
        int256 debtSharesMinted,
        uint256 receivedGho,
        uint256 receivedUsdt0,
        uint256 oracleAfterDeposit,
        uint256 oracleAfterBorrow,
        int256 oracleBorrowDelta,
        int256 oracleBorrowDeltaPpm,
        int256 topTickAfterBorrow
    );

    event OneSidedLiquidationResult(
        bool indexed borrowGho,
        uint256 requestedAmount1e18,
        uint256 indexed nftId,
        bytes4 selector,
        bool expectedResult,
        uint256 colLiquidated,
        uint256 debtLiquidated,
        uint256 errorId,
        bytes32 revertHash,
        bool eligibilityChanged
    );

    function _approveBorrower(address token) internal {
        vm.prank(BORROWER);
        (bool ok, bytes memory data) = token.call(
            abi.encodeWithSignature("approve(address,uint256)", VAULT, type(uint256).max)
        );
        require(ok && (data.length == 0 || abi.decode(data, (bool))), "approve failed");
    }

    function _vaultTopTick() internal returns (int256 tick) {
        vm.prank(IFactoryOneSidedBorrow(FACTORY).owner());
        uint256 variables = IVaultOneSidedBorrow(VAULT).readFromStorage(bytes32(uint256(0)));
        uint256 magnitude = (variables >> 3) & ((1 << 19) - 1);
        tick = (variables & 4) == 4 ? int256(magnitude) : -int256(magnitude);
    }

    function executeOneSidedCase(bool borrowGho, uint256 requestedAmount1e18) external {
        require(msg.sender == address(this), "self only");

        deal(GHO, BORROWER, COL_GHO);
        deal(USDT0, BORROWER, COL_USDT0);
        _approveBorrower(GHO);
        _approveBorrower(USDT0);

        uint256 oracleBefore = IOracleOneSidedBorrow(ORACLE).getExchangeRateLiquidate();
        vm.prank(BORROWER);
        (uint256 nftId, int256 colShares, int256 initialDebtShares) =
            IVaultOneSidedBorrow(VAULT).operate(
                0,
                int256(COL_GHO),
                int256(COL_USDT0),
                1,
                0,
                0,
                0,
                BORROWER
            );
        require(initialDebtShares == 0, "unexpected initial debt");
        require(IFactoryOneSidedBorrow(FACTORY).ownerOf(nftId) == BORROWER, "new NFT owner mismatch");

        uint256 oracleAfterDeposit = IOracleOneSidedBorrow(ORACLE).getExchangeRateLiquidate();
        Simulation memory depositSimulation = _simulate(false);
        int256 depositDelta = _delta(oracleAfterDeposit, oracleBefore);
        emit OneSidedDepositControl(
            borrowGho,
            requestedAmount1e18,
            nftId,
            colShares,
            oracleBefore,
            oracleAfterDeposit,
            depositDelta,
            depositDelta * int256(1e6) / int256(oracleBefore),
            _vaultTopTick(),
            depositSimulation.selector,
            depositSimulation.errorId,
            depositSimulation.expectedResult
        );

        uint256 ghoBefore = IERC20OneSidedBorrow(GHO).balanceOf(BORROWER);
        uint256 usdt0Before = IERC20OneSidedBorrow(USDT0).balanceOf(BORROWER);
        int256 debt0 = borrowGho ? int256(requestedAmount1e18) : int256(0);
        int256 debt1 = borrowGho ? int256(0) : int256(requestedAmount1e18 / 1e12);

        vm.prank(BORROWER);
        (, int256 noColShares, int256 debtShares) = IVaultOneSidedBorrow(VAULT).operate(
            nftId,
            0,
            0,
            0,
            debt0,
            debt1,
            1,
            BORROWER
        );
        require(noColShares == 0 && debtShares > 0, "unexpected borrow result");

        uint256 receivedGho = IERC20OneSidedBorrow(GHO).balanceOf(BORROWER) - ghoBefore;
        uint256 receivedUsdt0 = IERC20OneSidedBorrow(USDT0).balanceOf(BORROWER) - usdt0Before;
        uint256 oracleAfterBorrow = IOracleOneSidedBorrow(ORACLE).getExchangeRateLiquidate();
        int256 borrowDelta = _delta(oracleAfterBorrow, oracleAfterDeposit);
        emit OneSidedBorrowFlow(
            borrowGho,
            requestedAmount1e18,
            nftId,
            debtShares,
            receivedGho,
            receivedUsdt0,
            oracleAfterDeposit,
            oracleAfterBorrow,
            borrowDelta,
            borrowDelta * int256(1e6) / int256(oracleAfterDeposit),
            _vaultTopTick()
        );

        Simulation memory afterBorrow = _simulate(false);
        emit OneSidedLiquidationResult(
            borrowGho,
            requestedAmount1e18,
            nftId,
            afterBorrow.selector,
            afterBorrow.expectedResult,
            afterBorrow.colLiquidated,
            afterBorrow.debtLiquidated,
            afterBorrow.errorId,
            afterBorrow.revertHash,
            depositSimulation.expectedResult != afterBorrow.expectedResult
        );
    }

    function test_oneSidedBorrowLiquidationReachability() public {
        uint256[4] memory sizes = [
            uint256(100_000e18),
            uint256(500_000e18),
            uint256(1_000_000e18),
            uint256(2_000_000e18)
        ];

        for (uint256 direction; direction < 2; ++direction) {
            bool borrowGho = direction == 0;
            for (uint256 i; i < sizes.length; ++i) {
                vm.createSelectFork(rpcUrl, forkBlock);
                (bool ok, bytes memory reason) = address(this).call(
                    abi.encodeCall(this.executeOneSidedCase, (borrowGho, sizes[i]))
                );
                emit OneSidedCaseReachability(
                    borrowGho,
                    sizes[i],
                    ok,
                    ok ? bytes4(0) : _selector(reason),
                    ok ? bytes32(0) : keccak256(reason),
                    ok ? 0 : reason.length
                );
            }
        }
    }
}
