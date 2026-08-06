// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.21;

import {PlasmaVaultT4LargeLiquidationReachabilityV2Test} from "./PlasmaVaultT4LargeLiquidationReachabilityV2.t.sol";

contract PlasmaVaultT4LiquidationBoundaryTest is PlasmaVaultT4LargeLiquidationReachabilityV2Test {
    event BoundaryReachability(
        uint256 nominalGhoOutput1e18,
        bool success,
        bytes4 revertSelector,
        bytes32 revertHash,
        uint256 revertLength
    );

    function test_adverseDirectionLiquidityBoundary() public {
        uint256[6] memory sizes = [
            uint256(2_100_000e18),
            uint256(2_200_000e18),
            uint256(2_300_000e18),
            uint256(2_400_000e18),
            uint256(2_500_000e18),
            uint256(2_600_000e18)
        ];

        for (uint256 i; i < sizes.length; ++i) {
            vm.createSelectFork(rpcUrl, forkBlock);
            (bool ok, bytes memory reason) = address(this).call(
                abi.encodeCall(this.executeLargeV2, (false, sizes[i]))
            );
            emit BoundaryReachability(
                sizes[i],
                ok,
                ok ? bytes4(0) : _selector(reason),
                ok ? bytes32(0) : keccak256(reason),
                ok ? 0 : reason.length
            );
        }
    }
}
