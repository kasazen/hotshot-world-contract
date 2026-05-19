// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test } from "forge-std/Test.sol";
import { BondingCurve } from "../src/BondingCurve.sol";
import { Tokenomics } from "../src/Tokenomics.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { INonfungiblePositionManager } from "../src/interfaces/IUniswapV3.sol";
import { MockERC20 } from "./utils/MockERC20.sol";
import { MockNPM } from "./utils/MockNPM.sol";

contract BondingCurveTest is Test {
    MockERC20 tkn; // launched token
    MockERC20 wld; // quote
    MockNPM mockNpm;
    BondingCurve curve;

    address treasury = makeAddr("treasury");
    address buyer = makeAddr("buyer");

    uint256 constant E18 = 1e18;
    uint256 constant CURVE_SUPPLY = 650_000_000 * E18;
    uint256 constant VQR = 30_000 * E18; // virtual quote reserve
    uint256 constant THRESHOLD = 50_000 * E18;

    function setUp() public {
        tkn = new MockERC20();
        wld = new MockERC20();
        mockNpm = new MockNPM();

        curve = new BondingCurve(
            IERC20(address(tkn)),
            IERC20(address(wld)),
            treasury,
            INonfungiblePositionManager(address(mockNpm)),
            CURVE_SUPPLY,
            VQR,
            THRESHOLD
        );

        tkn.mint(address(curve), CURVE_SUPPLY); // factory funds the curve
        wld.mint(buyer, 1_000_000 * E18);
        vm.prank(buyer);
        wld.approve(address(curve), type(uint256).max);
    }

    function _buy(uint256 amt) internal returns (uint256) {
        vm.prank(buyer);
        return curve.buy(amt, 0);
    }

    // ── pricing / fees ──

    function test_buyDeliversTokensAndFeeToTreasury() public {
        // jump past anti-snipe so fee == schedule launch fee (1000 bps)
        vm.roll(block.number + 20);
        uint256 amt = 100 * E18;
        uint256 out = _buy(amt);
        assertGt(out, 0);
        assertEq(tkn.balanceOf(buyer), out);
        assertEq(wld.balanceOf(treasury), amt * Tokenomics.LAUNCH_FEE_BPS / 10_000);
        assertEq(curve.raisedWLD(), amt - amt * Tokenomics.LAUNCH_FEE_BPS / 10_000);
    }

    function test_constantProductInvariantHolds() public {
        vm.roll(block.number + 20);
        _buy(500 * E18);
        // (vQR + raised) * tokenReserve == k  (integer-floor tolerance)
        uint256 lhs = (VQR + curve.raisedWLD()) * curve.tokenReserve();
        assertApproxEqRel(lhs, curve.k(), 1e12); // ~1e-6
    }

    function test_feeScheduleDecays1000to300() public {
        vm.roll(block.number + 20); // disable anti-snipe
        assertEq(curve.scheduleFeeBps(), Tokenomics.LAUNCH_FEE_BPS);
        vm.warp(block.timestamp + 30 minutes);
        uint16 mid = curve.scheduleFeeBps();
        assertLt(mid, Tokenomics.LAUNCH_FEE_BPS);
        assertGt(mid, Tokenomics.POST_HOUR_FEE_BPS);
        vm.warp(block.timestamp + 31 minutes);
        assertEq(curve.scheduleFeeBps(), Tokenomics.POST_HOUR_FEE_BPS);
    }

    function test_antiSnipeSpikeAtLaunchDecays() public {
        uint16 f0 = curve.currentFeeBps();
        assertGt(f0, Tokenomics.LAUNCH_FEE_BPS); // spiked
        vm.roll(block.number + 20);
        assertEq(curve.currentFeeBps(), Tokenomics.LAUNCH_FEE_BPS); // back to schedule
    }

    function test_sellRoundTripReducesValue() public {
        vm.roll(block.number + 20);
        uint256 got = _buy(1000 * E18);
        vm.startPrank(buyer);
        tkn.approve(address(curve), type(uint256).max);
        uint256 back = curve.sell(got, 0);
        vm.stopPrank();
        // round trip must lose to fees/curvature — no free money
        assertLt(back, 1000 * E18);
    }

    // ── graduation ──

    function test_buyTriggersGraduation() public {
        vm.roll(block.number + 20);
        vm.expectEmit(false, false, false, false);
        emit BondingCurve.Graduated(address(0), 0, 0, address(0));
        _buy(60_000 * E18); // exceeds 50k threshold (net of fee still well over)

        assertTrue(curve.graduated());
        // graduation fee paid to treasury (in addition to trading fee)
        assertGt(wld.balanceOf(treasury), 0);
        // two positions minted; one burned, one in a locker
        assertEq(mockNpm.nextId(), 3);
        assertEq(mockNpm.ownerOf(1), 0x000000000000000000000000000000000000dEaD);
        assertTrue(mockNpm.ownerOf(2) != address(0));
        // mock NPM pulled the seeded liquidity from the curve
        assertGt(tkn.balanceOf(address(mockNpm)), 0);
        assertGt(wld.balanceOf(address(mockNpm)), 0);
    }

    function test_tradesRevertAfterGraduation() public {
        vm.roll(block.number + 20);
        _buy(60_000 * E18);
        vm.prank(buyer);
        vm.expectRevert(BondingCurve.AlreadyGraduated.selector);
        curve.buy(1 * E18, 0);
    }

    function test_manualGraduateRequiresThreshold() public {
        vm.expectRevert(bytes("threshold"));
        curve.graduate();
    }

    // ── admin ──

    function test_setThresholdOnlyTreasury() public {
        vm.expectRevert(BondingCurve.NotTreasury.selector);
        curve.setGraduationThreshold(1);
        vm.prank(treasury);
        curve.setGraduationThreshold(123);
        assertEq(curve.graduationThresholdWLD(), 123);
    }

    function test_zeroBuyReverts() public {
        vm.prank(buyer);
        vm.expectRevert(BondingCurve.ZeroAmount.selector);
        curve.buy(0, 0);
    }

    // ── fuzz: no free money on a single buy→sell round trip ──

    function testFuzz_buySellNoProfit(uint256 amt) public {
        amt = bound(amt, 1e15, 40_000 * E18); // stay under graduation
        vm.roll(block.number + 20);
        uint256 out = _buy(amt);
        vm.startPrank(buyer);
        tkn.approve(address(curve), type(uint256).max);
        uint256 back = curve.sell(out, 0);
        vm.stopPrank();
        assertLe(back, amt);
    }
}
