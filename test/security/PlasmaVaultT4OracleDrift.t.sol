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

            IPlasmaVaultDriftProbe.ConstantViews memory c =
                IPlasmaVaultDriftProbe(vault).constantsView();

            vm.prank(factoryOwner);
            uint256 vaultVariables = IPlasmaVaultDriftProbe(vault).readFromStorage(bytes32(uint256(0)));
            uint256 totalBorrowEncoded = (vaultVariables >> 146) & type(uint64).max;
            if (totalBorrowEncoded == 0) continue;

            vm.prank(factoryOwner);
            uint256 vaultVariables2 = IPlasmaVaultDriftProbe(vault).readFromStorage(bytes32(uint256(1)));
            uint256 oracleNonce = (vaultVariables2 >> 92) & X30;
            address oracle = _addressCalc(c.deployer, oracleNonce);

            require(oracle.code.length > 0, "oracle has no code");
            require(c.borrow.code.length > 0, "borrow DEX has no code");

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

        revert("no active Plasma T4 vault");
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

    function _addressCalc(address deployedFrom, uint256 nonce) internal pure returns (address calculated) {
        bytes memory data;
        if (nonce == 0) return address(0);
        if (nonce <= 0x7f) {
            data = abi.encodePacked(bytes1(0xd6), bytes1(0x94), deployedFrom, uint8(nonce));
        } else if (nonce <= 0xff) {
            data = abi.encodePacked(bytes1(0xd7), bytes1(0x94), deployedFrom, bytes1(0x81), uint8(nonce));
        } else if (nonce <= 0xffff) {
            data = abi.encodePacked(bytes1(0xd8), bytes1(0x94), deployedFrom, bytes1(0x82), uint16(nonce));
        } else if (nonce <= 0xffffff) {
            data = abi.encodePacked(bytes1(0xd9), bytes1(0x94), deployedFrom, bytes1(0x83), uint24(nonce));
        } else {
            data = abi.encodePacked(bytes1(0xda), bytes1(0x94), deployedFrom, bytes1(0x84), uint32(nonce));
        }
        calculated = address(uint160(uint256(keccak256(data))));
    }
}
