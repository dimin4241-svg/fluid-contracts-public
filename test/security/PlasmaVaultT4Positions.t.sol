// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.21;

import {Test} from "forge-std/Test.sol";

interface IPlasmaVaultFactoryPositions {
    function owner() external view returns (address);
    function totalVaults() external view returns (uint256);
    function getVaultAddress(uint256 vaultId) external view returns (address);
    function totalSupply() external view returns (uint256);
    function ownerOf(uint256 nftId) external view returns (address);
    function readFromStorage(bytes32 slot) external view returns (uint256);
}

interface IPlasmaVaultPositionStorage {
    function readFromStorage(bytes32 slot) external view returns (uint256);
}

contract PlasmaVaultT4PositionsTest is Test {
    address internal constant FACTORY = 0x324c5Dc1fC42c7a4D43d92df1eBA58a54d13Bf2d;
    uint256 internal constant FACTORY_TOKEN_CONFIG_SLOT = 3;
    uint256 internal constant VAULT_POSITION_DATA_SLOT = 3;
    uint256 internal constant T4_ENCODED_TYPE = 40_000;

    event T4Target(
        uint256 indexed vaultId,
        address indexed vault,
        address smartCollateral,
        address smartDebt,
        address supplyToken0,
        address supplyToken1,
        address borrowToken0,
        address borrowToken1,
        uint256 totalPositions
    );
    event BorrowPosition(
        uint256 indexed nftId,
        address indexed owner,
        int256 tick,
        uint256 tickId,
        uint256 rawSupply,
        uint256 dustDebt,
        uint256 rawPositionData
    );
    event PositionSummary(
        uint256 indexed vaultId,
        uint256 configuredPositions,
        uint256 factoryNfts,
        uint256 nonzeroPositions,
        uint256 borrowPositions,
        uint256 supplyOnlyPositions,
        uint256 largestRawSupplyNft,
        uint256 largestRawSupply
    );

    function setUp() public {
        vm.createSelectFork(vm.envString("PLASMA_RPC_URL"), vm.envUint("PLASMA_FORK_BLOCK"));
        assertEq(block.chainid, 9745, "unexpected chain");
    }

    function test_inventoryRealT4BorrowPositions() public {
        IPlasmaVaultFactoryPositions factory = IPlasmaVaultFactoryPositions(FACTORY);
        address factoryOwner = factory.owner();
        uint256 totalVaults = factory.totalVaults();

        uint256 targetVaultId;
        address targetVault;
        uint256 configuredPositions;

        for (uint256 vaultId = 1; vaultId <= totalVaults; ++vaultId) {
            address vault = factory.getVaultAddress(vaultId);
            (bool ok, bytes memory data) = vault.staticcall(abi.encodeWithSignature("constantsView()"));
            assertTrue(ok, "constantsView failed");

            if (data.length != 18 * 32 || _word(data, 13) != T4_ENCODED_TYPE) continue;
            assertEq(targetVault, address(0), "more than one T4 target");

            targetVaultId = vaultId;
            targetVault = vault;

            vm.prank(factoryOwner);
            uint256 vars = IPlasmaVaultPositionStorage(vault).readFromStorage(bytes32(uint256(0)));
            configuredPositions = (vars >> 210) & type(uint32).max;

            emit T4Target(
                vaultId,
                vault,
                address(uint160(_word(data, 6))),
                address(uint160(_word(data, 7))),
                address(uint160(_word(data, 8))),
                address(uint160(_word(data, 9))),
                address(uint160(_word(data, 10))),
                address(uint160(_word(data, 11))),
                configuredPositions
            );
        }

        assertEq(targetVaultId, 33, "unexpected T4 vault id");
        assertEq(targetVault, 0x6E0cDB09eb33cD3894C905E0DFF9289b95a86FFF, "unexpected T4 vault");

        uint256 factoryNfts;
        uint256 nonzeroPositions;
        uint256 borrowPositions;
        uint256 supplyOnlyPositions;
        uint256 largestRawSupplyNft;
        uint256 largestRawSupply;
        uint256 maxNftId = factory.totalSupply();

        for (uint256 nftId = 1; nftId <= maxNftId; ++nftId) {
            bytes32 tokenConfigSlot = keccak256(abi.encode(nftId, FACTORY_TOKEN_CONFIG_SLOT));
            vm.prank(factoryOwner);
            uint256 tokenConfig = factory.readFromStorage(tokenConfigSlot);
            uint256 vaultId = (tokenConfig >> 192) & type(uint32).max;
            if (vaultId != targetVaultId) continue;

            ++factoryNfts;
            bytes32 positionSlot = keccak256(abi.encode(nftId, VAULT_POSITION_DATA_SLOT));
            vm.prank(factoryOwner);
            uint256 positionData = IPlasmaVaultPositionStorage(targetVault).readFromStorage(positionSlot);
            if (positionData == 0) continue;

            ++nonzeroPositions;
            bool supplyOnly = (positionData & 1) == 1;
            uint256 rawSupply = (positionData >> 45) & type(uint64).max;
            uint256 dustDebt = (positionData >> 109) & type(uint64).max;

            if (supplyOnly) {
                ++supplyOnlyPositions;
                continue;
            }

            ++borrowPositions;
            uint256 absTick = (positionData >> 2) & ((1 << 19) - 1);
            int256 tick = ((positionData >> 1) & 1) == 1 ? int256(absTick) : -int256(absTick);
            uint256 tickId = (positionData >> 21) & ((1 << 24) - 1);
            address positionOwner = factory.ownerOf(nftId);

            if (rawSupply > largestRawSupply) {
                largestRawSupply = rawSupply;
                largestRawSupplyNft = nftId;
            }

            emit BorrowPosition(nftId, positionOwner, tick, tickId, rawSupply, dustDebt, positionData);
        }

        emit PositionSummary(
            targetVaultId,
            configuredPositions,
            factoryNfts,
            nonzeroPositions,
            borrowPositions,
            supplyOnlyPositions,
            largestRawSupplyNft,
            largestRawSupply
        );

        assertEq(nonzeroPositions, configuredPositions, "position count mismatch");
        assertGt(borrowPositions, 0, "no live T4 debt positions");
    }

    function _word(bytes memory data, uint256 index) internal pure returns (uint256 value) {
        require(data.length >= (index + 1) * 32, "word out of bounds");
        assembly {
            value := mload(add(add(data, 0x20), mul(index, 0x20)))
        }
    }
}
