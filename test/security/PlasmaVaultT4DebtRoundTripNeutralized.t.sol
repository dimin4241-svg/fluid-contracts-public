// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.21;

import {Test} from "forge-std/Test.sol";

interface IERC20DebtRoundTrip {
    function balanceOf(address account) external view returns (uint256);
}

interface IFactoryDebtRoundTrip {
    function ownerOf(uint256 nftId) external view returns (address);
}

interface IVaultT4DebtRoundTrip {
    function operatePerfect(
        uint256 nftId,
        int256 perfectColShares,
        int256 colToken0MinMax,
        int256 colToken1MinMax,
        int256 perfectDebtShares,
        int256 debtToken0MinMax,
        int256 debtToken1MinMax,
        address to
    ) external payable returns (uint256, int256[] memory);
}

interface IResolverDebtRoundTrip {
    function FACTORY() external view returns (address);
}

interface IDexDebtRoundTrip {
    function swapOut(bool swap0to1, uint256 amountOut, uint256 amountInMax, address to)
        external payable returns (uint256 amountIn);
}

contract PlasmaVaultT4DebtRoundTripNeutralizedTest is Test {
    address internal constant FACTORY = 0x324c5Dc1fC42c7a4D43d92df1eBA58a54d13Bf2d;
    address internal constant VAULT = 0x6E0cDB09eb33cD3894C905E0DFF9289b95a86FFF;
    address internal constant RESOLVER = 0xA5C3E16523eeeDDcC34706b0E6bE88b4c6EA95cC;
    address internal constant DEX = 0x080574D224E960c272e005aA03EFbe793f317640;
    address internal constant LIQUIDITY = 0x52Aa899454998Be5b000Ad077a46Bbe360F4e497;
    address internal constant GHO = 0xb77E872A68C62CfC0dFb02C067Ecc3DA23B4bbf3;
    address internal constant USDT0 = 0xB8CE59FC3717ada4C02eaDF9682A9e934F625ebb;

    uint256 internal constant MANIPULATOR_NFT = 2887;
    uint256 internal constant FUNDING_GHO = 1e28;
    uint256 internal constant FUNDING_USDT0 = 1e18;
    int256 internal constant MAX_USDT0_PAYMENT = -1e18;

    string internal rpcUrl;
    uint256 internal forkBlock;

    struct Position {
        uint256 nftId;
        address owner;
        bool isLiquidated;
        bool isSupplyPosition;
        uint256 supplyShares;
        uint256 borrowShares;
        uint256 dustBorrow;
    }

    event DebtRoundTripCycle(
        uint256 indexed shiftShares,
        uint256 indexed cycle,
        uint256 rawGhoReceived,
        uint256 rawUsdtSpent,
        uint256 neutralizingGhoSpent,
        int256 neutralizedGhoProfit,
        int256 neutralizedUsdtDelta,
        uint256 gasUsed
    );

    event DebtRoundTripSummary(
        uint256 indexed shiftShares,
        uint256 cycles,
        int256 cumulativeGhoProfit,
        int256 cumulativeUsdtDelta,
        uint256 borrowSharesBefore,
        uint256 borrowSharesAfter,
        uint256 dustBorrowBefore,
        uint256 dustBorrowAfter,
        int256 liquidityGhoDelta,
        int256 liquidityUsdtDelta,
        uint256 totalGasUsed
    );

    function setUp() public {
        rpcUrl = vm.envString("PLASMA_RPC_URL");
        forkBlock = vm.envUint("PLASMA_FORK_BLOCK");
        vm.createSelectFork(rpcUrl, forkBlock);
        assertEq(block.chainid, 9745, "unexpected chain");
        assertEq(IResolverDebtRoundTrip(RESOLVER).FACTORY(), FACTORY, "resolver factory mismatch");
    }

    function _word(bytes memory data, uint256 index) internal pure returns (uint256 value) {
        require(data.length >= (index + 1) * 32, "word out of bounds");
        assembly ("memory-safe") {
            value := mload(add(add(data, 0x20), mul(index, 0x20)))
        }
    }

    function _position(uint256 nftId) internal view returns (Position memory p) {
        (bool ok, bytes memory data) = RESOLVER.staticcall(
            abi.encodeWithSignature("positionByNftId(uint256)", nftId)
        );
        require(ok, "resolver position call failed");
        require(data.length >= 12 * 32, "short resolver response");

        p.nftId = _word(data, 0);
        p.owner = address(uint160(_word(data, 1)));
        p.isLiquidated = _word(data, 2) != 0;
        p.isSupplyPosition = _word(data, 3) != 0;
        p.supplyShares = _word(data, 9);
        p.borrowShares = _word(data, 10);
        p.dustBorrow = _word(data, 11);

        require(p.nftId == nftId, "resolver nft mismatch");
        require(p.owner == IFactoryDebtRoundTrip(FACTORY).ownerOf(nftId), "owner mismatch");
    }

    function _approve(address token, address owner, address spender) internal {
        vm.prank(owner);
        (bool ok, bytes memory data) = token.call(
            abi.encodeWithSignature("approve(address,uint256)", spender, type(uint256).max)
        );
        require(ok && (data.length == 0 || abi.decode(data, (bool))), "APPROVE_FAILED");
    }

    function _signed(uint256 after_, uint256 before_) internal pure returns (int256) {
        return after_ >= before_ ? int256(after_ - before_) : -int256(before_ - after_);
    }

    function _fundAndApprove(address owner) internal {
        // Ordinary working capital only. The measured result is the delta from these balances.
        deal(GHO, owner, FUNDING_GHO);
        deal(USDT0, owner, FUNDING_USDT0);
        _approve(GHO, owner, VAULT);
        _approve(USDT0, owner, VAULT);
        _approve(GHO, owner, DEX);
        _approve(USDT0, owner, DEX);
    }

    function _run(uint256 shiftShares, uint256 cycles) internal {
        vm.createSelectFork(rpcUrl, forkBlock);
        Position memory beforePosition = _position(MANIPULATOR_NFT);
        require(!beforePosition.isLiquidated && !beforePosition.isSupplyPosition, "inactive debt position");
        require(shiftShares > 0 && shiftShares < beforePosition.borrowShares, "invalid shift size");

        address owner = beforePosition.owner;
        _fundAndApprove(owner);

        uint256 initialGho = IERC20DebtRoundTrip(GHO).balanceOf(owner);
        uint256 initialUsdt = IERC20DebtRoundTrip(USDT0).balanceOf(owner);
        uint256 initialLiquidityGho = IERC20DebtRoundTrip(GHO).balanceOf(LIQUIDITY);
        uint256 initialLiquidityUsdt = IERC20DebtRoundTrip(USDT0).balanceOf(LIQUIDITY);
        uint256 totalGasUsed;

        for (uint256 cycle; cycle < cycles; ++cycle) {
            uint256 ghoBefore = IERC20DebtRoundTrip(GHO).balanceOf(owner);
            uint256 usdtBefore = IERC20DebtRoundTrip(USDT0).balanceOf(owner);
            uint256 gasBefore = gasleft();

            vm.startPrank(owner);
            IVaultT4DebtRoundTrip(VAULT).operatePerfect(
                MANIPULATOR_NFT,
                0,
                0,
                0,
                -int256(shiftShares),
                0,
                MAX_USDT0_PAYMENT,
                owner
            );
            IVaultT4DebtRoundTrip(VAULT).operatePerfect(
                MANIPULATOR_NFT,
                0,
                0,
                0,
                int256(shiftShares),
                1,
                1,
                owner
            );
            vm.stopPrank();

            uint256 ghoMid = IERC20DebtRoundTrip(GHO).balanceOf(owner);
            uint256 usdtMid = IERC20DebtRoundTrip(USDT0).balanceOf(owner);
            require(ghoMid >= ghoBefore, "round trip did not receive GHO");
            require(usdtMid <= usdtBefore, "round trip did not spend USDT0");

            uint256 rawGhoReceived = ghoMid - ghoBefore;
            uint256 rawUsdtSpent = usdtBefore - usdtMid;

            vm.prank(owner);
            uint256 neutralizingGhoSpent = IDexDebtRoundTrip(DEX).swapOut(
                true,
                rawUsdtSpent,
                type(uint256).max,
                owner
            );

            uint256 ghoAfter = IERC20DebtRoundTrip(GHO).balanceOf(owner);
            uint256 usdtAfter = IERC20DebtRoundTrip(USDT0).balanceOf(owner);
            uint256 gasUsed = gasBefore - gasleft();
            totalGasUsed += gasUsed;

            assertEq(usdtAfter, usdtBefore, "USDT0 was not exactly neutralized");
            emit DebtRoundTripCycle(
                shiftShares,
                cycle + 1,
                rawGhoReceived,
                rawUsdtSpent,
                neutralizingGhoSpent,
                _signed(ghoAfter, ghoBefore),
                _signed(usdtAfter, usdtBefore),
                gasUsed
            );
        }

        Position memory afterPosition = _position(MANIPULATOR_NFT);
        uint256 finalGho = IERC20DebtRoundTrip(GHO).balanceOf(owner);
        uint256 finalUsdt = IERC20DebtRoundTrip(USDT0).balanceOf(owner);
        uint256 finalLiquidityGho = IERC20DebtRoundTrip(GHO).balanceOf(LIQUIDITY);
        uint256 finalLiquidityUsdt = IERC20DebtRoundTrip(USDT0).balanceOf(LIQUIDITY);

        assertEq(afterPosition.supplyShares, beforePosition.supplyShares, "supply shares changed");
        assertEq(afterPosition.borrowShares, beforePosition.borrowShares, "borrow shares changed");

        emit DebtRoundTripSummary(
            shiftShares,
            cycles,
            _signed(finalGho, initialGho),
            _signed(finalUsdt, initialUsdt),
            beforePosition.borrowShares,
            afterPosition.borrowShares,
            beforePosition.dustBorrow,
            afterPosition.dustBorrow,
            _signed(finalLiquidityGho, initialLiquidityGho),
            _signed(finalLiquidityUsdt, initialLiquidityUsdt),
            totalGasUsed
        );
    }

    function test_neutralized_size_matrix() public {
        uint256[5] memory sizes = [uint256(1e18), uint256(1e20), uint256(1e21), uint256(5e21), uint256(1e22)];
        for (uint256 i; i < sizes.length; ++i) _run(sizes[i], 1);
    }

    function test_neutralized_repeat_matrix() public {
        _run(1e22, 1);
        _run(1e22, 2);
        _run(1e22, 4);
        _run(1e22, 8);
    }
}
