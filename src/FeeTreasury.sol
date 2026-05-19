// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title FeeTreasury
/// @notice Sink for all protocol revenue: bonding-curve trading fees, the 3%
///         graduation fee, and the collect-only LP fees from every LpLocker.
///         Owned by a Safe multisig (plan §4.4 privilege separation). The
///         automation/fee-sweeper key may only *route fees here*, never change
///         ownership or withdraw — withdrawal is multisig-gated.
///
/// @dev SKELETON. Owner is set to the Safe at deploy; replace the placeholder
///      onlyOwner with OZ Ownable2Step or AccessControl in Phase 1.
contract FeeTreasury {
    using SafeERC20 for IERC20;

    address public owner; // Safe multisig

    event Withdrawn(address indexed token, address indexed to, uint256 amount);
    event OwnerTransferred(address indexed prev, address indexed next);

    error NotOwner();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor(address safeOwner) {
        owner = safeOwner;
    }

    /// @notice Multisig-gated withdrawal of accumulated fees.
    function withdraw(IERC20 token, address to, uint256 amount) external onlyOwner {
        token.safeTransfer(to, amount);
        emit Withdrawn(address(token), to, amount);
    }

    function transferOwnership(address next) external onlyOwner {
        emit OwnerTransferred(owner, next);
        owner = next; // TODO(impl): use Ownable2Step for safety
    }

    receive() external payable {}
}
