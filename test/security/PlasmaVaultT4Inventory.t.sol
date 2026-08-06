// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.21;

import {Test} from "forge-std/Test.sol";

struct TokenPair {
    address token0;
    address token1;
}

struct ConstantViews {
    address liquidity;
    address factory;
    address operateImplementation;
    address adminImplementation;
    address secondaryImplementation;
    address supply;
    address borrow;
    TokenPair supplyToken;
    TokenPair borrowToken;
    uint256 vaultId;
    uint256 vaultType;
    bytes32 supplyExchangePriceSlot;
    bytes32 borrowExchangePriceSlot;
    bytes32 userSupplySlot;
    bytes32 userBorrowSlot;
}

interface IFactoryT4Inventory {
    function owner() external view returns (address);
    function totalVaults() external view returns (uint256);
    function getVaultAddress(uint256 vaultId) external view returns (address);
    function totalSupply() external view returns (uint256);
    function ownerOf(uint256 nftId) external view returns (address);
    function readFromStorage(bytes32 slot) external view returns (uint256);
}

interface IVaultT4Inventory {
    function constantsView() external view returns (ConstantViews memory);
    function readFromStorage(bytes32 slot) external view returns (uint256);
}

contract PlasmaVaultT4InventoryTest is Test {
    address internal constant FACTORY = 0x324c5Dc1fC42c7a4D43d92df1eBA58a54d13Bf2d;

    event InventoryHeader(uint256 forkBlock, uint256 totalVaults, uint256 totalNfts, address factoryOwner);
    event VaultInventory(
        uint256 indexed vaultId,
        address indexed vault,
        uint256 vaultType,
        address smartCollateral,
        address smartDebt,
        address supplyToken0,
        address supplyToken1,
        address borrowToken0,
        address borrowToken1,
        uint256 encodedSupply,
        uint256 encodedBorrow,
        uint256 totalPositions
    );
    event T4Position(
        uint256 indexed nftId,
        uint256 indexed vaultId,
        address indexed vault,
        address owner,
        uint256 rawPositionData,
        uint256 encodedSupply,
        uint256 encodedDustDebt,
        bool supplyOnly
    );
    event T4Summary(uint256 t4Vaults, uint256 t4FactoryNfts, uint256 t4NonzeroPositions);

    function setUp() public {
        vm.createSelectFork(vm.envString("PLASMA_RPC_URL"), vm.envUint("PLASMA_FORK_BLOCK"));
        assertEq(block.chainid, 9745, "unexpected chain");
    }

    function test_inventoryLiveT4VaultsAndPositions() public {
        IFactoryT4Inventory factory = IFactoryT4Inventory(FACTORY);
        uint256 totalVaults = factory.totalVaults();
        uint256 totalNfts = factory.totalSupply();
        address factoryOwner = factory.owner();
        emit InventoryHeader(block.number, totalVaults, totalNfts, factoryOwner);

        // constantsView() is routed to the public core module. Raw StorageRead on
        // both the factory and vault is auth-gated, so the real factory owner is
        // impersonated only for read-only inspection on this local fork.
        vm.startPrank(factoryOwner);

        address[] memory vaultById = new address[](totalVaults + 1);
        uint256[] memory typeById = new uint256[](totalVaults + 1);
        uint256 t4Vaults;

        for (uint256 vaultId = 1; vaultId <= totalVaults; ++vaultId) {
            address vault = factory.getVaultAddress(vaultId);
            ConstantViews memory c = IVaultT4Inventory(vault).constantsView();
            assertEq(c.vaultId, vaultId, "factory/constants vault id mismatch");

            vaultById[vaultId] = vault;
            typeById[vaultId] = c.vaultType;
            if (c.vaultType != 4) continue;

            ++t4Vaults;
            uint256 vars = IVaultT4Inventory(vault).readFromStorage(bytes32(uint256(0)));
            emit VaultInventory(
                vaultId,
                vault,
                c.vaultType,
                c.supply,
                c.borrow,
                c.supplyToken.token0,
                c.supplyToken.token1,
                c.borrowToken.token0,
                c.borrowToken.token1,
                (vars >> 82) & type(uint64).max,
                (vars >> 146) & type(uint64).max,
                (vars >> 210) & type(uint32).max
            );
        }

        uint256 t4FactoryNfts;
        uint256 t4NonzeroPositions;
        for (uint256 nftId = 1; nftId <= totalNfts; ++nftId) {
            // VaultFactory ERC721._tokenConfig is mapping slot 3. Its top 32
            // bits encode the vault id assigned when the position was minted.
            bytes32 factoryTokenConfigSlot = keccak256(abi.encode(nftId, uint256(3)));
            uint256 tokenConfig = factory.readFromStorage(factoryTokenConfigSlot);
            uint256 vaultId = (tokenConfig >> 192) & type(uint32).max;
            if (vaultId == 0 || vaultId > totalVaults || typeById[vaultId] != 4) continue;

            ++t4FactoryNfts;
            address vault = vaultById[vaultId];

            // Vault Variables layout: vaultVariables slot 0, vaultVariables2
            // slot 1, absorbedLiquidity slot 2, positionData mapping slot 3.
            bytes32 positionSlot = keccak256(abi.encode(nftId, uint256(3)));
            uint256 positionData = IVaultT4Inventory(vault).readFromStorage(positionSlot);
            if (positionData == 0) continue;

            ++t4NonzeroPositions;
            emit T4Position(
                nftId,
                vaultId,
                vault,
                factory.ownerOf(nftId),
                positionData,
                (positionData >> 45) & type(uint64).max,
                (positionData >> 109) & type(uint64).max,
                (positionData & 1) == 1
            );
        }

        vm.stopPrank();
        emit T4Summary(t4Vaults, t4FactoryNfts, t4NonzeroPositions);
        assertGt(t4Vaults, 0, "no T4 vaults found");
    }
}
