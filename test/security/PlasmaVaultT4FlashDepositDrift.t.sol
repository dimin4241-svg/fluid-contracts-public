// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.21;

import {Test} from "forge-std/Test.sol";

interface IERC20FlashDeposit {
    function decimals() external view returns (uint8);
}

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

    event DepositProbe(
        uint256 indexed units0,
        uint256 indexed units1,
        bool depositSuccess,
        bytes4 depositRevertSelector,
        uint256 nftId,
        int256 mintedColShares,
        uint256 rateBefore,
        uint256 rateDuring,
        int256 drift,
        uint256 absoluteDriftPpm,
        uint256 liquidationInBefore,
        uint256 liquidationOutBefore,
        uint256 liquidationInDuring,
        uint256 liquidationOutDuring,
        bool closeSuccess,
        bytes4 closeRevertSelector,
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
        uint256 amount0 = units0 * 1e18;
        uint256 amount1 = units1 * 1e6;
        uint256 balance0Before = _balance(TOKEN0);
        uint256 balance1Before = _balance(TOKEN1);
        uint256 rateBefore = IFluidOracleFlashDeposit(ORACLE).getExchangeRateLiquidate();
        IFluidVaultResolverFlashDeposit.LiquidationStruct memory beforeData =
            IFluidVaultResolverFlashDeposit(RESOLVER).getVaultLiquidation(VAULT, 0);
        uint256 gasBefore = gasleft();

        (bool depositOk, bytes memory depositData) = VAULT.call(
            abi.encodeWithSelector(
                IFluidVaultT4FlashDeposit.operate.selector,
                0,
                int256(amount0),
                int256(amount1),
                int256(1),
                int256(0),
                int256(0),
                int256(0),
                address(this)
            )
        );

        if (!depositOk || depositData.length < 96) {
            emit DepositProbe(
                units0,
                units1,
                false,
                _selector(depositData),
                0,
                0,
                rateBefore,
                rateBefore,
                0,
                0,
                beforeData.inAmt,
                beforeData.outAmt,
                beforeData.inAmt,
                beforeData.outAmt,
                false,
                bytes4(0),
                rateBefore,
                0,
                0,
                gasBefore - gasleft()
            );
            return;
        }

        (uint256 nftId, int256 colShares, ) = abi.decode(depositData, (uint256, int256, int256));
        uint256 rateDuring = IFluidOracleFlashDeposit(ORACLE).getExchangeRateLiquidate();
        IFluidVaultResolverFlashDeposit.LiquidationStruct memory duringData =
            IFluidVaultResolverFlashDeposit(RESOLVER).getVaultLiquidation(VAULT, 0);
        int256 drift = int256(rateDuring) - int256(rateBefore);
        uint256 absDrift = drift >= 0 ? uint256(drift) : uint256(-drift);

        (bool closeOk, bytes memory closeData) = VAULT.call(
            abi.encodeWithSelector(
                IFluidVaultT4FlashDeposit.operatePerfect.selector,
                nftId,
                -colShares,
                int256(-1),
                int256(-1),
                int256(0),
                int256(0),
                int256(0),
                address(this)
            )
        );

        uint256 rateAfter = IFluidOracleFlashDeposit(ORACLE).getExchangeRateLiquidate();
        emit DepositProbe(
            units0,
            units1,
            true,
            bytes4(0),
            nftId,
            colShares,
            rateBefore,
            rateDuring,
            drift,
            (absDrift * 1_000_000) / rateBefore,
            beforeData.inAmt,
            beforeData.outAmt,
            duringData.inAmt,
            duringData.outAmt,
            closeOk,
            _selector(closeOk ? bytes("") : closeData),
            rateAfter,
            int256(_balance(TOKEN0)) - int256(balance0Before),
            int256(_balance(TOKEN1)) - int256(balance1Before),
            gasBefore - gasleft()
        );
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
        assembly { out := mload(add(data, 32)) }
    }
}
