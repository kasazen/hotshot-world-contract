// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Ownable2Step, Ownable } from "@openzeppelin/contracts/access/Ownable2Step.sol";

/// @title FeeTreasury
/// @notice Sink for all protocol revenue: bonding-curve trading fees, the 3%
///         graduation fee, and collect-only LP fees from every LpLocker.
///         Owned by a Safe multisig (plan §4.4 privilege separation):
///         withdrawals are multisig-gated; the automation/sweeper key can only
///         *route fees here* (it never owns this contract). Ownership transfer
///         is two-step to prevent handing control to a wrong/dead address.
contract FeeTreasury is Ownable2Step {
    using SafeERC20 for IERC20;

    event Withdrawn(address indexed token, address indexed to, uint256 amount);
    event NativeWithdrawn(address indexed to, uint256 amount);

    constructor(address safeOwner) Ownable(safeOwner) { }

    /// @notice Multisig-gated withdrawal of accumulated ERC-20 fees.
    function withdraw(IERC20 token, address to, uint256 amount) external onlyOwner {
        token.safeTransfer(to, amount);
        emit Withdrawn(address(token), to, amount);
    }

    function withdrawNative(address to, uint256 amount) external onlyOwner {
        (bool ok,) = to.call{ value: amount }("");
        require(ok, "native xfer failed");
        emit NativeWithdrawn(to, amount);
    }

    receive() external payable { }
}
