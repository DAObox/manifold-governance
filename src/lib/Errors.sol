// SPDX-License-Identifier: MIT
pragma solidity >=0.8.17;

library Errors {
    error TOKEN_DECIMALS_OVERFLOW(uint8 amount, uint8 max);
    error DelegationNotAllowed();
    error CannotCheckpointAtThisTime(bool canCheckpointToken, uint256 timeRemaining);

    error ContractAlreadyKilled();
    error TokenTransferFailed(address recipient, uint256 value);

    error CannotWithdrawVestedToken(address tokenAddress, address token);
    error NeedNonZeroValue(uint256 value);
    error NoExistingLockFound(int128 amount);
    error CannotAddToExpiredLock(uint256 lockedEnd, uint256 currentTimestamp);
    error WithdrawOldTokensFirst(int128 amount);
    error CanOnlyLockUntilTimeInTheFuture(uint256 unlockTime, uint256 currentTimestamp);
    error VotingLockCanBe3YearsMax(uint256 unlockTime, uint256 maxTime);
    error LockExpired(uint256 lockedEnd, uint256 currentTimestamp);
    error NothingIsLocked(int128 amount);
    error CanOnlyIncreaseLockDuration(uint256 unlockTime, uint256 lockedEnd);
    error SmartContractDepositorsNotAllowed();
}
