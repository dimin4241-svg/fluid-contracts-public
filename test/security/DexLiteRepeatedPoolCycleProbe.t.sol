// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.29;

import {Test} from "forge-std/Test.sol";

struct DexKey {
    address token0;
    address token1;
    bytes32 salt;
}

struct TransferParams {
    address to;
    bool isCallback;
    bytes callbackData;
    bytes extraData;
}

interface IDexLiteCycleProbe {
    function swapHop(
        address[] calldata path,
        DexKey[] calldata dexKeys,
        int256 amountSpecified,
        uint256[] calldata amountLimits,
        TransferParams calldata transferParams
    ) external payable returns (uint256 amountUnspecified);

    function readFromStorage(bytes32 slot) external view returns (uint256 result);
}

interface IERC20MetadataProbe {
    function decimals() external view returns (uint8);
}

contract DexLiteRepeatedPoolCycleProbeTest is Test {
    address internal constant DEX_LITE = 0xBbcb91440523216e2b87052A99F69c604A7b6e00;
    address internal constant NATIVE_TOKEN = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
    bytes32 internal constant ESTIMATE_SWAP = keccak256(bytes("ESTIMATE_SWAP"));
    bytes4 internal constant ESTIMATE_SELECTOR = bytes4(keccak256("EstimateSwap(uint256)"));
    uint256 internal constant DEXES_LIST_SLOT = 1;
    uint256 internal constant INTERNAL_DECIMALS = 9;

    uint256 internal validQuotes;
    int256 internal globalBest;

    event DexInventory(uint256 indexed index, address token0, address token1, bytes32 salt);
    event CycleQuote(
        uint256 indexed dexIndex,
        uint256 hops,
        bool startsToken0,
        bool exactOutput,
        uint256 specified,
        uint256 unspecified,
        int256 grossDelta
    );
    event PositiveCycle(
        uint256 indexed dexIndex,
        uint256 hops,
        bool startsToken0,
        bool exactOutput,
        uint256 specified,
        uint256 unspecified,
        int256 grossDelta
    );

    function setUp() public {
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"), vm.envUint("MAINNET_FORK_BLOCK"));
        assertEq(block.chainid, 1, "unexpected chain");
        assertGt(DEX_LITE.code.length, 0, "DexLite missing");
    }

    function _readDex(uint256 index) internal view returns (DexKey memory key) {
        bytes32 base = keccak256(abi.encode(DEXES_LIST_SLOT));
        key.token0 = address(uint160(IDexLiteCycleProbe(DEX_LITE).readFromStorage(bytes32(uint256(base) + index * 3))));
        key.token1 = address(uint160(IDexLiteCycleProbe(DEX_LITE).readFromStorage(bytes32(uint256(base) + index * 3 + 1))));
        key.salt = bytes32(IDexLiteCycleProbe(DEX_LITE).readFromStorage(bytes32(uint256(base) + index * 3 + 2)));
    }

    function _decimals(address token) internal view returns (uint8) {
        if (token == NATIVE_TOKEN) return 18;
        try IERC20MetadataProbe(token).decimals() returns (uint8 d) {
            return d;
        } catch {
            return 18;
        }
    }

    function _rawFromInternal(uint256 internalAmount, uint8 decimals_) internal pure returns (uint256 raw) {
        if (decimals_ > INTERNAL_DECIMALS) {
            raw = internalAmount * (10 ** (decimals_ - INTERNAL_DECIMALS));
        } else {
            uint256 divisor = 10 ** (INTERNAL_DECIMALS - decimals_);
            raw = (internalAmount + divisor - 1) / divisor;
        }
        if (raw == 0) raw = 1;
    }

    function _sizeAt(uint256 index) internal pure returns (uint256) {
        if (index == 0) return 1e4;
        if (index == 1) return 1e5;
        if (index == 2) return 1e6;
        if (index == 3) return 1e7;
        if (index == 4) return 1e8;
        return 1e9;
    }

    function _hopsAt(uint256 index) internal pure returns (uint256) {
        if (index == 0) return 2;
        if (index == 1) return 4;
        if (index == 2) return 8;
        return 16;
    }

    function _buildCycle(
        DexKey memory key,
        uint256 hops,
        bool startsToken0
    ) internal pure returns (address[] memory path, DexKey[] memory keys) {
        path = new address[](hops + 1);
        keys = new DexKey[](hops);
        path[0] = startsToken0 ? key.token0 : key.token1;
        for (uint256 i; i < hops; ++i) {
            path[i + 1] = path[i] == key.token0 ? key.token1 : key.token0;
            keys[i] = key;
        }
    }

    function _estimate(
        address[] memory path,
        DexKey[] memory keys,
        int256 amountSpecified
    ) internal returns (bool ok, uint256 amountUnspecified) {
        uint256[] memory limits = new uint256[](keys.length);
        if (amountSpecified < 0) {
            for (uint256 i; i < limits.length; ++i) limits[i] = type(uint256).max;
        }

        try IDexLiteCycleProbe(DEX_LITE).swapHop(
            path,
            keys,
            amountSpecified,
            limits,
            TransferParams(address(0), false, "", abi.encode(ESTIMATE_SWAP))
        ) returns (uint256) {
            return (false, 0);
        } catch (bytes memory reason) {
            if (reason.length != 36) return (false, 0);
            bytes4 selector;
            assembly ("memory-safe") {
                selector := mload(add(reason, 0x20))
                amountUnspecified := mload(add(reason, 0x24))
            }
            ok = selector == ESTIMATE_SELECTOR;
        }
    }

    function _record(
        uint256 dexIndex,
        uint256 hops,
        bool startsToken0,
        bool exactOutput,
        uint256 specified,
        uint256 unspecified,
        int256 delta
    ) internal {
        ++validQuotes;
        if (delta > globalBest) globalBest = delta;
        emit CycleQuote(dexIndex, hops, startsToken0, exactOutput, specified, unspecified, delta);
        if (delta > 0) {
            emit PositiveCycle(dexIndex, hops, startsToken0, exactOutput, specified, unspecified, delta);
        }
    }

    function _probeOne(
        uint256 dexIndex,
        DexKey memory key,
        uint256 hops,
        bool startsToken0,
        uint256 internalSize
    ) internal {
        (address[] memory path, DexKey[] memory keys) = _buildCycle(key, hops, startsToken0);
        uint256 amount = _rawFromInternal(internalSize, _decimals(path[0]));
        if (amount > uint256(type(int256).max)) return;

        (bool okOut, uint256 requiredInput) = _estimate(path, keys, -int256(amount));
        if (okOut) {
            _record(
                dexIndex,
                hops,
                startsToken0,
                true,
                amount,
                requiredInput,
                int256(amount) - int256(requiredInput)
            );
        }

        (bool okIn, uint256 receivedOutput) = _estimate(path, keys, int256(amount));
        if (okIn) {
            _record(
                dexIndex,
                hops,
                startsToken0,
                false,
                amount,
                receivedOutput,
                int256(receivedOutput) - int256(amount)
            );
        }
    }

    function test_allLiveDexes_repeatedPoolCycles() public {
        uint256 count = IDexLiteCycleProbe(DEX_LITE).readFromStorage(bytes32(DEXES_LIST_SLOT));
        assertGt(count, 0, "no live dexes");

        for (uint256 dexIndex; dexIndex < count; ++dexIndex) {
            DexKey memory key = _readDex(dexIndex);
            emit DexInventory(dexIndex, key.token0, key.token1, key.salt);

            for (uint256 hopIndex; hopIndex < 4; ++hopIndex) {
                for (uint256 side; side < 2; ++side) {
                    for (uint256 sizeIndex; sizeIndex < 6; ++sizeIndex) {
                        _probeOne(
                            dexIndex,
                            key,
                            _hopsAt(hopIndex),
                            side == 0,
                            _sizeAt(sizeIndex)
                        );
                    }
                }
            }
        }

        emit log_named_uint("live dex count", count);
        emit log_named_uint("valid cycle quotes", validQuotes);
        emit log_named_int("global best gross delta", globalBest);
        assertGt(validQuotes, 0, "no cycle quotes succeeded");
    }
}
