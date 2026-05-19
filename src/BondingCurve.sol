// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { Tokenomics } from "./Tokenomics.sol";
import { INonfungiblePositionManager } from "./interfaces/IUniswapV3.sol";
import { LpLocker } from "./LpLocker.sol";

/// @title BondingCurve
/// @notice WLD-quoted constant-product curve with a VIRTUAL quote reserve
///         (pump.fun model → non-zero opening price, smooth path). Anyone on
///         World Chain can buy/sell; NO identity gating (plan §4.6). At
///         `graduationThresholdWLD` raised it atomically graduates to a
///         Uniswap V3 pool and splits LP 50% burn / 50% collect-only locker.
///
/// @dev Curve & fee math is implemented and unit/fuzz-tested. The Uniswap V3
///      seeding (`_sqrtPriceX96`, tick range, two-position split) is AUDIT-
///      CRITICAL and must additionally be fork-tested against real Uniswap V3
///      on World Chain before mainnet — tests here use a mock NPM and validate
///      orchestration/accounting/LP-split/state only, not AMM price exactness.
contract BondingCurve is ReentrancyGuard {
    using SafeERC20 for IERC20;

    IERC20 public immutable token;
    IERC20 public immutable quote; // WLD
    address public immutable treasury;
    address public immutable factory;
    INonfungiblePositionManager public immutable npm;
    uint24 public constant POOL_FEE = 10_000; // 1% tier
    int24 internal constant FULL_RANGE_TICK = 887_200; // multiple of spacing(200)
    address internal constant BURN = 0x000000000000000000000000000000000000dEaD;

    uint256 public immutable launchBlock;
    uint256 public immutable launchTime;
    uint256 public immutable virtualQuoteReserve; // R_q0
    uint256 public immutable k; // R_q0 * curveTokenSupply (invariant constant)

    uint256 public graduationThresholdWLD;
    uint256 public tokenReserve; // curve token side (real, decreasing on buys)
    uint256 public raisedWLD; // net WLD accumulated on the curve
    bool public graduated;

    uint16 internal constant ANTI_SNIPE_START_BPS = 9000;
    uint256 internal constant ANTI_SNIPE_BLOCKS = 15; // ~30s at 2s blocks
    uint256 internal constant FEE_WINDOW = 1 hours;

    event Bought(address indexed buyer, uint256 quoteIn, uint256 tokensOut, uint16 feeBps);
    event Sold(address indexed seller, uint256 tokensIn, uint256 quoteOut, uint16 feeBps);
    event Graduated(address indexed pool, uint256 liqQuote, uint256 liqToken, address locker);
    event ThresholdUpdated(uint256 newThresholdWLD);

    error AlreadyGraduated();
    error NotTreasury();
    error SlippageExceeded();
    error ZeroAmount();

    constructor(
        IERC20 token_,
        IERC20 quote_,
        address treasury_,
        INonfungiblePositionManager npm_,
        uint256 curveTokenSupply, // 650M * 1e18
        uint256 virtualQuoteReserve_,
        uint256 thresholdWLD
    ) {
        token = token_;
        quote = quote_;
        treasury = treasury_;
        factory = msg.sender;
        npm = npm_;
        launchBlock = block.number;
        launchTime = block.timestamp;
        virtualQuoteReserve = virtualQuoteReserve_;
        tokenReserve = curveTokenSupply;
        k = virtualQuoteReserve_ * curveTokenSupply;
        graduationThresholdWLD = thresholdWLD;
    }

    // ───────────────────────── pricing ─────────────────────────

    function _quoteReserve() internal view returns (uint256) {
        return virtualQuoteReserve + raisedWLD;
    }

    function scheduleFeeBps() public view returns (uint16) {
        uint256 t = block.timestamp - launchTime;
        if (t >= FEE_WINDOW) return Tokenomics.POST_HOUR_FEE_BPS;
        uint256 step = (t * Tokenomics.FEE_DECAY_PERIODS) / FEE_WINDOW; // 0..9
        uint256 drop = (uint256(Tokenomics.LAUNCH_FEE_BPS - Tokenomics.POST_HOUR_FEE_BPS) * step)
            / Tokenomics.FEE_DECAY_PERIODS;
        return uint16(Tokenomics.LAUNCH_FEE_BPS - drop);
    }

    function antiSnipeFeeBps() public view returns (uint16) {
        uint256 b = block.number - launchBlock;
        if (b >= ANTI_SNIPE_BLOCKS) return 0;
        uint256 drop =
            (uint256(ANTI_SNIPE_START_BPS - Tokenomics.LAUNCH_FEE_BPS) * b) / ANTI_SNIPE_BLOCKS;
        return uint16(ANTI_SNIPE_START_BPS - drop);
    }

    /// @notice Active trading fee — the higher of the decaying schedule and the
    ///         first-blocks anti-snipe spike.
    function currentFeeBps() public view returns (uint16) {
        uint16 s = scheduleFeeBps();
        uint16 a = antiSnipeFeeBps();
        return a > s ? a : s;
    }

    /// @notice Tokens out for a gross WLD input (after fee), at current state.
    function quoteBuy(uint256 quoteIn) public view returns (uint256 tokensOut, uint16 feeBps) {
        feeBps = currentFeeBps();
        uint256 net = quoteIn - (quoteIn * feeBps) / Tokenomics.BPS_DENOMINATOR;
        uint256 newTokenR = k / (_quoteReserve() + net);
        tokensOut = tokenReserve - newTokenR;
    }

    // ───────────────────────── trading ─────────────────────────

    function buy(uint256 quoteIn, uint256 minTokensOut)
        external
        nonReentrant
        returns (uint256 tokensOut)
    {
        if (graduated) revert AlreadyGraduated();
        if (quoteIn == 0) revert ZeroAmount();

        uint16 feeBps = currentFeeBps();
        uint256 fee = (quoteIn * feeBps) / Tokenomics.BPS_DENOMINATOR;
        uint256 net = quoteIn - fee;

        uint256 newQuoteR = _quoteReserve() + net;
        uint256 newTokenR = k / newQuoteR;
        tokensOut = tokenReserve - newTokenR;
        if (tokensOut < minTokensOut) revert SlippageExceeded();

        tokenReserve = newTokenR; // effects (CEI)
        raisedWLD += net;

        quote.safeTransferFrom(msg.sender, address(this), quoteIn);
        quote.safeTransfer(treasury, fee);
        token.safeTransfer(msg.sender, tokensOut);
        emit Bought(msg.sender, quoteIn, tokensOut, feeBps);

        if (raisedWLD >= graduationThresholdWLD) _graduate();
    }

    function sell(uint256 tokensIn, uint256 minQuoteOut)
        external
        nonReentrant
        returns (uint256 quoteOut)
    {
        if (graduated) revert AlreadyGraduated();
        if (tokensIn == 0) revert ZeroAmount();

        uint256 newTokenR = tokenReserve + tokensIn;
        uint256 grossOut = _quoteReserve() - (k / newTokenR);
        uint16 feeBps = currentFeeBps();
        uint256 fee = (grossOut * feeBps) / Tokenomics.BPS_DENOMINATOR;
        quoteOut = grossOut - fee;
        if (quoteOut < minQuoteOut) revert SlippageExceeded();

        tokenReserve = newTokenR; // effects (CEI)
        raisedWLD -= grossOut;

        token.safeTransferFrom(msg.sender, address(this), tokensIn);
        quote.safeTransfer(treasury, fee);
        quote.safeTransfer(msg.sender, quoteOut);
        emit Sold(msg.sender, tokensIn, quoteOut, feeBps);
    }

    // ─────────────────────── graduation ───────────────────────

    /// @notice Atomic: 3% graduation fee → treasury; create+seed Uniswap V3 at
    ///         the curve's terminal price; split LP 50% burn / 50% locker.
    function _graduate() internal {
        graduated = true; // one-shot guard

        uint256 gradFee = (raisedWLD * Tokenomics.GRADUATION_FEE_BPS) / Tokenomics.BPS_DENOMINATOR;
        quote.safeTransfer(treasury, gradFee);

        uint256 liqQuote = quote.balanceOf(address(this));
        uint256 liqToken = token.balanceOf(address(this));

        (address t0, address t1, uint256 a0, uint256 a1) = address(token) < address(quote)
            ? (address(token), address(quote), liqToken, liqQuote)
            : (address(quote), address(token), liqQuote, liqToken);

        uint160 sp = _sqrtPriceX96(a0, a1);
        address pool = npm.createAndInitializePoolIfNecessary(t0, t1, POOL_FEE, sp);

        IERC20(t0).forceApprove(address(npm), a0);
        IERC20(t1).forceApprove(address(npm), a1);

        // Two equal positions → 50% burned (permanent floor), 50% locked
        // (collect-only). V3 has no native NFT split, so mint twice.
        (uint256 idBurn,,,) = _mintHalf(t0, t1, a0 / 2, a1 / 2);
        (uint256 idKeep,,,) = _mintHalf(t0, t1, a0 - a0 / 2, a1 - a1 / 2);

        npm.safeTransferFrom(address(this), BURN, idBurn);
        LpLocker locker = new LpLocker(address(npm), idKeep, treasury);
        npm.safeTransferFrom(address(this), address(locker), idKeep);

        emit Graduated(pool, liqQuote, liqToken, address(locker));
    }

    function _mintHalf(address t0, address t1, uint256 a0, uint256 a1)
        internal
        returns (uint256 id, uint128 liq, uint256 used0, uint256 used1)
    {
        return npm.mint(
            INonfungiblePositionManager.MintParams({
                token0: t0,
                token1: t1,
                fee: POOL_FEE,
                tickLower: -FULL_RANGE_TICK,
                tickUpper: FULL_RANGE_TICK,
                amount0Desired: a0,
                amount1Desired: a1,
                amount0Min: 0, // atomic, no public mempool gap (plan §4.4)
                amount1Min: 0,
                recipient: address(this),
                deadline: block.timestamp
            })
        );
    }

    /// @dev sqrtPriceX96 = sqrt(amount1/amount0) * 2^96.
    ///      AUDIT-CRITICAL: validate precision/overflow & fork-test vs real
    ///      Uniswap before mainnet. Uses OZ Math.sqrt + mulDiv.
    function _sqrtPriceX96(uint256 amount0, uint256 amount1) internal pure returns (uint160) {
        if (amount0 == 0) return 0;
        // ratioX192 = amount1 * 2^192 / amount0 ; sqrt → X96
        uint256 ratioX192 = Math.mulDiv(amount1, 1 << 192, amount0);
        return uint160(Math.sqrt(ratioX192));
    }

    /// @notice Manual graduation trigger (e.g. threshold reached but no further
    ///         trade). Permissionless — graduation is deterministic & atomic.
    function graduate() external nonReentrant {
        if (graduated) revert AlreadyGraduated();
        require(raisedWLD >= graduationThresholdWLD, "threshold");
        _graduate();
    }

    /// @notice Treasury multisig retunes the WLD threshold (no oracle, v1).
    function setGraduationThreshold(uint256 newThresholdWLD) external {
        if (msg.sender != treasury) revert NotTreasury();
        graduationThresholdWLD = newThresholdWLD;
        emit ThresholdUpdated(newThresholdWLD);
    }
}
