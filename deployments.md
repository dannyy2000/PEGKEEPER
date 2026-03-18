# Deployments

## Unichain Sepolia (Chain ID 1301)

Deployed: 2026-03-15 (redeployed — previous ReactiveMonitor was outdated)

| Contract        | Address                                      |
|----------------|----------------------------------------------|
| PegKeeper       | `0xD097AaE843980Da4b8b5D273c154a80b9414DC80` |
| ReactiveMonitor | `0x693eE35A0c3D04b65D58AC075A18941dc212c90b` |
| MockUSDT        | `0x7A72c437B5c7d2E88E015E3c87839304E2896e16` |
| MockPriceFeed   | `0x4148d2953E3Db7E8CB446aa30f08bcfe28317883` |
| PoolManager     | `0x00B036B58a818B1BC34d502D3fE730Db729e62AC` |
| USDC (real)     | `0x31d0220469e10c4E71834a79b1f276d740d3768F` |

**Pool pair:** USDC / MockUSDT
**Pool ID:** `0xa6d8966efa2903448e27307a1d5bd35e664bd5f739702191459edb7f50cd5b57`

## Lasna (Reactive Network Testnet — Chain ID 5318007)

Deployed: 2026-03-18 (redeployed — previous ReactiveSender pointed to outdated ReactiveMonitor)

| Contract        | Address                                      |
|----------------|----------------------------------------------|
| ReactiveSender  | `0x7D95cD74DA9c4C8f48349c8B4b624e9E7ADF7585` |

ReactiveSender is authorized on ReactiveMonitor. ✓

## Mock Price Feeds — Source Chains (for Reactive wiring)

Deployed: 2026-03-15

| Chain | Chain ID | MockPriceFeed Address |
|---|---|---|
| Ethereum Sepolia | 11155111 | `0xd4297fB5Ccf8573B02fbBEA1e62103507A42727b` |
| Base Sepolia | 84532 | `0x807035ec27D5A09424029F71Ca394a051618640f` |
| Polygon Amoy | 80002 | `0x807035ec27D5A09424029F71Ca394a051618640f` |

ReactiveSender subscribes to `PriceUpdated` events on all 3 feeds.

## Architecture Summary

```
MockPriceFeed (Eth Sepolia / Base Sepolia / Polygon Amoy)
  → PriceUpdated event
    → ReactiveSender.react() on Lasna
      → Callback event
        → ReactiveMonitor.receiveReactiveAlert() on Unichain Sepolia
          → PegKeeper.receiveAlert() on Unichain Sepolia
            → Stage + fee update
```
