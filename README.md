# LCTS: Senior Risk USDS (`srUSDS`)

A yield-bearing token backed by sUSDS, entered and exited through asynchronous queues that are settled on a fixed schedule. srUSDS holders provide risk capital to Sky: each settlement credits them a premium on top of the Sky Savings Rate, and charges them losses reported by the facilitator, up to the full backing. It is built on the Liquidity Constrained Token Standard (LCTS), which converts queued requests in batches as capacity allows, sharing each conversion pro rata among everyone waiting. The request, cancel and claim flow is inspired by ERC-7540 (asynchronous vaults) and ERC-7575 (a vault with a separate share token), without implementing them fully.

The system consists of four contracts:

| Contract | Role |
| --- | --- |
| **`SrUsds`** | The `srUSDS` token. An upgradeable (UUPS) ERC-20 whose price in sUSDS (`chi`) moves with each settlement's gain or loss. Holds the sUSDS backing every srUSDS in existence. |
| **`SrUsdsQueues`** | The vault users interact with. An upgradeable (UUPS) contract with a deposit queue (sUSDS → srUSDS) and a redeem queue (srUSDS → sUSDS). Holds everything owed to users: pending requests and converted amounts not yet claimed. |
| **`SrUsdsBeam`** | The facilitator's entry point. Lets an approved facilitator settle the queues within configured limits, and can be halted. |
| **`SrUsdsMom`** | Emergency module. Can halt the Beam without a governance delay. |

`srUSDS` is a standard ERC-20 with 18 decimals and EIP-2612 `permit` (EOA and ERC-1271 signatures). Transfers to the zero address or to the token itself are rejected.

---

## User Functions (`SrUsdsQueues`)

Roles follow ERC-7540: `owner` provides the tokens of a request, `controller` owns the request, and `receiver` gets the tokens on cancel or claim. Requests and cancellations revert while the queues are locked for settlement; claims work at any time.

#### `queueDeposit(assets, controller, owner, referral)`

- Takes `assets` sUSDS from `owner` into the deposit queue, credited to `controller`.
- `msg.sender` must be `owner` or its operator, and `owner` must have approved `SrUsdsQueues` for sUSDS.
- Emits `QueueDeposit` and `Referral` (with the integrator's `referral` code).

#### `queueRedeem(shares, controller, owner)`

- Takes `shares` srUSDS from `owner` into the redeem queue, credited to `controller`.
- `msg.sender` must be `owner` or its operator, and `owner` must have approved `SrUsdsQueues` for srUSDS.
- Emits `QueueRedeem`.

#### `cancelDeposit(receiver, controller)` / `cancelRedeem(receiver, controller)`

- Returns the `controller`'s whole **pending** sUSDS (or srUSDS) to `receiver`. Anything already converted stays claimable.
- `msg.sender` must be `controller` or its operator.
- Returns 0, without reverting, when nothing is pending: no request was made, it was already cancelled, or its generation has been fully converted.

#### `claimDeposit(shares, receiver, controller)` / `claimRedeem(assets, receiver, controller)`

- Sends converted srUSDS (or sUSDS) to `receiver`. `type(uint256).max` claims everything.
- `msg.sender` must be `controller` or its operator.

#### `setOperator(operator, approved)`

- Lets `operator` act as `owner` or `controller` on behalf of `msg.sender`, including choosing any `receiver`.

---

## Settlement

### Schedule

Settlements happen on scheduled **settlement days**, every `period` days starting from `startDay`. On a settlement day, the queues lock for a daily window `[lockTimeBgn, lockTimeEnd)` (seconds into the day, UTC) until the facilitator settles:

```
 settlement day
 00:00 ──────────── lockTimeBgn ════════════ settle() ──────── lockTimeEnd ──────── 24:00
        open:                     locked:                open again:            open
        queue, cancel, claim      claim only             queue, cancel, claim
```

- **Before the window**, users can queue and cancel freely. Planning happens off-chain against the queue sizes at this point.
- **While locked**, requests and cancellations revert, so the queues can't change under the facilitator's plan.
- If nobody settles, the queues reopen at `lockTimeEnd` and that cycle converts nothing.

The backing always sits in `SrUsds` as sUSDS, so capacity is not a liquidity limit: it controls how fast risk capital can enter and leave.

### `settle(profit, depositCapacity, redeemCapacity)`

The facilitator calls `SrUsdsBeam.settle`, which checks its limits and forwards to `SrUsdsQueues.settle`. Callable once per settlement day, only while locked, it:

1. Records the day as settled, which reopens the queues for the rest of the window.
2. Revalues srUSDS by `profit` (in sUSDS), by changing `chi` in `SrUsds`:
   - **Gain**: new USDS is generated through `vat.suck`, charged to the vow, and converted into exactly `profit` sUSDS for the backing. `chi` increases by `profit * RAY / totalSupply`, rounded down.
   - **Loss**: up to the full backing in sUSDS is redeemed for USDS and returned to the vow. `chi` decreases by the amount removed, rounded up, and a total loss leaves it at 0.
   - With no srUSDS outstanding (such as the first settlement after launch), nothing is revalued.
3. Converts up to `depositCapacity` sUSDS from the deposit queue into srUSDS, at the new price.
4. Converts up to `redeemCapacity` srUSDS from the redeem queue into sUSDS, at the same price.

Because the price is updated before converting, pending redeems take part in the cycle's gain or loss, while pending deposits enter at the new price. Rounding always favors the backing, so `sUSDS balance ≥ totalSupply * chi / RAY` always holds.

The Beam bounds each settlement: `profit ≤ maxMint` for gains, `-profit ≤ maxCut` for losses, `depositCapacity ≤ maxDepositCapacity` and `redeemCapacity ≤ maxRedeemCapacity`. It only accepts approved facilitators (`buds`), and only while it is not halted.

---

## Mechanics

### Price (`chi`)

- `chi` is the price of one srUSDS in sUSDS, stored with 27 decimals (`RAY = 10^27` is 1.0) and starting at 1.0.
- Conversions: `convertToAssets(shares) = shares * chi / RAY`, `convertToShares(assets) = assets * RAY / chi`, and `totalAssets() = totalSupply * chi / RAY`.
- `chi` only changes at settlement. Between settlements srUSDS grows in USDS terms through its sUSDS backing, and only changes in sUSDS terms through the facilitator's reported gains or losses.

### Queues and Generations

Each queue pools all requests into a **generation** that shares every conversion pro rata:

- A request adds the underlying (sUSDS or srUSDS) to the queue and gives the position queue **units** in proportion to it: one per unit of underlying at the generation's current ratio.
- Each settlement converts part or all of the queue. Every position in the generation gets the same fraction: its share of what was converted becomes **claimable**, and the rest stays **pending**.
- Converted amounts are tracked with a per-generation accumulator (`convertedPerUnit`) and credited lazily, each position keeping a `checkpoint` of the accumulator, so a settlement does constant work regardless of how many positions there are.
- When a conversion takes everything that is queued, the generation ends. New requests start the next one; positions in an ended generation keep their claimable balance.
- There is no time priority within a generation: a request that joins later shares the next conversions equally with those that were already waiting, and never receives anything converted before it joined.

**Example.** Alice queues 100 sUSDS and Bob 300. A settlement converts 200, half of the queue: Alice can claim 50 srUSDS with 50 still pending, and Bob 150 with 150 pending. Carol then queues 100. The next settlement converts 150 of the 300 pending, again half: Alice gets 25, Bob 75 and Carol 50.

### Unit Ratio Limit

- A partial conversion removes underlying from the queue but keeps all its units, so the units per unit of underlying grow with each partial conversion within a generation. A conversion always uses its full capacity, whatever it leaves behind.
- The ratio is a problem once it gets extreme. A request joining at a ratio of `r` is given `r` units per unit of underlying, and each conversion is credited per unit rounded down to 27 decimals, so a position loses up to `r * 1e-9` wei per token on every conversion. At a ratio of 1e9 that is a wei. With no limit, a conversion that leaves a single wei behind would push the ratio to 1e20 or more, where each conversion loses up to 1e11 wei per token joined (hundreds of tokens on a large queue) and the products in requests and cancels get within a few orders of magnitude of overflowing.
- So requests are accepted only while the ratio is at most `MAX_UNIT_RATIO` (1e9). Past it the generation is **closed**: `queueDeposit` or `queueRedeem` reverts with `queue-closed` until a conversion drains the generation and the next one starts at 1:1. Cancels and claims keep working while it is closed. `isQueueDepositClosed()` and `isQueueRedeemClosed()` report the state.
- The limit is passed by a partial conversion that leaves less than a billionth of the queue behind, or after about 30 conversions of half the queue. A closed queue reopens as soon as the remainder is converted, normally at the next settlement.

### Emergency Halt (`SrUsdsMom`)

- `haltBeam(beam)` sets the Beam's `bad` flag, after which `SrUsdsBeam.settle` reverts. Callable by the Mom's `owner` (the `PauseProxy`) or through its `authority` (the Chief), so governance can halt immediately, without waiting for the governance delay.
- While halted, nothing is settled or converted. Users can still queue, cancel and claim: the queues lock during each window and reopen at `lockTimeEnd`.
- Only governance can lift the halt (`file("bad", 0)` on the Beam). Governance can also settle directly on `SrUsdsQueues`, for example to book a loss.

### Upgradeability

- `SrUsds` and `SrUsdsQueues` sit behind ERC-1967 proxies (UUPS). Upgrades are authorized by their `wards`, i.e. governance through the `PauseProxy`.

---

## Funds Overview

```
                               Users
          queue sUSDS │  ▲ cancel: sUSDS      queue srUSDS │  ▲ cancel: srUSDS
                      │  │ claim:  sUSDS                   │  │ claim:  srUSDS
                      ▼  │                                 ▼  │
 ┌──────────────────────────────────────────────────────────────────────────┐
 │ SrUsdsQueues                                                             │
 │                                                                          │
 │  sUSDS balance                         srUSDS balance                    │
 │  ├─ deposit queue: pending             ├─ redeem queue: pending          │
 │  └─ redeem queue: claimable            └─ deposit queue: claimable       │
 └──────────────────────────────────────────────────────────────────────────┘
        │ settle → deposit conversion:          │ settle → redeem conversion:
        │ sUSDS in, srUSDS minted               │ srUSDS burned, sUSDS out
        │ to SrUsdsQueues                       │ to SrUsdsQueues
        ▼                                       ▼
 ┌──────────────────────────────────────────────────────────────────────────┐
 │ SrUsds                                                                   │
 │                                                                          │
 │  sUSDS balance: backing of all srUSDS ≥ totalSupply × chi / RAY          │
 │                                                                          │
 │  totalSupply covers srUSDS held by:                                      │
 │   • users (claimed, freely transferable)                                 │
 │   • SrUsdsQueues (redeem pending + deposit claimable)                    │
 └──────────────────────────────────────────────────────────────────────────┘
        ▲ gain: vat.suck → USDS → mint sUSDS    │ loss: redeem sUSDS → USDS → join to vow
        │                                       ▼
 ┌──────────────────────────────────────────────────────────────────────────┐
 │ Vat / vow                                                                │
 └──────────────────────────────────────────────────────────────────────────┘
```

---

## Configuration

| Parameter | Contract | Notes |
| --- | --- | --- |
| `lockTimeBgn` | `SrUsdsQueues` | Seconds into the day; `< lockTimeEnd` |
| `lockTimeEnd` | `SrUsdsQueues` | Seconds into the day; `> lockTimeBgn`, `≤ 1 days` |
| `period` | `SrUsdsQueues` | Days between settlement days; `> 0` |
| `startDay` | `SrUsdsQueues` | First settlement day, in days since the epoch |
| `maxMint` | `SrUsdsBeam` | Largest gain per settlement [sUSDS] |
| `maxCut` | `SrUsdsBeam` | Largest loss per settlement [sUSDS] |
| `maxDepositCapacity` | `SrUsdsBeam` | Largest deposit capacity per settlement [sUSDS] |
| `maxRedeemCapacity` | `SrUsdsBeam` | Largest redeem capacity per settlement [srUSDS] |
| `bad` | `SrUsdsBeam` | `1` halts settlement, `0` resumes it |

---

## Roles & Permissions

- **Governance (`PauseProxy`)** is the ward of `SrUsds`, `SrUsdsQueues` and `SrUsdsBeam`, and the owner of `SrUsdsMom`. Acting through executive spells, after the governance delay, it configures the system (`file`), approves facilitators (`kiss`, `diss`), manages wards (`rely`, `deny`), upgrades `SrUsds` and `SrUsdsQueues`, and lifts a halt.
- **The facilitator** is a bud of `SrUsdsBeam`. It calls `SrUsdsBeam.settle` to report each cycle's profit and choose the capacities, within the Beam's limits and only while it is not halted.
- **Users:**
  - Only the owner of the tokens, or its operator, can queue them (`queueDeposit`, `queueRedeem`).
  - Only the controller of a request, or its operator, can cancel or claim it (`cancelDeposit`, `cancelRedeem`, `claimDeposit`, `claimRedeem`).
  - Anyone can approve operators (`setOperator`) and use the srUSDS ERC-20 functions and `permit`.
- **The Chief** is the authority of `SrUsdsMom`, so governance can call `haltBeam` immediately, without waiting for the governance delay.

---

## Considerations

- **Trust in the facilitator.** Within the Beam's limits, the facilitator decides the reported profit and the capacities.
- **Queued redeems keep their exposure.** srUSDS waiting in the redeem queue is still part of the supply and takes part in every settlement's gain or loss until it is converted. sUSDS waiting in the deposit queue only earns the Sky Savings Rate.
- **Pro-rata allocation.** Capacity is shared in proportion to what is queued, with no time priority, so queuing more than needed and cancelling the rest after a settlement gets a larger share. Queue sizes are therefore not a reliable measure of demand.
- **Closed queues.** A queue closes when a partial conversion leaves less than a billionth of it behind, which with ordinary capacities happens by chance only rarely, but can be arranged: a request sized so that the queue exceeds the capacity by a sliver closes the queue to everyone else until the remainder is drained, normally one settlement. Repeating this with a large request pending when the limit is passed keeps the queue closed, and the capacity to the pending requests, until they drain; new requests revert meanwhile instead of waiting. A sliver is visible on-chain before the settlement, so the facilitator can avoid leaving it by choosing the capacity, and if a queue does get held closed, governance can always upgrade `SrUsdsQueues` to end the generation or change the rule.
- **Severe losses.** At a `chi` of 0, or an extremely small one after a near-total loss, converting deposits reverts, so the settlement has to be made with `depositCapacity = 0`. Redemptions keep working, and queued depositors can cancel.
- **Halts stop all conversions.** While the Beam is halted, no deposit or redemption is converted.
- **Not a full ERC-4626 vault.** `SrUsds` exposes ERC-4626 pricing views and the `deposit`/`redeem` used by the queues, but `maxDeposit` and `maxRedeem` are 0 and there is no `mint`, `withdraw` or `preview*`.
- **Upgradeability.** Governance can upgrade `SrUsds` and `SrUsdsQueues`, and so has full control over the funds they hold.
