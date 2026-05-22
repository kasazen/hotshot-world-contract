// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title Guardian
/// @notice 72-hour-timelocked pause switch for the HOTSHOT contract suite
///         (Workstream E2 — unaudited-mainnet risk mitigation).
///
///         The treasury Safe multisig can `pause()` instantly in response
///         to a known bug, halting `BondingCurve.buy`/`sell` and the
///         distributor's `claim` (via the `whenNotPaused` modifier on
///         each).
///
///         Unpause is intentionally NOT instant:
///           - `requestUnpause()` starts a 72h timer
///           - `executeUnpause()` succeeds only after the timer elapses
///         This protects against a compromised guardian being used to
///         BOTH pause AND immediately unpause for cover. If the Safe is
///         compromised, defenders have 72h to respond.
///
///         A hard 7-day auto-unpause is built in: even if no one ever
///         calls `executeUnpause`, the system unpauses itself at
///         `pausedAt + 7 days`. Guardian cannot indefinitely freeze
///         user funds — at worst delays them a week.
///
/// @dev SCOPE OF PAUSE: the Guardian cannot:
///        - mutate merkle roots
///        - seize tokens
///        - affect tokens already paid out
///        - prevent post-graduation Uniswap V3 trading (curve is dead
///          post-graduation; AMM lives outside our contracts)
///      It can ONLY pause user-facing entrypoints on contracts that
///      explicitly check `guardian.isPaused()` before mutating state.
contract Guardian {
    /// @notice Treasury Safe multisig — sole privileged caller for pause / unpause.
    address public immutable SAFE;

    /// @notice 72h between requestUnpause and executeUnpause.
    uint64 public constant UNPAUSE_TIMELOCK = 72 hours;

    /// @notice Hard ceiling: pause auto-resolves 7d after `pausedAt`
    ///         regardless of any executeUnpause call.
    uint64 public constant AUTO_UNPAUSE_AFTER = 7 days;

    /// @notice Storage flag toggled by pause()/executeUnpause(). Read it
    ///         via `isPaused()` which factors in the auto-unpause window.
    bool public pausedFlag;

    /// @notice When the current pause started. 0 if never paused.
    uint64 public pausedAt;

    /// @notice When `requestUnpause` was called. 0 if no pending request.
    uint64 public unpauseRequestedAt;

    event Paused(address indexed by, uint64 at);
    event UnpauseRequested(address indexed by, uint64 at);
    event Unpaused(address indexed by, bool wasAuto);

    error NotSafe();
    error NotPaused();
    error AlreadyPaused();
    error UnpauseAlreadyRequested();
    error UnpauseNotRequested();
    error TimelockActive(uint64 secondsRemaining);

    constructor(address safe_) {
        SAFE = safe_;
    }

    /// @notice True if the suite is paused. Returns false past the auto-
    ///         unpause horizon even if `pausedFlag` storage is still true
    ///         (callers may settle storage via `settleAutoUnpause`).
    function isPaused() external view returns (bool) {
        if (!pausedFlag) return false;
        return block.timestamp < uint256(pausedAt) + AUTO_UNPAUSE_AFTER;
    }

    /// @notice Safe-multisig-only. Halts all `whenNotPaused`-gated entry
    ///         points across the suite. Idempotent revert if already paused.
    function pause() external {
        if (msg.sender != SAFE) revert NotSafe();
        if (pausedFlag) revert AlreadyPaused();
        pausedFlag = true;
        pausedAt = uint64(block.timestamp);
        unpauseRequestedAt = 0; // clear any stale request
        emit Paused(msg.sender, uint64(block.timestamp));
    }

    /// @notice Start the 72h unpause timer. Safe-multisig-only.
    function requestUnpause() external {
        if (msg.sender != SAFE) revert NotSafe();
        if (!pausedFlag) revert NotPaused();
        if (unpauseRequestedAt != 0) revert UnpauseAlreadyRequested();
        unpauseRequestedAt = uint64(block.timestamp);
        emit UnpauseRequested(msg.sender, uint64(block.timestamp));
    }

    /// @notice Lift the pause. Requires a prior requestUnpause and 72h elapsed.
    function executeUnpause() external {
        if (msg.sender != SAFE) revert NotSafe();
        if (!pausedFlag) revert NotPaused();
        if (unpauseRequestedAt == 0) revert UnpauseNotRequested();
        uint64 ready = unpauseRequestedAt + UNPAUSE_TIMELOCK;
        if (block.timestamp < ready) {
            revert TimelockActive(ready - uint64(block.timestamp));
        }
        pausedFlag = false;
        unpauseRequestedAt = 0;
        emit Unpaused(msg.sender, false);
    }

    /// @notice Permissionless: after AUTO_UNPAUSE_AFTER, anyone can settle
    ///         storage so on-chain reads of `pausedFlag` agree with
    ///         `isPaused()`. Optional — `isPaused()` already returns false
    ///         past the horizon — but cleans up so explorers don't show
    ///         a misleading paused state.
    function settleAutoUnpause() external {
        if (!pausedFlag) revert NotPaused();
        if (block.timestamp < uint256(pausedAt) + AUTO_UNPAUSE_AFTER) {
            revert TimelockActive(
                uint64(uint256(pausedAt) + AUTO_UNPAUSE_AFTER - block.timestamp)
            );
        }
        pausedFlag = false;
        unpauseRequestedAt = 0;
        emit Unpaused(msg.sender, true);
    }
}

interface IGuardian {
    function isPaused() external view returns (bool);
}
