// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Tokenomics} from "./Tokenomics.sol";

/// @title BondingCurve
/// @notice WLD-quoted virtual-reserve constant-product curve (pump.fun model:
///         smooth, non-zero opening price). Holds ~650M of the token; anyone
///         on World Chain can buy/sell — NO identity gating (plan §4.6).
///         At `graduationThresholdWLD` raised, atomically graduates to a
///         Uniswap V3 pool and locks LP (50% burn / 50% collect-only locker).
///
/// @dev SKELETON. Curve math, atomic graduation and the decaying anti-snipe
///      fee are `// TODO(impl)` — Phase 1, then fuzz/invariant, then audit.
///      Never read Uniswap `slot0` spot internally (use the curve's terminal
///      price / TWAP).
contract BondingCurve is ReentrancyGuard {
    using SafeERC20 for IERC20;

    IERC20  public immutable token;            // the HotshotToken
    IERC20  public immutable quote;            // WLD
    address public immutable treasury;         // FeeTreasury
    address public immutable factory;
    uint256 public immutable launchBlock;

    /// @notice Governable, WLD-denominated, NO oracle (plan §13 d). Set at
    ///         deploy from Tokenomics default; retunable by treasury multisig.
    uint256 public graduationThresholdWLD;

    uint256 public raisedWLD;
    bool    public graduated;

    event Bought(address indexed buyer, uint256 quoteIn, uint256 tokensOut, uint256 feeBps);
    event Sold(address indexed seller, uint256 tokensIn, uint256 quoteOut, uint256 feeBps);
    event Graduated(address indexed univ3Pool, uint256 raisedWLD, uint256 graduationFee);
    event ThresholdUpdated(uint256 newThresholdWLD);

    error AlreadyGraduated();
    error NotTreasury();
    error SlippageExceeded();

    constructor(IERC20 token_, IERC20 quote_, address treasury_, uint256 thresholdWLD) {
        token = token_;
        quote = quote_;
        treasury = treasury_;
        factory = msg.sender;
        launchBlock = block.number;
        graduationThresholdWLD = thresholdWLD;
    }

    /// @notice Current trading fee (bps). Decays LAUNCH→POST_HOUR over the fee
    ///         schedule, PLUS a steep first-blocks anti-snipe spike. TODO(impl).
    function currentFeeBps() public view returns (uint16) {
        // TODO(impl): max(antiSnipeDecay(launchBlock), feeSchedule(launchTime))
        return Tokenomics.LAUNCH_FEE_BPS;
    }

    /// @notice Buy tokens with WLD. Permissionless; off-app callers welcome.
    function buy(uint256 quoteIn, uint256 minTokensOut) external nonReentrant returns (uint256) {
        if (graduated) revert AlreadyGraduated();
        // TODO(impl): pull WLD; tokensOut from virtual-reserve x*y=k; take fee
        // → treasury; transfer tokens; raisedWLD += net; emit; auto-graduate
        // when raisedWLD >= graduationThresholdWLD.
        revert("TODO(impl): buy");
    }

    /// @notice Sell tokens back to the curve for WLD. Permissionless.
    function sell(uint256 tokensIn, uint256 minQuoteOut) external nonReentrant returns (uint256) {
        if (graduated) revert AlreadyGraduated();
        revert("TODO(impl): sell");
    }

    /// @notice ATOMIC: take 3% graduation fee → treasury; create+initialize the
    ///         WLD/token Uniswap V3 pool at the curve's TERMINAL price (price
    ///         continuity); seed full-range; split LP 50% burn / 50% locker —
    ///         all in ONE tx (no mempool gap to snipe). TODO(impl).
    function graduate() external nonReentrant {
        if (graduated) revert AlreadyGraduated();
        revert("TODO(impl): atomic graduate + Uniswap V3 seed + LP lock/burn");
    }

    /// @notice Treasury multisig retunes the WLD threshold (no oracle, v1).
    function setGraduationThreshold(uint256 newThresholdWLD) external {
        if (msg.sender != treasury) revert NotTreasury();
        graduationThresholdWLD = newThresholdWLD;
        emit ThresholdUpdated(newThresholdWLD);
    }
}
