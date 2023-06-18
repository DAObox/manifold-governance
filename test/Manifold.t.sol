// SPDX-License-Identifier: MIT
pragma solidity >=0.8.17;

import { ManifoldBase } from "./ManifoldBase.sol";
import { console } from "forge-std/console.sol";

contract VestingTest is ManifoldBase {
    uint256 internal maxTransferAmount = 12e18;

    function setUp() public virtual override {
        ManifoldBase.setUp();
        console.log("Vesting Test");
    }
}
