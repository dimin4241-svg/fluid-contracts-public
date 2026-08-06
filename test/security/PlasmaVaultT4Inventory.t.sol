// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.21;

import {Test} from "forge-std/Test.sol";

interface IFactoryRawInventory {
    function owner() external view returns (address);
    function totalVaults() external view returns (uint256);
    function getVaultAddress(uint256 vaultId) external view returns (address);
    function totalSupply() external view returns (uint256);
}

interface IVaultRawInventory {
    function readFromStorage(bytes32 slot) external view returns (uint256);
}

contract PlasmaVaultT4InventoryTest is Test {
    address internal constant FACTORY = 0x324c5Dc1fC42c7a4D43d92df1eBA58a54d13Bf2d;

    event InventoryHeader(uint256 forkBlock, uint256 totalVaults, uint256 totalNfts, address factoryOwner);
    event VaultConstantsRaw(
        uint256 indexed vaultId,
        address indexed vault,
        uint256 returnLength,
        bytes returnData
    );
    event VaultPackedState(
        uint256 indexed vaultId,
        address indexed vault,
        uint256 encodedSupply,
        uint256 encodedBorrow,
        uint256 totalPositions
    );
    event RawSummary(uint256 successfulConstantsCalls, uint256 totalVaults);

    function setUp() public {
        vm.createSelectFork(vm.envString("PLASMA_RPC_URL"), vm.envUint("PLASMA_FORK_BLOCK"));
        assertEq(block.chainid, 9745, "unexpected chain");
    }

    function test_inventoryRawLiveVaultConstants() public {
        IFactoryRawInventory factory = IFactoryRawInventory(FACTORY);
        uint256 totalVaults = factory.totalVaults();
        address factoryOwner = factory.owner();
        emit InventoryHeader(block.number, totalVaults, factory.totalSupply(), factoryOwner);

        // Plasma has multiple generations of vault implementations. Their live
        // constantsView() return layouts differ from the current source interface,
        // so preserve exact returndata instead of decoding through a stale ABI.
        uint256 successfulCalls;
        for (uint256 vaultId = 1; vaultId <= totalVaults; ++vaultId) {
            address vault = factory.getVaultAddress(vaultId);
            (bool ok, bytes memory data) = vault.staticcall(abi.encodeWithSignature("constantsView()"));
            assertTrue(ok, "constantsView failed");
            ++successfulCalls;
            emit VaultConstantsRaw(vaultId, vault, data.length, data);

            vm.prank(factoryOwner);
            uint256 vars = IVaultRawInventory(vault).readFromStorage(bytes32(uint256(0)));
            emit VaultPackedState(
                vaultId,
                vault,
                (vars >> 82) & type(uint64).max,
                (vars >> 146) & type(uint64).max,
                (vars >> 210) & type(uint32).max
            );
        }

        emit RawSummary(successfulCalls, totalVaults);
        assertEq(successfulCalls, totalVaults, "missing vault constants");
    }
}
