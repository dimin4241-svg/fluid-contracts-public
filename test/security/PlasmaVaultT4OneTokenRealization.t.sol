// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.21;

import {Test} from "forge-std/Test.sol";

interface IERC20Realization {
    function balanceOf(address account) external view returns (uint256);
}

interface IFactoryRealization {
    function ownerOf(uint256 nftId) external view returns (address);
}

interface IVaultT4Realization {
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

interface IDexRealization {
    function swapIn(bool swap0to1, uint256 amountIn, uint256 amountOutMin, address to)
        external payable returns (uint256 amountOut);
}

contract PlasmaVaultT4OneTokenRealizationTest is Test {
    address internal constant FACTORY = 0x324c5Dc1fC42c7a4D43d92df1eBA58a54d13Bf2d;
    address internal constant VAULT = 0x6E0cDB09eb33cD3894C905E0DFF9289b95a86FFF;
    address internal constant DEX = 0x080574D224E960c272e005aA03EFbe793f317640;
    address internal constant GHO = 0xb77E872A68C62CfC0dFb02C067Ecc3DA23B4bbf3;
    address internal constant USDT0 = 0xB8CE59FC3717ada4C02eaDF9682A9e934F625ebb;
    uint256 internal constant NFT = 2887;
    uint256 internal constant FUNDING = 1e28;
    int256 internal constant MAX_USDT_PAYMENT = -1e24;

    string internal rpcUrl;
    uint256 internal forkBlock;

    event RealizedResult(
        uint256 indexed sharesPerRound,
        uint256 rounds,
        int256 preSwapGhoDelta,
        int256 preSwapUsdtDelta,
        int256 preSwapNominal1e18,
        uint256 ghoSwapped,
        uint256 usdtFromSwap,
        int256 finalGhoDelta,
        int256 finalUsdtDelta,
        int256 finalNominal1e18,
        uint256 gasUsed
    );

    function setUp() public {
        rpcUrl = vm.envString("PLASMA_RPC_URL");
        forkBlock = vm.envUint("PLASMA_FORK_BLOCK");
        vm.createSelectFork(rpcUrl, forkBlock);
        assertEq(block.chainid, 9745, "unexpected chain");
    }

    function _approve(address token, address spender) internal {
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
        owner = IFactoryRealization(FACTORY).ownerOf(NFT);
        deal(GHO, owner, FUNDING, true);
        deal(USDT0, owner, FUNDING, true);
        vm.startPrank(owner);
        _approve(GHO, VAULT);
        _approve(USDT0, VAULT);
        _approve(GHO, DEX);
        _approve(USDT0, DEX);
        vm.stopPrank();
    }

    function _cycle(address owner, uint256 shares) internal {
        vm.prank(owner);
        (, int256[] memory payback) = IVaultT4Realization(VAULT).operatePerfect(
            NFT,
            0,
            0,
            0,
            -int256(shares),
            0,
            MAX_USDT_PAYMENT,
            owner
        );
        assertEq(uint256(-payback[3]), shares, "wrong shares burned");

        vm.prank(owner);
        (, int256[] memory borrow_) = IVaultT4Realization(VAULT).operatePerfect(
            NFT,
            0,
            0,
            0,
            int256(shares),
            1,
            1,
            owner
        );
        assertEq(uint256(borrow_[3]), shares, "wrong shares restored");
    }

    function _run(uint256 sharesPerRound, uint256 rounds) internal {
        address owner = _prepare();
        uint256 ghoBefore = IERC20Realization(GHO).balanceOf(owner);
        uint256 usdtBefore = IERC20Realization(USDT0).balanceOf(owner);
        uint256 gasBefore = gasleft();

        for (uint256 i; i < rounds; ++i) _cycle(owner, sharesPerRound);

        int256 preGho = _delta(IERC20Realization(GHO).balanceOf(owner), ghoBefore);
        int256 preUsdt = _delta(IERC20Realization(USDT0).balanceOf(owner), usdtBefore);
        assertGt(preGho, 0, "cycle produced no GHO surplus");
        assertLt(preUsdt, 0, "cycle produced no USDT deficit");

        uint256 ghoSwapped = uint256(preGho);
        vm.prank(owner);
        uint256 usdtFromSwap = IDexRealization(DEX).swapIn(true, ghoSwapped, 0, owner);

        int256 finalGho = _delta(IERC20Realization(GHO).balanceOf(owner), ghoBefore);
        int256 finalUsdt = _delta(IERC20Realization(USDT0).balanceOf(owner), usdtBefore);
        uint256 gasUsed = gasBefore - gasleft();

        emit RealizedResult(
            sharesPerRound,
            rounds,
            preGho,
            preUsdt,
            preGho + preUsdt * 1e12,
            ghoSwapped,
            usdtFromSwap,
            finalGho,
            finalUsdt,
            finalGho + finalUsdt * 1e12,
            gasUsed
        );
    }

    function test_realizeOneTokenCycle() public {
        _run(1e20, 1);
        _run(1e21, 1);
        _run(1e22, 1);
        _run(1e20, 10);
        _run(1e20, 100);
    }
}
