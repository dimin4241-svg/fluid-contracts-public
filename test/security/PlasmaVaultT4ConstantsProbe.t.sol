// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.21;

import {Test} from "forge-std/Test.sol";

interface IFluidVaultConstantsProbe {
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

    function constantsView() external view returns (ConstantViews memory);
    function TYPE() external view returns (uint256);
    function VAULT_ID() external view returns (uint256);
}

contract PlasmaVaultT4ConstantsProbeTest is Test {
    address internal constant VAULT = 0x6E0cDB09eb33cD3894C905E0DFF9289b95a86FFF;
    address internal constant FSL6_DEX = 0x36a905DCD12C0201f884fAFda71e63E9547975DA;

    event ConstantsResult(
        address indexed vault,
        uint256 vaultId,
        uint256 vaultType,
        address supply,
        address borrow,
        address supplyToken0,
        address supplyToken1,
        address borrowToken0,
        address borrowToken1,
        address liquidity,
        bool borrowIsFsl6Dex,
        bool supplyIsFsl6Dex
    );

    function setUp() public {
        vm.createSelectFork(vm.envString("PLASMA_RPC_URL"), vm.envUint("PLASMA_FORK_BLOCK"));
        assertEq(block.chainid, 9745, "unexpected chain");
    }

    function test_readLiveT4Constants() public {
        IFluidVaultConstantsProbe.ConstantViews memory c =
            IFluidVaultConstantsProbe(VAULT).constantsView();

        emit ConstantsResult(
            VAULT,
            c.vaultId,
            c.vaultType,
            c.supply,
            c.borrow,
            c.supplyToken.token0,
            c.supplyToken.token1,
            c.borrowToken.token0,
            c.borrowToken.token1,
            c.liquidity,
            c.borrow == FSL6_DEX,
            c.supply == FSL6_DEX
        );

        assertEq(c.vaultId, IFluidVaultConstantsProbe(VAULT).VAULT_ID(), "vault id mismatch");
        assertEq(c.vaultType, IFluidVaultConstantsProbe(VAULT).TYPE(), "vault type mismatch");
    }
}
