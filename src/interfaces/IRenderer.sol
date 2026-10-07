// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface IRenderer {
    function tokenURI(uint256 id) external view returns (string memory);
}
