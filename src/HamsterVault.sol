// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IHamsterHour} from "./interfaces/IHamsterHour.sol";
import {IERC20} from "./interfaces/IERC20.sol";
import {IERC721} from "./interfaces/IERC721.sol";

/// @title HamsterVault
/// @notice Mining, vesting and staking vault for $HAMSTER on Ethereum mainnet, fed by HamsterHour v2.
/// No owner, pause, upgrade or withdrawal path exists. TEAM (the launch wallet) holds exactly two
/// one-shot powers: `bindToken` and the 12-hour timelocked `scheduleBoost` / `activateBoost`.
///
/// Buckets of HAMSTER (set at bind): mining 750M, boost 50M. Rewards to stakers are IMD only.
contract HamsterVault {
    // ----------------------------------------------------------------- constants
    address public constant IMD = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;
    /// @dev HamsterHour v2 window geometry (source constants of the game).
    uint64 public constant GENESIS = 1791847200;
    uint64 public constant WINDOW_DURATION = 3600;

    uint256 public constant EXPECTED_SUPPLY = 1e27;
    uint256 public constant EXPECTED_REMAINDER = 8e26;
    uint256 public constant MINING_BUCKET = 750_000_000e18;
    uint256 public constant BOOST_BUCKET = 50_000_000e18;

    /// @notice HAMSTER per IMD of eligible loss in era 0 (both 18 decimals).
    uint256 public constant BASE_RATE = 20_000;
    /// @notice Cumulative eligible loss per halving era.
    uint256 public constant HALVING_LOSS = 18_750e18;

    uint64 public constant VESTING = 7 days;
    uint64 public constant WARMUP = 24 hours;
    uint64 public constant UNSTAKE_DELAY = 24 hours;
    uint64 public constant STREAM_DURATION = 7 days;
    uint64 public constant BACKLOG_DURATION = 30 days;
    uint64 public constant TIMELOCK = 12 hours;
    uint64 public constant BOOST_DEADLINE = 365 days;
    uint64 public constant REGISTRATION_LEAD = 24 hours;

    uint256 public constant BOOST_PCT = 50;
    uint256 public constant BOOST_NFT_DAILY_CAP = 10_000e18;
    uint256 public constant BOOST_GLOBAL_DAILY_CAP = 100_000e18;

    /// @notice Per-second drip factor: 0.99^(1/86400) in 1e18 fixed point (1% of the pot per day).
    uint256 public constant DRIP_FACTOR = 999999883676675127;
    uint256 internal constant ONE = 1e18;
    uint256 internal constant ACC = 1e36;

    uint256 public constant MIN_STAKE = 1e18;
    uint256 public constant MAX_CLAIM_BATCH = 48;
    uint256 public constant MAX_SQUEEKS = 20;
    /// @notice Warm-ups end on the next game-window boundary at or after 24 hours, so activations
    /// due between two interactions are at most ~26 grid points and a sync never needs batching.
    uint64 public constant ACTIVATION_GRID = 3600;
    uint256 public constant MAX_GRANTS_PER_CALL = 64;

    bytes4 internal constant ERC721_INTERFACE = 0x80ac58cd;

    // ----------------------------------------------------------------- immutables
    address public immutable TEAM;
    IHamsterHour public immutable GAME;
    uint64 public immutable DEPLOYED_AT;

    // ----------------------------------------------------------------- types
    struct Grant {
        uint128 amount;
        uint128 withdrawn;
        uint64 start;
    }

    struct Unstake {
        uint128 amount;
        uint64 releaseAt;
    }

    struct Account {
        uint256 active; // liquid stake earning weight
        uint256 pending; // liquid stake in warm-up
        uint64 pendingActivateAt;
        uint256 grantBalance; // unwithdrawn grant tokens, always weight
        uint256 rewardPerWeightPaid;
        uint256 accrued; // IMD earned, not yet claimed
        uint256 grantCursor;
        uint256 unstakeCursor;
    }

    struct Stream {
        uint256 remaining;
        uint64 end;
    }

    // ----------------------------------------------------------------- storage: token and buckets
    IERC20 public token;
    uint64 public boundAt;
    uint256 public miningBucket;
    uint256 public boostBucket;
    uint256 public miningCommitted;
    uint256 public boostCommitted;
    /// @notice Whole units of rounding dust of the mining curve, kept in the vault forever.
    uint256 public miningDust;
    mapping(uint256 => uint256) internal _dustScaled;
    mapping(uint256 => mapping(address => bool)) public claimed;
    mapping(uint256 => uint256) public windowClaimed;

    // ----------------------------------------------------------------- storage: vesting
    mapping(address => Grant[]) internal _grants;
    uint256 public totalGrantBalance;

    // ----------------------------------------------------------------- storage: staking
    mapping(address => Account) internal _accounts;
    mapping(address => Unstake[]) internal _unstakes;
    /// @dev Queue of distinct activation times (ascending); amount warming up per time; the
    /// accumulator value at each processed activation time.
    mapping(uint256 => uint64) internal _queue;
    mapping(uint64 => uint256) public pendingAt;
    mapping(uint64 => uint256) internal _rpwAt;
    uint256 public queueHead;
    uint256 public queueTail;
    uint256 public totalWeight;
    uint256 public totalStaked; // active + pending liquid stake
    uint256 public totalUnstaking;
    uint256 public rewardPerWeight; // ACC-scaled
    uint64 public lastSync;
    uint256 public totalRewardsAccrued; // IMD distributed to weight so far
    uint256 public totalRewardsClaimed;

    Stream public stream; // 7-day: hook swap share and later game pulls
    Stream public backlog; // 30-day: the game's pre-vault backlog (first pull)
    uint256 public dripPot;
    bool public backlogPulled;

    // ----------------------------------------------------------------- storage: boost
    IERC721 public collection;
    address public scheduledCollection;
    uint64 public boostReadyAt;
    uint64 public boostActivatedAt;
    bool public boostSwept;
    mapping(uint256 => address) public registrant;
    mapping(uint256 => uint64) public registeredAt;
    mapping(address => uint256[]) internal _squeeks;
    mapping(uint256 => mapping(uint256 => uint256)) public nftDayUsed;
    mapping(uint256 => uint256) public globalDayUsed;

    uint256 private _lock = 1;

    // ----------------------------------------------------------------- errors
    error ZeroAddress();
    error NotTeam();
    error Reentrancy();
    error TransferFailed();
    error AlreadyBound();
    error NotBound();
    error WrongSupply();
    error WrongRemainder();
    error NotFinalized();
    error AlreadyClaimed();
    error NothingToClaim();
    error BatchTooLarge();
    error BucketExceeded();
    error BelowMinimum();
    error InvalidAmount();
    error InsufficientStake();
    error BoostNotActive();
    error BoostAlreadyActive();
    error BoostSweptAlready();
    error NothingScheduled();
    error TimelockNotReady();
    error BadCollection();
    error NotOwnerOfToken();
    error AlreadyRegistered();
    error NotRegistered();
    error TooManyRegistrations();
    error TooEarly();

    // ----------------------------------------------------------------- events
    event TokenBound(address indexed token);
    event Mined(uint256 indexed k, address indexed account, uint256 base, uint256 boost);
    event GrantCreated(address indexed account, uint256 indexed id, uint256 amount, uint64 start);
    event GrantWithdrawn(address indexed account, uint256 amount);
    event Staked(address indexed account, uint256 amount, uint64 activateAt);
    event StakeActivated(address indexed account, uint256 amount, uint64 at);
    event UnstakeRequested(address indexed account, uint256 amount, uint64 releaseAt);
    event Unstaked(address indexed account, uint256 amount);
    event RewardsClaimed(address indexed account, uint256 amount);
    event RewardsDeposited(address indexed from, uint256 amount, uint64 end);
    event DripDeposited(address indexed from, uint256 amount, uint256 pot);
    event GamePulled(uint256 amount, bool backlog, uint64 end);
    event BoostScheduled(address indexed collection, uint64 readyAt);
    event BoostActivated(address indexed collection);
    event BoostSwept(uint256 amount);
    event SqueekRegistered(address indexed account, uint256 indexed tokenId);
    event SqueekUnregistered(address indexed account, uint256 indexed tokenId);
    event SqueekVoided(address indexed account, uint256 indexed tokenId);

    modifier nonReentrant() {
        if (_lock != 1) revert Reentrancy();
        _lock = 2;
        _;
        _lock = 1;
    }

    modifier onlyTeam() {
        if (msg.sender != TEAM) revert NotTeam();
        _;
    }

    /// @param team_ The launch wallet: `bindToken` and the boost activation, nothing else.
    /// @param game_ HamsterHour v2. Checked on first use, never in the constructor.
    constructor(address team_, address game_) {
        if (team_ == address(0) || game_ == address(0)) revert ZeroAddress();
        TEAM = team_;
        GAME = IHamsterHour(game_);
        DEPLOYED_AT = uint64(block.timestamp);
        lastSync = uint64(block.timestamp);
    }

    // ================================================================= TOKEN BIND
    /// @notice Binds the HAMSTER token once. The token must have the full 1e27 supply and this vault
    /// must already hold at least the 8e26 remainder, which becomes the mining and boost buckets. Any
    /// surplus (a donation before the bind) is untracked, like donations after it, so a stray transfer
    /// cannot block the bind.
    function bindToken(address token_) external onlyTeam {
        if (address(token) != address(0)) revert AlreadyBound();
        if (token_ == address(0)) revert ZeroAddress();
        if (IERC20(token_).totalSupply() != EXPECTED_SUPPLY) revert WrongSupply();
        if (IERC20(token_).balanceOf(address(this)) < EXPECTED_REMAINDER) revert WrongRemainder();
        token = IERC20(token_);
        boundAt = uint64(block.timestamp);
        miningBucket = MINING_BUCKET;
        boostBucket = boostSwept ? 0 : BOOST_BUCKET;
        if (boostSwept) miningBucket += BOOST_BUCKET;
        emit TokenBound(token_);
    }

    // ================================================================= MINING
    /// @notice Cumulative HAMSTER emitted by the curve once `loss` IMD of eligible loss has accrued:
    /// 20,000 per IMD, halving every 18,750 IMD, converging to the 750M mining bucket.
    function emissionAt(uint256 loss) public pure returns (uint256) {
        uint256 era = loss / HALVING_LOSS;
        uint256 inEra = (loss - era * HALVING_LOSS) * BASE_RATE;
        return (MINING_BUCKET - (MINING_BUCKET >> era)) + (inEra >> era);
    }

    /// @notice Window `k`'s budget: emission between its cumulative loss bounds, across halvings.
    function windowBudget(uint256 k) public view returns (uint256) {
        return emissionAt(GAME.cumulativeLossAfter(k)) - emissionAt(GAME.cumulativeLossBefore(k));
    }

    function windowStart(uint256 k) public pure returns (uint64) {
        return GENESIS + uint64(k) * WINDOW_DURATION;
    }

    /// @notice Claims window shares for `account` and vests them in one 7-day grant. Anyone may call;
    /// the grant always belongs to `account`. Each (window, account) is claimable once.
    function claimMined(uint256[] calldata windows, address account) external nonReentrant {
        if (address(token) == address(0)) revert NotBound();
        if (account == address(0)) revert ZeroAddress();
        if (windows.length > MAX_CLAIM_BATCH) revert BatchTooLarge();
        uint256 finalized = GAME.nextFinalizeWindow();
        uint256 base;
        uint256 boost;
        for (uint256 i; i < windows.length; ++i) {
            uint256 k = windows[i];
            if (k >= finalized) revert NotFinalized();
            if (claimed[k][account]) revert AlreadyClaimed();
            claimed[k][account] = true;
            uint256 b = _baseShare(k, account);
            uint256 x = b == 0 ? 0 : _allocateBoost(k, account, b * BOOST_PCT / 100, boost);
            windowClaimed[k] += b;
            base += b;
            boost += x;
            emit Mined(k, account, b, x);
        }
        uint256 total = base + boost;
        if (total == 0) revert NothingToClaim();
        miningCommitted += base;
        boostCommitted += boost;
        if (miningCommitted > miningBucket || boostCommitted > boostBucket) revert BucketExceeded();
        _sync();
        _settle(account);
        _grants[account].push(Grant(uint128(total), 0, uint64(block.timestamp)));
        _accounts[account].grantBalance += total;
        totalGrantBalance += total;
        totalWeight += total;
        emit GrantCreated(account, _grants[account].length - 1, total, uint64(block.timestamp));
    }

    /// @dev budget * lossOf / totalEligibleLoss, rounded down; the remainder feeds the dust bucket.
    function _baseShare(uint256 k, address account) private returns (uint256 share) {
        uint256 total = GAME.totalEligibleLoss(k);
        if (total == 0) return 0;
        uint256 loss = GAME.lossOf(k, account);
        if (loss == 0) return 0;
        uint256 product = windowBudget(k) * loss;
        share = product / total;
        uint256 scaled = _dustScaled[k] + (product - share * total);
        if (scaled >= total) {
            miningDust += scaled / total;
            scaled %= total;
        }
        _dustScaled[k] = scaled;
    }

    function _previewBase(uint256 k, address account) private view returns (uint256) {
        uint256 total = GAME.totalEligibleLoss(k);
        if (total == 0) return 0;
        return windowBudget(k) * GAME.lossOf(k, account) / total;
    }

    // ================================================================= VESTING
    function grantsOf(address account) external view returns (Grant[] memory) {
        return _grants[account];
    }

    function grantCount(address account) external view returns (uint256) {
        return _grants[account].length;
    }

    function vestedOf(Grant memory g) public view returns (uint256) {
        if (block.timestamp >= uint256(g.start) + VESTING) return g.amount;
        return uint256(g.amount) * (block.timestamp - g.start) / VESTING;
    }

    /// @notice Vested HAMSTER `account` can withdraw now across its grants.
    function withdrawableVested(address account) external view returns (uint256 due) {
        Grant[] storage gs = _grants[account];
        for (uint256 i = _accounts[account].grantCursor; i < gs.length; ++i) {
            due += vestedOf(gs[i]) - gs[i].withdrawn;
        }
    }

    /// @notice Withdraws vested HAMSTER from up to `maxGrants` grants (oldest first). Withdrawn tokens
    /// stop counting as weight.
    function withdrawVested(uint256 maxGrants) external nonReentrant {
        if (address(token) == address(0)) revert NotBound();
        Account storage a = _accounts[msg.sender];
        Grant[] storage gs = _grants[msg.sender];
        if (maxGrants > MAX_GRANTS_PER_CALL) maxGrants = MAX_GRANTS_PER_CALL;
        uint256 due;
        uint256 i = a.grantCursor;
        uint256 n;
        for (; i < gs.length && n < maxGrants; ++i) {
            Grant storage g = gs[i];
            uint256 vested = vestedOf(g);
            uint256 part = vested - g.withdrawn;
            if (part > 0) {
                g.withdrawn = uint128(vested);
                due += part;
            }
            if (vested == g.amount) {
                if (i == a.grantCursor) a.grantCursor = i + 1;
            }
            ++n;
        }
        if (due == 0) revert NothingToClaim();
        _sync();
        _settle(msg.sender);
        a.grantBalance -= due;
        totalGrantBalance -= due;
        totalWeight -= due;
        _push(address(token), msg.sender, due);
        emit GrantWithdrawn(msg.sender, due);
    }

    // ================================================================= STAKING
    /// @notice Stakes liquid HAMSTER. Weight starts earning after the 24-hour warm-up, at the next
    /// game-window boundary (`activationTime`). Staking again during a warm-up merges the amounts and
    /// restarts the warm-up for the merged pending amount.
    function stake(uint256 amount) external nonReentrant {
        if (address(token) == address(0)) revert NotBound();
        if (amount < MIN_STAKE) revert BelowMinimum();
        _sync();
        _settle(msg.sender);
        Account storage a = _accounts[msg.sender];
        _pull(address(token), msg.sender, amount);
        uint64 at = activationTime(block.timestamp);
        if (a.pending > 0) pendingAt[a.pendingActivateAt] -= a.pending;
        a.pending += amount;
        a.pendingActivateAt = at;
        pendingAt[at] += a.pending;
        totalStaked += amount;
        if (queueTail == queueHead || _queue[queueTail - 1] != at) _queue[queueTail++] = at;
        emit Staked(msg.sender, amount, at);
    }

    /// @notice When stake made at time `t` starts earning: the first window boundary at or after t + 24h.
    function activationTime(uint256 t) public pure returns (uint64) {
        uint256 offset = GENESIS % ACTIVATION_GRID;
        uint256 x = t + WARMUP - offset;
        return uint64((x + ACTIVATION_GRID - 1) / ACTIVATION_GRID * ACTIVATION_GRID + offset);
    }

    /// @notice Stops weight immediately; tokens release 24 hours later via `withdrawUnstaked`.
    function requestUnstake(uint256 amount) external nonReentrant {
        if (amount == 0) revert InvalidAmount();
        _sync();
        _settle(msg.sender);
        Account storage a = _accounts[msg.sender];
        if (a.active < amount) revert InsufficientStake();
        a.active -= amount;
        totalWeight -= amount;
        _queueUnstake(msg.sender, amount);
    }

    /// @notice Cancels the whole pending (warm-up) stake into the 24-hour unstake queue.
    function cancelPendingStake() external nonReentrant {
        _sync();
        _settle(msg.sender);
        Account storage a = _accounts[msg.sender];
        uint256 amount = a.pending;
        if (amount == 0) revert InvalidAmount();
        pendingAt[a.pendingActivateAt] -= amount;
        a.pending = 0;
        a.pendingActivateAt = 0;
        _queueUnstake(msg.sender, amount);
    }

    function _queueUnstake(address account, uint256 amount) private {
        uint64 releaseAt = uint64(block.timestamp) + UNSTAKE_DELAY;
        totalStaked -= amount;
        totalUnstaking += amount;
        _unstakes[account].push(Unstake(uint128(amount), releaseAt));
        emit UnstakeRequested(account, amount, releaseAt);
    }

    /// @notice Releases every matured unstake request of the caller.
    function withdrawUnstaked() external nonReentrant {
        Account storage a = _accounts[msg.sender];
        Unstake[] storage us = _unstakes[msg.sender];
        uint256 due;
        uint256 i = a.unstakeCursor;
        for (; i < us.length; ++i) {
            if (us[i].releaseAt > block.timestamp) break;
            due += us[i].amount;
        }
        if (due == 0) revert NothingToClaim();
        a.unstakeCursor = i;
        totalUnstaking -= due;
        _push(address(token), msg.sender, due);
        emit Unstaked(msg.sender, due);
    }

    /// @notice Pays the caller's earned IMD.
    function claimRewards() external nonReentrant {
        _sync();
        _settle(msg.sender);
        Account storage a = _accounts[msg.sender];
        uint256 amount = a.accrued;
        if (amount == 0) revert NothingToClaim();
        a.accrued = 0;
        totalRewardsClaimed += amount;
        _push(IMD, msg.sender, amount);
        emit RewardsClaimed(msg.sender, amount);
    }

    /// @notice Brings the reward accumulator and due activations up to now. Never required: every
    /// state-changing entry point syncs itself. Useful before reading `pendingRewards`.
    function sync() external nonReentrant {
        _sync();
    }

    // ----------------------------------------------------------------- reward sources
    /// @notice The hook's swap share: streamed to weight over 7 days. A deposit during a running
    /// stream merges with the leftover; the merged end is the amount-weighted average of the old end
    /// and now + 7 days, so small deposits cannot stretch the leftover.
    function depositRewards(uint256 amount) external nonReentrant {
        if (amount == 0) revert InvalidAmount();
        _sync();
        _pull(IMD, msg.sender, amount);
        uint64 end = _addToStream(stream, amount, STREAM_DURATION);
        emit RewardsDeposited(msg.sender, amount, end);
    }

    /// @notice The anti-snipe tax share: added to the perpetual drip pot (1% of the remainder per day).
    function depositDrip(uint256 amount) external nonReentrant {
        if (amount == 0) revert InvalidAmount();
        _sync();
        _pull(IMD, msg.sender, amount);
        dripPot += amount;
        emit DripDeposited(msg.sender, amount, dripPot);
    }

    /// @notice Pulls the vault's staking balance from the game. The first pull (the pre-vault backlog)
    /// streams over 30 days; later pulls join the 7-day stream. Anyone may call.
    function pullFromGame() external nonReentrant {
        _sync();
        uint256 before = IERC20(IMD).balanceOf(address(this));
        GAME.withdraw();
        uint256 amount = IERC20(IMD).balanceOf(address(this)) - before;
        if (amount == 0) revert NothingToClaim();
        bool first = !backlogPulled;
        uint64 end;
        if (first) {
            backlogPulled = true;
            end = _addToStream(backlog, amount, BACKLOG_DURATION);
        } else {
            end = _addToStream(stream, amount, STREAM_DURATION);
        }
        emit GamePulled(amount, first, end);
    }

    function _addToStream(Stream storage s, uint256 amount, uint64 duration) private returns (uint64 end) {
        uint256 remaining = s.remaining;
        uint256 fresh = block.timestamp + duration;
        if (remaining == 0 || s.end <= block.timestamp) {
            end = uint64(fresh);
        } else {
            end = uint64((remaining * s.end + amount * fresh) / (remaining + amount));
        }
        s.remaining = remaining + amount;
        s.end = end;
    }

    // ----------------------------------------------------------------- accounting core
    /// @dev Brings the global accumulator to now: processes due activation times in order (each at its
    /// own time, recording the accumulator there), then advances to the present. Activation times sit
    /// on the hourly grid and every stake is itself a sync, so at most ~26 can be due at once.
    function _sync() private {
        uint256 head = queueHead;
        uint256 tail = queueTail;
        while (head < tail) {
            uint64 at = _queue[head];
            if (at > block.timestamp) break;
            _advance(at);
            _rpwAt[at] = rewardPerWeight;
            totalWeight += pendingAt[at];
            delete pendingAt[at];
            delete _queue[head];
            ++head;
        }
        queueHead = head;
        _advance(uint64(block.timestamp));
    }

    /// @dev Flows rewards from `lastSync` to `t`. With zero weight every source pauses: streams extend
    /// their end and the drip pot does not decay, so nothing is ever paid to the first staker at once.
    function _advance(uint64 t) private {
        uint64 last = lastSync;
        if (t <= last) return;
        uint256 dt = t - last;
        if (totalWeight == 0) {
            if (stream.remaining > 0) stream.end += uint64(dt);
            if (backlog.remaining > 0) backlog.end += uint64(dt);
            lastSync = t;
            return;
        }
        uint256 paid = _flow(stream, last, t) + _flow(backlog, last, t);
        uint256 pot = dripPot;
        if (pot > 0) {
            uint256 kept = pot * _decay(dt) / ONE;
            paid += pot - kept;
            dripPot = kept;
        }
        if (paid > 0) {
            rewardPerWeight += paid * ACC / totalWeight;
            totalRewardsAccrued += paid;
        }
        lastSync = t;
    }

    function _flow(Stream storage s, uint64 last, uint64 t) private returns (uint256 paid) {
        uint256 remaining = s.remaining;
        if (remaining == 0 || s.end <= last) return 0;
        if (t >= s.end) {
            paid = remaining;
        } else {
            paid = remaining * (t - last) / (s.end - last);
        }
        s.remaining = remaining - paid;
    }

    /// @dev Called only after `_sync`. A pending stake whose activation time has passed was already
    /// added to total weight by `_sync`; here it is credited from the accumulator at that time.
    function _settle(address account) private {
        Account storage a = _accounts[account];
        uint256 w = a.active + a.grantBalance;
        uint256 paid = a.rewardPerWeightPaid;
        uint64 at = a.pendingActivateAt;
        if (a.pending > 0 && at <= block.timestamp) {
            uint256 rpwAt = _rpwAt[at];
            if (w > 0) a.accrued += w * (rpwAt - paid) / ACC;
            paid = rpwAt;
            uint256 amount = a.pending;
            a.pending = 0;
            a.pendingActivateAt = 0;
            a.active += amount;
            w += amount;
            emit StakeActivated(account, amount, at);
        }
        uint256 rpw = rewardPerWeight;
        if (w > 0) a.accrued += w * (rpw - paid) / ACC;
        a.rewardPerWeightPaid = rpw;
    }

    /// @notice DRIP_FACTOR ^ dt in 1e18 fixed point.
    function _decay(uint256 dt) internal pure returns (uint256 result) {
        result = ONE;
        uint256 b = DRIP_FACTOR;
        while (dt > 0) {
            if (dt & 1 == 1) result = result * b / ONE;
            b = b * b / ONE;
            dt >>= 1;
        }
    }

    // ================================================================= SQUEEK BOOST
    /// @notice Schedules boost activation for the canonical Squeek collection; ready 12 hours later.
    function scheduleBoost(address collection_) external onlyTeam {
        if (collection_ == address(0)) revert ZeroAddress();
        if (address(collection) != address(0)) revert BoostAlreadyActive();
        if (boostSwept) revert BoostSweptAlready();
        scheduledCollection = collection_;
        boostReadyAt = uint64(block.timestamp) + TIMELOCK;
        emit BoostScheduled(collection_, boostReadyAt);
    }

    /// @notice Activates the boost once the timelock has passed. The collection must be an ERC-721
    /// contract (ERC-165 check on first use).
    function activateBoost(address collection_) external onlyTeam {
        if (address(collection) != address(0)) revert BoostAlreadyActive();
        if (boostSwept) revert BoostSweptAlready();
        if (scheduledCollection == address(0) || scheduledCollection != collection_) revert NothingScheduled();
        if (block.timestamp < boostReadyAt) revert TimelockNotReady();
        if (collection_.code.length == 0) revert BadCollection();
        (bool ok, bytes memory ret) =
            collection_.staticcall(abi.encodeCall(IERC721.supportsInterface, (ERC721_INTERFACE)));
        if (!ok || ret.length < 32 || !abi.decode(ret, (bool))) revert BadCollection();
        collection = IERC721(collection_);
        boostActivatedAt = uint64(block.timestamp);
        delete scheduledCollection;
        delete boostReadyAt;
        emit BoostActivated(collection_);
    }

    /// @notice If the boost was never activated within 365 days of deployment, anyone may move the
    /// 50M boost bucket into the mining bucket once. The emission curve is unchanged.
    function sweepBoost() external {
        if (address(collection) != address(0)) revert BoostAlreadyActive();
        if (boostSwept) revert BoostSweptAlready();
        if (block.timestamp < uint256(DEPLOYED_AT) + BOOST_DEADLINE) revert TooEarly();
        boostSwept = true;
        delete scheduledCollection;
        delete boostReadyAt;
        if (address(token) != address(0)) {
            miningBucket += boostBucket;
            boostBucket = 0;
        }
        emit BoostSwept(BOOST_BUCKET);
    }

    function boostActive() public view returns (bool) {
        return address(collection) != address(0);
    }

    /// @notice Registers a Squeek the caller owns, without transferring it. Earns boost only for
    /// windows starting at least 24 hours later and is void once `ownerOf` changes. Entries of the
    /// caller's list that another wallet has since registered are pruned here.
    function registerSqueek(uint256 tokenId) external nonReentrant {
        if (!boostActive()) revert BoostNotActive();
        if (collection.ownerOf(tokenId) != msg.sender) revert NotOwnerOfToken();
        if (registrant[tokenId] == msg.sender) revert AlreadyRegistered();
        uint256[] storage list = _squeeks[msg.sender];
        for (uint256 i; i < list.length;) {
            uint256 id = list[i];
            if (id == tokenId || registrant[id] != msg.sender) {
                list[i] = list[list.length - 1];
                list.pop();
            } else {
                ++i;
            }
        }
        if (list.length >= MAX_SQUEEKS) revert TooManyRegistrations();
        address previous = registrant[tokenId];
        if (previous != address(0)) emit SqueekVoided(previous, tokenId);
        registrant[tokenId] = msg.sender;
        registeredAt[tokenId] = uint64(block.timestamp);
        list.push(tokenId);
        emit SqueekRegistered(msg.sender, tokenId);
    }

    /// @notice Permanently voids `tokenId`'s registration if its registrant no longer owns it. Anyone
    /// may call, e.g. the new owner or a keeper watching transfers. The former registrant must
    /// register again and wait a fresh 24 hours. Claims also void any registration they observe.
    function voidSqueek(uint256 tokenId) external {
        address r = registrant[tokenId];
        if (r == address(0)) revert NotRegistered();
        if (_ownerOf(tokenId) == r) revert AlreadyRegistered();
        _void(tokenId, r);
    }

    function _void(uint256 tokenId, address account) private {
        delete registrant[tokenId];
        delete registeredAt[tokenId];
        emit SqueekVoided(account, tokenId);
    }

    /// @dev ownerOf, or address(0) when the call fails (a burned token).
    function _ownerOf(uint256 tokenId) private view returns (address) {
        (bool ok, bytes memory ret) = address(collection).staticcall(abi.encodeCall(IERC721.ownerOf, (tokenId)));
        if (!ok || ret.length < 32) return address(0);
        return abi.decode(ret, (address));
    }

    /// @notice Removes a token from the caller's registration list (frees a slot).
    function unregisterSqueek(uint256 tokenId) external {
        uint256[] storage list = _squeeks[msg.sender];
        uint256 n = list.length;
        for (uint256 i; i < n; ++i) {
            if (list[i] == tokenId) {
                list[i] = list[n - 1];
                list.pop();
                if (registrant[tokenId] == msg.sender) {
                    delete registrant[tokenId];
                    delete registeredAt[tokenId];
                }
                emit SqueekUnregistered(msg.sender, tokenId);
                return;
            }
        }
        revert NotRegistered();
    }

    function squeeksOf(address account) external view returns (uint256[] memory) {
        return _squeeks[account];
    }

    /// @notice True when `tokenId` earns boost for `account` in window `k`: registered by it at least
    /// 24 hours before the window started and still owned by it.
    function squeekEligible(uint256 tokenId, address account, uint256 k) public view returns (bool) {
        if (!boostActive() || registrant[tokenId] != account) return false;
        if (uint256(registeredAt[tokenId]) + REGISTRATION_LEAD > windowStart(k)) return false;
        return _ownerOf(tokenId) == account;
    }

    /// @dev `pendingBoost` is boost already allocated earlier in the same claim batch (not yet in
    /// `boostCommitted`). Registrations whose token left the registrant are voided when seen.
    function _allocateBoost(uint256 k, address account, uint256 wanted, uint256 pendingBoost)
        private
        returns (uint256 got)
    {
        if (!boostActive() || wanted == 0) return 0;
        uint256[] storage list = _squeeks[account];
        if (list.length == 0) return 0;
        uint256 day = uint256(windowStart(k)) / 1 days;
        uint256 left = BOOST_GLOBAL_DAILY_CAP - globalDayUsed[day];
        uint256 bucketLeft = boostBucket - boostCommitted - pendingBoost;
        if (left > bucketLeft) left = bucketLeft;
        if (wanted > left) wanted = left;
        for (uint256 i; i < list.length && got < wanted;) {
            uint256 id = list[i];
            bool stale = registrant[id] != account;
            if (!stale && _ownerOf(id) != account) {
                _void(id, account);
                stale = true;
            }
            if (stale) {
                list[i] = list[list.length - 1];
                list.pop();
                continue;
            }
            ++i;
            if (uint256(registeredAt[id]) + REGISTRATION_LEAD > windowStart(k)) continue;
            uint256 capLeft = BOOST_NFT_DAILY_CAP - nftDayUsed[id][day];
            uint256 take = wanted - got;
            if (take > capLeft) take = capLeft;
            if (take == 0) continue;
            nftDayUsed[id][day] += take;
            got += take;
        }
        if (got > 0) globalDayUsed[day] += got;
    }

    /// @dev Pure preview of `_allocateBoost`.
    function _previewBoost(uint256 k, address account, uint256 wanted) private view returns (uint256 got) {
        if (!boostActive() || wanted == 0) return 0;
        uint256[] storage list = _squeeks[account];
        uint256 day = uint256(windowStart(k)) / 1 days;
        uint256 left = BOOST_GLOBAL_DAILY_CAP - globalDayUsed[day];
        uint256 bucketLeft = boostBucket - boostCommitted;
        if (left > bucketLeft) left = bucketLeft;
        if (wanted > left) wanted = left;
        for (uint256 i; i < list.length && got < wanted; ++i) {
            uint256 id = list[i];
            if (!squeekEligible(id, account, k)) continue;
            uint256 capLeft = BOOST_NFT_DAILY_CAP - nftDayUsed[id][day];
            uint256 take = wanted - got;
            if (take > capLeft) take = capLeft;
            got += take;
        }
    }

    // ================================================================= VIEWS
    struct MiningView {
        uint256 cumulativeLoss;
        uint256 era;
        uint256 ratePerImd; // HAMSTER per IMD now (whole tokens)
        uint256 nextHalvingAtLoss;
        uint256 emitted;
        uint256 miningBucket;
        uint256 miningCommitted;
        uint256 miningLeft;
        uint256 boostBucket;
        uint256 boostCommitted;
        uint256 boostLeft;
        uint256 miningDust;
    }

    struct StakeView {
        uint256 active;
        uint256 pending;
        uint64 pendingActivateAt;
        uint256 grantBalance;
        uint256 weight;
        uint256 pendingRewards;
        uint256 unstaking;
        uint256 withdrawableUnstake;
        uint256 grantCursor;
        uint256 unstakeCursor;
    }

    struct RewardsView {
        uint256 totalWeight;
        uint256 rewardPerWeight;
        uint64 lastSync;
        uint256 streamRemaining;
        uint64 streamEnd;
        uint256 backlogRemaining;
        uint64 backlogEnd;
        uint256 dripPot;
        uint256 dripPerDay;
        uint256 pendingActivations;
        uint256 totalRewardsAccrued;
        uint256 totalRewardsClaimed;
    }

    /// @notice What a claim of window `k` for `account` would grant right now: base and boost.
    function claimableMined(uint256 k, address account) external view returns (uint256 base, uint256 boost) {
        if (claimed[k][account] || k >= GAME.nextFinalizeWindow()) return (0, 0);
        base = _previewBase(k, account);
        boost = _previewBoost(k, account, base * BOOST_PCT / 100);
    }

    function miningInfo() external view returns (MiningView memory v) {
        v.cumulativeLoss = GAME.cumulativeLoss();
        v.era = v.cumulativeLoss / HALVING_LOSS;
        v.ratePerImd = BASE_RATE >> v.era;
        v.nextHalvingAtLoss = (v.era + 1) * HALVING_LOSS;
        v.emitted = emissionAt(v.cumulativeLoss);
        v.miningBucket = miningBucket;
        v.miningCommitted = miningCommitted;
        v.miningLeft = miningBucket - miningCommitted;
        v.boostBucket = boostBucket;
        v.boostCommitted = boostCommitted;
        v.boostLeft = boostBucket - boostCommitted;
        v.miningDust = miningDust;
    }

    function stakeInfo(address account) external view returns (StakeView memory v) {
        Account storage a = _accounts[account];
        v.active = a.active;
        v.pending = a.pending;
        v.pendingActivateAt = a.pendingActivateAt;
        if (v.pending > 0 && v.pendingActivateAt <= block.timestamp) {
            v.active += v.pending;
            v.pending = 0;
            v.pendingActivateAt = 0;
        }
        v.grantBalance = a.grantBalance;
        v.weight = v.active + v.grantBalance;
        v.pendingRewards = pendingRewards(account);
        Unstake[] storage us = _unstakes[account];
        for (uint256 i = a.unstakeCursor; i < us.length; ++i) {
            v.unstaking += us[i].amount;
            if (us[i].releaseAt <= block.timestamp) v.withdrawableUnstake += us[i].amount;
        }
        v.grantCursor = a.grantCursor;
        v.unstakeCursor = a.unstakeCursor;
    }

    function unstakesOf(address account) external view returns (Unstake[] memory) {
        return _unstakes[account];
    }

    /// @notice IMD `account` could claim now. Exact when no activation time has passed since the last
    /// sync; otherwise it projects without that weight (call `sync()` first for an exact figure).
    function pendingRewards(address account) public view returns (uint256) {
        Account storage a = _accounts[account];
        uint256 w = a.active + a.grantBalance;
        uint256 paid = a.rewardPerWeightPaid;
        uint256 accrued = a.accrued;
        if (a.pending > 0 && a.pendingActivateAt <= lastSync) {
            uint256 rpwAt = _rpwAt[a.pendingActivateAt];
            accrued += w * (rpwAt - paid) / ACC;
            paid = rpwAt;
            w += a.pending;
        }
        uint256 rpw = _projectedRewardPerWeight();
        return accrued + (w == 0 ? 0 : w * (rpw - paid) / ACC);
    }

    function _projectedRewardPerWeight() private view returns (uint256 rpw) {
        rpw = rewardPerWeight;
        uint64 last = lastSync;
        if (block.timestamp <= last || totalWeight == 0) return rpw;
        uint64 t = uint64(block.timestamp);
        uint256 paid = _flowPreview(stream, last, t) + _flowPreview(backlog, last, t);
        if (dripPot > 0) paid += dripPot - dripPot * _decay(t - last) / ONE;
        rpw += paid * ACC / totalWeight;
    }

    function _flowPreview(Stream storage s, uint64 last, uint64 t) private view returns (uint256) {
        if (s.remaining == 0 || s.end <= last) return 0;
        if (t >= s.end) return s.remaining;
        return s.remaining * (t - last) / (s.end - last);
    }

    function rewardsInfo() external view returns (RewardsView memory v) {
        v.totalWeight = totalWeight;
        v.rewardPerWeight = rewardPerWeight;
        v.lastSync = lastSync;
        v.streamRemaining = stream.remaining;
        v.streamEnd = stream.end;
        v.backlogRemaining = backlog.remaining;
        v.backlogEnd = backlog.end;
        v.dripPot = dripPot;
        v.dripPerDay = dripPot / 100;
        v.pendingActivations = queueTail - queueHead;
        v.totalRewardsAccrued = totalRewardsAccrued;
        v.totalRewardsClaimed = totalRewardsClaimed;
    }

    /// @notice IMD the vault holds that it owes: undistributed streams and pot plus distributed, unclaimed rewards.
    function trackedImd() external view returns (uint256) {
        return stream.remaining + backlog.remaining + dripPot + totalRewardsAccrued - totalRewardsClaimed;
    }

    /// @notice HAMSTER the vault holds that it owes: buckets (less what left as withdrawn grants) and stakes.
    function trackedHamster() external view returns (uint256) {
        return miningBucket + boostBucket - miningCommitted - boostCommitted + totalGrantBalance + totalStaked
            + totalUnstaking;
    }

    // ================================================================= token helpers
    function _pull(address asset, address from, uint256 amount) private {
        uint256 before = IERC20(asset).balanceOf(address(this));
        _call(asset, abi.encodeCall(IERC20.transferFrom, (from, address(this), amount)));
        if (IERC20(asset).balanceOf(address(this)) - before != amount) revert TransferFailed();
    }

    function _push(address asset, address to, uint256 amount) private {
        _call(asset, abi.encodeCall(IERC20.transfer, (to, amount)));
    }

    function _call(address asset, bytes memory data) private {
        (bool ok, bytes memory ret) = asset.call(data);
        if (!ok || (ret.length != 0 && !abi.decode(ret, (bool))) || (ret.length == 0 && asset.code.length == 0)) {
            revert TransferFailed();
        }
    }
}
