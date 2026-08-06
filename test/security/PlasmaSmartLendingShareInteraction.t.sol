// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.21;

import {Test} from "forge-std/Test.sol";

interface IERC20ShareProbe {
    function balanceOf(address account) external view returns (uint256);
    function totalSupply() external view returns (uint256);
}

interface IFluidDexShareProbe {
    function swapOut(bool swap0to1, uint256 amountOut, uint256 amountInMax, address to)
        external payable returns (uint256 amountIn);
}

interface IFluidSmartLendingShareProbe {
    function balanceOf(address account) external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function exchangePrice() external view returns (uint184);
    function rebalanceDiff() external view returns (int256);

    function deposit(
        uint256 token0Amt,
        uint256 token1Amt,
        uint256 minSharesAmt,
        address to
    ) external payable returns (uint256 amount, uint256 shares);

    function withdrawPerfect(
        uint256 shares,
        uint256 minToken0Withdraw,
        uint256 minToken1Withdraw,
        address to
    ) external returns (uint256 amount, uint256 token0Amt, uint256 token1Amt);
}

contract PlasmaSmartLendingShareInteractionTest is Test {
    address internal constant WRAPPER = 0x983107BB3dcb71f3A30176114D8a17c454A62514;
    address internal constant POOL = 0x36a905DCD12C0201f884fAFda71e63E9547975DA;
    address internal constant TOKEN0 = 0x0B2b2B2076d95dda7817e785989fE353fe955ef9; // sUSDai, 18 decimals
    address internal constant TOKEN1 = 0xB8CE59FC3717ada4C02eaDF9682A9e934F625ebb; // USDT0, 6 decimals

    uint256 internal constant PERTURB_ROUNDS = 128;
    uint256 internal constant PERTURB_AMOUNT_OUT0_EACH = 256100000000001;
    uint256 internal constant START_TOKEN0 = 10_000_000 ether;
    uint256 internal constant START_TOKEN1 = 10_000_000 * 1e6;

    string internal rpcUrl;
    uint256 internal forkBlock;

    enum Scenario {
        PerturbOnly,
        WrapperOnly,
        WrapperAndPerturb
    }

    struct Result {
        int256 token0Delta;
        int256 token1Delta;
        uint256 token1SpentInPerturb;
        uint256 token0SpentInReverse;
        uint256 wrapperMinted;
        uint256 dexSharesReceived;
        uint256 token0Withdraw;
        uint256 token1Withdraw;
        int256 rebalanceDiffBefore;
        int256 rebalanceDiffAfter;
        uint256 gasUsed;
    }

    event ProbeMetadata(
        uint256 forkBlock,
        uint256 wrapperTotalSupply,
        uint184 exchangePrice,
        int256 rebalanceDiff,
        uint256 perturbRounds,
        uint256 perturbAmountOut0Each
    );

    event ScenarioResult(
        uint256 indexed positionToken0,
        uint256 indexed positionToken1,
        Scenario indexed scenario,
        int256 token0Delta,
        int256 token1Delta,
        uint256 token1SpentInPerturb,
        uint256 token0SpentInReverse,
        uint256 wrapperMinted,
        uint256 dexSharesReceived,
        uint256 token0Withdraw,
        uint256 token1Withdraw,
        int256 rebalanceDiffBefore,
        int256 rebalanceDiffAfter,
        uint256 gasUsed
    );

    event InteractionResult(
        uint256 indexed positionToken0,
        uint256 indexed positionToken1,
        int256 interactionToken0,
        int256 interactionToken1,
        int256 combinedToken0Delta,
        int256 combinedToken1Delta,
        int256 wrapperOnlyToken0Delta,
        int256 wrapperOnlyToken1Delta,
        int256 perturbOnlyToken0Delta,
        int256 perturbOnlyToken1Delta
    );

    function setUp() public {
        rpcUrl = vm.envString("PLASMA_RPC_URL");
        forkBlock = vm.envUint("PLASMA_FORK_BLOCK");
        vm.createSelectFork(rpcUrl, forkBlock);
        assertEq(block.chainid, 9745, "unexpected chain");
    }

    function _safeApprove(address token, address spender) internal {
        (bool ok, bytes memory data) = token.call(
            abi.encodeWithSignature("approve(address,uint256)", spender, type(uint256).max)
        );
        require(ok && (data.length == 0 || abi.decode(data, (bool))), "APPROVE_FAILED");
    }

    function _signedDelta(uint256 after_, uint256 before_) internal pure returns (int256) {
        if (after_ >= before_) return int256(after_ - before_);
        return -int256(before_ - after_);
    }

    function _prepare() internal {
        vm.createSelectFork(rpcUrl, forkBlock);
        deal(TOKEN0, address(this), START_TOKEN0);
        deal(TOKEN1, address(this), START_TOKEN1);
        _safeApprove(TOKEN0, WRAPPER);
        _safeApprove(TOKEN1, WRAPPER);
        _safeApprove(TOKEN0, POOL);
        _safeApprove(TOKEN1, POOL);
    }

    function _perturb() internal returns (uint256 totalToken1Input, uint256 reverseToken0Input) {
        IFluidDexShareProbe pool = IFluidDexShareProbe(POOL);
        for (uint256 i; i < PERTURB_ROUNDS; ++i) {
            totalToken1Input += pool.swapOut(
                false,
                PERTURB_AMOUNT_OUT0_EACH,
                type(uint256).max,
                address(this)
            );
        }
        reverseToken0Input = pool.swapOut(
            true,
            totalToken1Input,
            type(uint256).max,
            address(this)
        );
    }

    function _runScenario(
        uint256 positionToken0,
        uint256 positionToken1,
        Scenario scenario
    ) internal returns (Result memory result) {
        _prepare();

        IFluidSmartLendingShareProbe wrapper = IFluidSmartLendingShareProbe(WRAPPER);
        uint256 token0Before = IERC20ShareProbe(TOKEN0).balanceOf(address(this));
        uint256 token1Before = IERC20ShareProbe(TOKEN1).balanceOf(address(this));
        result.rebalanceDiffBefore = wrapper.rebalanceDiff();
        uint256 gasBefore = gasleft();

        if (scenario != Scenario.PerturbOnly) {
            (result.wrapperMinted, result.dexSharesReceived) = wrapper.deposit(
                positionToken0,
                positionToken1,
                1,
                address(this)
            );
            assertGt(result.wrapperMinted, 0, "no wrapper shares minted");
            assertGt(result.dexSharesReceived, 0, "no dex shares received");
        }

        if (scenario != Scenario.WrapperOnly) {
            (result.token1SpentInPerturb, result.token0SpentInReverse) = _perturb();
        }

        if (scenario != Scenario.PerturbOnly) {
            uint256 wrapperBalance = wrapper.balanceOf(address(this));
            assertEq(wrapperBalance, result.wrapperMinted, "unexpected wrapper balance");
            (, result.token0Withdraw, result.token1Withdraw) = wrapper.withdrawPerfect(
                type(uint256).max,
                1,
                1,
                address(this)
            );
            assertEq(wrapper.balanceOf(address(this)), 0, "wrapper position not fully closed");
        }

        result.gasUsed = gasBefore - gasleft();
        result.rebalanceDiffAfter = wrapper.rebalanceDiff();
        result.token0Delta = _signedDelta(
            IERC20ShareProbe(TOKEN0).balanceOf(address(this)),
            token0Before
        );
        result.token1Delta = _signedDelta(
            IERC20ShareProbe(TOKEN1).balanceOf(address(this)),
            token1Before
        );

        emit ScenarioResult(
            positionToken0,
            positionToken1,
            scenario,
            result.token0Delta,
            result.token1Delta,
            result.token1SpentInPerturb,
            result.token0SpentInReverse,
            result.wrapperMinted,
            result.dexSharesReceived,
            result.token0Withdraw,
            result.token1Withdraw,
            result.rebalanceDiffBefore,
            result.rebalanceDiffAfter,
            result.gasUsed
        );
    }

    function test_measureShareInteractionAcrossPositionSizes() public {
        vm.createSelectFork(rpcUrl, forkBlock);
        IFluidSmartLendingShareProbe wrapper = IFluidSmartLendingShareProbe(WRAPPER);
        emit ProbeMetadata(
            block.number,
            wrapper.totalSupply(),
            wrapper.exchangePrice(),
            wrapper.rebalanceDiff(),
            PERTURB_ROUNDS,
            PERTURB_AMOUNT_OUT0_EACH
        );

        uint256[3] memory token0Positions = [uint256(1 ether), uint256(1_000 ether), uint256(100_000 ether)];
        uint256[3] memory token1Positions = [uint256(1e6), uint256(1_000e6), uint256(100_000e6)];

        for (uint256 i; i < token0Positions.length; ++i) {
            Result memory perturbOnly = _runScenario(
                token0Positions[i],
                token1Positions[i],
                Scenario.PerturbOnly
            );
            Result memory wrapperOnly = _runScenario(
                token0Positions[i],
                token1Positions[i],
                Scenario.WrapperOnly
            );
            Result memory combined = _runScenario(
                token0Positions[i],
                token1Positions[i],
                Scenario.WrapperAndPerturb
            );

            int256 interaction0 = combined.token0Delta - wrapperOnly.token0Delta - perturbOnly.token0Delta;
            int256 interaction1 = combined.token1Delta - wrapperOnly.token1Delta - perturbOnly.token1Delta;

            emit InteractionResult(
                token0Positions[i],
                token1Positions[i],
                interaction0,
                interaction1,
                combined.token0Delta,
                combined.token1Delta,
                wrapperOnly.token0Delta,
                wrapperOnly.token1Delta,
                perturbOnly.token0Delta,
                perturbOnly.token1Delta
            );
        }
    }
}
