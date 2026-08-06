// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.21;

import {Test} from "forge-std/Test.sol";

interface IFactoryT4Inventory {
    function totalVaults() external view returns (uint256);
    function getVaultAddress(uint256 vaultId) external view returns (address);
    function totalSupply() external view returns (uint256);
    function ownerOf(uint256 nftId) external view returns (address);
    function readFromStorage(bytes32 slot) external view returns (uint256);
}

interface IVaultT4Inventory {
    function TYPE() external view returns (uint256);
    function VAULT_ID() external view returns (uint256);
    function LIQUIDITY() external view returns (address);
    function readFromStorage(bytes32 slot) external view returns (uint256);
}

contract PlasmaVaultT4InventoryTest is Test {
    address internal constant FACTORY = 0x324c5Dc1fC42c7a4D43d92df1eBA58a54d13Bf2d;

    event InventoryHeader(uint256 forkBlock, uint256 totalVaults, uint256 totalNfts);
    event VaultInventory(
        uint256 indexed vaultId,
        address indexed vault,
        uint256 vaultType,
        uint256 packedVaultVariables,
        uint256 encodedSupply,
        uint256 encodedBorrow,
        uint256 totalPositions,
        address liquidity
    );
    event T4Position(
        uint256 indexed nftId,
        uint256 indexed vaultId,
        address indexed vault,
        address owner,
        uint256 rawPositionData
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
        emit InventoryHeader(block.number, totalVaults, totalNfts);

        address[] memory vaultById = new address[](totalVaults + 1);
        uint256[] memory typeById = new uint256[](totalVaults + 1);
        uint256 t4Vaults;

        for (uint256 vaultId = 1; vaultId <= totalVaults; ++vaultId) {
            address vault = factory.getVaultAddress(vaultId);
            uint256 vaultType = IVaultT4Inventory(vault).TYPE();
            uint256 vars = IVaultT4Inventory(vault).readFromStorage(bytes32(uint256(0)));
            vaultById[vaultId] = vault;
            typeById[vaultId] = vaultType;
            if (vaultType == 4) ++t4Vaults;

            emit VaultInventory(
                vaultId,
                vault,
                vaultType,
                vars,
                (vars >> 82) & type(uint64).max,
                (vars >> 146) & type(uint64).max,
                (vars >> 210) & type(uint32).max,
                address(IVaultT4Inventory(vault).LIQUIDITY())
            );
        }

        uint256 t4FactoryNfts;
        uint256 t4NonzeroPositions;
        for (uint256 nftId = 1; nftId <= totalNfts; ++nftId) {
            bytes32 factoryTokenConfigSlot = keccak256(abi.encode(nftId, uint256(3)));
            uint256 tokenConfig = factory.readFromStorage(factoryTokenConfigSlot);
            uint256 vaultId = (tokenConfig >> 192) & type(uint32).max;
            if (vaultId == 0 || vaultId > totalVaults || typeById[vaultId] != 4) continue;

            ++t4FactoryNfts;
            address vault = vaultById[vaultId];
            bytes32 positionSlot = keccak256(abi.encode(nftId, uint256(3)));
            uint256 positionData = IVaultT4Inventory(vault).readFromStorage(positionSlot);
            if (positionData != 0) ++t4NonzeroPositions;

            emit T4Position(nftId, vaultId, vault, factory.ownerOf(nftId), positionData);
        }

        emit T4Summary(t4Vaults, t4FactoryNfts, t4NonzeroPositions);
    }
}
