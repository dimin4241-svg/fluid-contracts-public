// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.21;

import {Test} from "forge-std/Test.sol";

interface IVaultFactoryPairInventory {
    function owner() external view returns (address);
    function totalVaults() external view returns (uint256);
    function getVaultAddress(uint256 vaultId) external view returns (address);
}

contract PlasmaVaultT4PairInventoryTest is Test {
    address internal constant FACTORY = 0x324c5Dc1fC42c7a4D43d92df1eBA58a54d13Bf2d;
    address internal constant TARGET_BORROW = 0x36a905DCD12C0201f884fAFda71e63E9547975DA;

    bytes4 internal constant OPERATE_PERFECT_SELECTOR = bytes4(
        keccak256("operatePerfect(uint256,int256,int256,int256,int256,int256,int256,address)")
    );

    event PairInventoryHeader(uint256 forkBlock, uint256 totalVaults, address factoryOwner, bytes4 selector);
    event T4Pair(
        uint256 indexed vaultId,
        address indexed vault,
        address indexed borrow,
        address supply,
        address supplyToken0,
        address supplyToken1,
        address borrowToken0,
        address borrowToken1,
        uint256 encodedSupply,
        uint256 encodedBorrow,
        uint256 totalPositions,
        bool targetBorrowMatch
    );
    event PairSummary(uint256 t4Vaults, uint256 activeDebtVaults, uint256 targetMatches);

    function setUp() public {
        vm.createSelectFork(vm.envString("PLASMA_RPC_URL"), vm.envUint("PLASMA_FORK_BLOCK"));
        assertEq(block.chainid, 9745, "unexpected chain");
    }

    function _containsSelector(bytes memory code, bytes4 selector) internal pure returns (bool) {
        if (code.length < 4) return false;
        for (uint256 i; i + 3 < code.length; ++i) {
            if (
                code[i] == selector[0] && code[i + 1] == selector[1] &&
                code[i + 2] == selector[2] && code[i + 3] == selector[3]
            ) return true;
        }
        return false;
    }

    function _probeAddress(address target, address caller, string memory signature)
        internal returns (address value)
    {
        vm.prank(caller);
        (bool ok, bytes memory data) = target.staticcall(abi.encodeWithSignature(signature));
        if (ok && data.length >= 32) value = abi.decode(data, (address));
    }

    function _readSlot(address target, address caller, bytes32 slot) internal returns (uint256 value) {
        vm.prank(caller);
        (bool ok, bytes memory data) = target.staticcall(
            abi.encodeWithSignature("readFromStorage(bytes32)", slot)
        );
        if (ok && data.length >= 32) value = abi.decode(data, (uint256));
    }

    function test_inventoryT4Pairs() public {
        IVaultFactoryPairInventory factory = IVaultFactoryPairInventory(FACTORY);
        uint256 totalVaults = factory.totalVaults();
        address factoryOwner = factory.owner();
        emit PairInventoryHeader(block.number, totalVaults, factoryOwner, OPERATE_PERFECT_SELECTOR);

        uint256 t4Vaults;
        uint256 activeDebtVaults;
        uint256 targetMatches;

        for (uint256 vaultId = 1; vaultId <= totalVaults; ++vaultId) {
            address vault = factory.getVaultAddress(vaultId);
            if (!_containsSelector(vault.code, OPERATE_PERFECT_SELECTOR)) continue;
            ++t4Vaults;

            uint256 vars = _readSlot(vault, factoryOwner, bytes32(uint256(0)));
            uint256 encodedBorrow = (vars >> 146) & type(uint64).max;
            if (encodedBorrow != 0) ++activeDebtVaults;

            address borrow = _probeAddress(vault, factoryOwner, "BORROW()");
            bool matchTarget = borrow == TARGET_BORROW;
            if (matchTarget) ++targetMatches;

            emit T4Pair(
                vaultId,
                vault,
                borrow,
                _probeAddress(vault, factoryOwner, "SUPPLY()"),
                _probeAddress(vault, factoryOwner, "SUPPLY_TOKEN0()"),
                _probeAddress(vault, factoryOwner, "SUPPLY_TOKEN1()"),
                _probeAddress(vault, factoryOwner, "BORROW_TOKEN0()"),
                _probeAddress(vault, factoryOwner, "BORROW_TOKEN1()"),
                (vars >> 82) & type(uint64).max,
                encodedBorrow,
                (vars >> 210) & type(uint32).max,
                matchTarget
            );
        }

        emit PairSummary(t4Vaults, activeDebtVaults, targetMatches);
        assertGt(t4Vaults, 0, "no T4 vaults found");
    }
}
