// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Swarmlings} from "src/Swarmlings.sol";

/// @dev Local integration fixture, not a claim to reproduce the unpublished launch
/// distributor. Leaves bind (index, account, amount); pairs are sorted by hash.
contract SwarmMerkleFixture {
    Swarmlings public immutable token;
    bytes32 public immutable root;
    mapping(uint256 => bool) public claimed;

    error AlreadyClaimed();
    error InvalidProof();

    constructor(Swarmlings token_, bytes32 root_) {
        token = token_;
        root = root_;
    }

    function claim(uint256 index, address account, uint256 amount, bytes32[] calldata proof) external {
        if (claimed[index]) revert AlreadyClaimed();
        bytes32 hash = keccak256(abi.encode(index, account, amount));
        for (uint256 i; i < proof.length; ++i) {
            hash = hash < proof[i]
                ? keccak256(abi.encodePacked(hash, proof[i]))
                : keccak256(abi.encodePacked(proof[i], hash));
        }
        if (hash != root) revert InvalidProof();
        claimed[index] = true;
        require(token.transfer(account, amount));
    }
}
