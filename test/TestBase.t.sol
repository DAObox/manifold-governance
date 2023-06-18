// SPDX-License-Identifier: MIT
pragma solidity >=0.8.17;

import { console } from "forge-std/console.sol";
import { stdStorage, StdStorage, Test } from "forge-std/Test.sol";

import { Utils } from "./utils/Utils.sol";

contract TestBase is Test {
    Utils internal utils;
    address payable[] internal users;
    address internal dao;

    function setUp() public virtual {
        utils = new Utils();
        users = utils.createUsers(3);

        dao = users[0];
        vm.label(dao, "DAO");
    }

    function createFork(string memory network, uint256 blockNumber) public {
        // Silently pass this test if there is no API key.
        string memory alchemyApiKey = vm.envOr("API_KEY_ALCHEMY", string(""));
        if (bytes(alchemyApiKey).length == 0) {
            return;
        }
        // Otherwise, run the test against the mainnet fork.
        vm.createSelectFork({ urlOrAlias: network, blockNumber: blockNumber });
        console.log("Curent Block: ", blockNumber);
    }
}
