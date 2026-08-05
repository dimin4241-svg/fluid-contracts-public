// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.21;

import { Test } from "forge-std/Test.sol";

interface IERC20Chunked {
    function balanceOf(address account) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
}

interface IFluidDexChunked {
    function swapOut(bool swap0to1, uint256 amountOut, uint256 amountInMax, address to)
        external payable returns (uint256 amountIn);
}

/// @notice Persists the forward input total across many externally callable
/// chunks. Each forwardChunk call can be sent as a separate transaction, so
/// the total route is not restricted to one block's gas limit.
contract ChunkedSplitExecutor {
    address internal immutable pool;
    address internal immutable token0;
    address internal immutable token1;
    bool internal immutable forward0to1;
    uint256 internal immutable amountOutEach;

    uint256 public totalForwardInput;
    uint256 public completedRounds;

    constructor(
        address pool_,
        address token0_,
        address token1_,
        bool forward0to1_,
        uint256 amountOutEach_
    ) {
        pool = pool_;
        token0 = token0_;
        token1 = token1_;
        forward0to1 = forward0to1_;
        amountOutEach = amountOutEach_;
        _approve(token0_, pool_);
        _approve(token1_, pool_);
    }

    function _approve(address token, address spender) private {
        (bool ok, bytes memory data) = token.call(
            abi.encodeWithSelector(IERC20Chunked.approve.selector, spender, type(uint256).max)
        );
        require(ok && (data.length == 0 || abi.decode(data, (bool))), "APPROVE_FAILED");
    }

    function forwardChunk(uint256 rounds) external returns (uint256 chunkInput) {
        for (uint256 i; i < rounds; ++i) {
            chunkInput += IFluidDexChunked(pool).swapOut(
                forward0to1, amountOutEach, type(uint256).max, address(this)
            );
        }
        totalForwardInput += chunkInput;
        completedRounds += rounds;
    }

    function reverseAll() external returns (uint256 reverseInput) {
        uint256 amountOut = totalForwardInput;
        require(amountOut > 0, "NO_FORWARD_INPUT");
        reverseInput = IFluidDexChunked(pool).swapOut(
            !forward0to1, amountOut, type(uint256).max, address(this)
        );
    }
}

contract SelectedChunkedSplitScalingTest is Test {
    event ChunkedScaleResult(
        string candidate,
        uint256 indexed rounds,
        uint256 chunkSize,
        uint256 completedRounds,
        uint256 totalForwardInput,
        uint256 reverseInput,
        int256 inputDelta,
        int256 profit,
        uint256 liquidityLoss,
        uint256 totalForwardGas,
        uint256 maxForwardChunkGas,
        uint256 reverseGas
    );

    event ChunkedScaleRevert(
        string candidate,
        uint256 indexed targetRounds,
        uint256 completedRounds,
        string phase,
        bytes4 selector,
        uint256 errorId,
        uint256 totalForwardInput,
        uint256 totalForwardGas,
        uint256 maxForwardChunkGas
    );

    address internal pool;
    address internal liquidity;
    address internal token0;
    address internal token1;
    bool internal forward0to1;
    uint256 internal amountOutEach;
    uint256 internal chunkSize;
    uint8 internal dec0;
    uint8 internal dec1;
    string internal candidate;

    function setUp() public {
        vm.createSelectFork(vm.envString("RPC_URL"));
        pool = vm.envAddress("POOL");
        liquidity = vm.envAddress("LIQUIDITY");
        token0 = vm.envAddress("TOKEN0");
        token1 = vm.envAddress("TOKEN1");
        forward0to1 = vm.envBool("FORWARD_0_TO_1");
        amountOutEach = vm.envUint("AMOUNT_OUT_EACH");
        chunkSize = vm.envUint("CHUNK_SIZE");
        dec0 = uint8(vm.envUint("TOKEN0_DECIMALS"));
        dec1 = uint8(vm.envUint("TOKEN1_DECIMALS"));
        candidate = vm.envString("CANDIDATE");
    }

    function _funding(uint8 decimals_) internal pure returns (uint256) {
        uint256 exponent = uint256(decimals_) + 14;
        if (exponent > 34) exponent = 34;
        return 10 ** exponent;
    }

    function _decode(bytes memory reason) internal pure returns (bytes4 selector, uint256 errorId) {
        if (reason.length >= 4) {
            assembly {
                selector := mload(add(reason, 32))
            }
        }
        if (reason.length >= 36) {
            assembly {
                errorId := mload(add(reason, 36))
            }
        }
    }

    function _run(uint256 targetRounds) internal {
        ChunkedSplitExecutor executor = new ChunkedSplitExecutor(
            pool, token0, token1, forward0to1, amountOutEach
        );
        deal(token0, address(executor), _funding(dec0));
        deal(token1, address(executor), _funding(dec1));

        address inputToken = forward0to1 ? token0 : token1;
        address profitToken = forward0to1 ? token1 : token0;
        uint256 inputBefore = IERC20Chunked(inputToken).balanceOf(address(executor));
        uint256 profitBefore = IERC20Chunked(profitToken).balanceOf(address(executor));
        uint256 liquidityBefore = IERC20Chunked(profitToken).balanceOf(liquidity);

        uint256 totalForwardGas;
        uint256 maxForwardChunkGas;
        uint256 done;

        while (done < targetRounds) {
            uint256 currentChunk = targetRounds - done;
            if (currentChunk > chunkSize) currentChunk = chunkSize;
            uint256 gasBefore = gasleft();
            try executor.forwardChunk(currentChunk) returns (uint256) {
                uint256 gasUsed = gasBefore - gasleft();
                totalForwardGas += gasUsed;
                if (gasUsed > maxForwardChunkGas) maxForwardChunkGas = gasUsed;
                done += currentChunk;
            } catch (bytes memory reason) {
                (bytes4 selector, uint256 errorId) = _decode(reason);
                emit ChunkedScaleRevert(
                    candidate,
                    targetRounds,
                    done,
                    "forward",
                    selector,
                    errorId,
                    executor.totalForwardInput(),
                    totalForwardGas,
                    maxForwardChunkGas
                );
                return;
            }
        }

        uint256 reverseGasBefore = gasleft();
        try executor.reverseAll() returns (uint256 reverseInput) {
            uint256 reverseGas = reverseGasBefore - gasleft();
            int256 inputDelta = int256(
                IERC20Chunked(inputToken).balanceOf(address(executor))
            ) - int256(inputBefore);
            int256 profit = int256(
                IERC20Chunked(profitToken).balanceOf(address(executor))
            ) - int256(profitBefore);
            uint256 liquidityAfter = IERC20Chunked(profitToken).balanceOf(liquidity);
            uint256 liquidityLoss = liquidityBefore > liquidityAfter
                ? liquidityBefore - liquidityAfter
                : 0;

            emit ChunkedScaleResult(
                candidate,
                targetRounds,
                chunkSize,
                executor.completedRounds(),
                executor.totalForwardInput(),
                reverseInput,
                inputDelta,
                profit,
                liquidityLoss,
                totalForwardGas,
                maxForwardChunkGas,
                reverseGas
            );
        } catch (bytes memory reason) {
            (bytes4 selector, uint256 errorId) = _decode(reason);
            emit ChunkedScaleRevert(
                candidate,
                targetRounds,
                done,
                "reverse",
                selector,
                errorId,
                executor.totalForwardInput(),
                totalForwardGas,
                maxForwardChunkGas
            );
        }
    }

    function test_scale_128() public { _run(128); }
    function test_scale_256() public { _run(256); }
    function test_scale_512() public { _run(512); }
    function test_scale_1024() public { _run(1024); }
    function test_scale_2048() public { _run(2048); }
    function test_scale_4096() public { _run(4096); }
    function test_scale_8192() public { _run(8192); }
}
