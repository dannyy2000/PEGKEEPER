# Deployments

## Unichain Sepolia (Chain ID 1301)

Deployed: 2026-03-13

| Contract        | Address                                      |
|----------------|----------------------------------------------|
| PegKeeper       | `0x547ce84327BE494753714Fb3e511311f10869C80` |
| ReactiveMonitor | `0x35067ef1c48207F633030BcB2c682f84e8918ec2` |
| MockUSDT        | `0x807035ec27D5A09424029F71Ca394a051618640f` |
| MockPriceFeed   | `0xAd6c53ED6933027bAF1c860050df46BA5CaDD975` |
| PoolManager     | `0x00B036B58a818B1BC34d502D3fE730Db729e62AC` |
| USDC (real)     | `0x31d0220469e10c4E71834a79b1f276d740d3768F` |

**Pool pair:** USDC / MockUSDT  
**Pool ID:** `0xf7cca37e06d0843797f5230b340f671f0fa3dfa2880701084c091435d34b82d6`

## Mock Price Feeds — Source Chains (for Reactive wiring)

Deployed: 2026-03-15

| Chain | Chain ID | MockPriceFeed Address |
|---|---|---|
| Ethereum Sepolia | 11155111 | `0xd4297fB5Ccf8573B02fbBEA1e62103507A42727b` |
| Base Sepolia | 84532 | `0x807035ec27D5A09424029F71Ca394a051618640f` |
| Arbitrum Sepolia | 421614 | `0x034c145740f58f11F83671A0Ba9b56dA59c488aE` |

Subscribe to the `PriceUpdated` event on each of these in the Kopli Reactive contract.

## For Ola — Reactive Wiring

Point the Reactive contract on Kopli at:

- **Callback target (Unichain):** `0x35067ef1c48207F633030BcB2c682f84e8918ec2` (ReactiveMonitor)
- **PegKeeper (receives alerts):** `0x547ce84327BE494753714Fb3e511311f10869C80`
- **Destination chain ID:** 1301 (Unichain Sepolia)

Once your Kopli sender address is known, Daniel will run:
```bash
cast send 0x35067ef1c48207F633030BcB2c682f84e8918ec2 \
  "setAuthorizedReactiveSender(address)" <YOUR_KOPLI_SENDER_ADDRESS> \
  --rpc-url https://unichain-sepolia.drpc.org \
  --private-key $PRIVATE_KEY
```
