// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.21;

import {Test} from "forge-std/Test.sol";

interface IERC20OneTokenCycle {
    function balanceOf(address account) external view returns (uint256);
}

interface IFactoryOneTokenCycle {
    function ownerOf(uint256 nftId) external view returns (address);
}

interface IVaultT4OneTokenCycle {
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

contract PlasmaVaultT4OneTokenDebtCycleTest is Test {
    address internal constant FACTORY = 0x324c5Dc1fC42c7a4D43d92df1eBA58a54d13Bf2d;
    address internal constant VAULT = 0x6E0cDB09eb33cD3894C905E0DFF9289b95a86FFF;
    address internal constant GHO = 0xb77E872A68C62CfC0dFb02C067Ecc3DA23B4bbf3;
    address internal constant USDT0 = 0xB8CE59FC3717ada4C02eaDF9682A9e934F625ebb;
    uint256 internal constant NFT = 2887;
    uint256 internal constant FUNDING = 1e24;
    int256 internal constant MAX_PAYMENT = -1e24;

    string internal rpcUrl;
    uint256 internal forkBlock;

    enum Direction {
        PayGhoThenBorrow,
        PayUsdtThenBorrow,
        BorrowThenPayGho,
        BorrowThenPayUsdt
    }

    event CycleResult(
        uint256 indexed nftId,
        Direction indexed direction,
        uint256 shares,
        int256 ghoDelta,
        int256 usdtDelta,
        int256 nominalDelta1e18,
        uint256 ghoPaid,
        uint256 usdtPaid,
        uint256 ghoBorrowed,
        uint256 usdtBorrowed
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

    function _delta(uint256 after_, uint256 before_) internal pure returns (int256) {
        return after_ >= before_ ? int256(after_ - before_) : -int256(before_ - after_);
    }

    function _prepare() internal returns (address owner) {
        vm.createSelectFork(rpcUrl, forkBlock);
        owner = IFactoryOneTokenCycle(FACTORY).ownerOf(NFT);
        deal(GHO, owner, FUNDING, true);
        deal(USDT0, owner, FUNDING, true);
        vm.startPrank(owner);
        _safeApprove(GHO, VAULT);
        _safeApprove(USDT0, VAULT);
        vm.stopPrank();
    }

    function _payOneToken(address owner, uint256 shares, bool payGho)
        internal
        returns (uint256 ghoPaid, uint256 usdtPaid)
    {
        uint256 beforeGho = IERC20OneTokenCycle(GHO).balanceOf(owner);
        uint256 beforeUsdt = IERC20OneTokenCycle(USDT0).balanceOf(owner);
        vm.prank(owner);
        (, int256[] memory r) = IVaultT4OneTokenCycle(VAULT).operatePerfect(
            NFT,
            0,
            0,
            0,
            -int256(shares),
            payGho ? MAX_PAYMENT : int256(0),
            payGho ? int256(0) : MAX_PAYMENT,
            owner
        );
        assertEq(r.length, 6, "bad payback return");
        ghoPaid = beforeGho - IERC20OneTokenCycle(GHO).balanceOf(owner);
        usdtPaid = beforeUsdt - IERC20OneTokenCycle(USDT0).balanceOf(owner);
        assertEq(ghoPaid == 0, !payGho, "unexpected GHO payment leg");
        assertEq(usdtPaid == 0, payGho, "unexpected USDT payment leg");
        assertEq(uint256(-r[3]), shares, "unexpected shares burned");
    }

    function _borrow(address owner, uint256 shares)
        internal
        returns (uint256 ghoBorrowed, uint256 usdtBorrowed)
    {
        uint256 beforeGho = IERC20OneTokenCycle(GHO).balanceOf(owner);
        uint256 beforeUsdt = IERC20OneTokenCycle(USDT0).balanceOf(owner);
        vm.prank(owner);
        (, int256[] memory r) = IVaultT4OneTokenCycle(VAULT).operatePerfect(
            NFT,
            0,
            0,
            0,
            int256(shares),
            1,
            1,
            owner
        );
        assertEq(r.length, 6, "bad borrow return");
        ghoBorrowed = IERC20OneTokenCycle(GHO).balanceOf(owner) - beforeGho;
        usdtBorrowed = IERC20OneTokenCycle(USDT0).balanceOf(owner) - beforeUsdt;
        assertEq(uint256(r[3]), shares, "unexpected shares minted");
    }

    function _run(uint256 shares, Direction direction) internal {
        address owner = _prepare();
        uint256 ghoBefore = IERC20OneTokenCycle(GHO).balanceOf(owner);
        uint256 usdtBefore = IERC20OneTokenCycle(USDT0).balanceOf(owner);
        uint256 ghoPaid;
        uint256 usdtPaid;
        uint256 ghoBorrowed;
        uint256 usdtBorrowed;

        if (direction == Direction.PayGhoThenBorrow || direction == Direction.PayUsdtThenBorrow) {
            bool payGho = direction == Direction.PayGhoThenBorrow;
            (ghoPaid, usdtPaid) = _payOneToken(owner, shares, payGho);
            (ghoBorrowed, usdtBorrowed) = _borrow(owner, shares);
        } else {
            (ghoBorrowed, usdtBorrowed) = _borrow(owner, shares);
            bool payGho = direction == Direction.BorrowThenPayGho;
            (ghoPaid, usdtPaid) = _payOneToken(owner, shares, payGho);
        }

        int256 ghoDelta = _delta(IERC20OneTokenCycle(GHO).balanceOf(owner), ghoBefore);
        int256 usdtDelta = _delta(IERC20OneTokenCycle(USDT0).balanceOf(owner), usdtBefore);
        int256 nominalDelta = ghoDelta + usdtDelta * 1e12;

        emit CycleResult(
            NFT,
            direction,
            shares,
            ghoDelta,
            usdtDelta,
            nominalDelta,
            ghoPaid,
            usdtPaid,
            ghoBorrowed,
            usdtBorrowed
        );
    }

    function test_oneTokenDebtRoundTrips() public {
        uint256[3] memory sizes = [uint256(1e18), uint256(1e19), uint256(1e20)];
        for (uint256 i; i < sizes.length; ++i) {
            _run(sizes[i], Direction.PayGhoThenBorrow);
            _run(sizes[i], Direction.PayUsdtThenBorrow);
            _run(sizes[i], Direction.BorrowThenPayGho);
            _run(sizes[i], Direction.BorrowThenPayUsdt);
        }
    }
}
