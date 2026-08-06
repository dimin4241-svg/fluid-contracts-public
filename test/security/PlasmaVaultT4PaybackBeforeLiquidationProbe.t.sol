// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.21;

import {Test} from "forge-std/Test.sol";

interface IERC20PaybackProbe {
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

interface IDexDebtPaybackProbe {
    function payback(
        uint256 token0Amt,
        uint256 token1Amt,
        uint256 minSharesAmt,
        bool estimate
    ) external payable returns (uint256 sharesBurned);

    function readFromStorage(bytes32 slot) external view returns (uint256);
}

interface IOraclePaybackProbe {
    function getExchangeRateLiquidate() external view returns (uint256);
}

contract PlasmaVaultT4PaybackBeforeLiquidationProbeTest is Test {
    address constant VAULT = 0x6E0cDB09eb33cD3894C905E0DFF9289b95a86FFF;
    address constant DEX = 0x080574D224E960c272e005aA03EFbe793f317640;
    address constant ORACLE = 0x029E6fF2173ff6c9e61787Fa7A3cfF1117D957b6;
    address constant GHO = 0xb77E872A68C62CfC0dFb02C067Ecc3DA23B4bbf3;
    address constant USDT0 = 0xB8CE59FC3717ada4C02eaDF9682A9e934F625ebb;
    address constant PAYER = 0x333333333333333333333333333333333333CAFE;

    uint256 constant VAULT_VARIABLES_SLOT = 0;
    uint256 constant DEX_FROM_ADDRESS_SLOT = 11;
    uint256 constant DEX_TOTAL_BORROW_SHARES_SLOT = 4;

    bytes4 constant LIQ_RESULT = bytes4(keccak256("FluidLiquidateResult(uint256,uint256)"));
    bytes4 constant VAULT_ERROR = bytes4(keccak256("FluidVaultError(uint256)"));

    string internal rpcUrl;
    uint256 internal forkBlock;

    struct Simulation {
        bytes4 selector;
        bool liquidatable;
        uint256 collateralShares;
        uint256 debtShares;
        uint256 errorId;
    }

    event PaybackProbeCase(
        bool indexed payGho,
        uint256 requested1e18,
        bool success,
        bytes4 revertSelector,
        uint256 errorId,
        bytes32 revertHash
    );

    event PaybackOracleMovement(
        bool indexed payGho,
        uint256 requested1e18,
        uint256 sharesBurned,
        uint256 token0Spent,
        uint256 token1Spent,
        uint256 totalSharesBefore,
        uint256 totalSharesAfter,
        uint256 oracleBefore,
        uint256 oracleAfter,
        int256 oracleDeltaPpm,
        bool liquidatableBefore,
        bool liquidatableAfter,
        bytes4 simulationSelectorBefore,
        bytes4 simulationSelectorAfter,
        uint256 simulationErrorBefore,
        uint256 simulationErrorAfter,
        uint256 collateralSharesAfter,
        uint256 debtSharesAfter,
        bool eligibilityChanged
    );

    function setUp() public {
        rpcUrl = vm.envString("PLASMA_RPC_URL");
        forkBlock = vm.envUint("PLASMA_FORK_BLOCK");
        vm.createSelectFork(rpcUrl, forkBlock);
        assertEq(block.chainid, 9745);
        assertEq(block.number, forkBlock);
        assertGt(VAULT.code.length, 0);
        assertGt(DEX.code.length, 0);
    }

    function _selector(bytes memory data) internal pure returns (bytes4 value) {
        if (data.length < 4) return bytes4(0);
        assembly ("memory-safe") {
            value := mload(add(data, 0x20))
        }
    }

    function _word(bytes memory data, uint256 index) internal pure returns (uint256 value) {
        require(data.length >= 4 + (index + 1) * 32, "short revert data");
        assembly ("memory-safe") {
            value := mload(add(add(data, 0x24), mul(index, 0x20)))
        }
    }

    function _errorId(bytes memory data) internal pure returns (uint256) {
        return data.length >= 36 ? _word(data, 0) : 0;
    }

    function _deltaPpm(uint256 afterValue, uint256 beforeValue) internal pure returns (int256) {
        int256 delta = afterValue >= beforeValue
            ? int256(afterValue - beforeValue)
            : -int256(beforeValue - afterValue);
        return delta * int256(1e6) / int256(beforeValue);
    }

    function _totalBorrowShares() internal view returns (uint256) {
        return IDexDebtPaybackProbe(DEX).readFromStorage(bytes32(DEX_TOTAL_BORROW_SHARES_SLOT)) & type(uint128).max;
    }

    function _simulate() internal returns (Simulation memory result) {
        (bool ok, bytes memory data) = VAULT.call(
            abi.encodeWithSignature("simulateLiquidate(uint256,bool)", type(uint256).max, false)
        );
        require(!ok, "simulateLiquidate returned normally");
        result.selector = _selector(data);
        if (result.selector == LIQ_RESULT && data.length >= 68) {
            result.liquidatable = true;
            result.collateralShares = _word(data, 0);
            result.debtShares = _word(data, 1);
        } else if (result.selector == VAULT_ERROR && data.length >= 36) {
            result.errorId = _word(data, 0);
        }
    }

    function _prepareVaultCallback() internal returns (bytes32 oldVaultVariables, bytes32 oldDexFrom) {
        oldVaultVariables = vm.load(VAULT, bytes32(VAULT_VARIABLES_SLOT));
        oldDexFrom = vm.load(VAULT, bytes32(DEX_FROM_ADDRESS_SLOT));
        vm.store(
            VAULT,
            bytes32(VAULT_VARIABLES_SLOT),
            bytes32(uint256(oldVaultVariables) | uint256(1))
        );
        vm.store(
            VAULT,
            bytes32(DEX_FROM_ADDRESS_SLOT),
            bytes32(uint256(uint160(PAYER)))
        );
    }

    function _restoreVaultCallback(bytes32 oldVaultVariables, bytes32 oldDexFrom) internal {
        vm.store(VAULT, bytes32(VAULT_VARIABLES_SLOT), oldVaultVariables);
        vm.store(VAULT, bytes32(DEX_FROM_ADDRESS_SLOT), oldDexFrom);
    }

    function executeCase(bool payGho, uint256 requested1e18) external {
        require(msg.sender == address(this), "self only");

        uint256 token0Amount = payGho ? requested1e18 : 0;
        uint256 token1Amount = payGho ? 0 : requested1e18 / 1e12;

        deal(GHO, PAYER, token0Amount + 10e18);
        deal(USDT0, PAYER, token1Amount + 10e6);
        vm.startPrank(PAYER);
        IERC20PaybackProbe(GHO).approve(VAULT, type(uint256).max);
        IERC20PaybackProbe(USDT0).approve(VAULT, type(uint256).max);
        vm.stopPrank();

        Simulation memory beforePayback = _simulate();
        uint256 oracleBefore = IOraclePaybackProbe(ORACLE).getExchangeRateLiquidate();
        uint256 sharesBefore = _totalBorrowShares();
        uint256 payerGhoBefore = IERC20PaybackProbe(GHO).balanceOf(PAYER);
        uint256 payerUsdtBefore = IERC20PaybackProbe(USDT0).balanceOf(PAYER);

        (bytes32 oldVaultVariables, bytes32 oldDexFrom) = _prepareVaultCallback();
        vm.prank(VAULT);
        uint256 sharesBurned = IDexDebtPaybackProbe(DEX).payback(
            token0Amount,
            token1Amount,
            0,
            false
        );
        uint256 oracleAfter = IOraclePaybackProbe(ORACLE).getExchangeRateLiquidate();
        uint256 sharesAfter = _totalBorrowShares();
        _restoreVaultCallback(oldVaultVariables, oldDexFrom);

        require(sharesBefore - sharesAfter == sharesBurned, "share delta mismatch");
        Simulation memory afterPayback = _simulate();

        emit PaybackOracleMovement(
            payGho,
            requested1e18,
            sharesBurned,
            payerGhoBefore - IERC20PaybackProbe(GHO).balanceOf(PAYER),
            payerUsdtBefore - IERC20PaybackProbe(USDT0).balanceOf(PAYER),
            sharesBefore,
            sharesAfter,
            oracleBefore,
            oracleAfter,
            _deltaPpm(oracleAfter, oracleBefore),
            beforePayback.liquidatable,
            afterPayback.liquidatable,
            beforePayback.selector,
            afterPayback.selector,
            beforePayback.errorId,
            afterPayback.errorId,
            afterPayback.collateralShares,
            afterPayback.debtShares,
            beforePayback.liquidatable != afterPayback.liquidatable
        );
    }

    function test_paybackBeforeLiquidationOracleOrdering() public {
        uint256[8] memory ghoSizes = [
            uint256(1_000e18),
            uint256(10_000e18),
            uint256(50_000e18),
            uint256(100_000e18),
            uint256(200_000e18),
            uint256(300_000e18),
            uint256(400_000e18),
            uint256(500_000e18)
        ];
        uint256[8] memory usdtSizes = [
            uint256(1_000e18),
            uint256(10_000e18),
            uint256(100_000e18),
            uint256(250_000e18),
            uint256(500_000e18),
            uint256(1_000_000e18),
            uint256(1_500_000e18),
            uint256(2_000_000e18)
        ];

        for (uint256 direction; direction < 2; ++direction) {
            bool payGho = direction == 0;
            for (uint256 i; i < 8; ++i) {
                vm.createSelectFork(rpcUrl, forkBlock);
                uint256 amount = payGho ? ghoSizes[i] : usdtSizes[i];
                (bool ok, bytes memory reason) = address(this).call(
                    abi.encodeCall(this.executeCase, (payGho, amount))
                );
                emit PaybackProbeCase(
                    payGho,
                    amount,
                    ok,
                    ok ? bytes4(0) : _selector(reason),
                    ok ? 0 : _errorId(reason),
                    ok ? bytes32(0) : keccak256(reason)
                );
            }
        }
    }
}
