// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.21;

import {Test} from "forge-std/Test.sol";

interface IERC20PaybackIsolated {
    function approve(address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

interface IDexPaybackIsolated {
    function payback(uint256, uint256, uint256, bool) external payable returns (uint256);
    function readFromStorage(bytes32) external view returns (uint256);
}

interface IOraclePaybackIsolated {
    function getExchangeRateLiquidate() external view returns (uint256);
}

contract PlasmaOneSidedBorrowIsolatedTest is Test {
    address constant VAULT = 0x6E0cDB09eb33cD3894C905E0DFF9289b95a86FFF;
    address constant DEX = 0x080574D224E960c272e005aA03EFbe793f317640;
    address constant ORACLE = 0x029E6fF2173ff6c9e61787Fa7A3cfF1117D957b6;
    address constant GHO = 0xb77E872A68C62CfC0dFb02C067Ecc3DA23B4bbf3;
    address constant USDT0 = 0xB8CE59FC3717ada4C02eaDF9682A9e934F625ebb;
    address constant PAYER = 0x333333333333333333333333333333333333CAFE;

    bytes4 constant LIQ_RESULT = bytes4(keccak256("FluidLiquidateResult(uint256,uint256)"));
    bytes4 constant VAULT_ERROR = bytes4(keccak256("FluidVaultError(uint256)"));

    string rpcUrl;
    uint256 forkBlock;

    struct Sim {
        bytes4 selector;
        bool liquidatable;
        uint256 colShares;
        uint256 debtShares;
        uint256 errorId;
    }

    event IsolatedReachability(
        bool indexed payGho,
        uint256 requested1e18,
        bool success,
        bytes4 selector,
        uint256 errorId,
        bytes32 revertHash
    );

    event IsolatedBorrow(
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
        bytes4 simulationSelectorAfter,
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
        assembly ("memory-safe") { value := mload(add(data, 0x20)) }
    }

    function _word(bytes memory data, uint256 index) internal pure returns (uint256 value) {
        require(data.length >= 4 + (index + 1) * 32, "short data");
        assembly ("memory-safe") { value := mload(add(add(data, 0x24), mul(index, 0x20))) }
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

    function _shares() internal view returns (uint256) {
        return IDexPaybackIsolated(DEX).readFromStorage(bytes32(uint256(4))) & type(uint128).max;
    }

    function _simulate() internal returns (Sim memory result) {
        (bool ok, bytes memory data) = VAULT.call(
            abi.encodeWithSignature("simulateLiquidate(uint256,bool)", type(uint256).max, false)
        );
        require(!ok, "simulation returned");
        result.selector = _selector(data);
        if (result.selector == LIQ_RESULT && data.length >= 68) {
            result.liquidatable = true;
            result.colShares = _word(data, 0);
            result.debtShares = _word(data, 1);
        } else if (result.selector == VAULT_ERROR && data.length >= 36) {
            result.errorId = _word(data, 0);
        }
    }

    function executeCase(bool payGho, uint256 requested1e18) external {
        require(msg.sender == address(this), "self only");
        uint256 amount0 = payGho ? requested1e18 : 0;
        uint256 amount1 = payGho ? 0 : requested1e18 / 1e12;

        deal(GHO, PAYER, amount0 + 10e18);
        deal(USDT0, PAYER, amount1 + 10e6);
        vm.startPrank(PAYER);
        IERC20PaybackIsolated(GHO).approve(VAULT, type(uint256).max);
        IERC20PaybackIsolated(USDT0).approve(VAULT, type(uint256).max);
        vm.stopPrank();

        Sim memory beforePayback = _simulate();
        uint256 oracleBefore = IOraclePaybackIsolated(ORACLE).getExchangeRateLiquidate();
        uint256 sharesBefore = _shares();
        uint256 ghoBefore = IERC20PaybackIsolated(GHO).balanceOf(PAYER);
        uint256 usdtBefore = IERC20PaybackIsolated(USDT0).balanceOf(PAYER);

        bytes32 oldVaultVariables = vm.load(VAULT, bytes32(uint256(0)));
        bytes32 oldDexFrom = vm.load(VAULT, bytes32(uint256(11)));
        vm.store(VAULT, bytes32(uint256(0)), bytes32(uint256(oldVaultVariables) | 1));
        vm.store(VAULT, bytes32(uint256(11)), bytes32(uint256(uint160(PAYER))));

        vm.prank(VAULT);
        uint256 sharesBurned = IDexPaybackIsolated(DEX).payback(amount0, amount1, 0, false);
        uint256 oracleAfter = IOraclePaybackIsolated(ORACLE).getExchangeRateLiquidate();
        uint256 sharesAfter = _shares();

        vm.store(VAULT, bytes32(uint256(0)), oldVaultVariables);
        vm.store(VAULT, bytes32(uint256(11)), oldDexFrom);
        require(sharesBefore - sharesAfter == sharesBurned, "share mismatch");

        Sim memory afterPayback = _simulate();
        emit IsolatedBorrow(
            payGho,
            requested1e18,
            sharesBurned,
            ghoBefore - IERC20PaybackIsolated(GHO).balanceOf(PAYER),
            usdtBefore - IERC20PaybackIsolated(USDT0).balanceOf(PAYER),
            sharesBefore,
            sharesAfter,
            oracleBefore,
            oracleAfter,
            _deltaPpm(oracleAfter, oracleBefore),
            beforePayback.liquidatable,
            afterPayback.liquidatable,
            afterPayback.selector,
            afterPayback.errorId,
            afterPayback.colShares,
            afterPayback.debtShares,
            beforePayback.liquidatable != afterPayback.liquidatable
        );
    }

    function test_oneSidedBorrowIsolated() public {
        uint256[8] memory gho = [
            uint256(1_000e18), 10_000e18, 50_000e18, 100_000e18,
            200_000e18, 300_000e18, 400_000e18, 500_000e18
        ];
        uint256[8] memory usdt = [
            uint256(1_000e18), 10_000e18, 100_000e18, 250_000e18,
            500_000e18, 1_000_000e18, 1_500_000e18, 2_000_000e18
        ];

        for (uint256 direction; direction < 2; ++direction) {
            bool payGho = direction == 0;
            for (uint256 i; i < 8; ++i) {
                vm.createSelectFork(rpcUrl, forkBlock);
                uint256 amount = payGho ? gho[i] : usdt[i];
                (bool ok, bytes memory reason) = address(this).call(
                    abi.encodeCall(this.executeCase, (payGho, amount))
                );
                emit IsolatedReachability(
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
