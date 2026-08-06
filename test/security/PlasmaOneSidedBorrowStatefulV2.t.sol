// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.21;

import {Test} from "forge-std/Test.sol";

interface IERC20StatefulV2 {
    function balanceOf(address) external view returns (uint256);
}

interface IFactoryStatefulV2 {
    function ownerOf(uint256) external view returns (address);
}

interface IVaultStatefulV2 {
    function operate(
        uint256,
        int256,
        int256,
        int256,
        int256,
        int256,
        int256,
        address
    ) external payable returns (uint256, int256, int256);
}

interface IOracleStatefulV2 {
    function getExchangeRateLiquidate() external view returns (uint256);
}

contract PlasmaOneSidedBorrowStatefulV2Test is Test {
    address constant FACTORY = 0x324c5Dc1fC42c7a4D43d92df1eBA58a54d13Bf2d;
    address constant VAULT = 0x6E0cDB09eb33cD3894C905E0DFF9289b95a86FFF;
    address constant ORACLE = 0x029E6fF2173ff6c9e61787Fa7A3cfF1117D957b6;
    address constant GHO = 0xb77E872A68C62CfC0dFb02C067Ecc3DA23B4bbf3;
    address constant USDT0 = 0xB8CE59FC3717ada4C02eaDF9682A9e934F625ebb;
    address constant BORROWER = 0x111111111111111111111111111111111111B077;

    uint256 constant COL_GHO = 2_000_000e18;
    uint256 constant COL_USDT0 = 2_000_000e6;

    bytes4 constant LIQ_RESULT = bytes4(keccak256("FluidLiquidateResult(uint256,uint256)"));
    bytes4 constant VAULT_ERROR = bytes4(keccak256("FluidVaultError(uint256)"));

    string rpcUrl;
    uint256 forkBlock;

    struct Sim {
        bytes4 selector;
        bool liquidatable;
        uint256 col;
        uint256 debt;
        uint256 errorId;
    }

    event StatefulReachability(
        bool indexed borrowGho,
        uint256 requested1e18,
        bool success,
        bytes4 selector,
        uint256 errorId,
        bytes32 revertHash
    );

    event StatefulBorrow(
        bool indexed borrowGho,
        uint256 requested1e18,
        uint256 indexed nftId,
        int256 colShares,
        int256 debtShares,
        uint256 receivedGho,
        uint256 receivedUsdt0,
        uint256 oracleAfterDeposit,
        uint256 oracleAfterBorrow,
        int256 oracleDeltaPpm,
        bool liquidatableBefore,
        bool liquidatableAfter,
        bytes4 simulationSelectorBefore,
        bytes4 simulationSelectorAfter,
        uint256 simulationErrorBefore,
        uint256 simulationErrorAfter,
        bool eligibilityChanged
    );

    function setUp() public {
        rpcUrl = vm.envString("PLASMA_RPC_URL");
        forkBlock = vm.envUint("PLASMA_FORK_BLOCK");
        vm.createSelectFork(rpcUrl, forkBlock);
        assertEq(block.chainid, 9745);
        assertGt(VAULT.code.length, 0);
    }

    function _selector(bytes memory data) internal pure returns (bytes4 value) {
        if (data.length < 4) return bytes4(0);
        assembly ("memory-safe") {
            value := mload(add(data, 0x20))
        }
    }

    function _word(bytes memory data, uint256 index) internal pure returns (uint256 value) {
        require(data.length >= 4 + (index + 1) * 32, "short data");
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

    function _approve(address token) internal {
        vm.prank(BORROWER);
        (bool ok, bytes memory data) = token.call(
            abi.encodeWithSignature("approve(address,uint256)", VAULT, type(uint256).max)
        );
        require(ok && (data.length == 0 || abi.decode(data, (bool))), "approve failed");
    }

    function _simulate() internal returns (Sim memory result) {
        (bool ok, bytes memory data) = VAULT.call(
            abi.encodeWithSignature("simulateLiquidate(uint256,bool)", type(uint256).max, false)
        );
        require(!ok, "simulation unexpectedly returned");
        result.selector = _selector(data);
        if (result.selector == LIQ_RESULT && data.length >= 68) {
            result.liquidatable = true;
            result.col = _word(data, 0);
            result.debt = _word(data, 1);
        } else if (result.selector == VAULT_ERROR && data.length >= 36) {
            result.errorId = _word(data, 0);
        }
    }

    function executeCase(bool borrowGho, uint256 requested1e18) external {
        require(msg.sender == address(this), "self only");

        deal(GHO, BORROWER, COL_GHO);
        deal(USDT0, BORROWER, COL_USDT0);
        _approve(GHO);
        _approve(USDT0);

        vm.prank(BORROWER);
        (uint256 nftId, int256 colShares, int256 initialDebtShares) = IVaultStatefulV2(VAULT).operate(
            0,
            int256(COL_GHO),
            int256(COL_USDT0),
            1,
            0,
            0,
            0,
            BORROWER
        );
        require(initialDebtShares == 0, "initial debt");
        require(IFactoryStatefulV2(FACTORY).ownerOf(nftId) == BORROWER, "owner mismatch");

        uint256 oracleAfterDeposit = IOracleStatefulV2(ORACLE).getExchangeRateLiquidate();
        Sim memory beforeBorrow = _simulate();
        uint256 ghoBefore = IERC20StatefulV2(GHO).balanceOf(BORROWER);
        uint256 usdtBefore = IERC20StatefulV2(USDT0).balanceOf(BORROWER);

        vm.prank(BORROWER);
        (, int256 noColShares, int256 debtShares) = IVaultStatefulV2(VAULT).operate(
            nftId,
            0,
            0,
            0,
            borrowGho ? int256(requested1e18) : int256(0),
            borrowGho ? int256(0) : int256(requested1e18 / 1e12),
            type(int256).max,
            BORROWER
        );
        require(noColShares == 0, "unexpected collateral change");
        require(debtShares > 0, "no debt shares");

        uint256 oracleAfterBorrow = IOracleStatefulV2(ORACLE).getExchangeRateLiquidate();
        Sim memory afterBorrow = _simulate();

        emit StatefulBorrow(
            borrowGho,
            requested1e18,
            nftId,
            colShares,
            debtShares,
            IERC20StatefulV2(GHO).balanceOf(BORROWER) - ghoBefore,
            IERC20StatefulV2(USDT0).balanceOf(BORROWER) - usdtBefore,
            oracleAfterDeposit,
            oracleAfterBorrow,
            _deltaPpm(oracleAfterBorrow, oracleAfterDeposit),
            beforeBorrow.liquidatable,
            afterBorrow.liquidatable,
            beforeBorrow.selector,
            afterBorrow.selector,
            beforeBorrow.errorId,
            afterBorrow.errorId,
            beforeBorrow.liquidatable != afterBorrow.liquidatable
        );
    }

    function test_oneSidedBorrowStatefulV2() public {
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
                    abi.encodeCall(this.executeCase, (borrowGho, sizes[i]))
                );
                emit StatefulReachability(
                    borrowGho,
                    sizes[i],
                    ok,
                    ok ? bytes4(0) : _selector(reason),
                    ok ? 0 : _errorId(reason),
                    ok ? bytes32(0) : keccak256(reason)
                );
                require(ok, "stateful case failed");
            }
        }
    }
}
