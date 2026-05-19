// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test } from "forge-std/Test.sol";
import { HotshotLaunchpadFactory } from "../src/HotshotLaunchpadFactory.sol";
import { MerkleVestDistributor } from "../src/MerkleVestDistributor.sol";
import { BondingCurve } from "../src/BondingCurve.sol";
import { FeeTreasury } from "../src/FeeTreasury.sol";
import { LpLocker } from "../src/LpLocker.sol";
import { Tokenomics } from "../src/Tokenomics.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { INonfungiblePositionManager } from "../src/interfaces/IUniswapV3.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { MockERC20 } from "./utils/MockERC20.sol";
import { MockNPM } from "./utils/MockNPM.sol";

contract LaunchpadTest is Test {
    HotshotLaunchpadFactory factory;
    MockERC20 wld;
    MockNPM npm;
    FeeTreasury treasury;

    address safe = makeAddr("safe");
    address launcher = makeAddr("launcher");
    uint256 constant UNIT = 1e18;

    function setUp() public {
        wld = new MockERC20();
        npm = new MockNPM();
        treasury = new FeeTreasury(safe);
        factory = new HotshotLaunchpadFactory(
            IERC20(address(wld)),
            address(treasury),
            INonfungiblePositionManager(address(npm)),
            launcher
        );
    }

    function _params(uint256 id)
        internal
        view
        returns (HotshotLaunchpadFactory.LaunchParams memory p)
    {
        p.contestId = id;
        p.name = "Shot";
        p.symbol = "SHOT";
        p.virtualQuoteReserve = 30_000 * UNIT;
        p.graduationThresholdWLD = 50_000 * UNIT;
        p.campaignExpiry = uint64(block.timestamp + 365 days);
        uint64 s = uint64(block.timestamp + 60);
        p.campaigns[0] = MerkleVestDistributor.Campaign(
            bytes32(uint256(1)),
            Tokenomics.CREATOR_UNLOCK_BPS,
            s,
            s + Tokenomics.CREATOR_VEST_SECS,
            0
        );
        p.campaigns[1] = MerkleVestDistributor.Campaign(
            bytes32(uint256(2)),
            Tokenomics.BACKERS_UNLOCK_BPS,
            s,
            s + Tokenomics.BACKERS_VEST_SECS,
            0
        );
        p.campaigns[2] = MerkleVestDistributor.Campaign(
            bytes32(uint256(3)), Tokenomics.VOTERS_UNLOCK_BPS, s, s + Tokenomics.VOTERS_VEST_SECS, 0
        );
    }

    // ── factory ──

    function test_launchWiresAndSplitsExactly() public {
        vm.prank(launcher);
        (address token, address curve, address dist) = factory.launch(_params(1));

        uint256 total = Tokenomics.TOTAL_SUPPLY * UNIT;
        assertEq(IERC20(token).totalSupply(), total);
        assertEq(IERC20(token).balanceOf(curve), Tokenomics.CURVE_ALLOCATION * UNIT);
        assertEq(IERC20(token).balanceOf(dist), Tokenomics.REWARDS_POOL_TOTAL * UNIT);
        assertEq(IERC20(token).balanceOf(address(factory)), 0);
        assertEq(
            Tokenomics.CURVE_ALLOCATION + Tokenomics.REWARDS_POOL_TOTAL, Tokenomics.TOTAL_SUPPLY
        );
    }

    function test_launchOnlyLauncher() public {
        vm.expectRevert(HotshotLaunchpadFactory.NotLauncher.selector);
        factory.launch(_params(1));
    }

    function test_duplicateContestReverts() public {
        vm.startPrank(launcher);
        factory.launch(_params(7));
        vm.expectRevert(); // CREATE2 collision on same salt
        factory.launch(_params(7));
        vm.stopPrank();
    }

    function test_setLauncherOnlyTreasury() public {
        vm.expectRevert(HotshotLaunchpadFactory.NotTreasury.selector);
        factory.setLauncher(address(1));
        vm.prank(safe); // FeeTreasury owner is `safe`, but setLauncher checks treasury *address*
        // setLauncher is gated on msg.sender == treasury (the FeeTreasury contract),
        // so a direct EOA call must revert; rotate via a treasury-initiated call.
        vm.expectRevert(HotshotLaunchpadFactory.NotTreasury.selector);
        factory.setLauncher(address(1));
        vm.prank(address(treasury));
        factory.setLauncher(address(99));
        assertEq(factory.launcher(), address(99));
    }

    // ── FeeTreasury ──

    function test_treasuryWithdrawOnlyOwner() public {
        wld.mint(address(treasury), 1000);
        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this))
        );
        treasury.withdraw(IERC20(address(wld)), address(this), 1000);
        vm.prank(safe);
        treasury.withdraw(IERC20(address(wld)), safe, 1000);
        assertEq(wld.balanceOf(safe), 1000);
    }

    function test_treasuryOwnable2Step() public {
        vm.prank(safe);
        treasury.transferOwnership(address(0xBEEF));
        assertEq(treasury.owner(), safe); // not yet
        vm.prank(address(0xBEEF));
        treasury.acceptOwnership();
        assertEq(treasury.owner(), address(0xBEEF));
    }

    // ── LpLocker ──

    function test_lockerRejectsForeignNft() public {
        LpLocker locker = new LpLocker(address(npm), 42, address(treasury));
        // not from npm
        vm.expectRevert(LpLocker.UnexpectedToken.selector);
        locker.onERC721Received(address(0), address(0), 42, "");
        // from npm but wrong id
        vm.prank(address(npm));
        vm.expectRevert(LpLocker.UnexpectedToken.selector);
        locker.onERC721Received(address(0), address(0), 7, "");
        // correct
        vm.prank(address(npm));
        assertEq(
            locker.onERC721Received(address(0), address(0), 42, ""),
            locker.onERC721Received.selector
        );
    }

    function test_lockerCollectsToTreasuryNoRevert() public {
        LpLocker locker = new LpLocker(address(npm), 1, address(treasury));
        (uint256 a0, uint256 a1) = locker.collectFees(); // mock returns 0,0
        assertEq(a0, 0);
        assertEq(a1, 0);
    }
}
