// SPDX-License-Identifier: MIT
pragma solidity >=0.8.17;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/security/ReentrancyGuard.sol";

import { PluginCloneable, IDAO } from "@aragon/core/plugin/PluginCloneable.sol";

import { VoteEscrowToken } from "./VoteEscrowToken.sol";
import { Errors } from "./lib/Errors.sol";
import { Events } from "./lib/Events.sol";
import { Point } from "./lib/Types.sol";

contract FeeDistributor is PluginCloneable, ReentrancyGuard {
    // =============================================================== //
    // ========================== CONSTANTS ========================== //
    // =============================================================== //

    bytes32 public constant CHECKPOINT_PERMISSION_ID = keccak256("CHECKPOINT_PERMISSION");
    bytes32 public constant KILL_PERMISSION_ID = keccak256("KILL_PERMISSION");

    uint256 public constant WEEK = 7 * 86_400; // all future times are rounded by week
    uint256 public constant TOKEN_CHECKPOINT_DEADLINE = 86_400;
    address public constant ZERO_ADDRESS = address(0);

    // =============================================================== //
    // =========================== STROAGE =========================== //
    // =============================================================== //

    uint256 public start_time;
    uint256 public time_cursor;
    uint256 public last_token_time;

    address public voting_escrow;
    address public token;

    uint256 public total_received;
    uint256 public token_last_balance;

    bool public can_checkpoint_token;
    bool public is_killed;

    mapping(address => uint256) public time_cursor_of;
    mapping(address => uint256) public user_epoch_of;
    mapping(uint256 => uint256) public tokens_per_week;
    mapping(uint256 => uint256) public ve_supply;

    // =============================================================== //
    // ========================= INITIALIZE ========================== //
    // =============================================================== //

    /**
     * @notice Contract constructor
     * @param _voting_escrow VotingEscrow contract address
     * @param _start_time Epoch time for fee distribution to start
     * @param _token Fee token address (3CRV)
     */
    function initialize(IDAO dao_, address _voting_escrow, uint256 _start_time, address _token) external initializer {
        __PluginCloneable_init(dao_);
        uint256 t = _start_time / WEEK * WEEK;

        start_time = t;
        last_token_time = t;
        time_cursor = t;
        token = _token;
        voting_escrow = _voting_escrow;
    }

    // =============================================================== //
    // ===================== GOVERNANCE FUNCTIONS ==================== //
    // =============================================================== //

    /**
     * @notice Toggle permission for checkpointing by any account
     */
    function toggle_allow_checkpoint_token() external auth(CHECKPOINT_PERMISSION_ID) {
        can_checkpoint_token = !can_checkpoint_token;
        emit Events.ToggleAllowCheckpointToken(can_checkpoint_token);
    }

    /**
     * @notice Kill the contract
     * @dev Killing transfers the entire fee balance to the emergency return address
     *      and blocks the ability to claim or burn. The contract cannot be unkilled.
     */
    function kill_me() external auth(KILL_PERMISSION_ID) {
        if (is_killed) revert Errors.ContractAlreadyKilled();

        uint256 contractBalance = ERC20(token).balanceOf(address(this));
        bool transferSuccessful = ERC20(token).transfer(address(dao()), contractBalance);

        if (!transferSuccessful) revert Errors.TokenTransferFailed(contractBalance);
    }

    // =============================================================== //
    // ======================== CORE FUNCTIONS ======================= //
    // =============================================================== //

    /**
     * @notice Update the token checkpoint by an authorized account
     * @dev Only callable by an authorized account.
     */
    function authorizedCheckpointToken() external auth(CHECKPOINT_PERMISSION_ID) {
        _checkpoint_token();
    }

    /**
     * @notice Update the token checkpoint by anyone
     * @dev Can be called by anyone if certain conditions are met.
     *      Calculates the total number of tokens to be distributed in a given week.
     */
    function checkpointToken() external {
        bool canCheckpoint = can_checkpoint_token && (block.timestamp > last_token_time + TOKEN_CHECKPOINT_DEADLINE);
        if (!canCheckpoint) {
            uint256 timeRemaining = (last_token_time + TOKEN_CHECKPOINT_DEADLINE) - block.timestamp;
            revert Errors.CannotCheckpointAtThisTime(can_checkpoint_token, timeRemaining);
        }
        _checkpoint_token();
    }

    /**
     * @notice Get the veToken balance for `_user` at `_timestamp`
     * @param _user Address to query balance for
     * @param _timestamp Epoch time
     * @return uint256 veToken balance
     */
    function ve_for_at(address _user, uint256 _timestamp) external view returns (uint256) {
        address ve = voting_escrow;
        uint256 max_user_epoch = VoteEscrowToken(ve).user_point_epoch(_user);
        uint256 epoch = _find_timestamp_user_epoch(ve, _user, _timestamp, max_user_epoch);

        (int128 bias, int128 slope, uint256 ts,) = VoteEscrowToken(ve).user_point_history(_user, epoch);
        return uint256(int256(max(bias - slope * int128(int256(_timestamp - ts)), 0)));
    }

    /**
     * @notice Update the veToken total supply checkpoint
     * @dev The checkpoint is also updated by the first claimant each
     *      new epoch week. This function may be called independently
     *      of a claim, to reduce claiming gas costs.
     */
    function checkpoint_total_supply() external {
        _checkpoint_total_supply();
    }

    /**
     * @notice Claim fees for `_addr`
     * @dev Each call to claim look at a maximum of 50 user veToken points.
     *      For accounts with many veToken related actions, this function
     *      may need to be called more than once to claim all available
     *      fees. In the `Claimed` event that fires, if `claim_epoch` is
     *      less than `max_epoch`, the account may claim again.
     * @return uint256 Amount of fees claimed in the call
     */
    function claim() external nonReentrant returns (uint256) {
        require(!is_killed, "veFeeDistributor/contract-killed");

        address _addr = msg.sender;

        if (block.timestamp >= time_cursor) {
            _checkpoint_total_supply();
        }

        if (can_checkpoint_token && (block.timestamp > last_token_time + TOKEN_CHECKPOINT_DEADLINE)) {
            _checkpoint_token();
            last_token_time = block.timestamp;
        }

        last_token_time = last_token_time / WEEK * WEEK;
        uint256 amount = _claim(_addr, voting_escrow, last_token_time);

        if (amount != 0) {
            require(ERC20(token).transfer(_addr, amount), "");
            token_last_balance -= amount;
        }

        return amount;
    }

    /**
     * @notice Make multiple fee claims in a single call
     * @dev Used to claim for many accounts at once, or to make
     *      multiple claims for the same address when that address
     *      has significant veCRV history
     * @param _receivers List of addresses to claim for. Claiming
     *                   terminates at the first `ZERO_ADDRESS`.
     * @return bool success
     */
    function claim_many(address[20] calldata _receivers) external nonReentrant returns (bool) {
        require(!is_killed, "veFeeDistributor/contract-killed");

        if (block.timestamp >= time_cursor) {
            _checkpoint_total_supply();
        }

        if (can_checkpoint_token && (block.timestamp > last_token_time + TOKEN_CHECKPOINT_DEADLINE)) {
            _checkpoint_token();
            last_token_time = block.timestamp;
        }

        last_token_time = last_token_time / WEEK * WEEK;
        uint256 total;
        uint256 amount;

        for (uint256 i = 0; i < _receivers.length; i++) {
            if (_receivers[i] == address(0)) break;

            amount = _claim(_receivers[i], voting_escrow, last_token_time);
            if (amount != 0) {
                require(ERC20(token).transfer(_receivers[i], amount), "veFeeDistributor/cannot-transfer-token");
                total += amount;
            }
        }

        if (total != 0) {
            token_last_balance -= total;
        }

        return true;
    }

    /**
     * @notice Receive fees into the contract and trigger a token checkpoint
     * @param _coin Address of the coin being received
     * @return bool success
     */
    function burn(address _coin) external returns (bool) {
        require(_coin == token, "veFeeDistributor/invalid-coin");
        require(!is_killed, "veFeeDistributor/contract-killed");

        uint256 amount = ERC20(_coin).balanceOf(msg.sender);
        if (amount != 0) {
            ERC20(_coin).transferFrom(msg.sender, address(this), amount);
            if (can_checkpoint_token && (block.timestamp > last_token_time + TOKEN_CHECKPOINT_DEADLINE)) {
                _checkpoint_token();
            }
        }

        return true;
    }

    // =============================================================== //
    // ====================== INTERNAL FUNCTIONS ===================== //
    // =============================================================== //

    function max(int128 x, int128 y) internal pure returns (int128 z) {
        z = (x >= y) ? x : y;
    }

    function min(uint256 x, uint256 y) internal pure returns (uint256 z) {
        z = (x <= y) ? x : y;
    }

    function _checkpoint_token() internal {
        uint256 token_balance = ERC20(token).balanceOf(address(this));
        uint256 to_distribute = token_balance - token_last_balance;
        token_last_balance = token_balance;

        uint256 t = last_token_time;
        uint256 since_last = block.timestamp - t;
        last_token_time = block.timestamp;
        uint256 this_week = t / WEEK * WEEK;
        uint256 next_week = 0;

        for (uint256 i = 0; i < 20; i++) {
            next_week = this_week + WEEK;

            if (block.timestamp < next_week) {
                if (since_last == 0 && block.timestamp == t) {
                    tokens_per_week[this_week] += to_distribute;
                } else {
                    tokens_per_week[this_week] += to_distribute * (block.timestamp - t) / since_last;
                }
                break;
            } else {
                if (since_last == 0 && next_week == t) {
                    tokens_per_week[this_week] += to_distribute;
                } else {
                    tokens_per_week[this_week] += to_distribute * (next_week - t) / since_last;
                }
            }

            t = next_week;
            this_week = next_week;
        }

        emit Events.CheckpointToken(block.timestamp, to_distribute);
    }

    function _find_timestamp_epoch(address ve, uint256 _timestamp) internal view returns (uint256) {
        uint256 _min = 0;
        uint256 _max = VoteEscrowToken(ve).epoch();
        uint256 _mid;

        for (uint256 i = 0; i < 128; i++) {
            if (_min >= _max) break;
            _mid = (_min + _max + 2) / 2;

            (,, uint256 ts,) = VoteEscrowToken(ve).point_history(_mid);
            if (ts <= _timestamp) {
                _min = _mid;
            } else {
                _max = _mid - 1;
            }
        }

        return _min;
    }

    function _find_timestamp_user_epoch(
        address ve,
        address user,
        uint256 _timestamp,
        uint256 max_user_epoch
    )
        internal
        view
        returns (uint256)
    {
        uint256 _min = 0;
        uint256 _mid;
        uint256 _max = max_user_epoch;

        for (uint256 i = 0; i < 128; i++) {
            if (_min >= _max) break;

            _mid = (_min + _max + 2) / 2;
            (,, uint256 ts,) = VoteEscrowToken(ve).user_point_history(user, _mid);

            if (ts <= _timestamp) {
                _min = _mid;
            } else {
                _max = _mid - 1;
            }
        }

        return _min;
    }

    function _checkpoint_total_supply() internal {
        address ve = voting_escrow;
        uint256 t = time_cursor;

        uint256 rounded_timestamp = block.timestamp / WEEK * WEEK;
        VoteEscrowToken(ve).checkpoint();

        for (uint256 i = 0; i < 20; i++) {
            if (t > rounded_timestamp) {
                break;
            } else {
                uint256 epoch = _find_timestamp_epoch(ve, t);
                int128 dt = 0;
                (int128 bias, int128 slope, uint256 ts,) = VoteEscrowToken(ve).point_history(epoch);

                if (t > ts) {
                    dt = int128(int256(t - ts));
                }

                ve_supply[t] = uint256(int256(max(bias - slope * dt, 0)));
            }
            t += WEEK;
        }

        time_cursor = t;
    }

    function _claim(address addr, address ve, uint256 _last_token_time) internal returns (uint256) {
        // Minimal user_epoch is 0 (if user had no point)
        uint256 user_epoch = 0;
        uint256 to_distribute = 0;

        uint256 max_user_epoch = VoteEscrowToken(ve).user_point_epoch(addr);
        uint256 _start_time = start_time;

        if (max_user_epoch == 0) {
            return 0;
        }

        uint256 week_cursor = time_cursor_of[addr];
        if (week_cursor == 0) {
            // Need to do the initial binary search
            user_epoch = _find_timestamp_user_epoch(ve, addr, _start_time, max_user_epoch);
        } else {
            user_epoch = user_epoch_of[addr];
        }

        if (user_epoch == 0) user_epoch = 1;

        // Initialize the user point
        Point memory user_point = getPoint(ve, addr, user_epoch);

        if (week_cursor == 0) {
            week_cursor = (user_point.ts + WEEK - 1) / WEEK * WEEK;
        }

        if (week_cursor >= _last_token_time) return 0;

        if (week_cursor < _start_time) {
            week_cursor = _start_time;
        }

        Point memory old_user_point;

        // Iterate over weeks
        for (uint256 i = 0; i < 50; i++) {
            if (week_cursor >= _last_token_time) {
                break;
            }

            if (week_cursor >= user_point.ts && user_epoch <= max_user_epoch) {
                user_epoch += 1;
                old_user_point = user_point;

                if (user_epoch > max_user_epoch) {
                    user_point = Point(0, 0, 0, 0);
                } else {
                    user_point = getPoint(ve, addr, user_epoch);
                }
            } else {
                // Calculations; + i * 2 is for rounding errors
                int128 dt = int128(int256(week_cursor - old_user_point.ts));
                uint256 balance_of = uint256(int256(max(old_user_point.bias - dt * old_user_point.slope, 0)));

                if (balance_of == 0 && user_epoch > max_user_epoch) {
                    break;
                }
                if (balance_of > 0) {
                    to_distribute += balance_of * tokens_per_week[week_cursor] / ve_supply[week_cursor];
                }

                week_cursor += WEEK;
            }
        }

        user_epoch = min(max_user_epoch, user_epoch - 1);

        user_epoch_of[addr] = user_epoch;
        time_cursor_of[addr] = week_cursor;

        emit Events.Claimed(addr, to_distribute, user_epoch, max_user_epoch);

        return to_distribute;
    }

    function getPoint(address ve, address addr, uint256 user_epoch) internal view returns (Point memory) {
        (int128 bias, int128 slope, uint256 ts, uint256 blk) = VoteEscrowToken(ve).user_point_history(addr, user_epoch);
        return Point(bias, slope, ts, blk);
    }
}
