// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { HotshotToken } from "./HotshotToken.sol";
import { BondingCurve } from "./BondingCurve.sol";
import { MerkleVestDistributor } from "./MerkleVestDistributor.sol";
import { INonfungiblePositionManager } from "./interfaces/IUniswapV3.sol";
import { Tokenomics } from "./Tokenomics.sol";

/// @title HotshotLaunchpadFactory
/// @notice Deploys the per-contest stack (token + curve + distributor) for one
///         winning submission and splits supply: 650M → curve, 350M →
///         distributor. Server-signer-only (the low-privilege KMS automation
///         key; plan §4.4). Treasury (Safe multisig) can rotate the key.
///
/// @dev CREATE2 salt = `keccak256(abi.encode(launcher, contestId))` —
///      includes the launcher key in the salt so an attacker who knows the
///      next contestId can't pre-deploy code at the predicted address and
///      DoS the launch (Virtuals Protocol Code4rena Apr-2025 attack class).
///      Duplicate launches for the same (launcher, contestId) still REVERT
///      via CREATE2 collision, preserving idempotency for the daily pipeline.
contract HotshotLaunchpadFactory {
    using SafeERC20 for IERC20;

    IERC20 public immutable quote; // WLD
    address public immutable treasury; // FeeTreasury (Safe-owned)
    INonfungiblePositionManager public immutable npm;
    address public launcher; // low-privilege automation key (KMS)
    /// @notice Suite-wide Guardian (Workstream E2). Wired into every
    ///         BondingCurve + Distributor this factory deploys. address(0)
    ///         is acceptable for testnet — disables the pause hook.
    address public immutable guardian;

    struct LaunchParams {
        uint256 contestId;
        string name;
        string symbol;
        uint256 virtualQuoteReserve; // curve R_q0
        uint256 graduationThresholdWLD; // governable (Tokenomics default)
        MerkleVestDistributor.Campaign[3] campaigns; // creator/backers/voters
        uint64 campaignExpiry; // distributor clawback gate
        /// @notice Per-tx WLD cap on the curve's buy(). 0 = unlimited.
        ///         Workstream E1: set low (e.g. 100 WLD) for the first
        ///         5 launches to cap flash-loan single-tx graduation.
        uint256 maxBuyPerTx;
        /// @notice HTTPS or ipfs:// URL of the launch metadata JSON.
        ///         Workstream B: bound to the token immutably.
        string metadataURI;
        /// @notice keccak256 of sorted EIP-712 payload hashes of all
        ///         signed votes for this contest. Workstream G — binds
        ///         the on-chain launch to the off-chain vote set so
        ///         anyone can verify roots were derived honestly.
        bytes32 voteTallyHash;
    }

    /// @notice Rich launch event. metadataURI + voteTallyHash give
    ///         block-explorers + indexers everything needed to render
    ///         and verify a launch without re-deriving off-chain state.
    event Launched(
        uint256 indexed contestId,
        address token,
        address curve,
        address distributor,
        string metadataURI,
        bytes32 voteTallyHash
    );

    error NotLauncher();
    error NotTreasury();
    error SplitMismatch();
    /// @notice setLauncher refuses to rotate the launcher to the zero
    ///         address — that would brick the launch pipeline (no future
    ///         launch could be signed). Use a real Privy wallet address.
    error ZeroLauncher();

    constructor(
        IERC20 quote_,
        address treasury_,
        INonfungiblePositionManager npm_,
        address launcher_,
        address guardian_ // 0 = no suite-wide pause hook
    ) {
        quote = quote_;
        treasury = treasury_;
        npm = npm_;
        launcher = launcher_;
        guardian = guardian_;
    }

    function launch(LaunchParams calldata p)
        external
        returns (address token, address curve, address distributor)
    {
        if (msg.sender != launcher) revert NotLauncher();
        // Salt includes launcher key to prevent external squatting of the
        // predicted CREATE2 address. The contestId alone is publicly
        // predictable; mixing in `launcher` raises the bar to "must also
        // know/control the current launcher key" which is itself rotated by
        // treasury Safe.
        bytes32 salt = keccak256(abi.encode(launcher, p.contestId));

        uint256 unit = 10 ** Tokenomics.TOKEN_DECIMALS;
        uint256 curveAmt = Tokenomics.CURVE_ALLOCATION * unit;
        uint256 rewardsAmt = Tokenomics.REWARDS_POOL_TOTAL * unit;

        // 1. token — mints full fixed supply to this factory for splitting.
        //    metadataURI is set immutably so the off-chain photo + vote
        //    commitments are forever bound to the token contract.
        HotshotToken t = new HotshotToken{ salt: salt }(
            p.name, p.symbol, p.contestId, p.metadataURI, address(this)
        );
        token = address(t);

        // 2. distributor (3 roles, double-hashed leaves, pay-to-leaf, Guardian-gated)
        MerkleVestDistributor d = new MerkleVestDistributor{ salt: salt }(
            IERC20(token), treasury, p.campaigns, p.campaignExpiry, guardian
        );
        distributor = address(d);

        // 3. curve (virtual-reserve, WLD-quoted, atomic graduation, Guardian-gated, capped buy)
        BondingCurve c = new BondingCurve{ salt: salt }(
            IERC20(token),
            quote,
            treasury,
            npm,
            curveAmt,
            p.virtualQuoteReserve,
            p.graduationThresholdWLD,
            guardian,
            p.maxBuyPerTx
        );
        curve = address(c);

        // 4. exact supply split: 650M → curve, 350M → distributor, 0 left.
        //    SafeERC20.safeTransfer checks the return value — OZ ERC20
        //    always returns true so this is belt-and-suspenders against a
        //    future token swap (Workstream D Solady ERC20 etc.).
        IERC20(token).safeTransfer(curve, curveAmt);
        IERC20(token).safeTransfer(distributor, rewardsAmt);
        if (IERC20(token).balanceOf(address(this)) != 0) revert SplitMismatch();

        emit Launched(p.contestId, token, curve, distributor, p.metadataURI, p.voteTallyHash);
    }

    /// @notice Safe-multisig (treasury) may rotate the automation key.
    ///         Refuses address(0) to prevent accidentally bricking the
    ///         launch pipeline.
    function setLauncher(address next) external {
        if (msg.sender != treasury) revert NotTreasury();
        if (next == address(0)) revert ZeroLauncher();
        launcher = next;
    }
}
