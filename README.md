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

The moment Reactive detects depeg pressure across multiple chains simultaneously, it fires an alert to the PEGKEEPER hook on Unichain. The hook then escalates through graduated protection stages — adjusting fees and LP ranges automatically — before arbitrage bots can exploit the gap.

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

| Stage | Trigger | Fees | LP Ranges | Deposits |
|-------|---------|------|-----------|----------|
| GREEN | Price $0.999 – $1.001 | 0.01% | Narrow | Open |
| YELLOW | Multi-chain pressure, price $0.996 – $0.999 | 0.05% | Slightly wider | Open |
| ORANGE | Sustained pressure, price $0.990 – $0.995 | 0.30% | Wide | Paused |
| RED | Crisis level, price below $0.985 | Maximum | Full width | Paused |

Conservative LPs who opted in to auto-protection are withdrawn at RED stage before the worst hits.

### Unichain Executes Faster Than Bots

When Reactive fires an alert, PEGKEEPER needs to update pool settings before arb bots react. Unichain's 1-second blocks (soon 250ms) mean the hook's fee update is confirmed in the pool before a bot traveling from mainnet even arrives.

The Trusted Execution Environment (TEE) ensures nobody can see the hook's protection response in the mempool and front-run it. The fee update lands invisibly and is already in place when the bot checks the pool.

### Recovery

As prices stabilize back toward $1.00, PEGKEEPER automatically steps back down through the stages:

```
RED → ORANGE → YELLOW → GREEN
```

Deposits re-open, ranges tighten, fees return to normal. LPs can re-enter.

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
│                    REACTIVE NETWORK                             │
│                                                                 │
│   ReactiveMonitor.sol                                           │
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
│   PegKeeper.sol — Uniswap v4 Hook                               │
│   - Receives alert from Reactive                                │
│   - Updates protection stage                                    │
│   - beforeSwap: applies dynamic fee                             │
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
│   ├── PegKeeper.sol              # Main Uniswap v4 hook — fee + range management
│   ├── ReactiveMonitor.sol        # Reactive Network contract — cross-chain watcher
│   ├── MockPriceFeed.sol          # Mock price feed for testing and demo
│   └── interfaces/
│       ├── IPegKeeper.sol         # Hook interface
│       └── IReactiveMonitor.sol   # Reactive monitor interface
├── test/
│   ├── PegKeeper.t.sol            # Unit tests for hook logic
│   ├── ReactiveMonitor.t.sol      # Unit tests for Reactive contract
│   └── Integration.t.sol          # End-to-end integration tests
├── script/
│   ├── Deploy.s.sol               # Full deployment script
│   ├── DeployMocks.s.sol          # Deploy mock price feeds for demo
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
PEGKEEPER makes frequent micro-adjustments as conditions evolve — nudging fees and ranges through stages as Reactive updates come in. Each adjustment is a transaction. On Ethereum mainnet, the cumulative gas cost would eat LP profits. On Unichain it is negligible.

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
# Deploy mock price feeds first (for testnet demo)
forge script script/DeployMocks.s.sol \
  --rpc-url unichain_sepolia \
  --broadcast \
  --verify

# Deploy the main PEGKEEPER hook
forge script script/Deploy.s.sol \
  --rpc-url unichain_sepolia \
  --broadcast \
  --verify
```

### Deploy Reactive Monitor

```bash
# Deploy to Reactive Kopli testnet
forge script script/Deploy.s.sol:DeployReactiveMonitor \
  --rpc-url reactive_kopli \
  --broadcast
```

---

## Running the Demo

The demo simulates a stablecoin depeg in real time and shows PEGKEEPER responding automatically.

**Step 1 — Verify the pool is in GREEN stage**
```bash
cast call $PEGKEEPER_HOOK_ADDRESS "getProtectionStage()" \
  --rpc-url unichain_sepolia
# Returns: 0 (GREEN)
```

**Step 2 — Trigger a mild depeg signal (YELLOW)**
```bash
forge script script/TriggerDepeg.s.sol:TriggerYellow \
  --rpc-url ethereum_sepolia \
  --broadcast
# Pushes USDC price to $0.997 on Ethereum + Base mock feeds
```

**Step 3 — Watch Reactive relay the alert to Unichain**

Within 1–2 seconds, check the hook stage:
```bash
cast call $PEGKEEPER_HOOK_ADDRESS "getProtectionStage()" \
  --rpc-url unichain_sepolia
# Returns: 1 (YELLOW) — fees already updated to 0.05%
```

**Step 4 — Escalate to ORANGE**
```bash
forge script script/TriggerDepeg.s.sol:TriggerOrange \
  --rpc-url ethereum_sepolia \
  --broadcast
# Pushes USDC price to $0.991 across 3 chains
```

**Step 5 — Attempt an arb attack**
```bash
forge script script/TriggerDepeg.s.sol:SimulateArbBot \
  --rpc-url unichain_sepolia \
  --broadcast
# Shows the attack is unprofitable due to elevated fees
```

**Step 6 — Trigger recovery**
```bash
forge script script/TriggerDepeg.s.sol:TriggerRecovery \
  --rpc-url ethereum_sepolia \
  --broadcast
# Pushes USDC price back to $1.00 — pool returns to GREEN
```

---

## Testing

```bash
# Run all tests
forge test

# Run with detailed output
forge test -vvvv

# Run only unit tests
forge test --match-path test/PegKeeper.t.sol

# Run integration tests
forge test --match-path test/Integration.t.sol

# Gas report
forge test --gas-report
```

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
| Conservative | Automatically withdrawn before crisis hits |
| Balanced | Stays in pool, benefits from elevated fees |
| Aggressive | Stays in pool, widens range to capture maximum fees from arb |

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
