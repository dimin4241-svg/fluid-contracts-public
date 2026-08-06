// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.21;

import {Test} from "forge-std/Test.sol";

interface IVaultFactoryBytecodeInventory {
    function owner() external view returns (address);
    function totalVaults() external view returns (uint256);
    function getVaultAddress(uint256 vaultId) external view returns (address);
    function totalSupply() external view returns (uint256);
    function ownerOf(uint256 nftId) external view returns (address);
    function readFromStorage(bytes32 slot) external view returns (uint256);
}

contract PlasmaVaultT4BytecodeInventoryTest is Test {
    address internal constant FACTORY = 0x324c5Dc1fC42c7a4D43d92df1eBA58a54d13Bf2d;

    bytes4 internal constant OPERATE_PERFECT_SELECTOR = bytes4(
        keccak256("operatePerfect(uint256,int256,int256,int256,int256,int256,int256,address)")
    );

    event InventoryHeader(
        uint256 forkBlock,
        uint256 totalVaults,
        uint256 totalNfts,
        address factoryOwner,
        bytes4 t4Selector
    );
    event T4VaultInventory(
        uint256 indexed vaultId,
        address indexed vault,
        uint256 codeSize,
        uint256 packedVaultVariables,
        uint256 encodedSupply,
        uint256 encodedBorrow,
        uint256 totalPositions,
        address liquidity,
        address supply,
        address borrow,
        address supplyToken0,
        address supplyToken1,
        address borrowToken0,
        address borrowToken1,
        address oracle
    );
    event T4Position(
        uint256 indexed nftId,
        uint256 indexed vaultId,
        address indexed vault,
        address owner,
        uint256 rawPositionData
    );
    event T4Summary(
        uint256 t4Vaults,
        uint256 t4FactoryNfts,
        uint256 t4NonzeroPositions,
        uint256 t4VaultsWithBorrow
    );

    function setUp() public {
        vm.createSelectFork(vm.envString("PLASMA_RPC_URL"), vm.envUint("PLASMA_FORK_BLOCK"));
        assertEq(block.chainid, 9745, "unexpected chain");
    }

    function _containsSelector(bytes memory code, bytes4 selector) internal pure returns (bool) {
        if (code.length < 4) return false;
        bytes1 a = selector[0];
        bytes1 b = selector[1];
        bytes1 c = selector[2];
        bytes1 d = selector[3];
        for (uint256 i; i + 3 < code.length; ++i) {
            if (code[i] == a && code[i + 1] == b && code[i + 2] == c && code[i + 3] == d) {
                return true;
            }
        }
        return false;
    }

    function _probeUint(address target, address caller, string memory signature)
        internal returns (bool ok, uint256 value)
    {
        vm.prank(caller);
        bytes memory data;
        (ok, data) = target.staticcall(abi.encodeWithSignature(signature));
        if (!ok || data.length < 32) return (false, 0);
        value = abi.decode(data, (uint256));
    }

    function _probeAddress(address target, address caller, string memory signature)
        internal returns (address value)
    {
        (bool ok, uint256 raw) = _probeUint(target, caller, signature);
        if (ok) value = address(uint160(raw));
    }

    function _readSlot(address vault, address caller, bytes32 slot) internal returns (uint256 value) {
        vm.prank(caller);
        (bool ok, bytes memory data) = vault.staticcall(
            abi.encodeWithSignature("readFromStorage(bytes32)", slot)
        );
        if (ok && data.length >= 32) value = abi.decode(data, (uint256));
    }

    function test_inventoryLiveT4VaultsByRuntimeSelector() public {
        IVaultFactoryBytecodeInventory factory = IVaultFactoryBytecodeInventory(FACTORY);
        uint256 totalVaults = factory.totalVaults();
        uint256 totalNfts = factory.totalSupply();
        address factoryOwner = factory.owner();
        emit InventoryHeader(block.number, totalVaults, totalNfts, factoryOwner, OPERATE_PERFECT_SELECTOR);

        bool[] memory isT4 = new bool[](totalVaults + 1);
        address[] memory vaultById = new address[](totalVaults + 1);
        uint256 t4Vaults;
        uint256 t4VaultsWithBorrow;

        for (uint256 vaultId = 1; vaultId <= totalVaults; ++vaultId) {
            address vault = factory.getVaultAddress(vaultId);
            vaultById[vaultId] = vault;
            bytes memory code = vault.code;
            if (!_containsSelector(code, OPERATE_PERFECT_SELECTOR)) continue;

            isT4[vaultId] = true;
            ++t4Vaults;
            uint256 vars = _readSlot(vault, factoryOwner, bytes32(uint256(0)));
            uint256 encodedBorrow = (vars >> 146) & type(uint64).max;
            if (encodedBorrow != 0) ++t4VaultsWithBorrow;

            emit T4VaultInventory(
                vaultId,
                vault,
                code.length,
                vars,
                (vars >> 82) & type(uint64).max,
                encodedBorrow,
                (vars >> 210) & type(uint32).max,
                _probeAddress(vault, factoryOwner, "LIQUIDITY()"),
                _probeAddress(vault, factoryOwner, "SUPPLY()"),
                _probeAddress(vault, factoryOwner, "BORROW()"),
                _probeAddress(vault, factoryOwner, "SUPPLY_TOKEN0()"),
                _probeAddress(vault, factoryOwner, "SUPPLY_TOKEN1()"),
                _probeAddress(vault, factoryOwner, "BORROW_TOKEN0()"),
                _probeAddress(vault, factoryOwner, "BORROW_TOKEN1()"),
                _probeAddress(vault, factoryOwner, "ORACLE()")
            );
        }

        uint256 t4FactoryNfts;
        uint256 t4NonzeroPositions;
        for (uint256 nftId = 1; nftId <= totalNfts; ++nftId) {
            bytes32 factoryTokenConfigSlot = keccak256(abi.encode(nftId, uint256(3)));
            uint256 tokenConfig = factory.readFromStorage(factoryTokenConfigSlot);
            uint256 vaultId = (tokenConfig >> 192) & type(uint32).max;
            if (vaultId == 0 || vaultId > totalVaults || !isT4[vaultId]) continue;

            ++t4FactoryNfts;
            address vault = vaultById[vaultId];
            bytes32 positionSlot = keccak256(abi.encode(nftId, uint256(3)));
            uint256 positionData = _readSlot(vault, factoryOwner, positionSlot);
            if (positionData != 0) ++t4NonzeroPositions;
            emit T4Position(nftId, vaultId, vault, factory.ownerOf(nftId), positionData);
        }

        emit T4Summary(t4Vaults, t4FactoryNfts, t4NonzeroPositions, t4VaultsWithBorrow);
        assertGt(t4Vaults, 0, "no T4 vault selector found");
    }
}
