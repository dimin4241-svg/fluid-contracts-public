// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.21;

import {Test} from "forge-std/Test.sol";

interface IFactoryExactState {
    function owner() external view returns (address);
    function ownerOf(uint256 nftId) external view returns (address);
    function readFromStorage(bytes32 slot) external view returns (uint256);
}

interface IStorageExactState {
    function readFromStorage(bytes32 slot) external view returns (uint256);
}

contract PlasmaVaultT4ExactStateProbeTest is Test {
    address internal constant FACTORY = 0x324c5Dc1fC42c7a4D43d92df1eBA58a54d13Bf2d;
    address internal constant VAULT = 0x6E0Cdb5c21B3c8E340E9C9210057035bAfA86ffF;
    address internal constant DEX = 0xbd5dD095d9a6565C8222bb36B5814953F1C46f71;

    uint256 internal constant FACTORY_TOKEN_CONFIG_SLOT = 3;
    uint256 internal constant VAULT_POSITION_DATA_SLOT = 3;

    event ExactStateHeader(
        uint256 forkBlock,
        address indexed vault,
        address indexed dex,
        uint256 vaultCodeSize,
        uint256 dexCodeSize,
        bytes32 vaultCodeHash,
        bytes32 dexCodeHash
    );
    event ConstantsRaw(uint256 returnLength, bytes32 returnHash);
    event ConstantsDecoded(
        address liquidity,
        address factory,
        address supply,
        address borrow,
        address supplyToken0,
        address supplyToken1,
        address borrowToken0,
        address borrowToken1,
        uint256 vaultId,
        uint256 vaultType,
        bool supplyIsExpectedDex,
        bool borrowIsExpectedDex
    );
    event TokenMetadata(address indexed token, string symbol, uint8 decimals);
    event DexMetadata(uint256 dexId, bool dexIdCallOk, uint256 id, bool idCallOk);
    event CandidateState(
        uint256 indexed nftId,
        address indexed owner,
        uint256 configuredVaultId,
        uint256 rawTokenConfig,
        uint256 rawPositionData,
        bool belongsToDecodedVault,
        bool hasDebtEncoding
    );

    function setUp() public {
        vm.createSelectFork(vm.envString("PLASMA_RPC_URL"), vm.envUint("PLASMA_FORK_BLOCK"));
        assertEq(block.chainid, 9745, "unexpected chain");
    }

    function _word(bytes memory data, uint256 index) internal pure returns (uint256 value) {
        require(data.length >= (index + 1) * 32, "word out of bounds");
        assembly ("memory-safe") {
            value := mload(add(add(data, 0x20), mul(index, 0x20)))
        }
    }

    function _probeUint(address target, string memory signature) internal view returns (bool ok, uint256 value) {
        bytes memory data;
        (ok, data) = target.staticcall(abi.encodeWithSignature(signature));
        if (ok && data.length >= 32) value = abi.decode(data, (uint256));
        else ok = false;
    }

    function _symbol(address token) internal view returns (string memory value) {
        (bool ok, bytes memory data) = token.staticcall(abi.encodeWithSignature("symbol()"));
        if (ok && data.length >= 64) value = abi.decode(data, (string));
        else value = "<unavailable>";
    }

    function _decimals(address token) internal view returns (uint8 value) {
        (bool ok, bytes memory data) = token.staticcall(abi.encodeWithSignature("decimals()"));
        if (ok && data.length >= 32) value = abi.decode(data, (uint8));
    }

    function test_exactPinnedStateAndCandidates() public {
        emit ExactStateHeader(
            block.number,
            VAULT,
            DEX,
            VAULT.code.length,
            DEX.code.length,
            VAULT.codehash,
            DEX.codehash
        );
        assertGt(VAULT.code.length, 0, "exact vault has no code at pinned block");
        assertGt(DEX.code.length, 0, "exact DEX has no code at pinned block");

        (bool ok, bytes memory data) = VAULT.staticcall(abi.encodeWithSignature("constantsView()"));
        assertTrue(ok, "constantsView failed on exact vault");
        emit ConstantsRaw(data.length, keccak256(data));
        assertGe(data.length, 18 * 32, "unexpected constants layout");

        address liquidity = address(uint160(_word(data, 0)));
        address factory = address(uint160(_word(data, 1)));
        address supply = address(uint160(_word(data, 6)));
        address borrow = address(uint160(_word(data, 7)));
        address supplyToken0 = address(uint160(_word(data, 8)));
        address supplyToken1 = address(uint160(_word(data, 9)));
        address borrowToken0 = address(uint160(_word(data, 10)));
        address borrowToken1 = address(uint160(_word(data, 11)));
        uint256 vaultId = _word(data, 12);
        uint256 vaultType = _word(data, 13);

        emit ConstantsDecoded(
            liquidity,
            factory,
            supply,
            borrow,
            supplyToken0,
            supplyToken1,
            borrowToken0,
            borrowToken1,
            vaultId,
            vaultType,
            supply == DEX,
            borrow == DEX
        );
        assertEq(factory, FACTORY, "unexpected factory");
        assertTrue(supply == DEX || borrow == DEX, "expected DEX is neither supply nor borrow side");

        emit TokenMetadata(supplyToken0, _symbol(supplyToken0), _decimals(supplyToken0));
        emit TokenMetadata(supplyToken1, _symbol(supplyToken1), _decimals(supplyToken1));
        emit TokenMetadata(borrowToken0, _symbol(borrowToken0), _decimals(borrowToken0));
        emit TokenMetadata(borrowToken1, _symbol(borrowToken1), _decimals(borrowToken1));

        (bool dexIdOk, uint256 dexId) = _probeUint(DEX, "DEX_ID()");
        (bool idOk, uint256 id) = _probeUint(DEX, "ID()");
        emit DexMetadata(dexId, dexIdOk, id, idOk);

        uint256[4] memory ids = [uint256(2770), uint256(2887), uint256(2869), uint256(2725)];
        address factoryOwner = IFactoryExactState(FACTORY).owner();
        for (uint256 i; i < ids.length; ++i) {
            uint256 nftId = ids[i];
            address nftOwner = IFactoryExactState(FACTORY).ownerOf(nftId);
            vm.prank(factoryOwner);
            uint256 tokenConfig = IFactoryExactState(FACTORY).readFromStorage(
                keccak256(abi.encode(nftId, FACTORY_TOKEN_CONFIG_SLOT))
            );
            uint256 configuredVaultId = (tokenConfig >> 192) & type(uint32).max;
            vm.prank(factoryOwner);
            uint256 positionData = IStorageExactState(VAULT).readFromStorage(
                keccak256(abi.encode(nftId, VAULT_POSITION_DATA_SLOT))
            );
            emit CandidateState(
                nftId,
                nftOwner,
                configuredVaultId,
                tokenConfig,
                positionData,
                configuredVaultId == vaultId,
                positionData != 0 && (positionData & 1) == 0
            );
            assertTrue(nftOwner != address(0), "missing candidate owner");
            assertEq(configuredVaultId, vaultId, "candidate belongs to another vault");
            assertTrue(positionData != 0 && (positionData & 1) == 0, "candidate has no debt encoding");
        }
    }
}
