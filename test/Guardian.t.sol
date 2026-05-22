// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test } from "forge-std/Test.sol";
import { Guardian } from "../src/Guardian.sol";

/// @notice Pause / unpause / timelock semantics for the Workstream E2
///         emergency lever. Covers:
///           - Only the Safe can pause / requestUnpause / executeUnpause
///           - Pause is instant; unpause is 72h-timelocked
///           - Auto-unpause at 7d makes isPaused() return false even when
///             storage still says paused
///           - settleAutoUnpause cleans up storage permissionlessly
contract GuardianTest is Test {
    Guardian guardian;
    address safe = makeAddr("safe");
    address attacker = makeAddr("attacker");

    function setUp() public {
        guardian = new Guardian(safe);
    }

    function test_initialUnpaused() public view {
        assertFalse(guardian.isPaused());
        assertEq(guardian.pausedAt(), 0);
    }

    function test_pauseOnlySafe() public {
        vm.expectRevert(Guardian.NotSafe.selector);
        vm.prank(attacker);
        guardian.pause();
    }

    function test_safePausesInstantly() public {
        vm.prank(safe);
        guardian.pause();
        assertTrue(guardian.isPaused());
        assertEq(guardian.pausedAt(), uint64(block.timestamp));
    }

    function test_pauseTwiceReverts() public {
        vm.prank(safe);
        guardian.pause();
        vm.prank(safe);
        vm.expectRevert(Guardian.AlreadyPaused.selector);
        guardian.pause();
    }

    function test_requestUnpauseOnlySafe() public {
        vm.prank(safe);
        guardian.pause();
        vm.expectRevert(Guardian.NotSafe.selector);
        vm.prank(attacker);
        guardian.requestUnpause();
    }

    function test_requestUnpauseRequiresPaused() public {
        vm.prank(safe);
        vm.expectRevert(Guardian.NotPaused.selector);
        guardian.requestUnpause();
    }

    function test_executeUnpauseRequiresRequest() public {
        vm.prank(safe);
        guardian.pause();
        vm.prank(safe);
        vm.expectRevert(Guardian.UnpauseNotRequested.selector);
        guardian.executeUnpause();
    }

    function test_executeUnpauseBeforeTimelockReverts() public {
        vm.prank(safe);
        guardian.pause();
        vm.prank(safe);
        guardian.requestUnpause();
        // 1 hour after request — still 71h away from ready
        vm.warp(block.timestamp + 1 hours);
        vm.prank(safe);
        vm.expectRevert(); // TimelockActive(uint64) — args vary, abi-encode-safe
        guardian.executeUnpause();
    }

    function test_executeUnpauseAfterTimelockSucceeds() public {
        vm.prank(safe);
        guardian.pause();
        vm.prank(safe);
        guardian.requestUnpause();
        vm.warp(block.timestamp + 72 hours + 1);
        vm.prank(safe);
        guardian.executeUnpause();
        assertFalse(guardian.isPaused());
    }

    function test_autoUnpauseAt7d() public {
        vm.prank(safe);
        guardian.pause();
        assertTrue(guardian.isPaused());
        // Just before horizon — still paused
        vm.warp(block.timestamp + 7 days - 1);
        assertTrue(guardian.isPaused());
        // At horizon — auto-unpaused
        vm.warp(block.timestamp + 2);
        assertFalse(guardian.isPaused());
        // Storage flag still true until settled
        assertTrue(guardian.pausedFlag());
    }

    function test_settleAutoUnpausePermissionless() public {
        vm.prank(safe);
        guardian.pause();
        vm.warp(block.timestamp + 7 days + 1);
        // Anyone can settle — no NotSafe revert
        vm.prank(attacker);
        guardian.settleAutoUnpause();
        assertFalse(guardian.pausedFlag());
        assertFalse(guardian.isPaused());
    }

    function test_settleAutoUnpauseBeforeHorizonReverts() public {
        vm.prank(safe);
        guardian.pause();
        vm.warp(block.timestamp + 3 days);
        vm.expectRevert();
        guardian.settleAutoUnpause();
    }

    function test_pauseAgainAfterUnpause() public {
        vm.prank(safe);
        guardian.pause();
        vm.prank(safe);
        guardian.requestUnpause();
        vm.warp(block.timestamp + 72 hours + 1);
        vm.prank(safe);
        guardian.executeUnpause();
        // Should be able to pause again — full cycle is reusable
        vm.prank(safe);
        guardian.pause();
        assertTrue(guardian.isPaused());
    }
}
