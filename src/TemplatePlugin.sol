// SPDX-License-Identifier: MIT
pragma solidity >=0.8.17;

import { PluginCloneable, IDAO } from "@aragon/core/plugin/PluginCloneable.sol";

contract TemplatePlugin is PluginCloneable {
    // =============================================================== //
    // ========================== CONSTANTS ========================== //
    // =============================================================== //

    /// @dev The identifier of the permission that allows an address to conduct the hatch.
    bytes32 public constant SOME_PERMISSION_ID = keccak256("SOME_PERMISSION");

    // =============================================================== //
    // =========================== STROAGE =========================== //
    // =============================================================== //

    /// @notice is some state
    bool private _someFlag;

    // =============================================================== //
    // ========================= INITIALIZE ========================== //
    // =============================================================== //

    /**
     * @param dao_ The associated DAO.
     * @param flag_ The bonded token.
     */
    function initialize(IDAO dao_, bool flag_) external initializer {
        __PluginCloneable_init(dao_);
        _someFlag = flag_;
    }

    // =============================================================== //
    // ===================== GOVERNANCE FUNCTIONS ==================== //
    // =============================================================== //

    /**
     * @notice switches the flag
     * @dev Only callable by authorized accounts.
     */
    function switchFlag() external auth(SOME_PERMISSION_ID) {
        _someFlag = !_someFlag;
    }
}
