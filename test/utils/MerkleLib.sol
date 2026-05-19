// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice Test-only Merkle helper. Produces roots/proofs that satisfy OZ
///         `MerkleProof.verify` (commutative sorted-pair hashing). Leaf format
///         matches the contract & OZ StandardMerkleTree: double-hashed
///         keccak256(bytes.concat(keccak256(abi.encode(index,account,amount)))).
/// @dev    Odd levels promote the last node (verify-compatible). The real
///         off-chain builder is the OpenZeppelin merkle-tree JS lib; this only
///         needs to be self-consistent with on-chain verification.
library MerkleLib {
    function leaf(uint256 index, address account, uint256 amount) internal pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(index, account, amount))));
    }

    function _hashPair(bytes32 a, bytes32 b) private pure returns (bytes32) {
        return a < b ? keccak256(abi.encode(a, b)) : keccak256(abi.encode(b, a));
    }

    function _nextLevel(bytes32[] memory nodes) private pure returns (bytes32[] memory up) {
        uint256 n = nodes.length;
        uint256 m = (n + 1) / 2;
        up = new bytes32[](m);
        for (uint256 i = 0; i < m; ++i) {
            uint256 l = 2 * i;
            up[i] = (l + 1 < n) ? _hashPair(nodes[l], nodes[l + 1]) : nodes[l];
        }
    }

    function root(bytes32[] memory leaves) internal pure returns (bytes32) {
        bytes32[] memory level = leaves;
        while (level.length > 1) {
            level = _nextLevel(level);
        }
        return level.length == 0 ? bytes32(0) : level[0];
    }

    function proof(bytes32[] memory leaves, uint256 idx)
        internal
        pure
        returns (bytes32[] memory pf)
    {
        // upper bound on depth
        bytes32[] memory tmp = new bytes32[](256);
        uint256 k;
        bytes32[] memory level = leaves;
        uint256 pos = idx;
        while (level.length > 1) {
            uint256 sib = pos ^ 1;
            if (sib < level.length) {
                tmp[k++] = level[sib];
            }
            pos /= 2;
            level = _nextLevel(level);
        }
        pf = new bytes32[](k);
        for (uint256 i = 0; i < k; ++i) {
            pf[i] = tmp[i];
        }
    }
}
