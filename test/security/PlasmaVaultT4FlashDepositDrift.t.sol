// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.21;

import {Test} from "forge-std/Test.sol";

interface IFluidVaultT4FlashDeposit {
    function operate(
        uint256 nftId,
        int256 newColToken0,
        int256 newColToken1,
        int256 colSharesMinMax,
        int256 newDebtToken0,
        int256 newDebtToken1,
        int256 debtSharesMinMax,
        address to
    ) external payable returns (uint256, int256, int256);

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

interface IFluidOracleFlashDeposit {
    function getExchangeRateLiquidate() external view returns (uint256);
}

interface IFluidVaultResolverFlashDeposit {
    struct LiquidationStruct {
        address vault;
        address token0In;
        address token0Out;
        address token1In;
        address token1Out;
        uint256 inAmt;
        uint256 outAmt;
        uint256 inAmtWithAbsorb;
        uint256 outAmtWithAbsorb;
        bool absorbAvailable;
    }

    function getVaultLiquidation(address vault, uint256 tokenInAmt)
        external returns (LiquidationStruct memory liquidationData);
}

contract PlasmaVaultT4FlashDepositDriftTest is Test {
    address internal constant VAULT = 0x6E0cDB09eb33cD3894C905E0DFF9289b95a86FFF;
    address internal constant RESOLVER = 0xA5C3E16523eeeDDcC34706b0E6bE88b4c6EA95cC;
    address internal constant ORACLE = 0x029E6fF2173ff6c9e61787Fa7A3cfF1117D957b6;
    address internal constant TOKEN0 = 0xb77E872A68C62CfC0dFb02C067Ecc3DA23B4bbf3;
    address internal constant TOKEN1 = 0xB8CE59FC3717ada4C02eaDF9682A9e934F625ebb;

    struct ProbeState {
        uint256 units0;
        uint256 units1;
        uint256 balance0Before;
        uint256 balance1Before;
        uint256 gasBefore;
        uint256 rateBefore;
        uint256 rateDuring;
        uint256 rateAfter;
        uint256 liquidationInBefore;
        uint256 liquidationInDuring;
        uint256 nftId;
        int256 colShares;
        int256 drift;
    }

    event DepositExecution(
        uint256 indexed units0,
        uint256 indexed units1,
        bool success,
        bytes4 revertSelector,
        uint256 nftId,
        int256 mintedColShares
    );

    event DepositImpact(
        uint256 indexed units0,
        uint256 indexed units1,
        uint256 rateBefore,
        uint256 rateDuring,
        int256 drift,
        uint256 absoluteDriftPpm,
        uint256 liquidationInBefore,
        uint256 liquidationInDuring
    );

    event DepositClose(
        uint256 indexed units0,
        uint256 indexed units1,
        bool success,
        bytes4 revertSelector,
        uint256 rateAfter,
        int256 token0Net,
        int256 token1Net,
        uint256 gasUsed
    );

    function setUp() public {
        vm.createSelectFork(vm.envString("PLASMA_RPC_URL"), vm.envUint("PLASMA_FORK_BLOCK"));
        assertEq(block.chainid, 9745, "unexpected chain");
        deal(TOKEN0, address(this), 100_000_000 * 1e18);
        deal(TOKEN1, address(this), 100_000_000 * 1e6);
        _approve(TOKEN0, VAULT);
        _approve(TOKEN1, VAULT);
    }

    function test_token0_100k() public { _probe(100_000, 0); }
    function test_token0_1m() public { _probe(1_000_000, 0); }
    function test_token0_5m() public { _probe(5_000_000, 0); }
    function test_token1_100k() public { _probe(0, 100_000); }
    function test_token1_1m() public { _probe(0, 1_000_000); }
    function test_token1_5m() public { _probe(0, 5_000_000); }
    function test_balanced_100k() public { _probe(100_000, 100_000); }
    function test_balanced_1m() public { _probe(1_000_000, 1_000_000); }
    function test_balanced_5m() public { _probe(5_000_000, 5_000_000); }

    function _probe(uint256 units0, uint256 units1) internal {
        ProbeState memory p;
        p.units0 = units0;
        p.units1 = units1;
        p.balance0Before = _balance(TOKEN0);
        p.balance1Before = _balance(TOKEN1);
        p.rateBefore = IFluidOracleFlashDeposit(ORACLE).getExchangeRateLiquidate();
        p.liquidationInBefore = _liquidationIn();
        p.gasBefore = gasleft();

        (bool depositOk, bytes memory depositData) = VAULT.call(
            abi.encodeWithSelector(
                IFluidVaultT4FlashDeposit.operate.selector,
                0,
                int256(units0 * 1e18),
                int256(units1 * 1e6),
                int256(1),
                int256(0),
                int256(0),
                int256(0),
                address(this)
            )
        );

        if (!depositOk || depositData.length < 96) {
            emit DepositExecution(units0, units1, false, _selector(depositData), 0, 0);
            emit DepositImpact(
                units0,
                units1,
                p.rateBefore,
                p.rateBefore,
                0,
                0,
                p.liquidationInBefore,
                p.liquidationInBefore
            );
            emit DepositClose(
                units0,
                units1,
                false,
                bytes4(0),
                p.rateBefore,
                0,
                0,
                p.gasBefore - gasleft()
            );
            return;
        }

        (p.nftId, p.colShares, ) = abi.decode(depositData, (uint256, int256, int256));
        emit DepositExecution(units0, units1, true, bytes4(0), p.nftId, p.colShares);

        p.rateDuring = IFluidOracleFlashDeposit(ORACLE).getExchangeRateLiquidate();
        p.liquidationInDuring = _liquidationIn();
        p.drift = int256(p.rateDuring) - int256(p.rateBefore);
        uint256 absoluteDrift = p.drift >= 0 ? uint256(p.drift) : uint256(-p.drift);

        emit DepositImpact(
            units0,
            units1,
            p.rateBefore,
            p.rateDuring,
            p.drift,
            (absoluteDrift * 1_000_000) / p.rateBefore,
            p.liquidationInBefore,
            p.liquidationInDuring
        );

        (bool closeOk, bytes memory closeData) = VAULT.call(
            abi.encodeWithSelector(
                IFluidVaultT4FlashDeposit.operatePerfect.selector,
                p.nftId,
                -p.colShares,
                int256(-1),
                int256(-1),
                int256(0),
                int256(0),
                int256(0),
                address(this)
            )
        );

        p.rateAfter = IFluidOracleFlashDeposit(ORACLE).getExchangeRateLiquidate();
        emit DepositClose(
            units0,
            units1,
            closeOk,
            _selector(closeOk ? bytes("") : closeData),
            p.rateAfter,
            int256(_balance(TOKEN0)) - int256(p.balance0Before),
            int256(_balance(TOKEN1)) - int256(p.balance1Before),
            p.gasBefore - gasleft()
        );
    }

    function _liquidationIn() internal returns (uint256) {
        IFluidVaultResolverFlashDeposit.LiquidationStruct memory data =
            IFluidVaultResolverFlashDeposit(RESOLVER).getVaultLiquidation(VAULT, 0);
        return data.inAmt;
    }

    function _balance(address token) internal view returns (uint256 value) {
        (bool ok, bytes memory data) = token.staticcall(
            abi.encodeWithSignature("balanceOf(address)", address(this))
        );
        require(ok && data.length >= 32, "balanceOf failed");
        value = abi.decode(data, (uint256));
    }

    function _approve(address token, address spender) internal {
        (bool ok, bytes memory data) = token.call(
            abi.encodeWithSignature("approve(address,uint256)", spender, type(uint256).max)
        );
        require(ok && (data.length == 0 || abi.decode(data, (bool))), "approve failed");
    }

    function _selector(bytes memory data) internal pure returns (bytes4 out) {
        if (data.length < 4) return bytes4(0);
        assembly ("memory-safe") { out := mload(add(data, 32)) }
    }
}
