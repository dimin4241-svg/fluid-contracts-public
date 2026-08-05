// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.21;

import {Test} from "forge-std/Test.sol";

interface IERC20Tri {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
}

interface IDexTri {
    function swapOut(bool, uint256, uint256, address) external returns (uint256);
    function swapIn(bool, uint256, uint256, address) external returns (uint256);
}

contract TriangleExecutor {
    address constant USDT0 = 0xB8CE59FC3717ada4C02eaDF9682A9e934F625ebb;
    address constant GHO = 0xb77E872A68C62CfC0dFb02C067Ecc3DA23B4bbf3;
    address constant USDE = 0x5d3a1Ff2b6BAb83b63cd9AD0787074081a52ef34;

    IDexTri constant GHO_USDT = IDexTri(0x080574D224E960c272e005aA03EFbe793f317640);
    IDexTri constant USDE_GHO = IDexTri(0x836951EB21F3Df98273517B7249dCEFF270d34bf);
    IDexTri constant USDE_USDT = IDexTri(0x667701e51B4D1Ca244F17C78F7aB8744B4C99F9B);

    constructor() {
        IERC20Tri(USDT0).approve(address(GHO_USDT), type(uint256).max);
        IERC20Tri(USDT0).approve(address(USDE_USDT), type(uint256).max);
        IERC20Tri(GHO).approve(address(GHO_USDT), type(uint256).max);
        IERC20Tri(GHO).approve(address(USDE_GHO), type(uint256).max);
        IERC20Tri(USDE).approve(address(USDE_GHO), type(uint256).max);
        IERC20Tri(USDE).approve(address(USDE_USDT), type(uint256).max);
    }

    // USDT0 -> GHO via repeated exact-output, then exact-input through GHO->USDe->USDT0.
    function routeA(uint256 rounds, uint256 ghoOutEach) external returns (int256 usdtDelta, int256 ghoDelta, int256 usdeDelta) {
        uint256 u0 = IERC20Tri(USDT0).balanceOf(address(this));
        uint256 g0 = IERC20Tri(GHO).balanceOf(address(this));
        uint256 e0 = IERC20Tri(USDE).balanceOf(address(this));
        for (uint256 i; i < rounds; ++i) GHO_USDT.swapOut(false, ghoOutEach, type(uint256).max, address(this));
        uint256 g = IERC20Tri(GHO).balanceOf(address(this)) - g0;
        uint256 e = USDE_GHO.swapIn(false, g, 0, address(this));
        USDE_USDT.swapIn(true, e, 0, address(this));
        usdtDelta = int256(IERC20Tri(USDT0).balanceOf(address(this))) - int256(u0);
        ghoDelta = int256(IERC20Tri(GHO).balanceOf(address(this))) - int256(g0);
        usdeDelta = int256(IERC20Tri(USDE).balanceOf(address(this))) - int256(e0);
    }

    // USDT0 -> USDe via repeated exact-output, then exact-input through USDe->GHO->USDT0.
    function routeB(uint256 rounds, uint256 usdeOutEach) external returns (int256 usdtDelta, int256 ghoDelta, int256 usdeDelta) {
        uint256 u0 = IERC20Tri(USDT0).balanceOf(address(this));
        uint256 g0 = IERC20Tri(GHO).balanceOf(address(this));
        uint256 e0 = IERC20Tri(USDE).balanceOf(address(this));
        for (uint256 i; i < rounds; ++i) USDE_USDT.swapOut(false, usdeOutEach, type(uint256).max, address(this));
        uint256 e = IERC20Tri(USDE).balanceOf(address(this)) - e0;
        uint256 g = USDE_GHO.swapIn(true, e, 0, address(this));
        GHO_USDT.swapIn(true, g, 0, address(this));
        usdtDelta = int256(IERC20Tri(USDT0).balanceOf(address(this))) - int256(u0);
        ghoDelta = int256(IERC20Tri(GHO).balanceOf(address(this))) - int256(g0);
        usdeDelta = int256(IERC20Tri(USDE).balanceOf(address(this))) - int256(e0);
    }
}

contract PlasmaStableTriangleSearchTest is Test {
    address constant USDT0 = 0xB8CE59FC3717ada4C02eaDF9682A9e934F625ebb;
    address constant GHO = 0xb77E872A68C62CfC0dFb02C067Ecc3DA23B4bbf3;
    address constant USDE = 0x5d3a1Ff2b6BAb83b63cd9AD0787074081a52ef34;

    event TriangleCandidate(uint8 route, uint256 rounds, uint256 amountOutEach, int256 usdtDelta, int256 ghoDelta, int256 usdeDelta, uint256 gasUsed);
    event TriangleBest(uint8 route, uint256 rounds, uint256 amountOutEach, int256 parityProfit18, uint256 gasUsed);

    function setUp() public { vm.createSelectFork(vm.envString("PLASMA_RPC_URL")); }

    function _rounds(uint256 i) internal pure returns (uint256) {
        uint256[8] memory r = [uint256(1), 8, 32, 64, 128, 256, 512, 1024];
        return r[i];
    }

    function _amount(uint256 i) internal pure returns (uint256) {
        uint256[18] memory a = [
            uint256(240000000000001), 248000000000001, 255000000000001,
            255900000000001, 255999000000001, 256000000000001,
            256100000000001, 256500000000001, 257000000000001,
            300000000000001, 512000000000001, 768000000000001,
            1024000000000001, 2048000000000001, 4096000000000001,
            10000000000000001, 100000000000000001, 1000000000000000001
        ];
        return a[i];
    }

    function _parity(int256 u, int256 g, int256 e) internal pure returns (int256) {
        return u * int256(1e12) + g + e;
    }

    function test_triangleSearch() public {
        int256 best;
        uint8 bestRoute;
        uint256 bestRounds;
        uint256 bestAmount;
        uint256 bestGas;

        for (uint8 route = 1; route <= 2; ++route) {
            for (uint256 ri; ri < 8; ++ri) {
                for (uint256 ai; ai < 18; ++ai) {
                    uint256 snap = vm.snapshot();
                    TriangleExecutor ex = new TriangleExecutor();
                    deal(USDT0, address(ex), 1_000_000_000_000);
                    deal(GHO, address(ex), 0);
                    deal(USDE, address(ex), 0);
                    uint256 gasBefore = gasleft();
                    try route == 1 ? ex.routeA(_rounds(ri), _amount(ai)) : ex.routeB(_rounds(ri), _amount(ai)) returns (int256 u, int256 g, int256 e) {
                        uint256 used = gasBefore - gasleft();
                        int256 p = _parity(u, g, e);
                        emit TriangleCandidate(route, _rounds(ri), _amount(ai), u, g, e, used);
                        if (p > best) { best = p; bestRoute = route; bestRounds = _rounds(ri); bestAmount = _amount(ai); bestGas = used; }
                    } catch {}
                    require(vm.revertTo(snap), "restore");
                }
            }
        }
        emit TriangleBest(bestRoute, bestRounds, bestAmount, best, bestGas);
    }
}
