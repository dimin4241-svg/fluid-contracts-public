// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.21;

import {Test} from "forge-std/Test.sol";

interface IERC20DriftProbe {
    function decimals() external view returns (uint8);
}

interface IFluidDexDriftProbe {
    function swapOut(bool swap0to1, uint256 amountOut, uint256 amountInMax, address to)
        external payable returns (uint256 amountIn);
}

interface IFluidOracleDriftProbe {
    function getExchangeRateOperate() external view returns (uint256);
    function getExchangeRateLiquidate() external view returns (uint256);
}

interface IPlasmaVaultResolverDriftProbe {
    function getContractForDeployerIndex(address vault, uint256 index) external view returns (address);
}

interface IPlasmaVaultFactoryDriftProbe {
    function owner() external view returns (address);
    function totalVaults() external view returns (uint256);
    function getVaultAddress(uint256 vaultId) external view returns (address);
}

interface IPlasmaVaultDriftProbe {
    struct Tokens {
        address token0;
        address token1;
    }

    struct ConstantViews {
        address liquidity;
        address factory;
        address operateImplementation;
        address adminImplementation;
        address secondaryImplementation;
        address deployer;
        address supply;
        address borrow;
        Tokens supplyToken;
        Tokens borrowToken;
        uint256 vaultId;
        uint256 vaultType;
        bytes32 supplyExchangePriceSlot;
        bytes32 borrowExchangePriceSlot;
        bytes32 userSupplySlot;
        bytes32 userBorrowSlot;
    }

    function TYPE() external view returns (uint256);
    function constantsView() external view returns (ConstantViews memory);
    function readFromStorage(bytes32 slot) external view returns (uint256);
}

contract PlasmaVaultT4OracleDriftTest is Test {
    address internal constant FACTORY = 0x324c5Dc1fC42c7a4D43d92df1eBA58a54d13Bf2d;
    address internal constant VAULT_RESOLVER = 0xA5C3E16523eeeDDcC34706b0E6bE88b4c6EA95cC;
    uint256 internal constant T4_TYPE = 40_000;
    uint256 internal constant X30 = (1 << 30) - 1;

    struct Target {
        address vault;
        address oracle;
        address supplyDex;
        address borrowDex;
        address borrowToken0;
        address borrowToken1;
        uint256 vaultId;
        uint256 totalBorrowEncoded;
    }

    event T4Candidate(
        uint256 indexed vaultId,
        address indexed vault,
        address indexed deployer,
        address oracle,
        address supplyDex,
        address borrowDex,
        uint256 oracleNonce,
        uint256 oracleCodeLength,
        uint256 totalBorrowEncoded,
        uint256 operateRate,
        uint256 liquidateRate
    );

    event DriftTarget(
        uint256 indexed vaultId,
        address indexed vault,
        address indexed oracle,
        address supplyDex,
        address borrowDex,
        address borrowToken0,
        address borrowToken1,
        uint256 totalBorrowEncoded,
        uint256 forkBlock
    );

    event OracleDriftResult(
        bool indexed swap0to1,
        uint256 unitsOut,
        uint256 amountOut,
        uint256 firstAmountIn,
        uint256 reverseAmountIn,
        uint256 operateBefore,
        uint256 operateDuring,
        uint256 operateAfter,
        uint256 liquidateBefore,
        uint256 liquidateDuring,
        uint256 liquidateAfter,
        int256 liquidateDrift,
        uint256 absoluteDriftBps,
        uint256 gasUsed
    );

    function setUp() public {
        vm.createSelectFork(vm.envString("PLASMA_RPC_URL"), vm.envUint("PLASMA_FORK_BLOCK"));
        assertEq(block.chainid, 9745, "unexpected chain");
    }

    function test_swap0to1_oneUnit() public { _probe(true, 1); }
    function test_swap0to1_hundredUnits() public { _probe(true, 100); }
    function test_swap0to1_tenThousandUnits() public { _probe(true, 10_000); }
    function test_swap1to0_oneUnit() public { _probe(false, 1); }
    function test_swap1to0_hundredUnits() public { _probe(false, 100); }
    function test_swap1to0_tenThousandUnits() public { _probe(false, 10_000); }

    function _probe(bool swap0to1, uint256 unitsOut) internal {
        Target memory target = _findActiveT4();
        emit DriftTarget(
            target.vaultId,
            target.vault,
            target.oracle,
            target.supplyDex,
            target.borrowDex,
            target.borrowToken0,
            target.borrowToken1,
            target.totalBorrowEncoded,
            block.number
        );

        IFluidOracleDriftProbe oracle = IFluidOracleDriftProbe(target.oracle);
        uint256 operateBefore = oracle.getExchangeRateOperate();
        uint256 liquidateBefore = oracle.getExchangeRateLiquidate();
        assertGt(operateBefore, 0, "zero operate rate");
        assertGt(liquidateBefore, 0, "zero liquidation rate");

        address outputToken = swap0to1 ? target.borrowToken1 : target.borrowToken0;
        uint8 outputDecimals = IERC20DriftProbe(outputToken).decimals();
        require(outputDecimals <= 24, "unexpected decimals");
        uint256 amountOut = unitsOut * (10 ** uint256(outputDecimals));

        _fundAndApprove(target.borrowToken0, target.borrowDex);
        _fundAndApprove(target.borrowToken1, target.borrowDex);

        uint256 gasBefore = gasleft();
        uint256 firstAmountIn = IFluidDexDriftProbe(target.borrowDex).swapOut(
            swap0to1,
            amountOut,
            type(uint256).max,
            address(this)
        );

        uint256 operateDuring = oracle.getExchangeRateOperate();
        uint256 liquidateDuring = oracle.getExchangeRateLiquidate();

        uint256 reverseAmountIn = IFluidDexDriftProbe(target.borrowDex).swapOut(
            !swap0to1,
            firstAmountIn,
            type(uint256).max,
            address(this)
        );
        uint256 gasUsed = gasBefore - gasleft();

        uint256 operateAfter = oracle.getExchangeRateOperate();
        uint256 liquidateAfter = oracle.getExchangeRateLiquidate();

        int256 drift = int256(liquidateDuring) - int256(liquidateBefore);
        uint256 absoluteDrift = drift >= 0 ? uint256(drift) : uint256(-drift);
        uint256 absoluteDriftBps = (absoluteDrift * 10_000) / liquidateBefore;

        emit OracleDriftResult(
            swap0to1,
            unitsOut,
            amountOut,
            firstAmountIn,
            reverseAmountIn,
            operateBefore,
            operateDuring,
            operateAfter,
            liquidateBefore,
            liquidateDuring,
            liquidateAfter,
            drift,
            absoluteDriftBps,
            gasUsed
        );

        assertGt(firstAmountIn, 0, "zero input");
        assertGt(reverseAmountIn, 0, "zero reverse input");
    }

    function _findActiveT4() internal returns (Target memory target) {
        IPlasmaVaultFactoryDriftProbe factory = IPlasmaVaultFactoryDriftProbe(FACTORY);
        address factoryOwner = factory.owner();
        uint256 totalVaults = factory.totalVaults();

        for (uint256 vaultId = 1; vaultId <= totalVaults; ++vaultId) {
            address vault = factory.getVaultAddress(vaultId);
            try IPlasmaVaultDriftProbe(vault).TYPE() returns (uint256 vaultType) {
                if (vaultType != T4_TYPE) continue;
            } catch {
                continue;
            }

            IPlasmaVaultDriftProbe.ConstantViews memory c = IPlasmaVaultDriftProbe(vault).constantsView();

            vm.prank(factoryOwner);
            uint256 vaultVariables = IPlasmaVaultDriftProbe(vault).readFromStorage(bytes32(uint256(0)));
            uint256 totalBorrowEncoded = (vaultVariables >> 146) & type(uint64).max;

            vm.prank(factoryOwner);
            uint256 vaultVariables2 = IPlasmaVaultDriftProbe(vault).readFromStorage(bytes32(uint256(1)));
            uint256 oracleNonce = (vaultVariables2 >> 92) & X30;
            address oracle = IPlasmaVaultResolverDriftProbe(VAULT_RESOLVER)
                .getContractForDeployerIndex(vault, oracleNonce);

            uint256 operateRate;
            uint256 liquidateRate;
            if (oracle.code.length > 0) {
                try IFluidOracleDriftProbe(oracle).getExchangeRateOperate() returns (uint256 rate) {
                    operateRate = rate;
                } catch {}
                try IFluidOracleDriftProbe(oracle).getExchangeRateLiquidate() returns (uint256 rate) {
                    liquidateRate = rate;
                } catch {}
            }

            emit T4Candidate(
                vaultId,
                vault,
                c.deployer,
                oracle,
                c.supply,
                c.borrow,
                oracleNonce,
                oracle.code.length,
                totalBorrowEncoded,
                operateRate,
                liquidateRate
            );

            if (
                totalBorrowEncoded == 0 ||
                oracle.code.length == 0 ||
                operateRate == 0 ||
                liquidateRate == 0 ||
                c.borrow.code.length == 0
            ) continue;

            target = Target({
                vault: vault,
                oracle: oracle,
                supplyDex: c.supply,
                borrowDex: c.borrow,
                borrowToken0: c.borrowToken.token0,
                borrowToken1: c.borrowToken.token1,
                vaultId: vaultId,
                totalBorrowEncoded: totalBorrowEncoded
            });
            return target;
        }

        revert("no active Plasma T4 vault with live oracle");
    }

    function _fundAndApprove(address token, address spender) internal {
        uint8 decimals_ = IERC20DriftProbe(token).decimals();
        require(decimals_ <= 24, "unexpected token decimals");
        deal(token, address(this), 100_000_000 * (10 ** uint256(decimals_)));

        (bool ok, bytes memory data) = token.call(
            abi.encodeWithSignature("approve(address,uint256)", spender, type(uint256).max)
        );
        require(ok && (data.length == 0 || abi.decode(data, (bool))), "approve failed");
    }
}
