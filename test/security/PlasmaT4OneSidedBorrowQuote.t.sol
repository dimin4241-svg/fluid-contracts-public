// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.21;

import {Test} from "forge-std/Test.sol";

interface IDexBorrowQuote {
    function borrow(uint256 token0Amt, uint256 token1Amt, uint256 maxSharesAmt, address to)
        external returns (uint256 shares);
    function readFromStorage(bytes32 slot) external view returns (uint256);
}

interface IOracleQuote {
    function getExchangeRateLiquidate() external view returns (uint256);
    function dexSmartDebtSharesRates() external view returns (uint256 operateRate, uint256 liquidateRate);
    function dexSmartColSharesRates() external view returns (uint256 operateRate, uint256 liquidateRate);
}

contract PlasmaT4OneSidedBorrowQuoteTest is Test {
    address internal constant DEX = 0x080574D224E960c272e005aA03EFbe793f317640;
    address internal constant ORACLE = 0x029E6fF2173ff6c9e61787Fa7A3cfF1117D957b6;
    address internal constant ADDRESS_DEAD = 0x000000000000000000000000000000000000dEaD;
    bytes4 internal constant LIQUIDITY_OUTPUT = bytes4(keccak256("FluidDexLiquidityOutput(uint256)"));
    bytes4 internal constant DEX_ERROR = bytes4(keccak256("FluidDexError(uint256)"));
    uint256 internal constant X128 = type(uint128).max;

    string internal rpcUrl;
    uint256 internal forkBlock;

    event QuoteSurface(
        uint256 forkBlock,
        uint256 oracleLiquidate,
        uint256 debtRateLiquidate,
        uint256 colRateLiquidate,
        uint256 totalBorrowShares,
        uint256 maxBorrowShares
    );

    event OneSidedBorrowQuote(
        bool indexed borrowToken0,
        uint256 requested1e18,
        uint256 rawToken0,
        uint256 rawToken1,
        bytes4 selector,
        uint256 quotedShares,
        uint256 errorId,
        bytes32 revertHash,
        uint256 revertLength
    );

    function setUp() public {
        rpcUrl = vm.envString("PLASMA_RPC_URL");
        forkBlock = vm.envUint("PLASMA_FORK_BLOCK");
        vm.createSelectFork(rpcUrl, forkBlock);
        assertEq(block.chainid, 9745, "wrong chain");
    }

    function _selector(bytes memory data) internal pure returns (bytes4 value) {
        if (data.length < 4) return bytes4(0);
        assembly ("memory-safe") { value := mload(add(data, 0x20)) }
    }

    function _word(bytes memory data) internal pure returns (uint256 value) {
        require(data.length >= 36, "short revert");
        assembly ("memory-safe") { value := mload(add(data, 0x24)) }
    }

    function _quote(bool borrowToken0, uint256 requested1e18) internal {
        uint256 raw0 = borrowToken0 ? requested1e18 : 0;
        uint256 raw1 = borrowToken0 ? 0 : requested1e18 / 1e12;
        (bool ok, bytes memory reason) = DEX.call(
            abi.encodeCall(IDexBorrowQuote.borrow, (raw0, raw1, type(uint256).max, ADDRESS_DEAD))
        );
        require(!ok, "quote unexpectedly succeeded");
        bytes4 selector = _selector(reason);
        uint256 shares;
        uint256 errorId;
        if (selector == LIQUIDITY_OUTPUT && reason.length >= 36) shares = _word(reason);
        if (selector == DEX_ERROR && reason.length >= 36) errorId = _word(reason);
        emit OneSidedBorrowQuote(
            borrowToken0,
            requested1e18,
            raw0,
            raw1,
            selector,
            shares,
            errorId,
            keccak256(reason),
            reason.length
        );
    }

    function test_oneSidedBorrowQuotes() public {
        (uint256 debtOperate, uint256 debtLiquidate) = IOracleQuote(ORACLE).dexSmartDebtSharesRates();
        (uint256 colOperate, uint256 colLiquidate) = IOracleQuote(ORACLE).dexSmartColSharesRates();
        uint256 packed = IDexBorrowQuote(DEX).readFromStorage(bytes32(uint256(4)));
        emit QuoteSurface(
            forkBlock,
            IOracleQuote(ORACLE).getExchangeRateLiquidate(),
            debtLiquidate,
            colLiquidate,
            packed & X128,
            packed >> 128
        );
        assertGt(debtOperate, 0);
        assertGt(colOperate, 0);

        uint256[6] memory sizes = [
            uint256(1_000e18),
            uint256(10_000e18),
            uint256(100_000e18),
            uint256(500_000e18),
            uint256(1_000_000e18),
            uint256(1_500_000e18)
        ];
        for (uint256 direction; direction < 2; ++direction) {
            for (uint256 i; i < sizes.length; ++i) {
                _quote(direction == 0, sizes[i]);
            }
        }
    }
}
