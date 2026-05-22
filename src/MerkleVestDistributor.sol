// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { MerkleProof } from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { Tokenomics } from "./Tokenomics.sol";
import { IGuardian } from "./Guardian.sol";

/// @title MerkleVestDistributor
/// @notice Distributes a launched token to contest participants by role
///         (creator / backers / voters) with an immediate unlock % plus a
///         linearly vesting remainder. ONE contract, THREE Merkle roots.
///
/// @dev Design hardened from industry research (plan §4.5, §13 item 6):
///  - Leaf = keccak256(bytes.concat(keccak256(abi.encode(index,account,amount))))
///    built off-chain with the OpenZeppelin merkle-tree StandardMerkleTree; verified
///    here with OZ MerkleProof (sorted-pair). Double-hash defeats the
///    second-preimage attack of the old single-hash/packed Jito/Uniswap shape.
///  - PARTIAL repeated claims → per-leaf `claimed` mapping (a bitmap is
///    insufficient for vesting).
///  - claim() is callable by ANYONE and pays the LEAF `account`. No
///    msg.sender / tx.origin / extcodesize checks — World App wallets are Safe
///    smart accounts (ERC-4337), not EOAs (plan §4.5). The proof is the sole
///    authority.
///  - CEI + SafeERC20 + ReentrancyGuard; no external callbacks in claim path.
contract MerkleVestDistributor is ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct Campaign {
        bytes32 merkleRoot;
        uint16 unlockBps; // immediate unlock at `start`, <= 10_000
        uint64 start; // vesting start
        uint64 end; // vesting end (linear between start..end)
        uint64 cliff; // optional; 0 = none. Within [start,end].
    }

    IERC20 public immutable token;
    address public immutable treasury; // Safe multisig; clawback sink
    uint64 public immutable campaignExpiry; // clawback allowed only after this
    /// @notice Optional Guardian (Workstream E2). When set, claim() reverts
    ///         while `guardian.isPaused()` returns true. address(0) means
    ///         no pause hook.
    IGuardian public immutable guardian;

    /// @dev role => Campaign (0=creator, 1=backers, 2=voters per Tokenomics).
    mapping(uint8 => Campaign) public campaigns;
    /// @dev role => leaf index => cumulative amount already transferred.
    mapping(uint8 => mapping(uint256 => uint256)) public claimed;

    event Claimed(
        uint8 indexed role, uint256 indexed index, address indexed account, uint256 amount
    );
    event ClawedBack(uint8 indexed role, uint256 amount);

    error InvalidProof();
    error NothingClaimable();
    error InvalidCampaign();
    error NotExpired();
    error ZeroAmount();
    error NotTreasury();
    /// @notice Reverted when guardian.isPaused() is true. Suite-wide pause
    ///         from the Workstream E2 risk-mitigation lever.
    error Paused();

    /// @param expiry Clawback gate; must be comfortably after the latest `end`.
    /// @param guardian_ Optional pause hook; address(0) for none.
    constructor(
        IERC20 token_,
        address treasury_,
        Campaign[3] memory init,
        uint64 expiry,
        address guardian_
    ) {
        token = token_;
        treasury = treasury_;
        campaignExpiry = expiry;
        guardian = IGuardian(guardian_);
        for (uint8 r = 0; r < 3; ++r) {
            Campaign memory c = init[r];
            if (
                c.merkleRoot == bytes32(0) || c.unlockBps > Tokenomics.BPS_DENOMINATOR
                    || c.end <= c.start || (c.cliff != 0 && (c.cliff < c.start || c.cliff > c.end))
            ) revert InvalidCampaign();
            campaigns[r] = c;
        }
        // NOTE: funding (Σ allocations of the 350M rewards pool) is transferred
        // in by the factory immediately after deploy; an off-chain/Phase-1
        // invariant test asserts balance >= total distributable.
    }

    /// @notice Claim everything currently unlocked for a leaf. Callable by anyone;
    ///         always pays `account` (the participant's Safe address).
    function claim(
        uint8 role,
        uint256 index,
        address account,
        uint256 amount,
        bytes32[] calldata proof
    ) external nonReentrant {
        if (address(guardian) != address(0) && guardian.isPaused()) revert Paused();
        if (amount == 0) revert ZeroAmount();
        Campaign memory c = campaigns[role];

        bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(index, account, amount))));
        if (!MerkleProof.verify(proof, c.merkleRoot, leaf)) revert InvalidProof();

        uint256 unlocked = _unlockedAmount(c, amount);
        uint256 already = claimed[role][index];
        if (unlocked <= already) revert NothingClaimable();

        uint256 payout = unlocked - already;
        claimed[role][index] = unlocked; // effects before interaction (CEI)
        token.safeTransfer(account, payout);
        emit Claimed(role, index, account, payout);
    }

    /// @notice Total unlocked (immediate + linearly-vested) for `total` at now.
    /// @dev `vesting = total - immediate` so rounding dust accrues into the
    ///      final bucket and the recipient eventually receives exactly `total`.
    function _unlockedAmount(Campaign memory c, uint256 total) internal view returns (uint256) {
        if (block.timestamp >= c.end) return total;
        uint256 immediate = (total * c.unlockBps) / Tokenomics.BPS_DENOMINATOR;
        if (block.timestamp <= c.start) return immediate;
        if (c.cliff != 0 && block.timestamp < c.cliff) return immediate;
        uint256 vesting = total - immediate;
        uint256 elapsed = block.timestamp - c.start;
        uint256 duration = c.end - c.start;
        return immediate + (vesting * elapsed) / duration;
    }

    /// @notice View helper for the frontend / `/api/claims`.
    function claimable(uint8 role, uint256 index, uint256 amount) external view returns (uint256) {
        uint256 u = _unlockedAmount(campaigns[role], amount);
        uint256 a = claimed[role][index];
        return u > a ? u - a : 0;
    }

    /// @notice Treasury-only reclaim of undistributed remainder, ONLY after
    ///         expiry (well past the latest vesting end). Never touches funds
    ///         already owed/claimed.
    function clawback(uint8 role, uint256 sweepAmount) external {
        if (msg.sender != treasury) revert NotTreasury();
        if (block.timestamp < campaignExpiry) revert NotExpired();
        token.safeTransfer(treasury, sweepAmount);
        emit ClawedBack(role, sweepAmount);
    }
}
