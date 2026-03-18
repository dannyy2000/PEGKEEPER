# PEGKEEPER

> A Uniswap v4 hook that gives stablecoin pools real-time cross-chain intelligence — protecting LPs before a depeg hits, not after.

---

## The Problem

Stablecoin pools are the highest TVL pools in DeFi. USDC/USDT, USDC/DAI — they are supposed to be safe.

But they are not.

When USDC depegged to **$0.87** during the SVB banking crisis in March 2023, stablecoin LPs lost billions overnight. The reason was not just the depeg itself — it was that the pool had **no idea it was coming.**

Every stablecoin pool is configured around one assumption: the price will not move. So fees are set at 0.01%, LP ranges are tight around $1.00, and the pool just sits there completely blind to the outside world.

When a depeg arrives, arb bots drain the pool at yesterday's prices while LPs are charged 0.01 cents in fees for the privilege. By the time the pool reflects reality, the damage is already done.

The worst part: **the signals were already there.** USDC was showing depeg pressure across Ethereum, Base, and Arbitrum well before any single pool was drained. But individual pools cannot see other chains. They are blind to every warning sign until the arb bot walks through the door.

**PEGKEEPER gives the pool eyes.**

---

## The Solution

PEGKEEPER is a Uniswap v4 hook purpose-built for stablecoin pools. It combines two key technologies:

- **Reactive Network** — watches stablecoin prices across Ethereum, Base, and Arbitrum simultaneously, 24/7, with no off-chain bots or keepers
- **Unichain** — provides the speed, TEE protection, and cheap execution needed to respond before attackers arrive

The moment Reactive detects depeg pressure across multiple chains simultaneously, it fires an alert to the PEGKEEPER hook on Unichain. The hook then escalates through graduated protection stages — adjusting fees and blocking deposits automatically — before arbitrage bots can exploit the gap.

The result is a stablecoin pool that **actively defends its LPs** instead of waiting to be drained.

---

## How It Works

### Normal Conditions

The pool runs with settings optimized for stability:

- Fees: **0.01%** — tight, as expected for a stablecoin pair
- LP ranges: **narrow** around $1.00 — concentrated for maximum fee efficiency
- Status: **GREEN**

LPs earn steady fees. Nothing unusual happens.

### Reactive Network Detects Early Pressure

Reactive Network has a smart contract deployed that continuously monitors price update events emitted by price feeds on Ethereum, Base, and Arbitrum.

The key filter: Reactive only escalates when depeg pressure is visible on **multiple chains at once**. A single-chain blip is noise. Multi-chain pressure is signal.

```
USDC drops to $0.997 on Ethereum only     → ignored, could be noise
USDC drops to $0.996 on Ethereum + Base  → alert fired, this is real
```

### Graduated Protection Stages

PEGKEEPER does not flip between calm and panic. It responds proportionally.

| Stage | Trigger | Swap Fee | New Deposits |
|-------|---------|----------|--------------|
| GREEN | Price $0.999 – $1.001 | 0.01% | Open |
| YELLOW | Multi-chain pressure, price $0.996 – $0.999 | 0.05% | Open |
| ORANGE | Sustained pressure, price $0.990 – $0.995 | 0.30% | Paused |
| RED | Crisis level, price below $0.985 | 1.00% | Paused |

At RED stage, conservative LPs who opted in at deposit time receive an on-chain withdrawal signal — their position data is emitted as a `ConservativeWithdrawalTriggered` event so they (and any off-chain tooling they use) know to exit before the worst hits.

### Unichain Executes Faster Than Bots

When Reactive fires an alert, PEGKEEPER needs to update pool settings before arb bots react. Unichain's 1-second blocks (soon 250ms) mean the hook's fee update is confirmed in the pool before a bot traveling from mainnet even arrives.

The Trusted Execution Environment (TEE) ensures nobody can see the hook's protection response in the mempool and front-run it. The fee update lands invisibly and is already in place when the bot checks the pool.

### Recovery

As prices stabilize back toward $1.00, PEGKEEPER automatically steps back down through the stages:

```
RED → ORANGE → YELLOW → GREEN
```

Deposits re-open, fees return to normal. LPs can re-enter.

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                     EXTERNAL CHAINS                             │
│                                                                 │
│   Ethereum Mainnet      Base          Arbitrum                  │
│   [Price Feed]          [Price Feed]  [Price Feed]              │
│        │                    │               │                   │
└────────┼────────────────────┼───────────────┼───────────────────┘
         │                    │               │
         └────────────────────┴───────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│                    REACTIVE NETWORK (Lasna)                     │
│                                                                 │
│   ReactiveSender.sol                                            │
│   - Subscribes to price events on all 3 chains                 │
│   - Aggregates signals                                          │
│   - Checks multi-chain threshold conditions                     │
│   - Determines severity level (YELLOW / ORANGE / RED)          │
│   - Fires cross-chain callback to Unichain hook                 │
└──────────────────────────────┬──────────────────────────────────┘
                               │  cross-chain alert
                               │  (severity + price data)
                               ▼
┌─────────────────────────────────────────────────────────────────┐
│                    UNICHAIN (TEE)                               │
│                                                                 │
│   ReactiveMonitor.sol — receives callback, forwards alert       │
│   PegKeeper.sol — Uniswap v4 Hook                               │
│   - Receives alert from Reactive                                │
│   - Updates protection stage                                    │
│   - beforeSwap: applies dynamic fee per stage                   │
│   - beforeAddLiquidity: pauses deposits if ORANGE/RED           │
│   - Manages LP protection profiles                              │
│   - Auto-withdraws conservative LPs at RED                      │
│                                                                 │
│   ┌─────────────────────────────────────┐                       │
│   │     Uniswap v4 Pool (USDC/USDT)     │                       │
│   │     Protected by PEGKEEPER hook     │                       │
│   └─────────────────────────────────────┘                       │
└─────────────────────────────────────────────────────────────────┘
```

---

## Contract Structure

```
pegkeeper/
├── src/
│   ├── PegKeeper.sol              # Main Uniswap v4 hook — fee + deposit management
│   ├── ReactiveMonitor.sol        # Unichain receiver — forwards Reactive alerts to hook
│   ├── ReactiveSender.sol         # Reactive Network contract — cross-chain watcher
│   ├── MockPriceFeed.sol          # Mock price feed for testing and demo
│   ├── MockERC20.sol              # Mock token for testnet pool
│   └── interfaces/
│       ├── IPegKeeper.sol         # Hook interface
│       └── IReactiveMonitor.sol   # Reactive monitor interface
├── test/
│   ├── PegKeeper.t.sol            # Unit tests for hook logic
│   ├── PegKeeperEdgeCases.t.sol   # Edge-case unit tests for hook
│   ├── PegKeeperFuzz.t.sol        # Fuzz tests for hook
│   ├── PegKeeperInvariant.t.sol   # Invariant tests for hook
│   ├── ReactiveMonitor.t.sol      # Unit tests for monitor contract
│   ├── ReactiveMonitorFuzz.t.sol  # Fuzz tests for monitor
│   ├── ReactiveSender.t.sol       # Unit tests for Reactive sender
│   ├── MockPriceFeed.t.sol        # Unit tests for price feed
│   ├── MockPriceFeedFuzz.t.sol    # Fuzz tests for price feed
│   └── MockERC20.t.sol            # Unit tests for mock token
├── script/
│   ├── Deploy.s.sol               # Full Unichain deployment (hook + pool)
│   ├── DeployMockFeeds.s.sol      # Deploy mock price feeds to source chains
│   ├── DeployReactiveSender.s.sol # Deploy Reactive sender to Lasna
│   └── TriggerDepeg.s.sol         # Demo script — simulate a depeg event
├── lib/                           # Forge dependencies
├── foundry.toml
├── .env.example
└── README.md
```

---

## Tech Stack

| Technology | Role |
|---|---|
| Uniswap v4 | Core AMM — hooks modify fee and liquidity behavior |
| Unichain | Deployment chain — fast blocks, TEE, Superchain interop |
| Reactive Network | Cross-chain event monitoring and alert dispatch |
| Foundry | Development, testing, deployment |
| Solidity 0.8.26 | Smart contract language |

---

## Partner Integrations

### Unichain

PEGKEEPER is deployed exclusively on Unichain and relies on three of its core properties:

**1. Speed**
Unichain's 1-second block times (250ms sub-blocks launching soon) are what make the protection viable. When Reactive fires an alert, the hook's fee update must confirm before arb bots traveling from mainnet arrive. On Ethereum's 12-second blocks this race is lost. On Unichain it is won comfortably.

**2. Trusted Execution Environment (TEE)**
The TEE hides the hook's protection response in the mempool until it is already committed. Without this, a sophisticated bot could see PEGKEEPER raising fees and front-run the update — jumping in for one last cheap drain right before the protection lands. The TEE closes that window entirely.

**3. Low Gas**
PEGKEEPER makes frequent micro-adjustments as conditions evolve — nudging fees through stages as Reactive updates come in. Each adjustment is a transaction. On Ethereum mainnet, the cumulative gas cost would eat LP profits. On Unichain it is negligible.

### Reactive Network

Reactive Network provides the cross-chain intelligence layer that PEGKEEPER cannot exist without.

**What it does:**
- Deploys a Reactive Smart Contract that subscribes to price update events on Ethereum, Base, and Arbitrum simultaneously
- Aggregates signals across chains to distinguish real depeg pressure from single-chain noise
- Calculates severity level based on how many chains are showing pressure and how far below peg
- Fires a trustless cross-chain callback to the PEGKEEPER hook on Unichain with the severity and price data

**Why it is essential:**
Without Reactive Network, PEGKEEPER would need off-chain bots or keepers to watch prices — introducing centralization, failure points, and trust assumptions. Reactive makes the entire monitoring and alerting layer fully on-chain and trustless. It is not a cosmetic integration — it is the foundation of the system.

---

## Deployed Contracts

### Unichain Sepolia (Chain ID 1301)

| Contract | Address |
|---|---|
| PegKeeper | [`0xD097AaE843980Da4b8b5D273c154a80b9414DC80`](https://unichain-sepolia.blockscout.com/address/0xD097AaE843980Da4b8b5D273c154a80b9414DC80) |
| ReactiveMonitor | [`0x693eE35A0c3D04b65D58AC075A18941dc212c90b`](https://unichain-sepolia.blockscout.com/address/0x693eE35A0c3D04b65D58AC075A18941dc212c90b) |
| MockUSDT | [`0x7A72c437B5c7d2E88E015E3c87839304E2896e16`](https://unichain-sepolia.blockscout.com/address/0x7A72c437B5c7d2E88E015E3c87839304E2896e16) |
| MockPriceFeed | [`0x4148d2953E3Db7E8CB446aa30f08bcfe28317883`](https://unichain-sepolia.blockscout.com/address/0x4148d2953E3Db7E8CB446aa30f08bcfe28317883) |
| PoolManager | [`0x00B036B58a818B1BC34d502D3fE730Db729e62AC`](https://unichain-sepolia.blockscout.com/address/0x00B036B58a818B1BC34d502D3fE730Db729e62AC) |
| USDC | [`0x31d0220469e10c4E71834a79b1f276d740d3768F`](https://unichain-sepolia.blockscout.com/address/0x31d0220469e10c4E71834a79b1f276d740d3768F) |

**Pool pair:** USDC / MockUSDT
**Pool ID:** `0xa6d8966efa2903448e27307a1d5bd35e664bd5f739702191459edb7f50cd5b57`

### Lasna (Reactive Network Testnet — Chain ID 5318007)

| Contract | Address |
|---|---|
| ReactiveSender | [`0x7D95cD74DA9c4C8f48349c8B4b624e9E7ADF7585`](https://lasna.explorer.rnk.dev/address/0x7D95cD74DA9c4C8f48349c8B4b624e9E7ADF7585) |

### Source Chain Mock Price Feeds

| Chain | Chain ID | MockPriceFeed Address |
|---|---|---|
| Ethereum Sepolia | 11155111 | `0xd4297fB5Ccf8573B02fbBEA1e62103507A42727b` |
| Base Sepolia | 84532 | `0x807035ec27D5A09424029F71Ca394a051618640f` |
| Polygon Amoy | 80002 | `0x807035ec27D5A09424029F71Ca394a051618640f` |

---

## Deployment

### Prerequisites

```bash
# Install Foundry
curl -L https://foundry.paradigm.xyz | bash
foundryup

# Clone the repo
git clone https://github.com/yourusername/pegkeeper
cd pegkeeper

# Install dependencies
forge install

# Copy and fill environment variables
cp .env.example .env
```

### Deploy to Unichain Sepolia

```bash
# Deploy the full PEGKEEPER system (hook + mock token + pool)
forge script script/Deploy.s.sol \
  --rpc-url unichain_sepolia \
  --broadcast \
  --verify
```

### Deploy Mock Price Feeds to Source Chains

```bash
# Deploy to each source chain (Ethereum Sepolia, Base Sepolia, Polygon Amoy)
forge script script/DeployMockFeeds.s.sol \
  --rpc-url ethereum_sepolia \
  --broadcast

forge script script/DeployMockFeeds.s.sol \
  --rpc-url base_sepolia \
  --broadcast
```

### Deploy Reactive Sender

```bash
# Deploy to Reactive Lasna testnet
forge script script/DeployReactiveSender.s.sol \
  --rpc-url reactive_kopli \
  --broadcast
```

---

## Running the Demo

The demo simulates a stablecoin depeg in real time and shows PEGKEEPER responding automatically.

**Step 1 — Verify the pool is in GREEN stage**
```bash
cast call 0xD097AaE843980Da4b8b5D273c154a80b9414DC80 \
  "getProtectionStage()(uint8)" \
  --rpc-url unichain_sepolia
# Returns: 0 (GREEN)
```

**Step 2 — Trigger a mild depeg signal (YELLOW) on 2 source chains**
```bash
forge script script/TriggerDepeg.s.sol:TriggerYellow \
  --rpc-url ethereum_sepolia --broadcast

forge script script/TriggerDepeg.s.sol:TriggerYellow \
  --rpc-url base_sepolia --broadcast
# Pushes price to $0.998 on Ethereum + Base mock feeds
```

**Step 3 — Wait ~30s for Reactive to relay, then check stage**
```bash
cast call 0xD097AaE843980Da4b8b5D273c154a80b9414DC80 \
  "getProtectionStage()(uint8)" \
  --rpc-url unichain_sepolia
# Returns: 1 (YELLOW) — swap fee now 0.05%
```

**Step 4 — Escalate to ORANGE**
```bash
forge script script/TriggerDepeg.s.sol:TriggerOrange \
  --rpc-url ethereum_sepolia --broadcast

forge script script/TriggerDepeg.s.sol:TriggerOrange \
  --rpc-url base_sepolia --broadcast
# Returns: 2 (ORANGE) after relay — swap fee now 0.30%, deposits paused
```

**Step 5 — Escalate to RED (full crisis)**
```bash
forge script script/TriggerDepeg.s.sol:TriggerRed \
  --rpc-url ethereum_sepolia --broadcast

forge script script/TriggerDepeg.s.sol:TriggerRed \
  --rpc-url base_sepolia --broadcast
# Returns: 3 (RED) after relay — swap fee 1.00%, conservative LPs signalled to exit
```

**Step 6 — Trigger recovery**
```bash
forge script script/TriggerDepeg.s.sol:TriggerRecovery \
  --rpc-url ethereum_sepolia --broadcast

forge script script/TriggerDepeg.s.sol:TriggerRecovery \
  --rpc-url base_sepolia --broadcast
# Pushes price back to $1.00 — pool returns to GREEN after relay
```

---

## Testing

```bash
# Run all tests
forge test

# Run with detailed output
forge test -vvvv

# Run specific contract tests
forge test --match-path test/PegKeeper.t.sol
forge test --match-path test/ReactiveMonitor.t.sol
forge test --match-path test/ReactiveSender.t.sol

# Gas report
forge test --gas-report

# Coverage report (exclude deployment scripts)
forge coverage --no-match-path "script/**"
```

### Coverage

All production contracts achieve 100% coverage across lines, statements, branches, and functions.

| Contract | Lines | Statements | Branches | Functions |
|---|---|---|---|---|
| `src/PegKeeper.sol` | 100% | 100% | 100% | 100% |
| `src/ReactiveMonitor.sol` | 100% | 100% | 100% | 100% |
| `src/ReactiveSender.sol` | 100% | 100% | 100% | 100% |
| `src/MockPriceFeed.sol` | 100% | 100% | 100% | 100% |
| `src/MockERC20.sol` | 100% | 100% | 100% | 100% |

### Test suite breakdown

| File | Type | Count |
|---|---|---|
| `test/PegKeeper.t.sol` | Unit | 43 |
| `test/PegKeeperEdgeCases.t.sol` | Unit (edge cases) | 26 |
| `test/PegKeeperFuzz.t.sol` | Fuzz (1000 runs each) | 18 |
| `test/PegKeeperInvariant.t.sol` | Invariant (128k calls each) | 7 |
| `test/ReactiveMonitor.t.sol` | Unit | 30 |
| `test/ReactiveMonitorFuzz.t.sol` | Fuzz (1000 runs each) | 13 |
| `test/ReactiveSender.t.sol` | Unit | 15 |
| `test/MockPriceFeed.t.sol` | Unit | 8 |
| `test/MockPriceFeedFuzz.t.sol` | Fuzz (1000 runs each) | 13 |
| `test/MockERC20.t.sol` | Unit | 9 |
| `test/HookMiner.t.sol` | Unit | 4 |
| **Total** | | **186 unit/fuzz + 7 invariants = 194** |

---

## Hook Permissions

PEGKEEPER uses the following Uniswap v4 hook flags:

| Hook | Used | Purpose |
|------|------|---------|
| `beforeInitialize` | No | — |
| `afterInitialize` | Yes | Register pool with protection system |
| `beforeAddLiquidity` | Yes | Block deposits during ORANGE / RED stages |
| `afterAddLiquidity` | Yes | Register LP protection profile |
| `beforeRemoveLiquidity` | No | — |
| `afterRemoveLiquidity` | No | — |
| `beforeSwap` | Yes | Apply dynamic fee based on current stage |
| `afterSwap` | No | — |

---

## LP Protection Profiles

When adding liquidity, LPs choose their protection profile:

| Profile | Behaviour at RED Stage |
|---------|----------------------|
| Conservative | Receives on-chain `ConservativeWithdrawalTriggered` event at RED — signal to exit before crisis deepens |
| Balanced | Stays in pool, benefits from elevated fees during depeg |
| Aggressive | Stays in pool, captures maximum fees from arb activity during depeg |

Profiles are set at deposit time and stored on-chain per LP position.

---

## Security Considerations

- **TEE Protection** — hook responses are hidden in Unichain's TEE until committed, preventing front-running of protection updates
- **Multi-chain Signal Validation** — single-chain price moves are ignored; alerts only fire on confirmed multi-chain consensus
- **No Admin Keys** — once deployed, the hook operates autonomously with no privileged admin functions
- **Reactive Trust Model** — Reactive Network's cross-chain messaging is fully on-chain and trustless; no centralized relay

---

## Hackathon

Built for the **UHI8 Hookathon — Specialized Markets** track.

Partner integrations: **Unichain** + **Reactive Network**

Category: **Dynamic Stablecoin Managers**

---

## License

MIT
