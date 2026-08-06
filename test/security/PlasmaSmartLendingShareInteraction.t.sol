// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.21;

import {Test} from "forge-std/Test.sol";

interface IERC20ShareProbe {
    function balanceOf(address account) external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
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
    address internal constant TOKEN1_LIVE_HOLDER = 0x8741B106e9738a6971AD07DABCFe95FF66337b51;

    uint256 internal constant PERTURB_ROUNDS = 128;
    uint256 internal constant PERTURB_AMOUNT_OUT0_EACH = 256100000000001;
    uint256 internal constant PERTURB_TOKEN1_FUNDING = 1e6;

    string internal rpcUrl;
    uint256 internal forkBlock;
    address internal fslHolder;
    uint256 internal discoveredHolderBalance;

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
        uint256 wrapperTransferred;
        uint256 wrapperBurned;
        uint256 token0Withdraw;
        uint256 token1Withdraw;
        int256 rebalanceDiffBefore;
        int256 rebalanceDiffAfter;
        uint256 gasUsed;
    }

    event ProbeMetadata(
        uint256 forkBlock,
        address indexed fslHolder,
        uint256 holderBalance,
        uint256 wrapperTotalSupply,
        uint184 exchangePrice,
        int256 rebalanceDiff,
        uint256 perturbRounds,
        uint256 perturbAmountOut0Each
    );

    event ScenarioResult(
        uint256 indexed positionShares,
        Scenario indexed scenario,
        int256 token0Delta,
        int256 token1Delta,
        uint256 token1SpentInPerturb,
        uint256 token0SpentInReverse,
        uint256 wrapperTransferred,
        uint256 wrapperBurned,
        uint256 token0Withdraw,
        uint256 token1Withdraw,
        int256 rebalanceDiffBefore,
        int256 rebalanceDiffAfter,
        uint256 gasUsed
    );

    event InteractionResult(
        uint256 indexed positionShares,
        uint256 positionPpmOfSupply,
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
        fslHolder = vm.envAddress("FSL_HOLDER");
        discoveredHolderBalance = vm.envUint("FSL_HOLDER_BALANCE");

        vm.createSelectFork(rpcUrl, forkBlock);
        assertEq(block.chainid, 9745, "unexpected chain");
        assertTrue(fslHolder != address(0), "zero fSL holder");
        assertEq(
            IERC20ShareProbe(WRAPPER).balanceOf(fslHolder),
            discoveredHolderBalance,
            "holder balance changed at fork block"
        );
    }

    function _safeApprove(address token, address spender) internal {
        (bool ok, bytes memory data) = token.call(
            abi.encodeWithSignature("approve(address,uint256)", spender, type(uint256).max)
        );
        require(ok && (data.length == 0 || abi.decode(data, (bool))), "APPROVE_FAILED");
    }

    function _safeTransfer(address token, address to, uint256 amount) internal {
        (bool ok, bytes memory data) = token.call(
            abi.encodeWithSignature("transfer(address,uint256)", to, amount)
        );
        require(ok && (data.length == 0 || abi.decode(data, (bool))), "TRANSFER_FAILED");
    }

    function _signedDelta(uint256 after_, uint256 before_) internal pure returns (int256) {
        if (after_ >= before_) return int256(after_ - before_);
        return -int256(before_ - after_);
    }

    function _prepare() internal {
        vm.createSelectFork(rpcUrl, forkBlock);

        assertGe(
            IERC20ShareProbe(WRAPPER).balanceOf(fslHolder),
            discoveredHolderBalance,
            "insufficient fSL holder balance"
        );
        assertGe(
            IERC20ShareProbe(TOKEN1).balanceOf(TOKEN1_LIVE_HOLDER),
            PERTURB_TOKEN1_FUNDING,
            "insufficient live USDT0 holder balance"
        );

        vm.prank(TOKEN1_LIVE_HOLDER);
        _safeTransfer(TOKEN1, address(this), PERTURB_TOKEN1_FUNDING);

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

    function _runScenario(uint256 positionShares, Scenario scenario)
        internal
        returns (Result memory result)
    {
        _prepare();

        IFluidSmartLendingShareProbe wrapper = IFluidSmartLendingShareProbe(WRAPPER);
        uint256 token0Before = IERC20ShareProbe(TOKEN0).balanceOf(address(this));
        uint256 token1Before = IERC20ShareProbe(TOKEN1).balanceOf(address(this));
        result.rebalanceDiffBefore = wrapper.rebalanceDiff();
        uint256 gasBefore = gasleft();

        if (scenario != Scenario.PerturbOnly) {
            assertLe(positionShares, wrapper.balanceOf(fslHolder), "position exceeds live holder balance");
            vm.prank(fslHolder);
            _safeTransfer(WRAPPER, address(this), positionShares);
            result.wrapperTransferred = positionShares;
            assertEq(wrapper.balanceOf(address(this)), positionShares, "fSL transfer mismatch");
        }

        if (scenario != Scenario.WrapperOnly) {
            (result.token1SpentInPerturb, result.token0SpentInReverse) = _perturb();
        }

        if (scenario != Scenario.PerturbOnly) {
            (result.wrapperBurned, result.token0Withdraw, result.token1Withdraw) = wrapper.withdrawPerfect(
                type(uint256).max,
                1,
                1,
                address(this)
            );
            assertEq(result.wrapperBurned, positionShares, "unexpected fSL amount burned");
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
            positionShares,
            scenario,
            result.token0Delta,
            result.token1Delta,
            result.token1SpentInPerturb,
            result.token0SpentInReverse,
            result.wrapperTransferred,
            result.wrapperBurned,
            result.token0Withdraw,
            result.token1Withdraw,
            result.rebalanceDiffBefore,
            result.rebalanceDiffAfter,
            result.gasUsed
        );
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    function test_measureShareInteractionAcrossPositionSizes() public {
        vm.createSelectFork(rpcUrl, forkBlock);
        IFluidSmartLendingShareProbe wrapper = IFluidSmartLendingShareProbe(WRAPPER);
        uint256 totalSupply = wrapper.totalSupply();
        uint256 holderBalance = wrapper.balanceOf(fslHolder);

        emit ProbeMetadata(
            block.number,
            fslHolder,
            holderBalance,
            totalSupply,
            wrapper.exchangePrice(),
            wrapper.rebalanceDiff(),
            PERTURB_ROUNDS,
            PERTURB_AMOUNT_OUT0_EACH
        );

        uint256[3] memory positions;
        positions[0] = _min(totalSupply / 1_000_000, holderBalance / 1_000_000);
        positions[1] = _min(totalSupply / 400, holderBalance / 1_000);
        positions[2] = _min(totalSupply / 4, holderBalance);

        if (positions[0] == 0) positions[0] = 1;
        if (positions[1] <= positions[0]) positions[1] = positions[0] + 1;
        if (positions[2] <= positions[1]) positions[2] = holderBalance;

        assertGt(holderBalance, positions[1], "live holder too small for scaling probe");
        assertGe(positions[2], positions[1], "invalid largest position");

        for (uint256 i; i < positions.length; ++i) {
            Result memory perturbOnly = _runScenario(positions[i], Scenario.PerturbOnly);
            Result memory wrapperOnly = _runScenario(positions[i], Scenario.WrapperOnly);
            Result memory combined = _runScenario(positions[i], Scenario.WrapperAndPerturb);

            assertGt(perturbOnly.token0Delta, 0, "perturbation no longer profitable");
            assertEq(perturbOnly.token1Delta, 0, "perturbation did not close token1 leg");

            int256 interaction0 = combined.token0Delta - wrapperOnly.token0Delta - perturbOnly.token0Delta;
            int256 interaction1 = combined.token1Delta - wrapperOnly.token1Delta - perturbOnly.token1Delta;

            emit InteractionResult(
                positions[i],
                (positions[i] * 1_000_000) / totalSupply,
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
