// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { INonfungiblePositionManager } from "./interfaces/IUniswapV3.sol";

/// @title LpLocker
/// @notice Holds the treasury's 50% Uniswap V3 LP position FOREVER. Principal
///         is permanently locked: there is intentionally NO decreaseLiquidity,
///         NO NFT transfer-out, NO owner. ONLY `collectFees()` routes accrued
///         swap fees to the FeeTreasury (plan §4.4 / §13 b — Clanker/Doppler
///         "fees-only withdrawable" pattern).
///
/// @dev Immutable & non-upgradeable. The other 50% of LP is burned by the
///      BondingCurve at graduation and is not represented here.
///      AUDIT FOCUS: prove NO path can reduce/transfer principal; the only
///      external mutation is fee collection to `treasury`.
contract LpLocker {
    INonfungiblePositionManager public immutable positionManager;
    uint256 public immutable tokenId;
    address public immutable treasury; // sole, hardcoded fee recipient

    event FeesCollected(uint256 amount0, uint256 amount1);

    error UnexpectedToken();

    constructor(address positionManager_, uint256 tokenId_, address treasury_) {
        positionManager = INonfungiblePositionManager(positionManager_);
        tokenId = tokenId_;
        treasury = treasury_;
    }

    /// @notice Accept exactly the configured position NFT from the position
    ///         manager; reject anything else so no stray NFT can be parked here.
    function onERC721Received(address, address, uint256 id, bytes calldata)
        external
        view
        returns (bytes4)
    {
        if (msg.sender != address(positionManager) || id != tokenId) {
            revert UnexpectedToken();
        }
        return this.onERC721Received.selector;
    }

    /// @notice Collect accrued LP fees to the treasury. Permissionless: the
    ///         recipient is hardcoded to `treasury`, and this CANNOT touch
    ///         principal liquidity (no decreaseLiquidity is ever called).
    function collectFees() external returns (uint256 amount0, uint256 amount1) {
        (amount0, amount1) = positionManager.collect(
            INonfungiblePositionManager.CollectParams({
                tokenId: tokenId,
                recipient: treasury,
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max
            })
        );
        emit FeesCollected(amount0, amount1);
    }

    // NOTE: deliberately NO decreaseLiquidity / NO sweep / NO owner / NO way to
    // transfer `tokenId` out. Principal is unreachable by design.
}
