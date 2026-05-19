// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title LpLocker
/// @notice Holds the treasury's 50% Uniswap V3 LP position FOREVER. Principal
///         is permanently locked: there is intentionally NO decreaseLiquidity,
///         NO NFT transfer, NO owner that can move the position. ONLY `collect()`
///         routes accrued swap fees to the FeeTreasury (plan §4.4 graduation,
///         §13 item b — Clanker/Doppler "fees-only withdrawable" pattern).
///
/// @dev Immutable & non-upgradeable by construction. The other 50% of LP is
///      burned (NFT → address(0)) by the BondingCurve at graduation and is not
///      represented here. SKELETON — Uniswap V3 NonfungiblePositionManager
///      wiring is `// TODO(impl)`.
///
///      AUDIT FOCUS: prove no code path can reduce/transfer principal; the
///      ONLY external mutation is fee collection to `treasury`.
contract LpLocker {
    /// @notice Uniswap V3 NonfungiblePositionManager.
    address public immutable positionManager;
    /// @notice The locked position NFT id (the treasury 50% only).
    uint256 public immutable tokenId;
    /// @notice Sole fee recipient — the FeeTreasury (Safe-multisig owned).
    address public immutable treasury;

    event FeesCollected(uint256 amount0, uint256 amount1);

    constructor(address positionManager_, uint256 tokenId_, address treasury_) {
        positionManager = positionManager_;
        tokenId = tokenId_;
        treasury = treasury_;
    }

    /// @notice Collect accrued LP fees to the treasury. Callable by anyone
    ///         (recipient is hardcoded to `treasury`, so this is safe to leave
    ///         permissionless). Does NOT and CANNOT touch principal liquidity.
    function collectFees() external returns (uint256 amount0, uint256 amount1) {
        // TODO(impl): INonfungiblePositionManager.collect({
        //   tokenId, recipient: treasury, amount0Max: max, amount1Max: max });
        revert("TODO(impl): collect");
    }

    // NOTE: deliberately NO decreaseLiquidity / NO onERC721Received that
    // forwards / NO sweep / NO owner. Principal is unreachable by design.
}
