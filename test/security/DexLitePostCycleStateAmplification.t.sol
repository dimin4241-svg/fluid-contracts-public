// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.29;

import {Test} from "forge-std/Test.sol";

struct DexKeyStateProbe {
    address token0;
    address token1;
    bytes32 salt;
}

struct TransferParamsStateProbe {
    address to;
    bool isCallback;
    bytes callbackData;
    bytes extraData;
}

interface IDexLiteStateProbe {
    function swapHop(
        address[] calldata path,
        DexKeyStateProbe[] calldata dexKeys,
        int256 amountSpecified,
        uint256[] calldata amountLimits,
        TransferParamsStateProbe calldata transferParams
    ) external payable returns (uint256 amountUnspecified);
}

interface IERC20StateProbe {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
}

interface IDexLiteCallbackStateProbe {
    function dexCallback(address token, uint256 amount, bytes calldata data) external;
}

contract DexLiteStateCycleExecutor is IDexLiteCallbackStateProbe {
    address internal constant DEX_LITE = 0xBbcb91440523216e2b87052A99F69c604A7b6e00;

    function execute(
        address[] memory path,
        DexKeyStateProbe[] memory keys,
        uint256 amountOut
    ) external returns (uint256 requiredInput) {
        uint256[] memory limits = new uint256[](keys.length);
        for (uint256 i; i < limits.length; ++i) limits[i] = type(uint256).max;
        requiredInput = IDexLiteStateProbe(DEX_LITE).swapHop(
            path,
            keys,
            -int256(amountOut),
            limits,
            TransferParamsStateProbe(address(this), true, "", "")
        );
    }

    function dexCallback(address token, uint256 amount, bytes calldata) external {
        require(msg.sender == DEX_LITE, "ONLY_DEX_LITE");
        require(IERC20StateProbe(token).transfer(DEX_LITE, amount), "PAYBACK_FAILED");
    }
}

contract DexLitePostCycleStateAmplificationTest is Test {
    address internal constant DEX_LITE = 0xBbcb91440523216e2b87052A99F69c604A7b6e00;
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address internal constant USDE = 0x4c9EDD5852cd905f086C759E8383e09bff1E68B3;
    bytes32 internal constant ESTIMATE_SWAP = keccak256(bytes("ESTIMATE_SWAP"));
    bytes4 internal constant ESTIMATE_SELECTOR = bytes4(keccak256("EstimateSwap(uint256)"));

    DexKeyStateProbe internal usdcUsdt;
    DexKeyStateProbe internal usdeUsdt;

    event LongCycleRound(
        uint256 indexed round,
        uint256 requiredInput,
        uint256 gain,
        uint256 dexUsdeBalance,
        uint256 gasUsed
    );
    event QuoteComparison(
        uint256 indexed routeKind,
        uint256 amount,
        uint256 beforeQuote,
        uint256 afterQuote,
        int256 quoteDelta
    );
    event StateSummary(
        uint256 rounds,
        uint256 firstGain,
        uint256 lastGain,
        uint256 maxGain,
        uint256 totalGain,
        uint256 dexLoss,
        int256 gainSlope
    );

    function setUp() public {
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"), vm.envUint("MAINNET_FORK_BLOCK"));
        usdcUsdt = DexKeyStateProbe(USDC, USDT, bytes32(0));
        usdeUsdt = DexKeyStateProbe(USDE, USDT, bytes32(0));
    }

    // 0: USDe -> USDT -> USDC
    // 1: USDC -> USDT -> USDe
    // 2: USDe -> USDT -> USDC -> USDT -> USDe
    function _build(uint256 routeKind, uint256 repeats)
        internal
        view
        returns (address[] memory path, DexKeyStateProbe[] memory keys)
    {
        if (routeKind == 0) {
            path = new address[](3);
            keys = new DexKeyStateProbe[](2);
            path[0] = USDE; path[1] = USDT; path[2] = USDC;
            keys[0] = usdeUsdt; keys[1] = usdcUsdt;
            return (path, keys);
        }
        if (routeKind == 1) {
            path = new address[](3);
            keys = new DexKeyStateProbe[](2);
            path[0] = USDC; path[1] = USDT; path[2] = USDE;
            keys[0] = usdcUsdt; keys[1] = usdeUsdt;
            return (path, keys);
        }

        uint256 hops = 4 * repeats;
        path = new address[](hops + 1);
        keys = new DexKeyStateProbe[](hops);
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

    function _estimate(
        address[] memory path,
        DexKeyStateProbe[] memory keys,
        int256 amountSpecified
    ) internal returns (bool ok, uint256 quote) {
        uint256[] memory limits = new uint256[](keys.length);
        if (amountSpecified < 0) {
            for (uint256 i; i < limits.length; ++i) limits[i] = type(uint256).max;
        }
        try IDexLiteStateProbe(DEX_LITE).swapHop(
            path,
            keys,
            amountSpecified,
            limits,
            TransferParamsStateProbe(address(0), false, "", abi.encode(ESTIMATE_SWAP))
        ) returns (uint256) {
            return (false, 0);
        } catch (bytes memory reason) {
            if (reason.length != 36) return (false, 0);
            bytes4 selector;
            assembly ("memory-safe") {
                selector := mload(add(reason, 0x20))
                quote := mload(add(reason, 0x24))
            }
            ok = selector == ESTIMATE_SELECTOR;
        }
    }

    function test_longCycles_doNotCreateNonlinearPostStateArbitrage() public {
        uint256[6] memory usdeAmounts = [uint256(1e15), 1e16, 1e17, 1e18, 10e18, 100e18];
        uint256[6] memory usdcAmounts = [uint256(1e3), 1e4, 1e5, 1e6, 10e6, 100e6];
        uint256[6] memory beforeUsdeToUsdc;
        uint256[6] memory beforeUsdcToUsde;

        (address[] memory p0, DexKeyStateProbe[] memory k0) = _build(0, 1);
        (address[] memory p1, DexKeyStateProbe[] memory k1) = _build(1, 1);
        for (uint256 i; i < 6; ++i) {
            (bool ok0, uint256 q0) = _estimate(p0, k0, int256(usdeAmounts[i]));
            (bool ok1, uint256 q1) = _estimate(p1, k1, int256(usdcAmounts[i]));
            if (ok0) beforeUsdeToUsdc[i] = q0;
            if (ok1) beforeUsdcToUsde[i] = q1;
        }

        (address[] memory cyclePath, DexKeyStateProbe[] memory cycleKeys) = _build(2, 256);
        DexLiteStateCycleExecutor executor = new DexLiteStateCycleExecutor();
        IERC20StateProbe usde = IERC20StateProbe(USDE);
        uint256 attackerStart = usde.balanceOf(address(executor));
        uint256 dexStart = usde.balanceOf(DEX_LITE);
        uint256 firstGain;
        uint256 lastGain;
        uint256 maxGain;
        uint256 rounds = 16;

        for (uint256 r; r < rounds; ++r) {
            uint256 before = usde.balanceOf(address(executor));
            uint256 gasBefore = gasleft();
            uint256 requiredInput = executor.execute(cyclePath, cycleKeys, 1e15);
            uint256 gasUsed = gasBefore - gasleft();
            uint256 gain = usde.balanceOf(address(executor)) - before;
            if (r == 0) firstGain = gain;
            lastGain = gain;
            if (gain > maxGain) maxGain = gain;
            emit LongCycleRound(r, requiredInput, gain, usde.balanceOf(DEX_LITE), gasUsed);
        }

        for (uint256 i; i < 6; ++i) {
            (bool ok0, uint256 after0) = _estimate(p0, k0, int256(usdeAmounts[i]));
            (bool ok1, uint256 after1) = _estimate(p1, k1, int256(usdcAmounts[i]));
            if (ok0 && beforeUsdeToUsdc[i] > 0) {
                emit QuoteComparison(0, usdeAmounts[i], beforeUsdeToUsdc[i], after0, int256(after0) - int256(beforeUsdeToUsdc[i]));
            }
            if (ok1 && beforeUsdcToUsde[i] > 0) {
                emit QuoteComparison(1, usdcAmounts[i], beforeUsdcToUsde[i], after1, int256(after1) - int256(beforeUsdcToUsde[i]));
            }
        }

        uint256 totalGain = usde.balanceOf(address(executor)) - attackerStart;
        uint256 dexLoss = dexStart - usde.balanceOf(DEX_LITE);
        emit StateSummary(
            rounds,
            firstGain,
            lastGain,
            maxGain,
            totalGain,
            dexLoss,
            int256(lastGain) - int256(firstGain)
        );
        assertEq(totalGain, dexLoss, "gain/loss mismatch");
    }
}
