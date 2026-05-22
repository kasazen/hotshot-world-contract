// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test } from "forge-std/Test.sol";
import { MerkleVestDistributor } from "../../src/MerkleVestDistributor.sol";
import { Tokenomics } from "../../src/Tokenomics.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { MockERC20 } from "../utils/MockERC20.sol";
import { MerkleLib } from "../utils/MerkleLib.sol";

/// @notice Handler: randomly advances time and claims for one known leaf.
contract Handler is Test {
    MerkleVestDistributor public dist;
    MockERC20 public token;
    address public alice;
    uint256 public amount;
    bytes32[] internal leaves;

    constructor(MerkleVestDistributor d, MockERC20 t, address a, uint256 amt, bytes32[] memory lv) {
        dist = d;
        token = t;
        alice = a;
        amount = amt;
        leaves = lv;
    }

    function warpAndClaim(uint256 dt) external {
        dt = bound(dt, 0, 90 days);
        vm.warp(block.timestamp + dt);
        try dist.claim(0, 0, alice, amount, MerkleLib.proof(leaves, 0)) { } catch { }
    }
}

contract DistributorInvariant is Test {
    MerkleVestDistributor dist;
    MockERC20 token;
    Handler handler;
    address alice = makeAddr("alice");
    uint256 amount = 157_500_000 ether;

    function setUp() public {
        token = new MockERC20();
        bytes32[] memory leaves = new bytes32[](2);
        leaves[0] = MerkleLib.leaf(0, alice, amount);
        leaves[1] = MerkleLib.leaf(1, makeAddr("pad"), 1 ether);

        uint64 s = uint64(block.timestamp + 60);
        MerkleVestDistributor.Campaign[3] memory cs;
        cs[0] = MerkleVestDistributor.Campaign(
            MerkleLib.root(leaves),
            Tokenomics.CREATOR_UNLOCK_BPS,
            s,
            s + Tokenomics.CREATOR_VEST_SECS,
            0
        );
        cs[1] = cs[0];
        cs[2] = cs[0];

        dist =
            new MerkleVestDistributor(IERC20(address(token)), makeAddr("t"), cs, s + 999 days, address(0));
        token.mint(address(dist), 1_000_000_000 ether);

        handler = new Handler(dist, token, alice, amount, leaves);
        targetContract(address(handler));
    }

    /// @notice A recipient can NEVER receive more than their leaf allocation,
    ///         and on-chain accounting always equals tokens actually paid out.
    function invariant_neverOverDistribute() public view {
        assertLe(dist.claimed(0, 0), amount);
        assertEq(token.balanceOf(alice), dist.claimed(0, 0));
    }
}
