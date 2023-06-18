// SPDX-License-Identifier: AGPL-3.0-or-later

pragma solidity 0.8.17;

import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";
import { Address } from "@openzeppelin/contracts/utils/Address.sol";
import { ERC165Checker } from "@openzeppelin/contracts/utils/introspection/ERC165Checker.sol";
import { IERC20Upgradeable } from "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { IVotesUpgradeable } from "@openzeppelin/contracts-upgradeable/governance/utils/IVotesUpgradeable.sol";

import { IDAO } from "@aragon/core/dao/IDAO.sol";
import { DAO } from "@aragon/core/dao/DAO.sol";
import { PermissionLib } from "@aragon/core/permission/PermissionLib.sol";
import { GovernanceERC20 } from "@aragon/token/ERC20/governance/GovernanceERC20.sol";
import { GovernanceWrappedERC20 } from "@aragon/token/ERC20/governance/GovernanceWrappedERC20.sol";
import { IGovernanceWrappedERC20 } from "@aragon/token/ERC20/governance/IGovernanceWrappedERC20.sol";
import { MajorityVotingBase } from "@aragon/plugins/governance/majority-voting/MajorityVotingBase.sol";
import { TokenVoting } from "@aragon/plugins/governance/majority-voting/token/TokenVoting.sol";
import { PluginSetup } from "@aragon/framework/plugin/setup/PluginSetup.sol";

import { VoteEscrowToken } from "./VoteEscrowToken.sol";
import { FeeDistributor } from "./FeeDistributor.sol";

/// @title ManifoldSetup
/// @author (@pythonpete32): DAOBox - 2023
/// @notice The setup contract of the `Manifold Template`.
contract ManifoldSetup is PluginSetup {
    using Address for address;
    using Clones for address;
    using ERC165Checker for address;

    /// @notice The address of the `TokenVoting` base contract.
    TokenVoting private immutable tokenVotingBase;

    /// @notice The address of the `VoteEscrowToken` base contract.
    address public immutable voteEscrowTokenBase;

    /// @notice The address of the `FeeDistributor` base contract.
    address public immutable feeDistributorBase;

    /// @notice Thrown if token address is passed which is not a token.
    /// @param token The token address
    error TokenNotContract(address token);

    /// @notice Thrown if token address is not ERC20.
    /// @param token The token address
    error TokenNotERC20(address token);

    /// @notice Thrown if passed helpers array is of wrong length.
    /// @param length The array length of passed helpers.
    error WrongHelpersArrayLength(uint256 length);

    /// @notice The contract constructor, that deploys the bases.
    constructor() {
        tokenVotingBase = new TokenVoting();
        voteEscrowTokenBase = address(new VoteEscrowToken());
        feeDistributorBase = address(new FeeDistributor());
    }

    function prepareInstallation(
        address _dao,
        bytes calldata _data
    )
        external
        returns (address plugin, PreparedSetupData memory preparedSetupData)
    {
        (
            MajorityVotingBase.VotingSettings memory votingSettings,
            address baseToken,
            address feeToken,
            uint256 epochStartTime
        ) = abi.decode(_data, (MajorityVotingBase.VotingSettings, address, address, uint256));

        if (!_isERC20(baseToken)) {
            revert TokenNotERC20(baseToken);
        }

        if (!_isERC20(feeToken)) {
            revert TokenNotERC20(feeToken);
        }

        // Prepare helpers.
        address[] memory helpers = new address[](1);

        address veToken = voteEscrowTokenBase.clone();
        VoteEscrowToken(veToken).initialize(
            IDAO(_dao),
            baseToken,
            string(abi.encodePacked("Vote Escrow ", ERC20(baseToken).name())),
            string(abi.encodePacked("ve", ERC20(baseToken).symbol()))
        );

        address feeDistributor = feeDistributorBase.clone();
        FeeDistributor(feeDistributor).initialize(IDAO(_dao), veToken, epochStartTime, feeToken);

        helpers[0] = veToken;
        helpers[1] = feeDistributor;

        // Prepare and deploy plugin proxy.
        plugin = createERC1967Proxy(
            address(tokenVotingBase),
            abi.encodeWithSelector(TokenVoting.initialize.selector, _dao, votingSettings, veToken)
        );

        // Prepare permissions
        PermissionLib.MultiTargetPermission[] memory permissions = new PermissionLib.MultiTargetPermission[](4);

        // Set plugin permissions to be granted.
        // Grant the list of permissions of the plugin to the DAO.
        permissions[0] = PermissionLib.MultiTargetPermission(
            PermissionLib.Operation.Grant,
            plugin,
            _dao,
            PermissionLib.NO_CONDITION,
            tokenVotingBase.UPDATE_VOTING_SETTINGS_PERMISSION_ID()
        );

        permissions[1] = PermissionLib.MultiTargetPermission(
            PermissionLib.Operation.Grant,
            plugin,
            _dao,
            PermissionLib.NO_CONDITION,
            tokenVotingBase.UPGRADE_PLUGIN_PERMISSION_ID()
        );

        // Grant `EXECUTE_PERMISSION` of the DAO to the plugin.
        permissions[2] = PermissionLib.MultiTargetPermission(
            PermissionLib.Operation.Grant,
            _dao,
            plugin,
            PermissionLib.NO_CONDITION,
            DAO(payable(_dao)).EXECUTE_PERMISSION_ID()
        );

        permissions[3] = PermissionLib.MultiTargetPermission(
            PermissionLib.Operation.Grant,
            veToken,
            plugin,
            PermissionLib.NO_CONDITION,
            VoteEscrowToken(veToken).WHITELIST_PERMISSION_ID()
        );

        permissions[4] = PermissionLib.MultiTargetPermission(
            PermissionLib.Operation.Grant,
            veToken,
            plugin,
            PermissionLib.NO_CONDITION,
            VoteEscrowToken(veToken).RECOVER_PERMISSION_ID()
        );

        permissions[5] = PermissionLib.MultiTargetPermission(
            PermissionLib.Operation.Grant,
            feeDistributor,
            plugin,
            PermissionLib.NO_CONDITION,
            FeeDistributor(veToken).CHECKPOINT_PERMISSION_ID()
        );

        permissions[6] = PermissionLib.MultiTargetPermission(
            PermissionLib.Operation.Grant,
            feeDistributor,
            plugin,
            PermissionLib.NO_CONDITION,
            FeeDistributor(veToken).KILL_PERMISSION_ID()
        );

        preparedSetupData.helpers = helpers;
        preparedSetupData.permissions = permissions;
    }

    function prepareUninstallation(
        address _dao,
        SetupPayload calldata _payload
    )
        external
        view
        returns (PermissionLib.MultiTargetPermission[] memory permissions)
    {
        // Prepare permissions.
        uint256 helperLength = _payload.currentHelpers.length;
        if (helperLength != 1) {
            revert WrongHelpersArrayLength({ length: helperLength });
        }

        // token can be either GovernanceERC20, GovernanceWrappedERC20, or IVotesUpgradeable, which
        // does not follow the GovernanceERC20 and GovernanceWrappedERC20 standard.
        address token = _payload.currentHelpers[0];

        bool[] memory supportedIds = _getTokenInterfaceIds(token);

        bool isGovernanceERC20 = supportedIds[0] && supportedIds[1] && !supportedIds[2];

        permissions = new PermissionLib.MultiTargetPermission[](isGovernanceERC20 ? 4 : 3);

        // Set permissions to be Revoked.
        permissions[0] = PermissionLib.MultiTargetPermission(
            PermissionLib.Operation.Revoke,
            _payload.plugin,
            _dao,
            PermissionLib.NO_CONDITION,
            tokenVotingBase.UPDATE_VOTING_SETTINGS_PERMISSION_ID()
        );

        permissions[1] = PermissionLib.MultiTargetPermission(
            PermissionLib.Operation.Revoke,
            _payload.plugin,
            _dao,
            PermissionLib.NO_CONDITION,
            tokenVotingBase.UPGRADE_PLUGIN_PERMISSION_ID()
        );

        permissions[2] = PermissionLib.MultiTargetPermission(
            PermissionLib.Operation.Revoke,
            _dao,
            _payload.plugin,
            PermissionLib.NO_CONDITION,
            DAO(payable(_dao)).EXECUTE_PERMISSION_ID()
        );

        // Revocation of permission is necessary only if the deployed token is GovernanceERC20,
        // as GovernanceWrapped does not possess this permission. Only return the following
        // if it's type of GovernanceERC20, otherwise revoking this permission wouldn't have any effect.
        if (isGovernanceERC20) {
            permissions[3] = PermissionLib.MultiTargetPermission(
                PermissionLib.Operation.Revoke,
                token,
                _dao,
                PermissionLib.NO_CONDITION,
                GovernanceERC20(token).MINT_PERMISSION_ID()
            );
        }
    }

    function implementation() external view virtual override returns (address) {
        return address(tokenVotingBase);
    }

    /// @notice Retrieves the interface identifiers supported by the token contract.
    /// @dev It is crucial to verify if the provided token address represents a valid contract before using the below.
    /// @param token The token address
    function _getTokenInterfaceIds(address token) private view returns (bool[] memory) {
        bytes4[] memory interfaceIds = new bytes4[](3);
        interfaceIds[0] = type(IERC20Upgradeable).interfaceId;
        interfaceIds[1] = type(IVotesUpgradeable).interfaceId;
        interfaceIds[2] = type(IGovernanceWrappedERC20).interfaceId;
        return token.getSupportedInterfaces(interfaceIds);
    }

    /// @notice Unsatisfiably determines if the contract is an ERC20 token.
    /// @dev It's important to first check whether token is a contract prior to this call.
    /// @param token The token address
    function _isERC20(address token) private view returns (bool) {
        (bool success, bytes memory data) =
            token.staticcall(abi.encodeWithSelector(IERC20Upgradeable.balanceOf.selector, address(this)));
        return success && data.length == 0x20;
    }
}
