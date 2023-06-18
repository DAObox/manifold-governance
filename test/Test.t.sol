// SPDX-License-Identifier: MIT
pragma solidity >=0.8.17;

import { TestBase } from "./TestBase.t.sol";
import { console } from "forge-std/console.sol";

contract VestingTest is TestBase {
    uint256 internal maxTransferAmount = 12e18;

    function setUp() public virtual override {
        TestBase.setUp();
        console.log("Vesting Test");
    }
}
