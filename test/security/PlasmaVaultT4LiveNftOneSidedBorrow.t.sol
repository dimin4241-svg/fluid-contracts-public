// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.21;

import "./PlasmaVaultT4LiquidationSurfaceProbe.t.sol";

interface IVaultLiveOneSided {
    function operate(uint256,int256,int256,int256,int256,int256,int256,address)
        external payable returns (uint256,int256,int256);
}

interface IFactoryLiveOneSided {
    function ownerOf(uint256 nftId) external view returns (address);
}

interface IERC20LiveOneSided {
    function balanceOf(address account) external view returns (uint256);
}

interface IOracleLiveOneSided {
    function getExchangeRateLiquidate() external view returns (uint256);
}

contract PlasmaVaultT4LiveNftOneSidedBorrowTest is PlasmaVaultT4LiquidationSurfaceProbeTest {
    address constant ORACLE_LIVE = 0x029E6fF2173ff6c9e61787Fa7A3cfF1117D957b6;

    event LiveBorrowReachability(
        uint256 indexed nftId,
        bool indexed borrowGho,
        uint256 requested1e18,
        bool success,
        bytes4 selector,
        uint256 errorId,
        bytes32 revertHash
    );
    event LiveBorrowMovement(
        uint256 indexed nftId,
        bool indexed borrowGho,
        uint256 requested1e18,
        int256 debtSharesMinted,
        uint256 receivedGho,
        uint256 receivedUsdt0,
        uint256 oracleBefore,
        uint256 oracleAfter,
        int256 oracleDelta,
        int256 oracleDeltaPpm
    );
    event LiveBorrowLiquidation(
        uint256 indexed nftId,
        bool indexed borrowGho,
        uint256 requested1e18,
        bytes4 selector,
        bool liquidatable,
        uint256 colLiquidated,
        uint256 debtLiquidated,
        uint256 errorId,
        bool eligibilityChanged
    );

    function _localError(bytes memory data) internal pure returns (uint256 value) {
        if (data.length < 36) return 0;
        assembly ("memory-safe") { value := mload(add(data, 0x24)) }
    }

    function executeLiveBorrow(uint256 nftId, bool borrowGho, uint256 requested1e18) external {
        require(msg.sender == address(this), "self only");
        address owner = IFactoryLiveOneSided(FACTORY).ownerOf(nftId);
        require(owner != address(0), "owner missing");
        Simulation memory beforeSim = _simulate(false);
        uint256 oracleBefore = IOracleLiveOneSided(ORACLE_LIVE).getExchangeRateLiquidate();
        uint256 ghoBefore = IERC20LiveOneSided(GHO).balanceOf(owner);
        uint256 usdtBefore = IERC20LiveOneSided(USDT0).balanceOf(owner);

        vm.prank(owner);
        (, int256 colShares, int256 debtShares) = IVaultLiveOneSided(VAULT).operate(
            nftId,
            0,
            0,
            0,
            borrowGho ? int256(requested1e18) : int256(0),
            borrowGho ? int256(0) : int256(requested1e18 / 1e12),
            1,
            owner
        );
        require(colShares == 0 && debtShares > 0, "unexpected operate result");
        uint256 oracleAfter = IOracleLiveOneSided(ORACLE_LIVE).getExchangeRateLiquidate();
        int256 delta = _delta(oracleAfter, oracleBefore);
        emit LiveBorrowMovement(
            nftId,
            borrowGho,
            requested1e18,
            debtShares,
            IERC20LiveOneSided(GHO).balanceOf(owner) - ghoBefore,
            IERC20LiveOneSided(USDT0).balanceOf(owner) - usdtBefore,
            oracleBefore,
            oracleAfter,
            delta,
            delta * int256(1e6) / int256(oracleBefore)
        );
        Simulation memory afterSim = _simulate(false);
        emit LiveBorrowLiquidation(
            nftId,
            borrowGho,
            requested1e18,
            afterSim.selector,
            afterSim.expectedResult,
            afterSim.colLiquidated,
            afterSim.debtLiquidated,
            afterSim.errorId,
            beforeSim.expectedResult != afterSim.expectedResult
        );
    }

    function test_liveNftOneSidedBorrow() public {
        uint256[4] memory ids = [uint256(2770), uint256(2887), uint256(2869), uint256(2725)];
        uint256[4] memory sizes = [uint256(1_000e18), uint256(10_000e18), uint256(50_000e18), uint256(100_000e18)];
        for (uint256 direction; direction < 2; ++direction) {
            bool borrowGho = direction == 0;
            for (uint256 i; i < ids.length; ++i) {
                for (uint256 j; j < sizes.length; ++j) {
                    vm.createSelectFork(rpcUrl, forkBlock);
                    (bool ok, bytes memory reason) = address(this).call(
                        abi.encodeCall(this.executeLiveBorrow, (ids[i], borrowGho, sizes[j]))
                    );
                    emit LiveBorrowReachability(
                        ids[i],
                        borrowGho,
                        sizes[j],
                        ok,
                        ok ? bytes4(0) : _selector(reason),
                        ok ? 0 : _localError(reason),
                        ok ? bytes32(0) : keccak256(reason)
                    );
                }
            }
        }
    }
}
