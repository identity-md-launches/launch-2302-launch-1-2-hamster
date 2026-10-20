# HamsterVault ($HAMSTER launch 1 of 2)

Mining, vesting and staking vault for $HAMSTER on Ethereum mainnet, fed by HamsterHour v2.
One contract, `HamsterVault` (`src/HamsterVault.sol`), with no owner, pause, upgrade or
withdrawal path. TEAM (the launch wallet) holds exactly two one-shot powers: `bindToken` and the
12-hour timelocked boost activation (`scheduleBoost` then `activateBoost`). Launch 2 deploys the
Uniswap v4 hook token HAMSTER (1B supply, 18 decimals) whose `remainderTo` is this vault.

## Build and test

```sh
forge build
FOUNDRY_FUZZ_SEED=0x50322a784a01fe90ed19d0bd7a2c4ea289755f66a15e8249941c21c0c87eba74 forge test
forge fmt --check
```

Solidity 0.8.26, Cancun, optimizer 200 runs, `bytecode_hash = "none"`. The fuzz seed is pinned in
`foundry.toml`. The only dependency is forge-std, vendored as ordinary files under `lib/`. Tests use
no environment variables, FFI or filesystem access; IMD is a mock etched at the real IMD address,
the game is `test/helpers/Mocks.sol:MockGame`, which reproduces the v2 loss-history and pull-balance
surface. The ABI is exported to `abi/HamsterVault.json`. Runtime size is 19,425 bytes.

## Deployment parameters (real addresses only)

| Constructor argument | Value | Source |
| --- | --- | --- |
| `team_` | `$owner` = `0x6cba4751742f6989fa224b2dc5d5d52fcef98a34` | the launch wallet (TEAM) |
| `game_` | `0xe33ab493249a2df0d8c4a71ac54f46d1f7778367` | HamsterHour v2, from the brief |

Chain id 1. IMD `0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7` and the game's window geometry
(genesis `1791847200`, 3600-second windows) are source constants. The constructor is nonpayable,
makes no external calls, needs no initialization and grants nothing to `msg.sender` or
`tx.origin`. `script/Deploy.s.sol` holds the same two values as constants and `test/Deploy.t.sol`
deploys with them on an empty chain. This table is guidance for the separate manifest step; no
`launch.json` is written here.

## After launch (operational responsibilities)

| Step | Who | Call | Value |
| --- | --- | --- | --- |
| 1. Staking recipient on the game | TEAM | `HamsterHour.scheduleStakingRecipient(vault)` then `executeStakingRecipient(vault)` after 12 h | this vault's deployed address |
| 2. Launch 2 | IMD | deploy HAMSTER with `remainderTo = vault` | delivers exactly 800,000,000 HAMSTER |
| 3. Bind | TEAM, once | `bindToken(token)` | the HAMSTER token from launch 2. Requires `totalSupply() == 1e27` and `balanceOf(vault) == 8e26` |
| 4. Hook wiring | launch 2's hook | `depositRewards(amount)` for its 0.5% swap share, `depositDrip(amount)` for 80% of the anti-snipe tax | the hook approves the vault for IMD and calls; both pull with `transferFrom` |
| 5. Boost (optional, within 365 days) | TEAM, once | `scheduleBoost(collection)` then `activateBoost(collection)` after 12 h | the canonical Squeek NFT collection on Ethereum mainnet. Its address was not available to this task and could not be verified here, so it is a TEAM-supplied setting; the vault checks only that it is an ERC-721 contract (ERC-165). Activate before day 365 or anyone may `sweepBoost()` |
| Keepers / anyone | anyone | `pullFromGame()` after fees allocate on the game; `claimMined(windows, account)`; `sync(n)` if ever needed | see below |

Nothing else is configurable. There is no setter for IMD, the game, rates, durations or caps.

## Token bind and buckets

`bindToken(token)` is TEAM-only, once, and requires the full 1e27 supply and exactly 8e26 HAMSTER
already held by the vault. It sets the buckets: **mining 750,000,000** and **boost 50,000,000**.
Claims, staking and grant withdrawals are refused until the token is bound (`NotBound`), but the
game's loss history accrues independently, so every finalized window is claimable afterwards
(retroactive from window 0). If `sweepBoost()` ran before the bind, the bind sets mining 800M and
boost 0.

## Mining

- Curve: `emissionAt(L)` is the cumulative HAMSTER emitted once `L` wei of eligible IMD loss has
  accrued: 20,000 HAMSTER per IMD, halving every 18,750 IMD (`HALVING_LOSS`), computed in closed form
  with floor rounding: `(750M - 750M >> era) + ((L - era * 18,750) * 20,000) >> era`. It is monotone,
  never exceeds 750M, and equals 750M exactly from era 90 on.
- Window budget: `windowBudget(k) = emissionAt(cumulativeLossAfter[k]) - emissionAt(cumulativeLossBefore[k])`,
  which handles any number of halvings crossed inside a window. Budgets telescope, so the sum of all
  budgets equals `emissionAt(cumulativeLoss)` and committed base emissions can never exceed the bucket
  (`BucketExceeded` is a belt-and-braces check).
- Account share: `budget * lossOf(k, account) / totalEligibleLoss[k]`, rounded down. The game
  guarantees the sum of `lossOf` never exceeds `totalEligibleLoss[k]`, so a window never
  over-distributes; hedged positions dilute everyone's share, as the game documents.
- Dust: each claim's rounding remainder (in units of `totalEligibleLoss[k]`) accumulates per window;
  whole tokens move to the `miningDust` bucket, which stays in the vault forever. Dust only exists in
  windows that cross a halving: inside one era a budget is an exact multiple of the total loss.
- `claimMined(windows[], account)`: permissionless, always grants to `account`, once per
  `(window, account)` (`AlreadyClaimed`), at most 48 windows per call (`MAX_CLAIM_BATCH`), only
  finalized windows (`k < game.nextFinalizeWindow()`, else `NotFinalized`), reverts `NothingToClaim`
  when the batch yields zero. The shares depend only on the game's stored history, so no claim order
  changes anyone's amount (tested).

## Vesting

Every claim creates one grant: `amount`, `start = now`, 7-day linear vesting (`VESTING`).
`withdrawVested(maxGrants)` pays the vested, unwithdrawn part of up to 64 grants, oldest first, and
advances a cursor past fully withdrawn grants. Grants are not transferable: they are only a weight
inside the vault until withdrawn. Unvested and vested-unwithdrawn grant balances count as stake
weight immediately (no warm-up) and leave the weight when withdrawn.

## Staking (rewards in IMD only)

- `stake(amount)` (min 1 HAMSTER): pulls liquid HAMSTER; the amount is pending for 24 hours
  (`WARMUP`) and then becomes weight. Staking again during a warm-up merges the pending amount and
  restarts the 24 hours for all of it. `cancelPendingStake()` moves the pending amount into the
  unstake queue.
- `requestUnstake(amount)`: weight stops immediately; the tokens release 24 hours later
  (`UNSTAKE_DELAY`) through `withdrawUnstaked()`, which releases every matured request in order.
- `claimRewards()`: pays the caller's earned IMD.
- Weight = active stake + grant balance. HAMSTER held in the buckets is never weight.

**Exact warm-up without keepers.** Warm-up ends are monotone in staking time, so pending stakes
form a FIFO queue. Every state-changing call first replays the due activations in time order,
advancing the reward accumulator to each activation second before adding its weight, then advances
to now. A stake therefore earns from exactly its warm-up end even if nobody touched the vault for
days (tested in `test_activationIsExactWithoutPoke`). A call processes at most 64 due activations
(`MAX_SYNC`); if more are due it reverts `SyncRequired` and the public `sync(n)` drains them. The
`pendingRewards` view does not replay the queue; call `sync` first for an exact figure while
activations are due.

**Reward sources** (all pro rata by weight over time, with a checkpoint before every weight change):

| Source | Call | Schedule |
| --- | --- | --- |
| (a) game's 5% staker share | `pullFromGame()`, anyone | first pull = the pre-vault backlog, streamed over 30 days; later pulls join the 7-day stream |
| (b) hook's 0.5% swap share | `depositRewards(amount)` | streamed over 7 days; a deposit during a running stream merges the leftover and restarts the 7 days |
| (c) 80% of the anti-snipe tax | `depositDrip(amount)` | perpetual drip: 1% of the remaining pot per day, continuous (`0.99^(dt/86400)` per second, `DRIP_FACTOR`), determined only by time, not by who calls |

**Zero-weight periods.** When total weight is zero every source pauses: streams extend their end by
the paused time and the drip pot does not decay. Rewards wait for the next interval; the first
staker never receives an instant payout (tested, including a gap between stakers).

`trackedImd()` is what the vault owes in IMD (undistributed streams and pot plus distributed,
unclaimed rewards); `trackedHamster()` is what it owes in HAMSTER (buckets less committed, plus grant
balances, stakes and unstaking). Both equal the token balances in the tests.

## Squeek boost (50M, dormant until activated)

- `scheduleBoost(collection)` then, 12 hours later, `activateBoost(collection)`: TEAM only, once.
  The collection must be a contract that reports ERC-721 through ERC-165, checked on first use.
- `registerSqueek(tokenId)`: the current `ownerOf` registers without transferring (max 20 per
  wallet, `unregisterSqueek` frees a slot). A registration earns only for windows that start 24 hours
  or more after it and is void as soon as `ownerOf` changes (a burned token is void, not a revert).
- Boost = 50% of the base mined in the window, capped at 10,000 HAMSTER per NFT per UTC day and
  100,000 per UTC day globally (day = `windowStart(k) / 86400`), and by the 50M bucket. Allocation is
  deterministic: within a claim, a wallet's registered NFTs are filled in registration order; across
  claims, the per-NFT and global daily caps are consumed in claim order. Base mining is never
  affected by the boost or by claim order. Boost vests in the same 7-day grant as the base.
- `sweepBoost()`: if the boost was not activated within 365 days of deployment, anyone may move the
  50M boost bucket into the mining bucket once. The emission curve is unchanged, so under the current
  curve the swept 50M stays in the vault; it only changes the bucket accounting, as the brief asks.

## Views for the site

`claimableMined(k, account)` (base and boost), `windowBudget(k)`, `emissionAt(L)`, `miningInfo()`
(cumulative loss, era, current rate, next halving, emitted, buckets left, dust), `grantsOf`,
`withdrawableVested`, `stakeInfo(account)` (active, pending and its activation time, grant balance,
weight, pending IMD, unstaking and withdrawable unstake), `unstakesOf`, `pendingRewards`,
`rewardsInfo()` (weight, accumulator, stream and backlog state, drip pot and per-day rate, pending
activations), `squeeksOf`, `squeekEligible`, `nftDayUsed`, `globalDayUsed`, `trackedImd`,
`trackedHamster`.

## Chosen values not fixed by the brief

`MIN_STAKE` 1 HAMSTER, `MAX_CLAIM_BATCH` 48 windows, `MAX_SQUEEKS` 20 per wallet, `MAX_SYNC` 64
activations per call, `MAX_GRANTS_PER_CALL` 64, later game pulls join the 7-day stream, re-staking
during a warm-up restarts it, a cancelled pending stake waits the 24-hour unstake delay, boost
allocation order (registration order within a wallet, claim order across wallets), the ERC-165 check
as the only on-chain test of the collection.

## Trust assumptions and open items

- The game's loss history (`lossOf`, `totalEligibleLoss`, cumulative bounds) is trusted as the sole
  source of mining truth; the vault never recomputes it.
- TEAM must pass the canonical Squeek collection to `scheduleBoost`; the vault cannot verify
  canonicality. The 12-hour timelock makes the choice reviewable before it takes effect.
- TEAM must bind the real HAMSTER token; the supply and remainder checks refuse any other token.
- `pullFromGame` only works after TEAM executes the staking recipient on the game.
- The first pull defines the 30-day backlog stream; call it as soon as the recipient is executed.
- Tests are not an audit. An independent adversarial review is required before funds are at risk.
