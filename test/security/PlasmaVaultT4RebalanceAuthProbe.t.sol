// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.21;

import {Test} from "forge-std/Test.sol";

interface IFactoryRebalanceAuth {
    function owner() external view returns (address);
}

interface IVaultRebalanceAuth {
    function rebalance(int,int,int,int) external payable returns (int,int);
    function readFromStorage(bytes32 slot) external view returns (uint256);
}

interface IReserveRebalanceAuth {
    function owner() external view returns (address);
    function isAuth(address account) external view returns (bool);
    function isRebalancer(address account) external view returns (bool);
    function nativeTokenAllowances(address protocol) external view returns (uint256);
    function rebalanceDexVault(address,uint256,int,int,int,int) external payable;
    function rebalanceDexVaults(address[] calldata,uint256[] calldata,int[] calldata,int[] calldata,int[] calldata,int[] calldata) external payable;
    function updateRebalancer(address,bool) external;
    function initialize(address[] calldata,address[] calldata,address) external;
}

contract PlasmaVaultT4RebalanceAuthProbeTest is Test {
    address internal constant FACTORY = 0x324c5Dc1fC42c7a4D43d92df1eBA58a54d13Bf2d;
    address internal constant VAULT = 0x6E0cDB09eb33cD3894C905E0DFF9289b95a86FFF;
    address internal constant RESERVE = 0x264786ef916af64a1db19f513f24a3681734ce92;
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;

    bytes4 internal constant VAULT_ERROR = bytes4(keccak256("FluidVaultError(uint256)"));
    bytes4 internal constant RESERVE_ERROR = bytes4(keccak256("FluidReserveContractError(uint256)"));
    bytes4 internal constant ERROR_STRING = 0x08c379a0;
    bytes4 internal constant PANIC = 0x4e487b71;

    uint256 internal constant VAULT_NOT_REBALANCER = 31010;
    uint256 internal constant RESERVE_UNAUTHORIZED = 90001;

    address internal attacker;

    event RebalanceLiveState(
        uint256 forkBlock,
        address indexed vault,
        address indexed reserve,
        uint256 reserveCodeSize,
        bytes32 reserveCodeHash,
        address vaultConfiguredRebalancer,
        address reserveOwner,
        address factoryOwner,
        uint256 nativeAllowance,
        bool attackerIsAuth,
        bool attackerIsRebalancer,
        bool reserveIsAuth,
        bool reserveIsRebalancer,
        bool vaultIsAuth,
        bool vaultIsRebalancer
    );

    event RebalanceAuthResult(
        bytes32 indexed scenario,
        address indexed caller,
        bool success,
        bytes4 selector,
        uint256 errorId,
        bytes32 revertHash,
        uint256 revertLength
    );

    function setUp() public {
        vm.createSelectFork(vm.envString("PLASMA_RPC_URL"), vm.envUint("PLASMA_FORK_BLOCK"));
        attacker = makeAddr("rebalance-attacker");
        assertEq(block.chainid, 9745, "wrong chain");
        assertGt(VAULT.code.length, 0, "vault missing");
        assertGt(RESERVE.code.length, 0, "reserve missing");
    }

    function _selector(bytes memory data) internal pure returns (bytes4 selector) {
        if (data.length < 4) return bytes4(0);
        assembly ("memory-safe") {
            selector := mload(add(data, 0x20))
        }
    }

    function _errorId(bytes memory data) internal pure returns (uint256 value) {
        if (data.length < 36) return 0;
        assembly ("memory-safe") {
            value := mload(add(data, 0x24))
        }
    }

    function _vaultRebalancer() internal returns (address value) {
        vm.prank(IFactoryRebalanceAuth(FACTORY).owner());
        uint256 raw = IVaultRebalanceAuth(VAULT).readFromStorage(bytes32(uint256(9)));
        value = address(uint160(raw));
    }

    function _emitResult(bytes32 scenario, address caller, bool ok, bytes memory data) internal {
        emit RebalanceAuthResult(
            scenario,
            caller,
            ok,
            ok ? bytes4(0) : _selector(data),
            ok ? 0 : _errorId(data),
            ok ? bytes32(0) : keccak256(data),
            ok ? 0 : data.length
        );
    }

    function _callAs(address caller, address target, bytes memory payload)
        internal
        returns (bool ok, bytes memory data)
    {
        vm.prank(caller);
        (ok, data) = target.call(payload);
    }

    function test_liveRebalanceAuthorization() public {
        address configured = _vaultRebalancer();
        address reserveOwner = IReserveRebalanceAuth(RESERVE).owner();
        address factoryOwner = IFactoryRebalanceAuth(FACTORY).owner();

        emit RebalanceLiveState(
            block.number,
            VAULT,
            RESERVE,
            RESERVE.code.length,
            RESERVE.codehash,
            configured,
            reserveOwner,
            factoryOwner,
            IReserveRebalanceAuth(RESERVE).nativeTokenAllowances(VAULT),
            IReserveRebalanceAuth(RESERVE).isAuth(attacker),
            IReserveRebalanceAuth(RESERVE).isRebalancer(attacker),
            IReserveRebalanceAuth(RESERVE).isAuth(RESERVE),
            IReserveRebalanceAuth(RESERVE).isRebalancer(RESERVE),
            IReserveRebalanceAuth(RESERVE).isAuth(VAULT),
            IReserveRebalanceAuth(RESERVE).isRebalancer(VAULT)
        );

        assertEq(configured, RESERVE, "vault points at another rebalancer");
        assertTrue(reserveOwner != address(0), "reserve unowned");
        assertFalse(IReserveRebalanceAuth(RESERVE).isRebalancer(attacker), "attacker already rebalancer");

        (bool ok, bytes memory data) = _callAs(
            attacker,
            VAULT,
            abi.encodeCall(IVaultRebalanceAuth.rebalance, (int256(1), int256(1), int256(1), int256(1)))
        );
        _emitResult("DIRECT_VAULT", attacker, ok, data);
        assertFalse(ok, "attacker directly rebalanced vault");
        assertEq(_selector(data), VAULT_ERROR, "unexpected vault revert selector");
        assertEq(_errorId(data), VAULT_NOT_REBALANCER, "unexpected vault error id");

        (ok, data) = _callAs(
            attacker,
            RESERVE,
            abi.encodeCall(
                IReserveRebalanceAuth.rebalanceDexVault,
                (VAULT, uint256(0), int256(1), int256(1), int256(1), int256(1))
            )
        );
        _emitResult("DIRECT_RESERVE", attacker, ok, data);
        assertFalse(ok, "attacker used reserve rebalance");
        assertEq(_selector(data), RESERVE_ERROR, "unexpected reserve selector");
        assertEq(_errorId(data), RESERVE_UNAUTHORIZED, "unexpected reserve error id");

        address[] memory protocols = new address[](1);
        protocols[0] = VAULT;
        uint256[] memory values = new uint256[](1);
        int256[] memory mins = new int256[](1);
        mins[0] = 1;
        (ok, data) = _callAs(
            attacker,
            RESERVE,
            abi.encodeCall(
                IReserveRebalanceAuth.rebalanceDexVaults,
                (protocols, values, mins, mins, mins, mins)
            )
        );
        _emitResult("BATCH_RESERVE", attacker, ok, data);
        assertFalse(ok, "attacker bypassed reserve via batch");
        assertEq(_selector(data), RESERVE_ERROR, "unexpected batch selector");
        assertEq(_errorId(data), RESERVE_UNAUTHORIZED, "unexpected batch error id");

        (ok, data) = _callAs(
            attacker,
            RESERVE,
            abi.encodeCall(IReserveRebalanceAuth.updateRebalancer, (attacker, true))
        );
        _emitResult("SELF_AUTHORIZE", attacker, ok, data);
        assertFalse(ok, "attacker self-authorized");
        assertEq(_selector(data), RESERVE_ERROR, "unexpected update selector");
        assertEq(_errorId(data), RESERVE_UNAUTHORIZED, "unexpected update error id");

        address[] memory empty = new address[](0);
        (ok, data) = _callAs(
            attacker,
            RESERVE,
            abi.encodeCall(IReserveRebalanceAuth.initialize, (empty, empty, attacker))
        );
        _emitResult("REINITIALIZE", attacker, ok, data);
        assertFalse(ok, "attacker reinitialized reserve");
        assertTrue(
            _selector(data) != bytes4(0) && _selector(data) != ERROR_STRING && _selector(data) != PANIC,
            "unexpected weak initializer revert"
        );

        (ok, data) = _callAs(
            DEAD,
            RESERVE,
            abi.encodeCall(
                IReserveRebalanceAuth.rebalanceDexVault,
                (VAULT, uint256(0), int256(1), int256(1), int256(1), int256(1))
            )
        );
        _emitResult("DEAD_CALLER", DEAD, ok, data);
        assertFalse(ok, "dead address authorized");
        assertEq(_selector(data), RESERVE_ERROR, "unexpected dead selector");
        assertEq(_errorId(data), RESERVE_UNAUTHORIZED, "unexpected dead error id");
    }
}
