// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.17 <0.9.0;

import { console2 } from "forge-std/console2.sol";
import { Vm } from "forge-std/Vm.sol";
import { Helpers } from "./utils/Helpers.sol";

import { TokenVoting } from "@aragon/plugins/governance/majority-voting/token/TokenVoting.sol";
import { MajorityVotingBase } from "@aragon/plugins/governance/majority-voting/MajorityVotingBase.sol";
import { PluginRepoFactory } from "@aragon/framework/plugin/repo/PluginRepoFactory.sol";
import { DAOFactory } from "@aragon/framework/dao/DAOFactory.sol";
import { PluginRepo } from "@aragon/framework/plugin/repo/PluginRepoFactory.sol";
import { DAO } from "@aragon/core/dao/DAO.sol";
import { PluginSetupRef } from "@aragon/framework/plugin/setup/PluginSetupProcessorHelpers.sol";

import { ManifoldSetup } from "../src/ManifoldSetup.sol";
import { MockToken } from "./mocks/MockToken.sol";
import { VoteEscrowToken } from "../src/VoteEscrowToken.sol";
import { FeeDistributor } from "../src/FeeDistributor.sol";

// NOTE: This should be run against a fork of mainnet
contract ManifoldBase is Helpers {
    // Constants
    uint32 internal RATIO = 10 ** 4;
    uint64 internal ONE_DAY = 86_400;
    bytes internal EMPTY_BYTES = "";
    uint256 internal TOKEN = 10 ** 18;

    // Agents
    address internal deployer;
    address internal alice;
    address internal bob;

    // Aragon Contracts
    DAOFactory internal daoFactory;
    PluginRepoFactory internal repoFactory;
    ManifoldSetup internal manifoldSetup;
    PluginRepo internal manifoldRepo;

    // DAO Contracts
    DAO internal dao;
    TokenVoting internal votingPlugin;
    FeeDistributor internal feeDistributor;

    // Tokens
    MockToken internal box;
    VoteEscrowToken internal veBOX;
    MockToken internal wETH;

    function setUp() public virtual {
        createFork("mainnet", 17_328_640);
        createAgents();
        setupRepo();
        deployContracts();
        deployDAO();
    }

    function createFork(string memory network, uint256 blockNumber) public {
        // Silently pass this test if there is no API key.

        string memory alchemyApiKey = vm.envOr("API_KEY_ALCHEMY", string(""));
        if (bytes(alchemyApiKey).length == 0) {
            return;
        }
        // Otherwise, run the test against the mainnet fork.
        vm.createSelectFork({ urlOrAlias: network, blockNumber: blockNumber });
        console2.log("Curent Block: ", blockNumber);
    }

    function createAgents() public {
        deployer = createNamedUser("DEPLOYER");
        alice = createNamedUser("ALICE");
        bob = createNamedUser("BOB");
    }

    function setupRepo() public {
        daoFactory = DAOFactory(0xA03C2182af8eC460D498108C92E8638a580b94d4);
        repoFactory = PluginRepoFactory(0x96E54098317631641703404C06A5afAD89da7373);
        vm.startPrank(deployer);
        manifoldSetup = new ManifoldSetup();
        manifoldRepo = repoFactory.createPluginRepoWithFirstVersion({
            _subdomain: "manifold-template",
            _pluginSetup: address(manifoldSetup),
            _maintainer: address(deployer),
            _releaseMetadata: "0x00",
            _buildMetadata: "0x00"
        });
        vm.stopPrank();
        vm.label(address(manifoldRepo), "manifoldRepo");
        vm.label(address(manifoldSetup), "manifoldSetup");
        vm.label(address(repoFactory), "repoFactory");
        vm.label(address(daoFactory), "daoFactory");
    }

    function deployContracts() public {
        vm.prank(deployer);
        box = new MockToken("Box Token", "BOX");
        wETH = new MockToken("Wrapped Ether", "WETH");

        vm.label(address(box), "BOX");
        vm.label(address(wETH), "WETH");

        box.mint(alice, 1_000_000 * TOKEN);
        box.mint(bob, 1_000_000 * TOKEN);
        wETH.mint(deployer, 10_000 * TOKEN);
    }

    function deployDAO() public {
        MajorityVotingBase.VotingSettings memory _votingSettings = MajorityVotingBase.VotingSettings({
            votingMode: MajorityVotingBase.VotingMode.Standard,
            supportThreshold: 50 * RATIO,
            minParticipation: 10 * RATIO,
            minDuration: ONE_DAY,
            minProposerVotingPower: 1
        });

        DAOFactory.DAOSettings memory _daoSettings = DAOFactory.DAOSettings({
            trustedForwarder: address(0),
            daoURI: "http://daobox.app",
            subdomain: "manifold-daobox",
            metadata: "0x00"
        });

        DAOFactory.PluginSettings[] memory _plugin = new DAOFactory.PluginSettings[](1);
        _plugin[0] = DAOFactory.PluginSettings({ pluginSetupRef: pluginSetupRef(), data: pluginData(_votingSettings) });

        vm.recordLogs();
        vm.prank(deployer);
        dao = daoFactory.createDao(_daoSettings, _plugin);
        Vm.Log[] memory entries = Vm(address(vm)).getRecordedLogs();

        for (uint256 i = 0; i < entries.length; i++) {
            if (entries[i].topics[0] == keccak256("DeployedContracts(address,address,address)")) {
                (address _voting, address _veToken, address _feeDistributor) =
                    abi.decode(entries[i].data, (address, address, address));
                votingPlugin = TokenVoting(_voting);
                veBOX = VoteEscrowToken(_veToken);
                feeDistributor = FeeDistributor(_feeDistributor);

                vm.label(address(dao), "DAO");
                vm.label(address(feeDistributor), "Fee Distributor");
                vm.label(address(veBOX), "veBOX");
                vm.label(address(votingPlugin), "Voting Plugin");
            }
        }
    }

    // ----------------- DAO SETUP HELPERS ------------------- //

    function pluginSetupRef() private view returns (PluginSetupRef memory) {
        return PluginSetupRef({ versionTag: PluginRepo.Tag({ release: 1, build: 1 }), pluginSetupRepo: manifoldRepo });
    }

    function pluginData(MajorityVotingBase.VotingSettings memory _voteSettings) private view returns (bytes memory) {
        return abi.encode(_voteSettings, address(box), address(wETH), block.timestamp);
    }
}
