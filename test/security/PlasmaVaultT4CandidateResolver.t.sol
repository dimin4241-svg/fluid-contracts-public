// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.21;

import {Test} from "forge-std/Test.sol";

interface IFactoryCandidateResolver {
    function owner() external view returns (address);
    function ownerOf(uint256 nftId) external view returns (address);
    function readFromStorage(bytes32 slot) external view returns (uint256);
    function getVaultAddress(uint256 vaultId) external view returns (address);
}

interface IVaultCandidateResolver {
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

contract PlasmaVaultT4CandidateResolverTest is Test {
    address internal constant FACTORY = 0x324c5Dc1fC42c7a4D43d92df1eBA58a54d13Bf2d;
    uint256 internal constant TOKEN_CONFIG_SLOT = 3;

    event FactoryState(
        uint256 forkBlock,
        address indexed factory,
        uint256 factoryCodeSize,
        address indexed factoryOwner
    );
    event CandidateResolved(
        uint256 indexed nftId,
        address indexed nftOwner,
        uint256 rawTokenConfig,
        uint256 vaultId,
        address indexed resolvedVault,
        uint256 vaultCodeSize,
        bytes32 vaultCodeHash
    );
    event ResolvedConstants(
        address indexed vault,
        uint256 vaultId,
        uint256 vaultType,
        address liquidity,
        address supply,
        address borrow,
        address supplyToken0,
        address supplyToken1,
        address borrowToken0,
        address borrowToken1
    );
    event TokenMetadata(address indexed token, string symbol, uint8 decimals);
    event ResolvedComparison(
        address indexed resolvedVault,
        address claimedVault,
        bool equalsClaimedVault,
        address claimedDex,
        bool supplyEqualsClaimedDex,
        bool borrowEqualsClaimedDex
    );

    function setUp() public {
        vm.createSelectFork(vm.envString("PLASMA_RPC_URL"), vm.envUint("PLASMA_FORK_BLOCK"));
        assertEq(block.chainid, 9745, "unexpected chain");
    }

    function _symbol(address token) internal view returns (string memory value) {
        if (token == address(0)) return "<zero>";
        (bool ok, bytes memory data) = token.staticcall(abi.encodeWithSignature("symbol()"));
        if (ok && data.length >= 64) value = abi.decode(data, (string));
        else value = "<unavailable>";
    }

    function _decimals(address token) internal view returns (uint8 value) {
        if (token == address(0)) return 0;
        (bool ok, bytes memory data) = token.staticcall(abi.encodeWithSignature("decimals()"));
        if (ok && data.length >= 32) value = abi.decode(data, (uint8));
    }

    function _emitToken(address token) internal {
        emit TokenMetadata(token, _symbol(token), _decimals(token));
    }

    function test_resolveCandidatesFromFactoryOnly() public {
        assertGt(FACTORY.code.length, 0, "factory has no code");
        address factoryOwner = IFactoryCandidateResolver(FACTORY).owner();
        emit FactoryState(block.number, FACTORY, FACTORY.code.length, factoryOwner);

        uint256[4] memory ids = [uint256(2770), uint256(2887), uint256(2869), uint256(2725)];
        address commonVault;
        uint256 commonVaultId;

        for (uint256 i; i < ids.length; ++i) {
            uint256 nftId = ids[i];
            address nftOwner = IFactoryCandidateResolver(FACTORY).ownerOf(nftId);
            vm.prank(factoryOwner);
            uint256 tokenConfig = IFactoryCandidateResolver(FACTORY).readFromStorage(
                keccak256(abi.encode(nftId, TOKEN_CONFIG_SLOT))
            );
            uint256 vaultId = (tokenConfig >> 192) & type(uint32).max;
            address resolvedVault = IFactoryCandidateResolver(FACTORY).getVaultAddress(vaultId);

            emit CandidateResolved(
                nftId,
                nftOwner,
                tokenConfig,
                vaultId,
                resolvedVault,
                resolvedVault.code.length,
                resolvedVault.codehash
            );

            assertTrue(nftOwner != address(0), "candidate owner missing");
            assertGt(vaultId, 0, "candidate vault id missing");
            assertGt(resolvedVault.code.length, 0, "resolved vault has no code");

            if (i == 0) {
                commonVault = resolvedVault;
                commonVaultId = vaultId;
            } else {
                assertEq(resolvedVault, commonVault, "candidates resolve to different vaults");
                assertEq(vaultId, commonVaultId, "candidates have different vault ids");
            }
        }

        IVaultCandidateResolver.ConstantViews memory c =
            IVaultCandidateResolver(commonVault).constantsView();
        emit ResolvedConstants(
            commonVault,
            c.vaultId,
            c.vaultType,
            c.liquidity,
            c.supply,
            c.borrow,
            c.supplyToken.token0,
            c.supplyToken.token1,
            c.borrowToken.token0,
            c.borrowToken.token1
        );

        assertEq(c.factory, FACTORY, "resolved vault factory mismatch");
        assertEq(c.vaultId, commonVaultId, "constants vault id mismatch");
        assertEq(c.vaultId, IVaultCandidateResolver(commonVault).VAULT_ID(), "VAULT_ID mismatch");
        assertEq(c.vaultType, IVaultCandidateResolver(commonVault).TYPE(), "TYPE mismatch");

        _emitToken(c.supplyToken.token0);
        _emitToken(c.supplyToken.token1);
        _emitToken(c.borrowToken.token0);
        _emitToken(c.borrowToken.token1);

        address claimedVault = address(uint160(uint256(keccak256("placeholder"))));
        address claimedDex = address(uint160(uint256(keccak256("placeholder-dex"))));
        // The exact claimed addresses are emitted from env so this resolver stays rooted only in NFT state.
        claimedVault = vm.envAddress("CLAIMED_VAULT");
        claimedDex = vm.envAddress("CLAIMED_DEX");
        emit ResolvedComparison(
            commonVault,
            claimedVault,
            commonVault == claimedVault,
            claimedDex,
            c.supply == claimedDex,
            c.borrow == claimedDex
        );
    }
}
