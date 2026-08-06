// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.21;

import {Test} from "forge-std/Test.sol";

interface IERC20OracleShift {
    function balanceOf(address account) external view returns (uint256);
}

interface IFactoryOracleShift {
    function ownerOf(uint256 nftId) external view returns (address);
}

interface IVaultOracleShift {
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
}

interface IOracleShift {
    function getExchangeRateOperate() external view returns (uint256);
    function getExchangeRateLiquidate() external view returns (uint256);
}

contract PlasmaVaultT4DebtOracleShiftTest is Test {
    address internal constant FACTORY = 0x324c5Dc1fC42c7a4D43d92df1eBA58a54d13Bf2d;
    address internal constant VAULT = 0x6E0cDB09eb33cD3894C905E0DFF9289b95a86FFF;
    address internal constant ORACLE = 0x029E6fF2173ff6c9e61787Fa7A3cfF1117D957b6;
    address internal constant GHO = 0xb77E872A68C62CfC0dFb02C067Ecc3DA23B4bbf3;
    address internal constant USDT0 = 0xB8CE59FC3717ada4C02eaDF9682A9e934F625ebb;
    uint256 internal constant NFT = 2887;
    uint256 internal constant SHARES_PER_ROUND = 1e20;
    uint256 internal constant FUNDING = 1e28;
    int256 internal constant MAX_USDT_PAYMENT = -1e24;

    string internal rpcUrl;
    uint256 internal forkBlock;

    event OracleShiftResult(
        uint256 rounds,
        uint256 operateBefore,
        uint256 operateAfter,
        int256 operateDelta,
        int256 operateDeltaPpb,
        uint256 liquidateBefore,
        uint256 liquidateAfter,
        int256 liquidateDelta,
        int256 liquidateDeltaPpb,
        int256 ghoDelta,
        int256 usdtDelta,
        int256 nominalDelta1e18,
        uint256 gasUsed
    );

    function setUp() public {
        rpcUrl = vm.envString("PLASMA_RPC_URL");
        forkBlock = vm.envUint("PLASMA_FORK_BLOCK");
        vm.createSelectFork(rpcUrl, forkBlock);
        assertEq(block.chainid, 9745, "unexpected chain");
    }

    function _approve(address token, address spender) internal {
        (bool ok, bytes memory data) = token.call(
            abi.encodeWithSignature("approve(address,uint256)", spender, type(uint256).max)
        );
        require(ok && (data.length == 0 || abi.decode(data, (bool))), "APPROVE_FAILED");
    }

    function _delta(uint256 after_, uint256 before_) internal pure returns (int256) {
        return after_ >= before_ ? int256(after_ - before_) : -int256(before_ - after_);
    }

    function _ppb(int256 delta_, uint256 base_) internal pure returns (int256) {
        if (delta_ >= 0) return int256((uint256(delta_) * 1e9) / base_);
        return -int256((uint256(-delta_) * 1e9) / base_);
    }

    function _prepare() internal returns (address owner) {
        vm.createSelectFork(rpcUrl, forkBlock);
        owner = IFactoryOracleShift(FACTORY).ownerOf(NFT);
        deal(GHO, owner, FUNDING, true);
        deal(USDT0, owner, FUNDING, true);
        vm.startPrank(owner);
        _approve(GHO, VAULT);
        _approve(USDT0, VAULT);
        vm.stopPrank();
    }

    function _cycle(address owner) internal {
        vm.prank(owner);
        IVaultOracleShift(VAULT).operatePerfect(
            NFT,
            0,
            0,
            0,
            -int256(SHARES_PER_ROUND),
            0,
            MAX_USDT_PAYMENT,
            owner
        );
        vm.prank(owner);
        IVaultOracleShift(VAULT).operatePerfect(
            NFT,
            0,
            0,
            0,
            int256(SHARES_PER_ROUND),
            1,
            1,
            owner
        );
    }

    function _run(uint256 rounds) internal {
        address owner = _prepare();
        uint256 ghoBefore = IERC20OracleShift(GHO).balanceOf(owner);
        uint256 usdtBefore = IERC20OracleShift(USDT0).balanceOf(owner);
        uint256 operateBefore = IOracleShift(ORACLE).getExchangeRateOperate();
        uint256 liquidateBefore = IOracleShift(ORACLE).getExchangeRateLiquidate();
        uint256 gasBefore = gasleft();

        for (uint256 i; i < rounds; ++i) _cycle(owner);

        uint256 gasUsed = gasBefore - gasleft();
        uint256 operateAfter = IOracleShift(ORACLE).getExchangeRateOperate();
        uint256 liquidateAfter = IOracleShift(ORACLE).getExchangeRateLiquidate();
        int256 operateDelta = _delta(operateAfter, operateBefore);
        int256 liquidateDelta = _delta(liquidateAfter, liquidateBefore);
        int256 ghoDelta = _delta(IERC20OracleShift(GHO).balanceOf(owner), ghoBefore);
        int256 usdtDelta = _delta(IERC20OracleShift(USDT0).balanceOf(owner), usdtBefore);

        emit OracleShiftResult(
            rounds,
            operateBefore,
            operateAfter,
            operateDelta,
            _ppb(operateDelta, operateBefore),
            liquidateBefore,
            liquidateAfter,
            liquidateDelta,
            _ppb(liquidateDelta, liquidateBefore),
            ghoDelta,
            usdtDelta,
            ghoDelta + usdtDelta * 1e12,
            gasUsed
        );
    }

    function test_measureDebtCompositionOracleShift() public {
        _run(1);
        _run(10);
        _run(100);
    }
}
