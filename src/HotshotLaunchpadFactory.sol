// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {HotshotToken} from "./HotshotToken.sol";
import {BondingCurve} from "./BondingCurve.sol";
import {MerkleVestDistributor} from "./MerkleVestDistributor.sol";
import {Tokenomics} from "./Tokenomics.sol";

/// @title HotshotLaunchpadFactory
/// @notice Deploys the per-contest stack (token + curve + distributor) for one
///         winning submission and splits supply: 650M → curve, 350M →
///         distributor. Server-signer-only (the KMS automation key; plan §4.4).
///
/// @dev CREATE2 with `salt = bytes32(contestId)` makes a re-run for the same
///      contest yield the SAME addresses → the daily pipeline is idempotent and
///      safe to retry after a serverless crash. SKELETON: full wiring/funding
///      is `// TODO(impl)`.
contract HotshotLaunchpadFactory {
    using SafeERC20 for IERC20;

    IERC20  public immutable quote;     // WLD
    address public immutable treasury;  // FeeTreasury (Safe-owned)
    address public launcher;            // low-privilege automation key (KMS)

    struct LaunchParams {
        uint256 contestId;
        string  name;
        string  symbol;
        uint256 graduationThresholdWLD;     // governable (Tokenomics default)
        MerkleVestDistributor.Campaign[3] campaigns; // creator/backers/voters
        uint64  campaignExpiry;             // distributor clawback gate
    }

    event Launched(
        uint256 indexed contestId,
        address token,
        address curve,
        address distributor
    );

    error NotLauncher();

    modifier onlyLauncher() {
        if (msg.sender != launcher) revert NotLauncher();
        _;
    }

    constructor(IERC20 quote_, address treasury_, address launcher_) {
        quote = quote_;
        treasury = treasury_;
        launcher = launcher_;
    }

    /// @notice Deploy + wire + fund the per-contest stack. Idempotent via
    ///         CREATE2(salt = contestId).
    function launch(LaunchParams calldata p)
        external
        onlyLauncher
        returns (address token, address curve, address distributor)
    {
        bytes32 salt = bytes32(p.contestId);
        // TODO(impl):
        //  1. token = new HotshotToken{salt}(name, symbol, contestId, address(this))
        //  2. distributor = new MerkleVestDistributor{salt}(token, treasury,
        //       p.campaigns, p.campaignExpiry)
        //  3. curve = new BondingCurve{salt}(token, quote, treasury,
        //       p.graduationThresholdWLD)
        //  4. transfer 650M → curve, 350M → distributor (assert exact split)
        //  5. emit Launched(...)
        revert("TODO(impl): launch");
    }

    /// @notice Safe-multisig (treasury) may rotate the automation key.
    function setLauncher(address next) external {
        if (msg.sender != treasury) revert NotLauncher();
        launcher = next;
    }
}
