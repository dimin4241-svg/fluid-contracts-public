// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.21;

import {Test} from "forge-std/Test.sol";

interface IERC20CloseCost {
    function balanceOf(address account) external view returns (uint256);
}

interface IFactoryCloseCost {
    function ownerOf(uint256 nftId) external view returns (address);
}

interface IVaultT4CloseCost {
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

interface IResolverCloseCost {
    function FACTORY() external view returns (address);
}

interface IDexStorageCloseCost {
    function readFromStorage(bytes32 slot) external view returns (uint256);
}

contract PlasmaVaultT4DebtCloseCostInteractionTest is Test {
    address internal constant FACTORY = 0x324c5Dc1fC42c7a4D43d92df1eBA58a54d13Bf2d;
    address internal constant VAULT = 0x6E0cDB09eb33cD3894C905E0DFF9289b95a86FFF;
    address internal constant RESOLVER = 0xA5C3E16523eeeDDcC34706b0E6bE88b4c6EA95cC;
    address internal constant DEX = 0x080574D224E960c272e005aA03EFbe793f317640;
    address internal constant GHO = 0xb77E872A68C62CfC0dFb02C067Ecc3DA23B4bbf3;
    address internal constant USDT0 = 0xB8CE59FC3717ada4C02eaDF9682A9e934F625ebb;

    uint256 internal constant MANIPULATOR_NFT = 2887;
    uint256 internal constant SHIFT_SHARES = 1e22;
    uint256 internal constant FUNDING_GHO = 1e28;
    uint256 internal constant FUNDING_USDT0 = 1e18;
    int256 internal constant MAX_GHO_PAYMENT = -1e28;
    int256 internal constant MAX_USDT0_PAYMENT = -1e18;

    string internal rpcUrl;
    uint256 internal forkBlock;

    enum PaybackMode {
        Proportional,
        UsdtOnly
    }

    struct Position {
        uint256 nftId;
        address owner;
        bool isLiquidated;
        bool isSupplyPosition;
        uint256 supplyShares;
        uint256 borrowShares;
        uint256 dustBorrow;
    }

    struct CloseResult {
        bool ok;
        uint256 ghoSpent;
        uint256 usdtSpent;
        int256 returnedDebtShares;
        int256 returnedToken0;
        int256 returnedToken1;
    }

    struct ShiftResult {
        int256 ghoDelta;
        int256 usdtDelta;
        uint256 dexSlot2Before;
        uint256 dexSlot2After;
        uint256 dexSlot4Before;
        uint256 dexSlot4After;
    }

    event PositionMetadata(
        uint256 indexed nftId,
        address indexed owner,
        uint256 supplyShares,
        uint256 borrowShares,
        uint256 dustBorrow
    );

    event ShiftEconomics(
        uint256 indexed manipulatorNft,
        uint256 shiftShares,
        int256 ghoDelta,
        int256 usdtDelta,
        int256 nominalDelta1e18,
        uint256 dexSlot2Before,
        uint256 dexSlot2After,
        uint256 dexSlot4Before,
        uint256 dexSlot4After
    );

    event CloseCostResult(
        uint256 indexed targetNft,
        PaybackMode indexed mode,
        uint256 testedShares,
        uint256 testedPpmOfPosition,
        bool baselineOk,
        bool shiftedOk,
        uint256 baselineGhoSpent,
        uint256 baselineUsdtSpent,
        uint256 shiftedGhoSpent,
        uint256 shiftedUsdtSpent,
        int256 ghoCostDelta,
        int256 usdtCostDelta,
        int256 nominalCostDelta1e18,
        int256 baselineReturnedDebtShares,
        int256 shiftedReturnedDebtShares
    );

    function setUp() public {
        rpcUrl = vm.envString("PLASMA_RPC_URL");
        forkBlock = vm.envUint("PLASMA_FORK_BLOCK");
        vm.createSelectFork(rpcUrl, forkBlock);
        assertEq(block.chainid, 9745, "unexpected chain");
        assertGt(RESOLVER.code.length, 0, "missing resolver");
        assertEq(IResolverCloseCost(RESOLVER).FACTORY(), FACTORY, "resolver factory mismatch");
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
        require(p.owner == IFactoryCloseCost(FACTORY).ownerOf(nftId), "owner mismatch");
    }

    function _approve(address token, address owner) internal {
        vm.prank(owner);
        (bool ok, bytes memory data) = token.call(
            abi.encodeWithSignature("approve(address,uint256)", VAULT, type(uint256).max)
        );
        require(ok && (data.length == 0 || abi.decode(data, (bool))), "APPROVE_FAILED");
    }

    function _signed(uint256 after_, uint256 before_) internal pure returns (int256) {
        return after_ >= before_ ? int256(after_ - before_) : -int256(before_ - after_);
    }

    function _spent(uint256 before_, uint256 after_) internal pure returns (uint256) {
        require(before_ >= after_, "unexpected balance increase during payback");
        return before_ - after_;
    }

    function _fundAndApprove(address owner) internal {
        // Ordinary repayment funding only. Do not alter token totalSupply.
        deal(GHO, owner, FUNDING_GHO);
        deal(USDT0, owner, FUNDING_USDT0);
        _approve(GHO, owner);
        _approve(USDT0, owner);
    }

    function _applyShift() internal returns (ShiftResult memory s) {
        address owner = IFactoryCloseCost(FACTORY).ownerOf(MANIPULATOR_NFT);
        _fundAndApprove(owner);

        uint256 ghoBefore = IERC20CloseCost(GHO).balanceOf(owner);
        uint256 usdtBefore = IERC20CloseCost(USDT0).balanceOf(owner);
        s.dexSlot2Before = IDexStorageCloseCost(DEX).readFromStorage(bytes32(uint256(2)));
        s.dexSlot4Before = IDexStorageCloseCost(DEX).readFromStorage(bytes32(uint256(4)));

        vm.startPrank(owner);
        IVaultT4CloseCost(VAULT).operatePerfect(
            MANIPULATOR_NFT,
            0,
            0,
            0,
            -int256(SHIFT_SHARES),
            0,
            MAX_USDT0_PAYMENT,
            owner
        );
        IVaultT4CloseCost(VAULT).operatePerfect(
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

        s.ghoDelta = _signed(IERC20CloseCost(GHO).balanceOf(owner), ghoBefore);
        s.usdtDelta = _signed(IERC20CloseCost(USDT0).balanceOf(owner), usdtBefore);
        s.dexSlot2After = IDexStorageCloseCost(DEX).readFromStorage(bytes32(uint256(2)));
        s.dexSlot4After = IDexStorageCloseCost(DEX).readFromStorage(bytes32(uint256(4)));
    }

    function _close(bool shifted, uint256 nftId, uint256 shares, PaybackMode mode)
        internal returns (CloseResult memory r, ShiftResult memory shift)
    {
        vm.createSelectFork(rpcUrl, forkBlock);
        if (shifted) shift = _applyShift();

        Position memory p = _position(nftId);
        require(!p.isLiquidated && !p.isSupplyPosition, "target is not active debt position");
        require(shares > 0 && shares < p.borrowShares, "invalid partial close size");

        _fundAndApprove(p.owner);
        uint256 ghoBefore = IERC20CloseCost(GHO).balanceOf(p.owner);
        uint256 usdtBefore = IERC20CloseCost(USDT0).balanceOf(p.owner);

        int256 token0Max = mode == PaybackMode.Proportional ? MAX_GHO_PAYMENT : int256(0);
        int256 token1Max = MAX_USDT0_PAYMENT;

        vm.prank(p.owner);
        (bool ok, bytes memory returnData) = VAULT.call(
            abi.encodeWithSelector(
                IVaultT4CloseCost.operatePerfect.selector,
                nftId,
                int256(0),
                int256(0),
                int256(0),
                -int256(shares),
                token0Max,
                token1Max,
                p.owner
            )
        );
        r.ok = ok;
        if (!ok) return (r, shift);

        (, int256[] memory values) = abi.decode(returnData, (uint256, int256[]));
        require(values.length == 6, "unexpected operatePerfect result");
        r.returnedDebtShares = values[3];
        r.returnedToken0 = values[4];
        r.returnedToken1 = values[5];
        r.ghoSpent = _spent(ghoBefore, IERC20CloseCost(GHO).balanceOf(p.owner));
        r.usdtSpent = _spent(usdtBefore, IERC20CloseCost(USDT0).balanceOf(p.owner));
    }

    function _probe(uint256 nftId, uint256 shares, PaybackMode mode, uint256 positionShares) internal {
        (CloseResult memory baseline,) = _close(false, nftId, shares, mode);
        (CloseResult memory shifted, ShiftResult memory shift) = _close(true, nftId, shares, mode);

        int256 ghoDelta = _signed(shifted.ghoSpent, baseline.ghoSpent);
        int256 usdtDelta = _signed(shifted.usdtSpent, baseline.usdtSpent);

        emit ShiftEconomics(
            MANIPULATOR_NFT,
            SHIFT_SHARES,
            shift.ghoDelta,
            shift.usdtDelta,
            shift.ghoDelta + shift.usdtDelta * 1e12,
            shift.dexSlot2Before,
            shift.dexSlot2After,
            shift.dexSlot4Before,
            shift.dexSlot4After
        );

        emit CloseCostResult(
            nftId,
            mode,
            shares,
            (shares * 1_000_000) / positionShares,
            baseline.ok,
            shifted.ok,
            baseline.ghoSpent,
            baseline.usdtSpent,
            shifted.ghoSpent,
            shifted.usdtSpent,
            ghoDelta,
            usdtDelta,
            ghoDelta + usdtDelta * 1e12,
            baseline.returnedDebtShares,
            shifted.returnedDebtShares
        );

        assertEq(shifted.ok, baseline.ok, "shift changed payback reachability");
        assertTrue(baseline.ok, "baseline partial payback failed");
        assertEq(baseline.returnedDebtShares, -int256(shares), "baseline shares mismatch");
        assertEq(shifted.returnedDebtShares, -int256(shares), "shifted shares mismatch");
    }

    function test_measureCloseCostInteraction() public {
        uint256[3] memory targets = [uint256(1871), uint256(2580), uint256(2869)];

        for (uint256 i; i < targets.length; ++i) {
            vm.createSelectFork(rpcUrl, forkBlock);
            Position memory p = _position(targets[i]);
            assertGt(p.borrowShares, 100, "target debt too small");
            emit PositionMetadata(p.nftId, p.owner, p.supplyShares, p.borrowShares, p.dustBorrow);

            uint256[3] memory sizes = [p.borrowShares / 100, p.borrowShares / 10, p.borrowShares / 2];
            for (uint256 j; j < sizes.length; ++j) {
                _probe(p.nftId, sizes[j], PaybackMode.Proportional, p.borrowShares);
                _probe(p.nftId, sizes[j], PaybackMode.UsdtOnly, p.borrowShares);
            }
        }
    }
}
