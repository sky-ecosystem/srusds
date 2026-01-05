# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build and Test Commands

```bash
# Build contracts
forge build

# Run all tests (requires ETH_RPC_URL for fork tests)
ETH_RPC_URL=<mainnet_rpc_url> forge test

# Run a specific test file
ETH_RPC_URL=<mainnet_rpc_url> forge test --match-path test/SrUsds-integration.t.sol

# Run a specific test function
ETH_RPC_URL=<mainnet_rpc_url> forge test --match-test testDeposit

# Run tests with upgrade validation (slower, validates storage layout)
ETH_RPC_URL=<mainnet_rpc_url> VALIDATE=true forge test

# Run ERC4626 conformance tests (no fork needed)
forge test --match-path test/SrUsds-erc4626.t.sol
```

## Architecture Overview

This is a MakerDAO Solidity project implementing **srUSDS (Senior Risk USDS)** - a tokenized wrapper around sUSDS with LCTS (Liquidity Constrained Token Standard) queue-based deposit/redeem mechanism.

### Core Contracts

- **SrUsds** (`src/SrUsds.sol`): ERC20 token with ERC4626-like interface. UUPS upgradeable proxy. Holds sUSDS as backing asset. Key state: `chi` (rate accumulator in RAY), `rho` (last settle timestamp). Deposit/redeem are `auth`-gated.

- **SrUsdsHandler** (`src/SrUsdsHandler.sol`): Manages cycles (epochs) and coordinates LCTS queue settlement. Each cycle has: `end` timestamp, `settleAmt` (chi adjustment), `depositCapacity`, `withdrawCapacity`, and resulting `chi`.

- **LCTSDepositQueue** (`src/LCTSDepositQueue.sol`): Generic queue for asset → vault share conversions. Users deposit sUSDS, receive internal shares representing queue position, get srUSDS over time as capacity is allocated. Implements generation-based proportional distribution.

- **LCTSWithdrawQueue** (`src/LCTSWithdrawQueue.sol`): Generic queue for vault share → asset conversions. Users deposit srUSDS, receive sUSDS over time as capacity is allocated.

- **SrUsdsSettler** (`src/SrUsdsSettler.sol`): Permissioned module for calling `plan()` on Handler. Has `buds` (facilitators), `maxMint`/`maxCut`/`maxDepositCapacity`/`maxWithdrawCapacity` limits, `zzz` buffer time, and `bad` circuit breaker.

- **SrUsdsMom** (`src/SrUsdsMom.sol`): Emergency governance module. Can halt settler, zero limits, remove facilitators, or zero settlement parameters.

### Key Concepts

- **RAY math**: Rate calculations use RAY (10^27) precision
- **WAD math**: LCTS queues use WAD (10^18) for rewardPerToken
- **chi**: Rate accumulator - srUSDS shares × chi / RAY = sUSDS assets
- **Generation**: LCTS concept - cohort of depositors sharing capacity proportionally
- **rewardPerToken/rewardDebt**: Accumulator pattern ensuring fair reward distribution
- **Auth pattern**: `wards` mapping for admin access, `rely`/`deny` to manage

### Handler User Functions

Users interact with queues through the Handler (queues are auth-gated):

```solidity
// Deposit queue (sUSDS/USDS → srUSDS)
depositUsds(cId, usdsAmt, receiver)           // Deposit USDS (converted to sUSDS internally)
depositSusds(cId, susdsAmt, receiver)         // Deposit sUSDS directly
claimDeposit(to)                              // Claim srUSDS rewards
claimDepositAndExitAsSusds(to)                // Exit → sUSDS + srUSDS
claimDepositAndExitAsUsds(to)                 // Exit → USDS + srUSDS

// Redeem queue (srUSDS → sUSDS/USDS)
redeem(cId, srUsdsAmt, receiver)              // Queue srUSDS for redemption
claimRedeemAsSusds(to)                        // Claim sUSDS
claimRedeemAsUsds(to)                         // Claim USDS (converted from sUSDS)
claimRedeemAsSusdsAndExit(to)                 // Exit → srUSDS + sUSDS
claimRedeemAsUsdsAndExit(to)                  // Exit → srUSDS + USDS
```

Entry functions (`deposit*`, `redeem`) require `cId` matching current cycle for front-running protection.

### LCTS Queue Flow

```
# Deposit flow (sUSDS → srUSDS)
User -> Handler.depositSusds(cId, amt, receiver)  # Queue sUSDS for conversion
Facilitator -> Settler.plan(...)                   # Set capacities
Anyone (after cycle.end) -> Handler.settle(cId)   # Process queues
User -> Handler.claimDeposit(to)                  # Get srUSDS rewards
User -> Handler.claimDepositAndExitAsSusds(to)    # Exit with sUSDS + srUSDS

# Redeem flow (srUSDS → sUSDS)
User -> Handler.redeem(cId, amt, receiver)        # Queue srUSDS for redemption
... (same settlement flow)
User -> Handler.claimRedeemAsSusds(to)            # Get sUSDS rewards
```

### Settlement Flow

1. `Settler.plan(settleAmt, depositCapacity, withdrawCapacity)` - Set cycle parameters
2. `Handler.settle(cId)` (after cycle end):
   - Mint/burn sUSDS based on settleAmt (affects chi)
   - Call `srusds.settle()` to update chi
   - Call `depositQueue.settle(capacity)` - converts sUSDS to srUSDS
   - Call `withdrawQueue.settle(capacity)` - converts srUSDS to sUSDS
   - Advance to next cycle

### Deployment

Deploy scripts in `deploy/`:
- `SrUsdsDeploy.sol`: Deploys all contracts (SrUsds, queues, Handler, Settler, Mom)
- `SrUsdsInit.sol`: Initializes permissions and registers in MakerDAO chainlog
- `SrUsdsInstance.sol`: Struct holding deployed addresses

### Dependencies

Uses MakerDAO ecosystem libraries via `lib/`:
- `openzeppelin-contracts-upgradeable`: UUPS proxy pattern
- `token-tests`: ERC20/permit test helpers
- `erc4626-tests`: ERC4626 conformance tests
- `openzeppelin-foundry-upgrades`: Upgrade safety validation
