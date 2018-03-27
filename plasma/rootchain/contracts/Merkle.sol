pragma solidity ^0.4.19;

/**
 * @title Merkle
 * @dev Checks that a particular leaf node is in a Merkle tree given the index, root hash, and a proof
 */

library Merkle {

    /**
     * @dev Checks that a leaf node is in a given Merkle tree
     * @param leaf Hash of the leaf node to check
     * @param index Index of the leaf node in the tree
     * @param rootHash Root hash of the Merkle tree
     * @param proof A Merkle proof showing the leaf is in the tree
     * @return true if the leaf is in the tree, false otherwise
     */
    function checkMembership(bytes32 leaf, uint256 index, bytes32 rootHash, bytes proof)
        internal
        pure
        returns (bool)
    {
        require(proof.length == 512);

        bytes32 proofElement;
        bytes32 computedHash = leaf;
        uint256 j = index;

        for (uint256 i = 32; i <= 512; i += 32) {
            assembly {
                proofElement := mload(add(proof, i))
            }
            if (j % 2 == 0) {
                computedHash = keccak256(computedHash, proofElement);
            } else {
                computedHash = keccak256(proofElement, computedHash);
            }
            j = j / 2;
        }
        return computedHash == rootHash;
    }
}
