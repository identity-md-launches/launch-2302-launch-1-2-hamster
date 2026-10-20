// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface IERC721 {
    function ownerOf(uint256 tokenId) external view returns (address);
    function supportsInterface(bytes4 interfaceId) external view returns (bool);
}
