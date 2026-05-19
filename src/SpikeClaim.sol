// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title SpikeClaim
/// @notice PHASE 0 GATING SPIKE — confirm what `msg.sender` is when a call
///         arrives via `MiniKit.sendTransaction` from the World App.
///
/// @dev The whole MerkleVestDistributor design hinges on World App wallets
///      being Safe smart accounts (ERC-4337), so `msg.sender` is the Safe, NOT
///      an EOA and NOT tx.origin (plan §4.5 — officially inferred, must be
///      empirically verified before the audit). This contract just records
///      both so the spike page can read them back.
contract SpikeClaim {
    event Ping(address indexed sender, address indexed origin, bool senderIsContract);

    mapping(address => uint256) public pings;
    address public lastSender;
    address public lastOrigin;
    bool public lastSenderWasContract;

    function ping() external {
        bool isContract = msg.sender.code.length > 0;
        lastSender = msg.sender;
        lastOrigin = tx.origin;
        lastSenderWasContract = isContract;
        pings[msg.sender] += 1;
        emit Ping(msg.sender, tx.origin, isContract);
    }
}
