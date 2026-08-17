# shinyUSDS — draft design notes

Status: **draft, not reviewed, no tests.** Compiles (`forge build`).

`src/shinyusds/` is a deliberate verbatim fork of `src/srusds/` — every srUSDS identifier is
unchanged so the two directories diff cleanly. See the TODO block at the top of each file.

## What it is

An LCTS-queued pooled vault where the backing is deployed by an **external asset manager**
(the Diamond PAU) rather than backstopped by the protocol.

| | `srusds/` | `shinyusds/` |
|---|---|---|
| Backing source | `vat.suck` → mint sUSDS into the token | asset manager returns sUSDS |
| `settle()` | moves assets **and** marks `chi` | marks `chi` only |
| Capital out | — | `take(uint256)` behind a `buds`/`toll` role |
| Loss can be marked while deployed | no | yes |
| Backstop | Sky (the Vat) | none |

### Functional diff, in full

**Vault (`ShinyUsds.sol`)**
1. `settle()` moves no assets. Both `susds` transfers removed.
2. `chi` derived as `newTotalAssets * RAY / supply` rather than as a ratio against the old
   value, so a total loss (`chi == 0`) is recoverable by a later positive settle. The
   original bricked: `deposit()` divides by `chi`, and the old formula could never climb
   back off zero.
3. `require(supply > 0)` in `settle()`; `require(chi > 0)` in `deposit()`.
4. `take(uint256)` added, plus `buds` / `toll` / `kiss` / `diss`.

**Handler (`ShinyUsdsHandler.sol`)**
1. Vat backstop removed entirely: `vat`, `usdsJoin`, `vow`, `RAY`, `VatLike`, `UsdsJoinLike`.
   Constructor drops two args → `(srusds_, depositQueue_, withdrawQueue_)`.
2. Approvals reduced to the USDS→sUSDS user leg and the two queue pulls.
3. `_settle()` is one line: `if (settleAmt_ != 0) srusds.settle(settleAmt_);`
4. All ten user-facing queue functions unchanged.

## Diamond PAU integration

`take(uint256)` sends to `msg.sender` and its selector is `0x4fd9efc4` — identical to
`ISparkVaultLike.take(uint256)` in `diamond-pau/src/facets/spark-vault/SparkVaultFacet.sol`.
So the PAU drives it with **no new facet code**:

- **out**: `SparkVaultFacet.take(vault, amt)` → `ALLOCATOR_ROLE`, bounded by `LIMIT_SPARK_VAULT_TAKE`
- **in**: `TransferAssetFacet.transfer(asset, vault, amt)` → bounded by `LIMIT_ASSET_TRANSFER`

There is deliberately no `give()`. An inbound plain transfer needs no bookkeeping because
`totalAssets()` derives from `chi`, not from the token balance. Same as Spark Vault V2, which
holds $10M against $271M owed.

Required permissions: `wards = { governance, handler, depositQueue, withdrawQueue }`,
`buds = { PAU ALMProxy }`.

---

## Open questions

### 1. Junior economics, senior name — BLOCKING

Removing the vat removed the backstop. srUSDS was *Senior* Risk Capital because Sky topped it
up; that was what `vat.suck` did. shinyUSDS holders now bear 100% of strategy P&L with nothing
beneath them — first-loss capital, i.e. **TEJRC** in the `laniakea-docs` LCTS table
(`smart-contracts/lcts.md:35`), not srUSDS's role.

Either the positioning changes, or something has to sit underneath absorbing losses first.
As drafted it inherits senior branding with junior economics.

### 2. sUSDS as the underlying makes `settleAmt` mean "excess return over SSR"

sUSDS earns the Sky Savings Rate *in place*. The PAU cannot deploy sUSDS into a strategy such
as Arkis; it must redeem sUSDS → USDS → (PSM) → USDC first. So while capital is deployed it
earns no SSR, yet `chi` is denominated in sUSDS, which appreciates on its own.

This is not a leak — the denomination handles it. Worked through: PAU takes 100 sUSDS
(= 105 USDS), Arkis returns 6% → 111.3 USDS. SSR was 5%, so sUSDS is now 1.1025 and 111.3 USDS
buys 100.95 sUSDS. `settleAmt = +0.95`. Holders go 100 → 100.95 sUSDS = 111.3 USDS, exactly
the 6%; the 0.95 is precisely the 1% outperformance over SSR.

Two consequences:

- **`settleAmt` measures excess return over SSR, not raw strategy return.** The operator must
  compute it as a delta in sUSDS-equivalent terms, not as raw USDS P&L converted at spot —
  the latter double-counts SSR into `chi`.
- **`chi` falls whenever the strategy underperforms SSR**, even though holders lost no USDS.
  Correct for an SSR-benchmarked fund, but it will look alarming the first time.

**Question: is SSR the intended benchmark? If not, the underlying should be USDS.**

### 3. `settleAmt` is an unverified assertion

`settle()` moves nothing, so the operator can mark NAV up or down with no on-chain evidence
that the value exists. Bounded only by `LCTSBeam`'s `maxMint` / `maxCut`. Inherent to marking
an off-chain position, but it is the single largest trust assumption in the design and belongs
at the top of any audit brief.

### 4. `take()` is unbounded in-contract

It relies entirely on the PAU's `LIMIT_SPARK_VAULT_TAKE`. That limit recharges over time —
Arkis sits at $20.3M against an originally-configured 5M cap. "The manager can eventually hold
everything" is therefore the design, not an edge case. Confirm that is intended.

### 5. Sequencing is convention only

The asset manager must return at least `withdrawCapacity × chi / RAY` before `settle()`, or
`LCTSWithdrawQueue._convert`'s `redeem` reverts and the entire settlement is lost. Nothing
enforces this on-chain.

### 6. UUPS plus a role that can drain

An upgradeable contract holding user funds, with a `bud` able to move all backing out. Each is
defensible alone; together the governance story needs writing down before audit.

### 7. Which layer is this — TEJRC/TISRC or Halo Unit?

Unresolved, and question 1 is really this one wearing a different hat. Per
`laniakea-docs/synomic-entities/halo-classes.md` the capital stack is
Generator → Prime → Halo, with Units as the connecting tissue. LCTS serves both layers with
different tokens. Naming, directory, and the backstop question all follow from the answer.

---

## Also outstanding

- **No tests.** Do not invest here until Q1 and Q2 are settled — both change the contract.
- **No deploy/init script.** Needs the ward/bud wiring plus PAU rate-limit config.
- **Rename pending** — see the TODO blocks.
- `src/halo/` is untouched at HEAD; it was drafted for a different shape (vault custodies,
  treasury settles P&L) and is not this product.
