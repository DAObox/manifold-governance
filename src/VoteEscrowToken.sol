// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity >=0.8.17;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { IVotes } from "@openzeppelin/contracts/governance/utils/IVotes.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/security/ReentrancyGuard.sol";

import { PluginCloneable, IDAO } from "@aragon/core/plugin/PluginCloneable.sol";
import { Errors } from "./lib/Errors.sol";
import { Events } from "./lib/Events.sol";

import { LockedBalance, Point } from "./lib/Types.sol";
import { SmartWalletChecker } from "./interfaces/SmartWalletChecker.sol";

contract VoteEscrowToken is PluginCloneable, ReentrancyGuard, IVotes {
    // =============================================================== //
    // ========================== CONSTANTS ========================== //
    // =============================================================== //
    address public constant ZERO_ADDRESS = address(0);

    /// @dev The identifier of the permission that allows an address add a whitelisted contract
    bytes32 public constant WHITELIST_PERMISSION_ID = keccak256("WHITELIST_PERMISSION");

    /// @dev The identifier of the permission that allows an address to recover tokens
    bytes32 public constant RECOVER_PERMISSION_ID = keccak256("RECOVER_PERMISSION");

    uint8 private constant MAX_DECIMALS = 255;

    int128 public constant DEPOSIT_FOR_TYPE = 0;
    int128 public constant CREATE_LOCK_TYPE = 1;
    int128 public constant INCREASE_LOCK_AMOUNT = 2;
    int128 public constant INCREASE_UNLOCK_TIME = 3;

    uint256 public constant WEEK = 7 * 86_400; // all future times are rounded by week
    uint256 public constant MAXTIME = 3 * 365 * 86_400; // 3 years
    uint256 public constant MULTIPLIER = 10 ** 18;

    // =============================================================== //
    // =========================== STROAGE =========================== //
    // =============================================================== //

    // Address of the token being locked
    address public token;
    // Current supply of vote locked tokens
    uint256 public supply;
    // Current vote lock epoch
    uint256 public epoch;

    // veToken name
    string public name;
    // veToken symbol
    string public symbol;
    // veToken version
    string public version;
    // veToken decimals
    uint256 public decimals;

    // Current smart wallet checker for whitelisted (smart contract) wallets which are allowed to deposit. The goal is
    // to prevent tokenizing the escrow
    address public smart_wallet_checker;

    // Locked balances and end date for each lock
    mapping(address => LockedBalance) public locked;
    // History of vote weights for each user
    mapping(address => mapping(uint256 => Point)) public user_point_history;
    // Vote epochs for each user vote weight
    mapping(address => uint256) public user_point_epoch;
    // Decay slope changes
    mapping(uint256 => int128) public slope_changes; // time -> signed slope change
    // Global vote weight history for each epoch
    mapping(uint256 => Point) public point_history; // epoch -> unsigned point

    // =============================================================== //
    // ========================= INITIALIZE ========================== //
    // =============================================================== //

    function initialize(
        IDAO dao_,
        address token_addr,
        string memory _name,
        string memory _symbol
    )
        external
        initializer
    {
        __PluginCloneable_init(dao_);
        uint256 _decimals = ERC20(token_addr).decimals();
        if (_decimals >= 255) revert Errors.TOKEN_DECIMALS_OVERFLOW({ amount: uint8(_decimals), max: MAX_DECIMALS });
        decimals = _decimals;
        name = _name;
        symbol = _symbol;
        token = token_addr;

        point_history[0].blk = block.number;
        point_history[0].ts = block.timestamp;
    }

    // =============================================================== //
    // ===================== GOVERNANCE FUNCTIONS ==================== //
    // =============================================================== //

    /**
     * @notice Set an external contract to check for approved smart contract wallets
     * @param addr Address of Smart contract checker
     */
    function commit_smart_wallet_checker(address addr) external auth(WHITELIST_PERMISSION_ID) {
        smart_wallet_checker = addr;
    }

    /**
     * @notice Added to support recovering LP Rewards and other mistaken tokens from other systems to be distributed to
     * holders
     * @param tokenAddress Address of the token to recover
     * @param tokenAmount The amount of tokens to transfer
     */
    function recoverERC20(address tokenAddress, uint256 tokenAmount) external auth(RECOVER_PERMISSION_ID) {
        // Admin cannot withdraw the staking token
        if (tokenAddress == address(token)) revert Errors.CannotWithdrawVestedToken(tokenAddress, address(token));

        // Only the owner address can ever receive the recovery withdrawal
        ERC20(tokenAddress).transfer(msg.sender, tokenAmount);
        emit Events.Recovered(tokenAddress, tokenAmount);
    }

    // =============================================================== //
    // ======================== USER FUNCTIONS ======================= //
    // =============================================================== //

    /**
     * @notice Deposit and lock tokens for a user
     * @dev Anyone (even a smart contract) can deposit for someone else, but
     *         cannot extend their locktime and deposit for a brand new user
     * @param _addr User's wallet address
     * @param _value Amount to add to user's lock
     */
    function deposit_for(address _addr, uint256 _value) external virtual nonReentrant {
        LockedBalance memory _locked = locked[_addr];
        if (_value <= 0) revert Errors.NeedNonZeroValue(_value);
        if (_locked.amount <= 0) revert Errors.NoExistingLockFound(_locked.amount);
        if (_locked.end <= block.timestamp) revert Errors.CannotAddToExpiredLock(_locked.end, block.timestamp);

        _deposit_for(_addr, _value, 0, locked[_addr], DEPOSIT_FOR_TYPE);
    }

    /**
     * @notice Deposit `_value` tokens for `msg.sender` and lock until `_unlock_time`
     * @param _value Amount to deposit
     * @param _unlock_time Epoch time when tokens unlock, rounded down to whole weeks
     */
    function create_lock(uint256 _value, uint256 _unlock_time) external nonReentrant {
        assert_not_contract(msg.sender);
        uint256 unlock_time = (_unlock_time / WEEK) * WEEK; // Locktime is rounded down to weeks
        LockedBalance memory _locked = locked[msg.sender];

        if (_value <= 0) revert Errors.NeedNonZeroValue(_value);
        if (_locked.amount != 0) revert Errors.WithdrawOldTokensFirst(_locked.amount);
        if (unlock_time <= block.timestamp) revert Errors.CanOnlyLockUntilTimeInTheFuture(unlock_time, block.timestamp);
        if (unlock_time > block.timestamp + MAXTIME) revert Errors.VotingLockCanBe3YearsMax(unlock_time, MAXTIME);

        _deposit_for(msg.sender, _value, unlock_time, _locked, CREATE_LOCK_TYPE);
    }

    /**
     * @notice Deposit `_value` additional tokens for `msg.sender`
     *            without modifying the unlock time
     * @param _value Amount of tokens to deposit and add to the lock
     */
    function increase_amount(uint256 _value) external virtual nonReentrant {
        assert_not_contract(msg.sender);
        LockedBalance memory _locked = locked[msg.sender];

        if (_value <= 0) revert Errors.NeedNonZeroValue(_value);
        if (_locked.amount <= 0) revert Errors.NoExistingLockFound(_locked.amount);
        if (_locked.end <= block.timestamp) revert Errors.CannotAddToExpiredLock(_locked.end, block.timestamp);

        _deposit_for(msg.sender, _value, 0, _locked, INCREASE_LOCK_AMOUNT);
    }

    /**
     * @notice Extend the unlock time for `msg.sender` to `_unlock_time`
     * @param _unlock_time New epoch time for unlocking
     */
    function increase_unlock_time(uint256 _unlock_time) external virtual nonReentrant {
        assert_not_contract(msg.sender);
        LockedBalance memory _locked = locked[msg.sender];
        uint256 unlock_time = (_unlock_time / WEEK) * WEEK; // Locktime is rounded down to weeks

        if (_locked.end <= block.timestamp) revert Errors.LockExpired(_locked.end, block.timestamp);
        if (_locked.amount <= 0) revert Errors.NothingIsLocked(_locked.amount);
        if (unlock_time <= _locked.end) revert Errors.CanOnlyIncreaseLockDuration(unlock_time, _locked.end);
        if (unlock_time > block.timestamp + MAXTIME) revert Errors.VotingLockCanBe3YearsMax(unlock_time, MAXTIME);

        _deposit_for(msg.sender, 0, unlock_time, _locked, INCREASE_UNLOCK_TIME);
    }

    /**
     * @notice Withdraw all tokens for `msg.sender`ime`
     * @dev Only possible if the lock has expired
     */
    function withdraw() external virtual nonReentrant {
        LockedBalance memory _locked = locked[msg.sender];
        require(block.timestamp >= _locked.end, "veToken/the-lock-did-not-expire");
        uint256 value = uint256(int256(_locked.amount));

        LockedBalance memory old_locked = _locked;
        _locked.end = 0;
        _locked.amount = 0;
        locked[msg.sender] = _locked;
        uint256 supply_before = supply;
        supply = supply_before - value;

        // old_locked can have either expired <= timestamp or zero end
        // _locked has only 0 end
        // Both can have >= 0 amount
        _checkpoint(msg.sender, old_locked, _locked);

        bool success = ERC20(token).transfer(msg.sender, value);
        if (!success) revert Errors.TokenTransferFailed(msg.sender, value);

        emit Events.Withdraw(msg.sender, value, block.timestamp);
        emit Events.Supply(supply_before, supply_before - value);
    }

    /**
     * @notice Record global data to checkpoint
     */
    function checkpoint() external {
        _checkpoint(ZERO_ADDRESS, EMPTY_LOCKED_BALANCE_FACTORY(), EMPTY_LOCKED_BALANCE_FACTORY());
    }

    // =============================================================== //
    // ===================== IVOTES COMPATABILITY ==================== //
    // =============================================================== //

    /// @inheritdoc IVotes
    function getVotes(address addr) public view returns (uint256) {
        return _getVotes(addr, block.timestamp);
    }

    /// @inheritdoc IVotes
    function getPastVotes(address account, uint256 timepoint) external view returns (uint256) {
        return _getVotes(account, timepoint);
    }

    /// @inheritdoc IVotes
    function getPastTotalSupply(uint256 timeStamp) external view returns (uint256) {
        return _totalSupplyAtTimestamp(timeStamp);
    }

    /// @inheritdoc IVotes
    function delegates(address account) external pure returns (address) {
        return account;
    }

    /// @inheritdoc IVotes
    // solhint-disable-next-line no-unused-vars
    function delegate(address delegatee) external pure {
        revert Errors.DelegationNotAllowed();
    }

    /// @inheritdoc IVotes
    // solhint-disable-next-line no-unused-vars
    function delegateBySig(
        address delegatee,
        uint256 nonce,
        uint256 expiry,
        uint8 v,
        bytes32 r,
        bytes32 s
    )
        external
        pure
    {
        revert Errors.DelegationNotAllowed();
    }

    // =============================================================== //
    // ======================== VIEW FUNCTIONS ======================= //
    // =============================================================== //

    /**
     * @notice Get the most recently recorded rate of voting power decrease for `addr`
     * @param addr Address of the user wallet
     * @return Value of the slope
     */
    function get_last_user_slope(address addr) external view returns (int128) {
        uint256 uepoch = user_point_epoch[addr];
        return user_point_history[addr][uepoch].slope;
    }

    /**
     * @notice Get the timestamp for checkpoint `_idx` for `_addr`
     * @param _addr User wallet address
     * @param _idx User epoch number
     * @return Epoch time of the checkpoint
     */
    function user_point_history__ts(address _addr, uint256 _idx) external view returns (uint256) {
        return user_point_history[_addr][_idx].ts;
    }

    /**
     * @notice Get timestamp when `_addr`'s lock finishes
     * @param _addr User wallet
     * @return Epoch time of the lock end
     */
    function locked__end(address _addr) external view returns (uint256) {
        return locked[_addr].end;
    }

    // =============================================================== //
    // ====================== INTERNAL FUNCTIONS ===================== //
    // =============================================================== //

    // Constant structs not allowed yet, so this will have to do
    function EMPTY_POINT_FACTORY() internal pure returns (Point memory) {
        return Point({ bias: 0, slope: 0, ts: 0, blk: 0 });
    }

    // Constant structs not allowed yet, so this will have to do
    function EMPTY_LOCKED_BALANCE_FACTORY() internal pure returns (LockedBalance memory) {
        return LockedBalance({ amount: 0, end: 0 });
    }

    /**
     * @notice Binary search to estimate timestamp for block number
     * @param _block Block to find
     * @param max_epoch Don't go beyond this epoch
     * @return Approximate timestamp for block
     */
    function find_block_epoch(uint256 _block, uint256 max_epoch) internal view returns (uint256) {
        // Binary search
        uint256 _min = 0;
        uint256 _max = max_epoch;

        // Will be always enough for 128-bit numbers
        for (uint256 i = 0; i < 128; i++) {
            if (_min >= _max) {
                break;
            }
            uint256 _mid = (_min + _max + 1) / 2;
            if (point_history[_mid].blk <= _block) {
                _min = _mid;
            } else {
                _max = _mid - 1;
            }
        }

        return _min;
    }

    /**
     * @notice Calculate total voting power at some point in the past
     * @param point The point (bias/slope) to start search from
     * @param t Time to calculate the total voting power at
     * @return Total voting power at that time
     */
    function supply_at(Point memory point, uint256 t) internal view returns (uint256) {
        Point memory last_point = point;
        uint256 t_i = (last_point.ts / WEEK) * WEEK;

        for (uint256 i = 0; i < 255; i++) {
            t_i += WEEK;
            int128 d_slope = 0;
            if (t_i > t) {
                t_i = t;
            } else {
                d_slope = slope_changes[t_i];
            }
            last_point.bias -= last_point.slope * (int128(int256(t_i)) - int128(int256(last_point.ts)));
            if (t_i == t) {
                break;
            }
            last_point.slope += d_slope;
            last_point.ts = t_i;
        }

        if (last_point.bias < 0) {
            last_point.bias = 0;
        }
        return uint256(int256(last_point.bias));
    }

    function _getVotes(address account, uint256 timepoint) internal view returns (uint256) {
        uint256 _epoch = user_point_epoch[account];
        if (_epoch == 0) {
            return 0;
        } else {
            Point memory last_point = user_point_history[account][_epoch];
            last_point.bias -= last_point.slope * (int128(int256(timepoint)) - int128(int256(last_point.ts)));
            if (last_point.bias < 0) {
                last_point.bias = 0;
            }
            return uint256(int256(last_point.bias));
        }
    }

    /**
     * @notice Calculate total voting power at the specified timestamp
     * @dev Adheres to the ERC20 `totalSupply` interface for Aragon compatibility
     * @return Total voting power
     */
    function _totalSupplyAtTimestamp(uint256 t) internal view returns (uint256) {
        uint256 _epoch = epoch;
        Point memory last_point = point_history[_epoch];
        return supply_at(last_point, t);
    }

    /**
     * @notice Deposit and lock tokens for a user
     * @param _addr User's wallet address
     * @param _value Amount to deposit
     * @param unlock_time New time when to unlock the tokens, or 0 if unchanged
     * @param locked_balance Previous locked amount / timestamp
     */
    function _deposit_for(
        address _addr,
        uint256 _value,
        uint256 unlock_time,
        LockedBalance memory locked_balance,
        int128 _type
    )
        internal
    {
        LockedBalance memory _locked = locked_balance;
        uint256 supply_before = supply;

        supply = supply_before + _value;
        LockedBalance memory old_locked = _locked;

        // Adding to existing lock, or if a lock is expired - creating a new one
        _locked.amount += int128(int256(_value));
        if (unlock_time != 0) {
            _locked.end = unlock_time;
        }
        locked[_addr] = _locked;

        // Possibilities:
        // Both old_locked.end could be current or expired (>/< block.timestamp)
        // value == 0 (extend lock) or value > 0 (add to lock or extend lock)
        // _locked.end > block.timestamp (always)
        _checkpoint(_addr, old_locked, _locked);

        if (_value != 0) {
            assert(ERC20(token).transferFrom(_addr, address(this), _value));
        }

        emit Events.Deposit(_addr, _value, _locked.end, _type, block.timestamp);
        emit Events.Supply(supply_before, supply_before + _value);
    }

    /**
     * @notice Check if the call is from a whitelisted smart contract, revert if not
     * @param addr Address to be checked
     */
    function assert_not_contract(address addr) internal {
        if (addr != tx.origin) {
            address checker = smart_wallet_checker;
            if (checker != ZERO_ADDRESS) {
                if (SmartWalletChecker(checker).check(addr)) {
                    return;
                }
            }
            revert Errors.SmartContractDepositorsNotAllowed();
        }
    }

    /**
     * @notice Record global and per-user data to checkpoint
     * @param addr User's wallet address. No user checkpoint if 0x0
     * @param old_locked Previous locked amount / end lock time for the user
     * @param new_locked New locked amount / end lock time for the user
     */
    function _checkpoint(address addr, LockedBalance memory old_locked, LockedBalance memory new_locked) internal {
        Point memory u_old = EMPTY_POINT_FACTORY();
        Point memory u_new = EMPTY_POINT_FACTORY();

        int128 old_dslope = 0;
        int128 new_dslope = 0;
        uint256 _epoch = epoch;

        if (addr != ZERO_ADDRESS) {
            // Calculate slopes and biases
            // Kept at zero when they have to
            if ((old_locked.end > block.timestamp) && (old_locked.amount > 0)) {
                u_old.slope = old_locked.amount / int128(int256(MAXTIME));
                u_old.bias = u_old.slope * (int128(int256(old_locked.end)) - int128(int256(block.timestamp)));
            }

            if ((new_locked.end > block.timestamp) && (new_locked.amount > 0)) {
                u_new.slope = new_locked.amount / int128(int256(MAXTIME));
                u_new.bias = u_new.slope * (int128(int256(new_locked.end)) - int128(int256(block.timestamp)));
            }

            // Read values of scheduled changes in the slope
            // old_locked.end can be in the past and in the future
            // new_locked.end can ONLY by in the FUTURE unless everything expired: than zeros
            old_dslope = slope_changes[old_locked.end];
            if (new_locked.end != 0) {
                if (new_locked.end == old_locked.end) {
                    new_dslope = old_dslope;
                } else {
                    new_dslope = slope_changes[new_locked.end];
                }
            }
        }

        Point memory last_point = Point({ bias: 0, slope: 0, ts: block.timestamp, blk: block.number });
        if (_epoch > 0) {
            last_point = point_history[_epoch];
        }
        uint256 last_checkpoint = last_point.ts;

        // initial_last_point is used for extrapolation to calculate block number
        // (approximately, for *At methods) and save them
        // as we cannot figure that out exactly from inside the contract
        Point memory initial_last_point = last_point;
        uint256 block_slope = 0; // dblock/dt
        if (block.timestamp > last_point.ts) {
            block_slope = MULTIPLIER * (block.number - last_point.blk) / (block.timestamp - last_point.ts);
        }

        //////////////////////////////////////////////////////////////
        // If last point is already recorded in this block, slope=0 //
        // But that's ok b/c we know the block in such case         //
        //////////////////////////////////////////////////////////////

        // Go over weeks to fill history and calculate what the current point is
        uint256 t_i = (last_checkpoint / WEEK) * WEEK;
        for (uint256 i = 0; i < 255; i++) {
            // Hopefully it won't happen that this won't get used in 5 years!
            // If it does, users will be able to withdraw but vote weight will be broken
            t_i += WEEK;
            int128 d_slope = 0;
            if (t_i > block.timestamp) {
                t_i = block.timestamp;
            } else {
                d_slope = slope_changes[t_i];
            }
            last_point.bias -= last_point.slope * (int128(int256(t_i)) - int128(int256(last_checkpoint)));
            last_point.slope += d_slope;
            if (last_point.bias < 0) {
                last_point.bias = 0; // This can happen
            }
            if (last_point.slope < 0) {
                last_point.slope = 0; // This cannot happen - just in case
            }
            last_checkpoint = t_i;
            last_point.ts = t_i;
            last_point.blk = initial_last_point.blk + block_slope * (t_i - initial_last_point.ts) / MULTIPLIER;
            _epoch += 1;
            if (t_i == block.timestamp) {
                last_point.blk = block.number;
                break;
            } else {
                point_history[_epoch] = last_point;
            }
        }

        epoch = _epoch;
        // Now point_history is filled until t=now

        if (addr != ZERO_ADDRESS) {
            // If last point was in this block, the slope change has been applied already
            // But in such case we have 0 slope(s)
            last_point.slope += (u_new.slope - u_old.slope);
            last_point.bias += (u_new.bias - u_old.bias);
            if (last_point.slope < 0) {
                last_point.slope = 0;
            }
            if (last_point.bias < 0) {
                last_point.bias = 0;
            }
        }

        // Record the changed point into history
        point_history[_epoch] = last_point;

        if (addr != ZERO_ADDRESS) {
            // Schedule the slope changes (slope is going down)
            // We subtract new_user_slope from [new_locked.end]
            // and add old_user_slope to [old_locked.end]
            if (old_locked.end > block.timestamp) {
                // old_dslope was <something> - u_old.slope, so we cancel that
                old_dslope += u_old.slope;
                if (new_locked.end == old_locked.end) {
                    old_dslope -= u_new.slope; // It was a new deposit, not extension
                }
                slope_changes[old_locked.end] = old_dslope;
            }

            if (new_locked.end > block.timestamp) {
                if (new_locked.end > old_locked.end) {
                    new_dslope -= u_new.slope; // old slope disappeared at this point
                    slope_changes[new_locked.end] = new_dslope;
                }
                // else: we recorded it already in old_dslope
            }

            // Now handle user history
            // Second function needed for 'stack too deep' issues
            _checkpoint_part_two(addr, u_new.bias, u_new.slope);
        }
    }

    /**
     * @notice Needed for 'stack too deep' issues in _checkpoint()
     * @param addr User's wallet address. No user checkpoint if 0x0
     * @param _bias from unew
     * @param _slope from unew
     */
    function _checkpoint_part_two(address addr, int128 _bias, int128 _slope) internal {
        uint256 user_epoch = user_point_epoch[addr] + 1;

        user_point_epoch[addr] = user_epoch;
        user_point_history[addr][user_epoch] =
            Point({ bias: _bias, slope: _slope, ts: block.timestamp, blk: block.number });
    }
}
