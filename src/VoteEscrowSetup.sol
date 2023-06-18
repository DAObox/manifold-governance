// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity 0.8.17;

import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";
import { DAO, IDAO } from "@aragon/core/dao/DAO.sol";
import { PermissionLib } from "@aragon/core/permission/PermissionLib.sol";
import { PluginSetup, IPluginSetup } from "@aragon/framework/plugin/setup/PluginSetup.sol";
import { VoteEscrowToken } from "./VoteEscrowToken.sol";

contract VoteEscrowSetup is PluginSetup {
    using Clones for address;

    /// @notice The address of `Plugin` plugin logic contract to be cloned.
    address private immutable PluginImplementation;

    /// @notice Thrown if the admin address is zero.
    /// @param admin The admin address.
    error AdminAddressInvalid(address admin);

    /// @notice The constructor setting the `Admin` implementation contract to clone from.
    constructor() {
        PluginImplementation = address(new VoteEscrowToken());
    }

    /// @inheritdoc IPluginSetup
    function prepareInstallation(
        address _dao,
        bytes calldata _data
    )
        external
        returns (address plugin, PreparedSetupData memory preparedSetupData)
    {
        // Decode `_data` to extract the params needed for cloning and initializing the `Admin` plugin.
        (address whitelister, address recoverer, address tokenAddress, string memory name, string memory symbol) =
            abi.decode(_data, (address, address, address, string, string));

        // Clone plugin contract.
        plugin = PluginImplementation.clone();

        // Initialize cloned plugin contract.
        VoteEscrowToken(plugin).initialize(IDAO(_dao), tokenAddress, name, symbol);

        // Prepare permissions
        uint256 numOfPermissions = (whitelister != address(0) && recoverer != address(0))
            ? 2
            : ((whitelister != address(0) || recoverer != address(0)) ? 1 : 0);

        PermissionLib.MultiTargetPermission[] memory permissions =
            new PermissionLib.MultiTargetPermission[](numOfPermissions);

        uint256 index = 0;

        if (whitelister != address(0)) {
            // Grant the `WHITELIST_PERMISSION` on the plugin to the whitelister.
            permissions[++index] = PermissionLib.MultiTargetPermission({
                operation: PermissionLib.Operation.Grant,
                where: plugin,
                who: whitelister,
                condition: PermissionLib.NO_CONDITION,
                permissionId: VoteEscrowToken(plugin).WHITELIST_PERMISSION_ID()
            });
        }

        if (recoverer != address(0)) {
            // Grant the `RECOVER_PERMISSION` on the plugin to the recoverer.
            permissions[++index] = PermissionLib.MultiTargetPermission({
                operation: PermissionLib.Operation.Grant,
                where: plugin,
                who: recoverer,
                condition: PermissionLib.NO_CONDITION,
                permissionId: VoteEscrowToken(plugin).RECOVER_PERMISSION_ID()
            });
        }

        preparedSetupData.permissions = permissions;
    }

    /// @inheritdoc IPluginSetup
    function prepareUninstallation(
        address _dao,
        SetupPayload calldata _payload
    )
        external
        view
        returns (PermissionLib.MultiTargetPermission[] memory permissions)
    {
        // Prepare permissions
        permissions = new PermissionLib.MultiTargetPermission[](0);
    }

    /// @inheritdoc IPluginSetup
    function implementation() external view returns (address) {
        return PluginImplementation;
    }
}
