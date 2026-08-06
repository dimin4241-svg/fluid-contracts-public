// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

interface Vm {
    function createSelectFork(string calldata urlOrAlias) external returns (uint256 forkId);
    function createSelectFork(string calldata urlOrAlias, uint256 blockNumber) external returns (uint256 forkId);
    function envOr(string calldata name, uint256 defaultValue) external returns (uint256 value);
}

interface ISmartLendingFactory {
    function allTokens() external view returns (address[] memory);
    function totalSmartLendings() external view returns (uint256);
    function createdTokens(uint256 index) external view returns (address);
    function isSmartLending(address token) external view returns (bool);
}

interface ISmartLendingView {
    function POOL() external view returns (address);
    function TOKEN_0() external view returns (address);
    function TOKEN_1() external view returns (address);
    function totalSupply() external view returns (uint256);
    function name() external view returns (string memory);
    function symbol() external view returns (string memory);
}

contract PlasmaSmartLendingInventory {
    Vm internal constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    address internal constant FACTORY = 0xe57227C7d5900165344b190fc7aa580bceb53B9B;
    address internal constant TARGET_POOL = 0x080574D224E960c272e005aA03EFbe793f317640;

    event InventoryHeader(uint256 forkBlock, uint256 totalSmartLendings, uint256 allTokensLength);
    event WrapperInventory(
        uint256 indexed index,
        address indexed wrapper,
        address indexed pool,
        address token0,
        address token1,
        uint256 totalSupply,
        bool factoryRecognized,
        string name,
        string symbol
    );
    event TargetMatch(
        uint256 indexed index,
        address indexed wrapper,
        address indexed pool,
        address token0,
        address token1,
        uint256 totalSupply
    );
    event TargetSummary(uint256 matches);

    function setUp() public {
        uint256 requestedBlock = vm.envOr("PLASMA_FORK_BLOCK", uint256(0));
        if (requestedBlock == 0) {
            vm.createSelectFork("https://rpc.plasma.to");
        } else {
            vm.createSelectFork("https://rpc.plasma.to", requestedBlock);
        }
    }

    function testInventorySmartLendingWrappers() public {
        ISmartLendingFactory factory = ISmartLendingFactory(FACTORY);
        address[] memory wrappers = factory.allTokens();
        uint256 declaredTotal = factory.totalSmartLendings();
        uint256 matches;

        emit InventoryHeader(block.number, declaredTotal, wrappers.length);

        for (uint256 i; i < wrappers.length; ++i) {
            address wrapper = wrappers[i];
            ISmartLendingView smart = ISmartLendingView(wrapper);

            address pool = smart.POOL();
            address token0 = smart.TOKEN_0();
            address token1 = smart.TOKEN_1();
            uint256 supply = smart.totalSupply();
            bool recognized = factory.isSmartLending(wrapper);
            string memory name_ = smart.name();
            string memory symbol_ = smart.symbol();

            emit WrapperInventory(i, wrapper, pool, token0, token1, supply, recognized, name_, symbol_);

            if (pool == TARGET_POOL) {
                ++matches;
                emit TargetMatch(i, wrapper, pool, token0, token1, supply);
            }
        }

        emit TargetSummary(matches);
    }
}
