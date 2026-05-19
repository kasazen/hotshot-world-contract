// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title Tokenomics
/// @notice Single source of truth for HOTSHOT World economics. Mirrors
///         `packages/tokenomics/src/index.ts` — keep the two in sync.
/// @dev    Whole-token figures are human units; multiply by 10**TOKEN_DECIMALS
///         for base units. Ported from the Solana reference (TOKENOMICS-v2.md);
///         only the quote asset (→ WLD) and graduation threshold differ.
library Tokenomics {
    uint8 internal constant TOKEN_DECIMALS = 18;
    uint256 internal constant TOTAL_SUPPLY = 1_000_000_000;

    uint256 internal constant CURVE_ALLOCATION = 650_000_000;
    uint256 internal constant REWARDS_POOL_TOTAL = 350_000_000;

    uint256 internal constant CREATOR_ALLOCATION = 157_500_000;
    uint256 internal constant BACKERS_ALLOCATION = 122_500_000;
    uint256 internal constant VOTERS_ALLOCATION = 70_000_000;

    uint16 internal constant CREATOR_UNLOCK_BPS = 1500;
    uint16 internal constant BACKERS_UNLOCK_BPS = 3000;
    uint16 internal constant VOTERS_UNLOCK_BPS = 6000;

    uint64 internal constant CREATOR_VEST_SECS = 60 days;
    uint64 internal constant BACKERS_VEST_SECS = 21 days;
    uint64 internal constant VOTERS_VEST_SECS = 7 days;

    uint16 internal constant LAUNCH_FEE_BPS = 1000; // 10% at open
    uint16 internal constant POST_HOUR_FEE_BPS = 300; // 3% after 1h
    uint16 internal constant FEE_DECAY_PERIODS = 10;
    uint16 internal constant GRADUATION_FEE_BPS = 300; // 3% of raised WLD

    // LP at graduation: 50% burned (permanent floor) / 50% collect-only locker.
    uint16 internal constant LP_BURN_BPS = 5000;
    uint16 internal constant LP_TREASURY_BPS = 5000;

    // Governable default; WLD-denominated, no oracle in v1 (plan §13 d).
    uint256 internal constant GRADUATION_THRESHOLD_WLD_DEFAULT = 50_000;

    uint16 internal constant BPS_DENOMINATOR = 10_000;

    /// @dev Roles for the MerkleVestDistributor campaigns.
    uint8 internal constant ROLE_CREATOR = 0;
    uint8 internal constant ROLE_BACKERS = 1;
    uint8 internal constant ROLE_VOTERS = 2;
}
