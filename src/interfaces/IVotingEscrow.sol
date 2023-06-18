// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

interface IVotingEscrow {
    function user_point_epoch(address) external view returns (uint256);
    function epoch() external view returns (uint256);
    function user_point_history(address, uint256) external view returns (int128, int128, uint256, uint256);
    function point_history(uint256) external view returns (int128, int128, uint256, uint256);
    function checkpoint() external;
}
