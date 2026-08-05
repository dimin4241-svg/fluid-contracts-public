// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.21;

import { Test } from "forge-std/Test.sol";

interface IERC20Route {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
}

interface IFluidDexRoute {
    function swapIn(bool swap0to1, uint256 amountIn, uint256 amountOutMin, address to)
        external payable returns (uint256 amountOut);
    function swapOut(bool swap0to1, uint256 amountOut, uint256 amountInMax, address to)
        external payable returns (uint256 amountIn);
}

contract CompositeRouteExecutor {
    address public immutable token0;
    address public immutable token1;

    constructor(address token0_, address token1_, address poolA_, address poolB_) {
        token0 = token0_;
        token1 = token1_;
        _approve(token0_, poolA_);
        _approve(token1_, poolA_);
        if (poolB_ != poolA_) {
            _approve(token0_, poolB_);
            _approve(token1_, poolB_);
        }
    }

    function _approve(address token, address spender) private {
        (bool ok, bytes memory data) = token.call(
            abi.encodeWithSelector(IERC20Route.approve.selector, spender, type(uint256).max)
        );
        require(ok && (data.length == 0 || abi.decode(data, (bool))), "APPROVE_FAILED");
    }

    /// exact token1 out from A, then spend all received token1 exact-in on B.
    function outThenIn(address poolA, address poolB, uint256 amountOut1)
        external returns (uint256 amountIn0, uint256 amountOut0, int256 delta0, int256 delta1)
    {
        uint256 before0 = IERC20Route(token0).balanceOf(address(this));
        uint256 before1 = IERC20Route(token1).balanceOf(address(this));
        amountIn0 = IFluidDexRoute(poolA).swapOut(true, amountOut1, type(uint256).max, address(this));
        amountOut0 = IFluidDexRoute(poolB).swapIn(false, amountOut1, 0, address(this));
        delta0 = int256(IERC20Route(token0).balanceOf(address(this))) - int256(before0);
        delta1 = int256(IERC20Route(token1).balanceOf(address(this))) - int256(before1);
    }

    /// exact token0 in on A, then request the same token0 exact-out from B.
    function inThenOut(address poolA, address poolB, uint256 amountIn0)
        external returns (uint256 amountOut1, uint256 amountIn1, int256 delta0, int256 delta1)
    {
        uint256 before0 = IERC20Route(token0).balanceOf(address(this));
        uint256 before1 = IERC20Route(token1).balanceOf(address(this));
        amountOut1 = IFluidDexRoute(poolA).swapIn(true, amountIn0, 0, address(this));
        amountIn1 = IFluidDexRoute(poolB).swapOut(false, amountIn0, type(uint256).max, address(this));
        delta0 = int256(IERC20Route(token0).balanceOf(address(this))) - int256(before0);
        delta1 = int256(IERC20Route(token1).balanceOf(address(this))) - int256(before1);
    }
}

contract LowFeeCompositeRoutesTest is Test {
    uint256 internal constant FORK_BLOCK = 25_686_672;
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address internal constant DEX2 = 0x667701e51B4D1Ca244F17C78F7aB8744B4C99F9B;
    address internal constant DEX34 = 0xea734B615888c669667038D11950f44b177F15C0;

    event RouteBest(
        string route,
        address indexed poolA,
        address indexed poolB,
        uint256 amount,
        int256 profitRaw,
        int256 otherDeltaRaw,
        uint256 firstQuote,
        uint256 secondQuote,
        uint256 gasUsed
    );

    function setUp() public {
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"), FORK_BLOCK);
    }

    function test_searchMixedAndCrossPoolRoutes() public {
        _searchOutThenIn(DEX2, DEX2, "DEX2 out-in");
        _searchInThenOut(DEX2, DEX2, "DEX2 in-out");
        _searchOutThenIn(DEX34, DEX34, "DEX34 out-in");
        _searchInThenOut(DEX34, DEX34, "DEX34 in-out");
        _searchOutThenIn(DEX2, DEX34, "DEX2->DEX34 out-in");
        _searchOutThenIn(DEX34, DEX2, "DEX34->DEX2 out-in");
        _searchInThenOut(DEX2, DEX34, "DEX2->DEX34 in-out");
        _searchInThenOut(DEX34, DEX2, "DEX34->DEX2 in-out");
    }

    function _newExecutor(address poolA, address poolB) internal returns (CompositeRouteExecutor executor) {
        executor = new CompositeRouteExecutor(USDC, USDT, poolA, poolB);
        deal(USDC, address(executor), 1_000_000_000_000); // fork-only attacker inventory
    }

    function _searchOutThenIn(address poolA, address poolB, string memory label) internal {
        CompositeRouteExecutor executor = _newExecutor(poolA, poolB);
        uint256 snap = vm.snapshot();
        int256 best;
        int256 bestOther;
        uint256 bestAmount;
        uint256 bestFirst;
        uint256 bestSecond;
        uint256 bestGas;

        for (uint256 amount = 100; amount <= 5_000; amount++) {
            uint256 gasBefore = gasleft();
            try executor.outThenIn(poolA, poolB, amount) returns (
                uint256 firstQuote, uint256 secondQuote, int256 d0, int256 d1
            ) {
                if (d0 > best) {
                    best = d0; bestOther = d1; bestAmount = amount;
                    bestFirst = firstQuote; bestSecond = secondQuote; bestGas = gasBefore - gasleft();
                }
            } catch {}
            require(vm.revertTo(snap), "restore failed");
        }

        uint256 amountLarge = 10_000;
        for (uint256 i; i < 9; i++) {
            uint256 gasBefore = gasleft();
            try executor.outThenIn(poolA, poolB, amountLarge) returns (
                uint256 firstQuote, uint256 secondQuote, int256 d0, int256 d1
            ) {
                if (d0 > best) {
                    best = d0; bestOther = d1; bestAmount = amountLarge;
                    bestFirst = firstQuote; bestSecond = secondQuote; bestGas = gasBefore - gasleft();
                }
            } catch {}
            require(vm.revertTo(snap), "restore failed");
            amountLarge *= 10;
        }
        emit RouteBest(label, poolA, poolB, bestAmount, best, bestOther, bestFirst, bestSecond, bestGas);
    }

    function _searchInThenOut(address poolA, address poolB, string memory label) internal {
        CompositeRouteExecutor executor = _newExecutor(poolA, poolB);
        uint256 snap = vm.snapshot();
        int256 best;
        int256 bestOther;
        uint256 bestAmount;
        uint256 bestFirst;
        uint256 bestSecond;
        uint256 bestGas;

        for (uint256 amount = 100; amount <= 5_000; amount++) {
            uint256 gasBefore = gasleft();
            try executor.inThenOut(poolA, poolB, amount) returns (
                uint256 firstQuote, uint256 secondQuote, int256 d0, int256 d1
            ) {
                if (d1 > best) {
                    best = d1; bestOther = d0; bestAmount = amount;
                    bestFirst = firstQuote; bestSecond = secondQuote; bestGas = gasBefore - gasleft();
                }
            } catch {}
            require(vm.revertTo(snap), "restore failed");
        }

        uint256 amountLarge = 10_000;
        for (uint256 i; i < 9; i++) {
            uint256 gasBefore = gasleft();
            try executor.inThenOut(poolA, poolB, amountLarge) returns (
                uint256 firstQuote, uint256 secondQuote, int256 d0, int256 d1
            ) {
                if (d1 > best) {
                    best = d1; bestOther = d0; bestAmount = amountLarge;
                    bestFirst = firstQuote; bestSecond = secondQuote; bestGas = gasBefore - gasleft();
                }
            } catch {}
            require(vm.revertTo(snap), "restore failed");
            amountLarge *= 10;
        }
        emit RouteBest(label, poolA, poolB, bestAmount, best, bestOther, bestFirst, bestSecond, bestGas);
    }
}
