// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.21;

import {Test} from "forge-std/Test.sol";

interface IFactoryLiquidationShift {
    function ownerOf(uint256 nftId) external view returns (address);
}

interface IVaultLiquidationShift {
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

interface IResolverLiquidationShift {
    struct LiquidationData {
        address vault;
        address token0In;
        address token0Out;
        address token1In;
        address token1Out;
        uint256 inAmt;
        uint256 outAmt;
        uint256 inAmtWithAbsorb;
        uint256 outAmtWithAbsorb;
        bool absorbAvailable;
    }

    function FACTORY() external view returns (address);

    function getVaultLiquidation(address vault, uint256 tokenInAmt)
        external returns (LiquidationData memory);
}

contract PlasmaVaultT4LiquidationShiftTest is Test {
    address internal constant FACTORY = 0x324c5Dc1fC42c7a4D43d92df1eBA58a54d13Bf2d;
    address internal constant VAULT = 0x6E0cDB09eb33cD3894C905E0DFF9289b95a86FFF;
    address internal constant RESOLVER = 0xA5C3E16523eeeDDcC34706b0E6bE88b4c6EA95cC;
    address internal constant GHO = 0xb77E872A68C62CfC0dFb02C067Ecc3DA23B4bbf3;
    address internal constant USDT0 = 0xB8CE59FC3717ada4C02eaDF9682A9e934F625ebb;
    uint256 internal constant MANIPULATOR_NFT = 2887;
    uint256 internal constant SHIFT_SHARES = 1e22;
    uint256 internal constant FUNDING = 1e28;
    int256 internal constant MAX_USDT_PAYMENT = -1e24;

    string internal rpcUrl;
    uint256 internal forkBlock;

    event LiquidationSurface(
        uint256 indexed requestedInput,
        bool indexed shifted,
        address token0In,
        address token0Out,
        address token1In,
        address token1Out,
        uint256 inAmt,
        uint256 outAmt,
        uint256 inAmtWithAbsorb,
        uint256 outAmtWithAbsorb,
        bool absorbAvailable
    );

    event LiquidationInteraction(
        uint256 indexed requestedInput,
        int256 inAmtDelta,
        int256 outAmtDelta,
        int256 inAmtWithAbsorbDelta,
        int256 outAmtWithAbsorbDelta,
        bool baselineAbsorb,
        bool shiftedAbsorb
    );

    function setUp() public {
        rpcUrl = vm.envString("PLASMA_RPC_URL");
        forkBlock = vm.envUint("PLASMA_FORK_BLOCK");
        vm.createSelectFork(rpcUrl, forkBlock);
        assertEq(block.chainid, 9745, "unexpected chain");
        assertGt(RESOLVER.code.length, 0, "missing resolver");
        assertEq(IResolverLiquidationShift(RESOLVER).FACTORY(), FACTORY, "resolver factory mismatch");
    }

    function _approve(address token, address spender) internal {
        (bool ok, bytes memory data) = token.call(
            abi.encodeWithSignature("approve(address,uint256)", spender, type(uint256).max)
        );
        require(ok && (data.length == 0 || abi.decode(data, (bool))), "APPROVE_FAILED");
    }

    function _signed(uint256 a, uint256 b) internal pure returns (int256) {
        return a >= b ? int256(a - b) : -int256(b - a);
    }

    function _shift() internal {
        address owner = IFactoryLiquidationShift(FACTORY).ownerOf(MANIPULATOR_NFT);
        deal(GHO, owner, FUNDING, true);
        deal(USDT0, owner, FUNDING, true);
        vm.startPrank(owner);
        _approve(GHO, VAULT);
        _approve(USDT0, VAULT);
        IVaultLiquidationShift(VAULT).operatePerfect(
            MANIPULATOR_NFT,
            0,
            0,
            0,
            -int256(SHIFT_SHARES),
            0,
            MAX_USDT_PAYMENT,
            owner
        );
        IVaultLiquidationShift(VAULT).operatePerfect(
            MANIPULATOR_NFT,
            0,
            0,
            0,
            int256(SHIFT_SHARES),
            1,
            1,
            owner
        );
        vm.stopPrank();
    }

    function _surface(bool shifted, uint256 requested)
        internal returns (IResolverLiquidationShift.LiquidationData memory data)
    {
        vm.createSelectFork(rpcUrl, forkBlock);
        if (shifted) _shift();
        data = IResolverLiquidationShift(RESOLVER).getVaultLiquidation(VAULT, requested);
        assertEq(data.vault, VAULT, "resolver returned another vault");
        emit LiquidationSurface(
            requested,
            shifted,
            data.token0In,
            data.token0Out,
            data.token1In,
            data.token1Out,
            data.inAmt,
            data.outAmt,
            data.inAmtWithAbsorb,
            data.outAmtWithAbsorb,
            data.absorbAvailable
        );
    }

    function _probe(uint256 requested) internal {
        IResolverLiquidationShift.LiquidationData memory baseline = _surface(false, requested);
        IResolverLiquidationShift.LiquidationData memory shifted = _surface(true, requested);
        assertEq(shifted.token0In, baseline.token0In, "token0In changed");
        assertEq(shifted.token0Out, baseline.token0Out, "token0Out changed");
        assertEq(shifted.token1In, baseline.token1In, "token1In changed");
        assertEq(shifted.token1Out, baseline.token1Out, "token1Out changed");
        emit LiquidationInteraction(
            requested,
            _signed(shifted.inAmt, baseline.inAmt),
            _signed(shifted.outAmt, baseline.outAmt),
            _signed(shifted.inAmtWithAbsorb, baseline.inAmtWithAbsorb),
            _signed(shifted.outAmtWithAbsorb, baseline.outAmtWithAbsorb),
            baseline.absorbAvailable,
            shifted.absorbAvailable
        );
    }

    function test_compareLiquidationSurface() public {
        _probe(1e12);
        _probe(1e18);
        _probe(1e22);
    }
}
