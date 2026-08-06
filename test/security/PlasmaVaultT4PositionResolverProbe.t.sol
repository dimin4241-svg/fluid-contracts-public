// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.21;

import {Test} from "forge-std/Test.sol";

interface IVaultFactoryPositionProbe {
    function ownerOf(uint256 nftId) external view returns (address);
}

contract PlasmaVaultT4PositionResolverProbeTest is Test {
    address internal constant RESOLVER = 0x2795717571D0A03b5c8B5962fcAE2682B92D3a9a;
    address internal constant FACTORY = 0x324c5Dc1fC42c7a4D43d92df1eBA58a54d13Bf2d;
    address internal constant VAULT = 0x6E0cDB09eb33cD3894C905E0DFF9289b95a86FFF;

    struct Position {
        uint256 nftId;
        address owner;
        bool isLiquidated;
        bool isSupplyPosition;
        int256 tick;
        uint256 tickId;
        uint256 beforeSupply;
        uint256 beforeBorrow;
        uint256 beforeDustBorrow;
        uint256 supply;
        uint256 borrow;
        uint256 dustBorrow;
    }

    event PositionDecoded(
        uint256 indexed nftId,
        address indexed owner,
        bool isLiquidated,
        bool isSupplyPosition,
        int256 tick,
        uint256 tickId,
        uint256 beforeSupply,
        uint256 beforeBorrow,
        uint256 beforeDustBorrow,
        uint256 supply,
        uint256 borrow,
        uint256 dustBorrow,
        uint256 debtToSupply1e18
    );
    event PositionSummary(
        uint256 decoded,
        uint256 positionsWithDebt,
        uint256 largestBorrowNft,
        uint256 largestBorrow,
        uint256 highestRatioNft,
        uint256 highestRatio1e18
    );

    function setUp() public {
        vm.createSelectFork(vm.envString("PLASMA_RPC_URL"), vm.envUint("PLASMA_FORK_BLOCK"));
        assertEq(block.chainid, 9745, "unexpected chain");
    }

    function _decodePosition(uint256 nftId) internal view returns (Position memory p) {
        (bool ok, bytes memory data) = RESOLVER.staticcall(
            abi.encodeWithSignature("positionByNftId(uint256)", nftId)
        );
        require(ok, "resolver position call failed");
        require(data.length >= 12 * 32, "short resolver response");

        uint256 ownerRaw;
        uint256 liquidatedRaw;
        uint256 supplyPositionRaw;
        int256 tick;
        assembly {
            mstore(p, mload(add(data, 0x20)))
            ownerRaw := mload(add(data, 0x40))
            liquidatedRaw := mload(add(data, 0x60))
            supplyPositionRaw := mload(add(data, 0x80))
            tick := mload(add(data, 0xa0))
            mstore(add(p, 0xa0), mload(add(data, 0xc0)))
            mstore(add(p, 0xc0), mload(add(data, 0xe0)))
            mstore(add(p, 0xe0), mload(add(data, 0x100)))
            mstore(add(p, 0x100), mload(add(data, 0x120)))
            mstore(add(p, 0x120), mload(add(data, 0x140)))
            mstore(add(p, 0x140), mload(add(data, 0x160)))
            mstore(add(p, 0x160), mload(add(data, 0x180)))
        }
        p.owner = address(uint160(ownerRaw));
        p.isLiquidated = liquidatedRaw != 0;
        p.isSupplyPosition = supplyPositionRaw != 0;
        p.tick = tick;
    }

    function test_decodeActiveT4Positions() public {
        uint256[10] memory ids = [
            uint256(1871),
            uint256(2473),
            uint256(2517),
            uint256(2580),
            uint256(2725),
            uint256(2726),
            uint256(2770),
            uint256(2864),
            uint256(2869),
            uint256(2887)
        ];

        uint256 positionsWithDebt;
        uint256 largestBorrowNft;
        uint256 largestBorrow;
        uint256 highestRatioNft;
        uint256 highestRatio;

        for (uint256 i; i < ids.length; ++i) {
            Position memory p = _decodePosition(ids[i]);
            assertEq(p.nftId, ids[i], "resolver nft mismatch");
            assertEq(p.owner, IVaultFactoryPositionProbe(FACTORY).ownerOf(ids[i]), "owner mismatch");

            uint256 ratio = p.supply == 0 ? type(uint256).max : (p.borrow * 1e18) / p.supply;
            if (p.borrow > 0) {
                ++positionsWithDebt;
                if (p.borrow > largestBorrow) {
                    largestBorrow = p.borrow;
                    largestBorrowNft = p.nftId;
                }
                if (ratio > highestRatio) {
                    highestRatio = ratio;
                    highestRatioNft = p.nftId;
                }
            }

            emit PositionDecoded(
                p.nftId,
                p.owner,
                p.isLiquidated,
                p.isSupplyPosition,
                p.tick,
                p.tickId,
                p.beforeSupply,
                p.beforeBorrow,
                p.beforeDustBorrow,
                p.supply,
                p.borrow,
                p.dustBorrow,
                ratio
            );
        }

        emit PositionSummary(
            ids.length,
            positionsWithDebt,
            largestBorrowNft,
            largestBorrow,
            highestRatioNft,
            highestRatio
        );
        assertGt(positionsWithDebt, 0, "no active T4 debt position");
    }
}
