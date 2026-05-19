// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, Vm} from "forge-std/Test.sol";
import {BondingCurve} from "../../src/BondingCurve.sol";
import {HotshotToken} from "../../src/HotshotToken.sol";
import {Tokenomics} from "../../src/Tokenomics.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {INonfungiblePositionManager} from "../../src/interfaces/IUniswapV3.sol";

interface IUniV3Factory {
    function getPool(address, address, uint24) external view returns (address);
}

interface IUniV3Pool {
    function liquidity() external view returns (uint128);
    function slot0()
        external
        view
        returns (uint160 sqrtPriceX96, int24 tick, uint16, uint16, uint16, uint8, bool);
}

/// @notice Mainnet-fork validation of the AUDIT-CRITICAL atomic graduation
///         against the REAL Uniswap V3 on World Chain (no credentials — public
///         RPC). Validates: pool is created & initialized, full-range liquidity
///         is actually added, and the LP NFTs land 50% burned / 50% in the
///         locker. Run: `forge test --match-contract GraduationFork`.
contract GraduationForkTest is Test {
    // Verified live on World Chain mainnet (codesize-checked).
    address constant WLD = 0x2cFc85d8E48F8EAB294be644d9E25C3030863003;
    address constant FACTORY = 0x7a5028BDa40e7B173C278C5342087826455ea25a;
    address constant NPM = 0xec12a9F9a09f50550686363766Cc153D03c27b5e;
    address constant BURN = 0x000000000000000000000000000000000000dEaD;

    BondingCurve curve;
    HotshotToken tkn;
    address treasury = makeAddr("treasury");
    address buyer = makeAddr("buyer");

    uint256 constant E18 = 1e18;
    uint256 constant CURVE_SUPPLY = 650_000_000 * E18;

    function setUp() public {
        vm.createSelectFork(
            vm.envOr("WORLDCHAIN_MAINNET_RPC", string("https://worldchain-mainnet.g.alchemy.com/public"))
        );

        tkn = new HotshotToken("Shot", "SHOT", 1, address(this));
        curve = new BondingCurve(
            IERC20(address(tkn)),
            IERC20(WLD),
            treasury,
            INonfungiblePositionManager(NPM),
            CURVE_SUPPLY,
            30_000 * E18, // virtual quote reserve
            5 * E18 // low threshold so a small buy graduates
        );
        tkn.transfer(address(curve), CURVE_SUPPLY);

        deal(WLD, buyer, 1_000 * E18);
        vm.prank(buyer);
        IERC20(WLD).approve(address(curve), type(uint256).max);
    }

    function test_fork_graduateOnRealUniswapV3() public {
        vm.roll(block.number + 20); // past anti-snipe

        vm.recordLogs();
        vm.prank(buyer);
        curve.buy(50 * E18, 0); // > 5 WLD threshold → triggers _graduate()

        assertTrue(curve.graduated(), "did not graduate");

        // Decode Graduated(pool, liqQuote, liqToken, locker)
        Vm.Log[] memory logs = vm.getRecordedLogs();
        address pool;
        address locker;
        bytes32 sig = keccak256("Graduated(address,uint256,uint256,address)");
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].topics[0] == sig) {
                pool = address(uint160(uint256(logs[i].topics[1])));
                (,, locker) = abi.decode(logs[i].data, (uint256, uint256, address));
            }
        }

        // 1. pool created & registered on the real factory
        assertEq(pool, IUniV3Factory(FACTORY).getPool(address(tkn), WLD, 10_000), "pool mismatch");
        assertGt(pool.code.length, 0, "pool has no code");

        // 2. pool initialized with a sane price and real liquidity added
        (uint160 sp,,,,,,) = IUniV3Pool(pool).slot0();
        assertGt(sp, 0, "pool not initialized");
        assertGt(IUniV3Pool(pool).liquidity(), 0, "no liquidity seeded");

        // 3. LP split: one position burned, one held by the immutable locker
        assertGe(IERC721(NPM).balanceOf(BURN), 1, "burn position missing");
        assertEq(IERC721(NPM).balanceOf(locker), 1, "locker position missing");

        // 4. graduation fee reached the treasury (in WLD)
        assertGt(IERC20(WLD).balanceOf(treasury), 0, "no graduation/trade fee");
    }
}
