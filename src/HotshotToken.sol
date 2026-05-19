// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Tokenomics} from "./Tokenomics.sol";

/// @title HotshotToken
/// @notice Per-contest winner token. Fixed 1B / 18-dec supply, minted ONCE at
///         construction to the launchpad, then immutable: no mint, no owner,
///         no upgrade, no pause, no identity gating. Freely tradable by anyone
///         on World Chain (plan §4.6 — product-locked).
contract HotshotToken is ERC20 {
    uint256 public immutable contestId;

    /// @param to        Launchpad/factory; receives the entire supply for splitting
    ///                   (650M → BondingCurve, 350M → MerkleVestDistributor).
    constructor(string memory name_, string memory symbol_, uint256 contestId_, address to)
        ERC20(name_, symbol_)
    {
        contestId = contestId_;
        _mint(to, Tokenomics.TOTAL_SUPPLY * (10 ** decimals()));
    }

    /// @dev Tokenomics.TOKEN_DECIMALS (18) — explicit for clarity.
    function decimals() public pure override returns (uint8) {
        return Tokenomics.TOKEN_DECIMALS;
    }
}
