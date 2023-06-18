// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

library Events {
    event AddAuthorization(address account);
    event RemoveAuthorization(address account);
    event Recovered(address token, uint256 amount);
    event CommitOwnership(address admin);
    event ApplyOwnership(address admin);
    event Deposit(address indexed provider, uint256 value, uint256 indexed locktime, int128 _type, uint256 ts);
    event Withdraw(address indexed provider, uint256 value, uint256 ts);
    event Supply(uint256 prevSupply, uint256 supply);

    event ToggleAllowCheckpointToken(bool toggle_flag);
    event CheckpointToken(uint256 time, uint256 tokens);
    event Claimed(address indexed recipient, uint256 amount, uint256 claim_epoch, uint256 max_epoch);
}
