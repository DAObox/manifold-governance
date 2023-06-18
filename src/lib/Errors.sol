// SPDX-License-Identifier: MIT
pragma solidity >=0.8.17;

library Errors {
    error TOKEN_DECIMALS_OVERFLOW(uint8 amount, uint8 max);
    error DelegationNotAllowed();
}
