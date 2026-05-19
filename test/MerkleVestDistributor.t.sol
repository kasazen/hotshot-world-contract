// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test } from "forge-std/Test.sol";
import { MerkleVestDistributor } from "../src/MerkleVestDistributor.sol";
import { Tokenomics } from "../src/Tokenomics.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { MockERC20 } from "./utils/MockERC20.sol";
import { MerkleLib } from "./utils/MerkleLib.sol";

contract MerkleVestDistributorTest is Test {
    MockERC20 token;
    MerkleVestDistributor dist;

    address treasury = makeAddr("treasury");
    address alice = makeAddr("alice"); // creator (role 0), idx 0
    address bob = makeAddr("bob"); // backers (role 1), idx 0
    address carol = makeAddr("carol"); // backers (role 1), idx 1
    address relayer = makeAddr("relayer"); // submits on behalf (Safe-style)

    uint256 constant E18 = 1e18;
    uint256 cAmt = Tokenomics.CREATOR_ALLOCATION * E18;
    uint256 bAmt = (Tokenomics.BACKERS_ALLOCATION / 2) * E18;
    uint256 vAmt = (Tokenomics.VOTERS_ALLOCATION) * E18;

    uint64 start;
    uint64 expiry;

    // leaves per role
    bytes32[] cLeaves;
    bytes32[] bLeaves;
    bytes32[] vLeaves;

    function _campaigns() internal view returns (MerkleVestDistributor.Campaign[3] memory cs) {
        cs[0] = MerkleVestDistributor.Campaign({
            merkleRoot: MerkleLib.root(cLeaves),
            unlockBps: Tokenomics.CREATOR_UNLOCK_BPS,
            start: start,
            end: start + Tokenomics.CREATOR_VEST_SECS,
            cliff: 0
        });
        cs[1] = MerkleVestDistributor.Campaign({
            merkleRoot: MerkleLib.root(bLeaves),
            unlockBps: Tokenomics.BACKERS_UNLOCK_BPS,
            start: start,
            end: start + Tokenomics.BACKERS_VEST_SECS,
            cliff: 0
        });
        cs[2] = MerkleVestDistributor.Campaign({
            merkleRoot: MerkleLib.root(vLeaves),
            unlockBps: Tokenomics.VOTERS_UNLOCK_BPS,
            start: start,
            end: start + Tokenomics.VOTERS_VEST_SECS,
            cliff: 0
        });
    }

    function setUp() public {
        token = new MockERC20();
        start = uint64(block.timestamp + 60);
        expiry = start + Tokenomics.CREATOR_VEST_SECS + 30 days;

        cLeaves.push(MerkleLib.leaf(0, alice, cAmt));
        cLeaves.push(MerkleLib.leaf(1, makeAddr("c1"), 123 * E18)); // padding leaf

        bLeaves.push(MerkleLib.leaf(0, bob, bAmt));
        bLeaves.push(MerkleLib.leaf(1, carol, bAmt));

        vLeaves.push(MerkleLib.leaf(0, makeAddr("v0"), vAmt));

        dist = new MerkleVestDistributor(IERC20(address(token)), treasury, _campaigns(), expiry);

        // factory funds the distributor with the rewards pool
        token.mint(address(dist), Tokenomics.REWARDS_POOL_TOTAL * E18 * 2);
    }

    function _claimCreator() internal {
        dist.claim(0, 0, alice, cAmt, MerkleLib.proof(cLeaves, 0));
    }

    // ---- vesting math ----

    function test_immediateUnlockAtStart() public {
        vm.warp(start);
        _claimCreator();
        assertEq(token.balanceOf(alice), cAmt * Tokenomics.CREATOR_UNLOCK_BPS / 10_000);
    }

    function test_beforeStartOnlyImmediate() public {
        // block.timestamp < start → immediate only (documented behavior)
        _claimCreator();
        assertEq(token.balanceOf(alice), cAmt * Tokenomics.CREATOR_UNLOCK_BPS / 10_000);
    }

    function test_linearMidVest() public {
        uint64 dur = Tokenomics.CREATOR_VEST_SECS;
        vm.warp(start + dur / 2);
        _claimCreator();
        uint256 immediate = cAmt * Tokenomics.CREATOR_UNLOCK_BPS / 10_000;
        uint256 expected = immediate + (cAmt - immediate) / 2;
        assertApproxEqAbs(token.balanceOf(alice), expected, 2);
    }

    function test_postEndFull() public {
        vm.warp(start + Tokenomics.CREATOR_VEST_SECS + 1);
        _claimCreator();
        assertEq(token.balanceOf(alice), cAmt);
    }

    function test_partialRepeatedClaimsSumToTotal() public {
        vm.warp(start);
        _claimCreator();
        vm.warp(start + Tokenomics.CREATOR_VEST_SECS / 2);
        _claimCreator();
        vm.warp(start + Tokenomics.CREATOR_VEST_SECS + 1);
        _claimCreator();
        assertEq(token.balanceOf(alice), cAmt);
        assertEq(dist.claimed(0, 0), cAmt);
    }

    function test_doubleClaimReverts() public {
        vm.warp(start);
        _claimCreator();
        vm.expectRevert(MerkleVestDistributor.NothingClaimable.selector);
        _claimCreator();
    }

    // ---- proof / auth ----

    function test_payToLeafAccount_anyoneCanSubmit() public {
        vm.warp(start + Tokenomics.CREATOR_VEST_SECS + 1);
        vm.prank(relayer); // Safe/relayer pattern: caller != beneficiary
        dist.claim(0, 0, alice, cAmt, MerkleLib.proof(cLeaves, 0));
        assertEq(token.balanceOf(alice), cAmt);
        assertEq(token.balanceOf(relayer), 0);
    }

    function test_wrongProofReverts() public {
        vm.warp(start);
        vm.expectRevert(MerkleVestDistributor.InvalidProof.selector);
        dist.claim(0, 0, alice, cAmt, MerkleLib.proof(bLeaves, 0));
    }

    function test_tamperedAmountReverts() public {
        vm.warp(start);
        vm.expectRevert(MerkleVestDistributor.InvalidProof.selector);
        dist.claim(0, 0, alice, cAmt + 1, MerkleLib.proof(cLeaves, 0));
    }

    function test_zeroAmountReverts() public {
        vm.expectRevert(MerkleVestDistributor.ZeroAmount.selector);
        dist.claim(0, 0, alice, 0, MerkleLib.proof(cLeaves, 0));
    }

    function test_crossRoleProofReverts() public {
        // bob's valid backers leaf must not work against the creator root
        vm.warp(start);
        vm.expectRevert(MerkleVestDistributor.InvalidProof.selector);
        dist.claim(0, 0, bob, bAmt, MerkleLib.proof(bLeaves, 0));
    }

    function test_backersTwoRecipients() public {
        vm.warp(start + Tokenomics.BACKERS_VEST_SECS + 1);
        dist.claim(1, 0, bob, bAmt, MerkleLib.proof(bLeaves, 0));
        dist.claim(1, 1, carol, bAmt, MerkleLib.proof(bLeaves, 1));
        assertEq(token.balanceOf(bob), bAmt);
        assertEq(token.balanceOf(carol), bAmt);
    }

    // ---- clawback ----

    function test_clawbackBeforeExpiryReverts() public {
        vm.prank(treasury);
        vm.expectRevert(MerkleVestDistributor.NotExpired.selector);
        dist.clawback(0, 1);
    }

    function test_clawbackNonTreasuryReverts() public {
        vm.warp(expiry + 1);
        vm.expectRevert(MerkleVestDistributor.NotTreasury.selector);
        dist.clawback(0, 1);
    }

    function test_clawbackAfterExpiryByTreasury() public {
        vm.warp(expiry + 1);
        uint256 bal = token.balanceOf(address(dist));
        vm.prank(treasury);
        dist.clawback(0, bal);
        assertEq(token.balanceOf(treasury), bal);
    }

    // ---- constructor validation ----

    function test_ctorRejectsZeroRoot() public {
        MerkleVestDistributor.Campaign[3] memory cs = _campaigns();
        cs[0].merkleRoot = bytes32(0);
        vm.expectRevert(MerkleVestDistributor.InvalidCampaign.selector);
        new MerkleVestDistributor(IERC20(address(token)), treasury, cs, expiry);
    }

    function test_ctorRejectsBadBps() public {
        MerkleVestDistributor.Campaign[3] memory cs = _campaigns();
        cs[1].unlockBps = 10_001;
        vm.expectRevert(MerkleVestDistributor.InvalidCampaign.selector);
        new MerkleVestDistributor(IERC20(address(token)), treasury, cs, expiry);
    }

    function test_ctorRejectsEndBeforeStart() public {
        MerkleVestDistributor.Campaign[3] memory cs = _campaigns();
        cs[2].end = cs[2].start;
        vm.expectRevert(MerkleVestDistributor.InvalidCampaign.selector);
        new MerkleVestDistributor(IERC20(address(token)), treasury, cs, expiry);
    }

    // ---- fuzz: unlocked is monotonic and bounded by total ----

    function testFuzz_claimableBounded(uint256 t) public {
        t = bound(t, 0, uint256(start) + Tokenomics.CREATOR_VEST_SECS * 3);
        vm.warp(t);
        uint256 c = dist.claimable(0, 0, cAmt);
        assertLe(c, cAmt);
        if (t >= uint256(start) + Tokenomics.CREATOR_VEST_SECS) {
            assertEq(c, cAmt);
        }
    }

    function testFuzz_monotonicNonDecreasing(uint64 t1, uint64 t2) public {
        vm.assume(t1 <= t2);
        vm.warp(t1);
        uint256 a = dist.claimable(0, 0, cAmt);
        vm.warp(t2);
        uint256 b = dist.claimable(0, 0, cAmt);
        assertGe(b, a);
    }
}
