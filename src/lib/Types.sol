// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;
/**
 * We cannot really do block numbers per second b/c slope is per time, not per block
 * and per block could be fairly bad b/c Ethereum changes blocktimes.
 * What we can do is to extrapolate ***At functions
 */

struct Point {
    int128 bias;
    int128 slope; // dweight / dt
    uint256 ts;
    uint256 blk; // block
}

struct LockedBalance {
    int128 amount;
    uint256 end;
}
