// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.21;

import {Test} from "forge-std/Test.sol";

interface IERC20CycleMeta {
    function balanceOf(address account) external view returns (uint256);
    function decimals() external view returns (uint8);
    function symbol() external view returns (string memory);
}

interface IFluidDexCycle {
    function DEX_ID() external view returns (uint256);
    function swapOut(bool swap0to1, uint256 amountOut, uint256 amountInMax, address to)
        external payable returns (uint256 amountIn);
}

contract PlasmaSmartLendingLiveCycleSearchTest is Test {
    struct PoolConfig {
        address wrapper;
        address pool;
        address token0;
        address token1;
    }

    string internal rpcUrl;
    uint256 internal forkBlock;

    event LivePoolMetadata(
        address indexed wrapper,
        address indexed pool,
        uint256 indexed dexId,
        address token0,
        string symbol0,
        uint8 decimals0,
        address token1,
        string symbol1,
        uint8 decimals1
    );

    event CycleResult(
        address indexed pool,
        uint256 indexed rounds,
        uint256 indexed amountOut0Each,
        bool success,
        int256 token0Delta,
        int256 token1Delta,
        uint256 totalToken1Input,
        uint256 reverseToken0Input,
        uint256 gasUsed
    );

    function setUp() public {
        rpcUrl = vm.envString("PLASMA_RPC_URL");
        forkBlock = vm.envUint("PLASMA_FORK_BLOCK");
        vm.createSelectFork(rpcUrl, forkBlock);
        assertEq(block.chainid, 9745, "unexpected chain");
    }

    function _configs() internal pure returns (PoolConfig[2] memory configs) {
        configs[0] = PoolConfig({
            wrapper: 0x983107BB3dcb71f3A30176114D8a17c454A62514,
            pool: 0x36a905DCD12C0201f884fAFda71e63E9547975DA,
            token0: 0x0B2b2B2076d95dda7817e785989fE353fe955ef9,
            token1: 0xB8CE59FC3717ada4C02eaDF9682A9e934F625ebb
        });
        configs[1] = PoolConfig({
            wrapper: 0x4f0C96408aF08473051Ea3EA1FF3e4F288115A5A,
            pool: 0xBA9ed8AE94C70Ef9AA2cd1045ED473aaa405C6c7,
            token0: 0x61E030A56D33e8260FdD81f03B162A79Fe3449Cd,
            token1: 0x9895D81bB462A195b4922ED7De0e3ACD007c32CB
        });
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

    function _attemptCycle(PoolConfig memory config, uint256 rounds, uint256 amountOut0Each)
        internal
        returns (
            bool success,
            int256 token0Delta,
            int256 token1Delta,
            uint256 totalToken1Input,
            uint256 reverseToken0Input,
            uint256 gasUsed
        )
    {
        vm.createSelectFork(rpcUrl, forkBlock);

        uint8 decimals0 = IERC20CycleMeta(config.token0).decimals();
        uint8 decimals1 = IERC20CycleMeta(config.token1).decimals();
        uint256 unit0 = 10 ** uint256(decimals0);
        uint256 unit1 = 10 ** uint256(decimals1);

        deal(config.token0, address(this), 10_000_000 * unit0);
        deal(config.token1, address(this), 10_000_000 * unit1);
        _safeApprove(config.token0, config.pool);
        _safeApprove(config.token1, config.pool);

        uint256 token0Before = IERC20CycleMeta(config.token0).balanceOf(address(this));
        uint256 token1Before = IERC20CycleMeta(config.token1).balanceOf(address(this));
        uint256 gasBefore = gasleft();

        success = true;
        for (uint256 i; i < rounds; ++i) {
            (bool ok, bytes memory data) = config.pool.call(
                abi.encodeWithSelector(
                    IFluidDexCycle.swapOut.selector,
                    false,
                    amountOut0Each,
                    type(uint256).max,
                    address(this)
                )
            );
            if (!ok || data.length < 32) {
                success = false;
                break;
            }
            totalToken1Input += abi.decode(data, (uint256));
        }

        if (success && totalToken1Input > 0) {
            (bool ok, bytes memory data) = config.pool.call(
                abi.encodeWithSelector(
                    IFluidDexCycle.swapOut.selector,
                    true,
                    totalToken1Input,
                    type(uint256).max,
                    address(this)
                )
            );
            if (!ok || data.length < 32) {
                success = false;
            } else {
                reverseToken0Input = abi.decode(data, (uint256));
            }
        }

        gasUsed = gasBefore - gasleft();
        uint256 token0After = IERC20CycleMeta(config.token0).balanceOf(address(this));
        uint256 token1After = IERC20CycleMeta(config.token1).balanceOf(address(this));
        token0Delta = _signedDelta(token0After, token0Before);
        token1Delta = _signedDelta(token1After, token1Before);
    }

    function test_searchLiveWrapperPoolExactOutputCycles() public {
        PoolConfig[2] memory configs = _configs();
        uint256[4] memory roundsGrid = [uint256(2), 8, 32, 128];

        for (uint256 p; p < configs.length; ++p) {
            PoolConfig memory config = configs[p];
            vm.createSelectFork(rpcUrl, forkBlock);

            uint8 decimals0 = IERC20CycleMeta(config.token0).decimals();
            uint8 decimals1 = IERC20CycleMeta(config.token1).decimals();
            string memory symbol0 = IERC20CycleMeta(config.token0).symbol();
            string memory symbol1 = IERC20CycleMeta(config.token1).symbol();
            uint256 dexId = IFluidDexCycle(config.pool).DEX_ID();
            uint256 unit0 = 10 ** uint256(decimals0);

            emit LivePoolMetadata(
                config.wrapper,
                config.pool,
                dexId,
                config.token0,
                symbol0,
                decimals0,
                config.token1,
                symbol1,
                decimals1
            );

            uint256[6] memory amounts;
            amounts[0] = (unit0 / 1_000_000) + 1;
            amounts[1] = (unit0 / 100_000) + 1;
            amounts[2] = (unit0 * 2561 / 10_000_000) + 1;
            amounts[3] = (unit0 / 10_000) + 1;
            amounts[4] = (unit0 / 1_000) + 1;
            amounts[5] = (unit0 / 100) + 1;

            for (uint256 a; a < amounts.length; ++a) {
                for (uint256 r; r < roundsGrid.length; ++r) {
                    (
                        bool success,
                        int256 delta0,
                        int256 delta1,
                        uint256 totalInput1,
                        uint256 reverseInput0,
                        uint256 gasUsed
                    ) = _attemptCycle(config, roundsGrid[r], amounts[a]);

                    emit CycleResult(
                        config.pool,
                        roundsGrid[r],
                        amounts[a],
                        success,
                        delta0,
                        delta1,
                        totalInput1,
                        reverseInput0,
                        gasUsed
                    );
                }
            }
        }
    }
}
