# Horoi Protocol — Unichain Sepolia Deployment

## ✓ Live deployment (2026-04-30)

| Contract | Address |
|----------|---------|
| MockWBTC (8d) | `0x141E32C0add68B5CF0d597Cf39FD21CD37580543` |
| MockUSDC (6d) | `0xa5CfcF29A7C0E6f9f875b68AF1DA7f322009e1c8` |
| OracleRelayer | `0x8A7bA8e02fD429607a32F81089Ca6582e4ACbf12` |
| GrintaEngine | `0x3Ca116ac93920cfefd588a41b9B29fb2AD840005` |
| PIDController | `0x908cfBAEd216A7F5cE6fe0D20ADF8b0d019D2bd4` |
| CollateralJoin | `0xAf4003266322E77FaE1332c1Da2D674FAa947045` |
| GrintaHook (V4) | `0x63a1F84fa3cFB4269afC7063E8E87935AD9Ec040` |
| SafeManager | `0xf3303768fcbE7f1bB57bCBB63603f2f9504BE7bA` |
| **ParameterGuard** | `0xC5e659Db76111cdABC624f8078a6D881a16A53A5` |
| LiquidityHelper | `0x8e0F6b963ff8cDC83F16Af4e2A1fE1e5D108e072` |
| SwapHelper | `0x55C119A3D32637eDF3E945FDE316E7F19Ae8A8B5` |

Deployer / Agent EOA: `0x8A0ac096D9494d69e47BC3ad12060f0a727faAE4`. Hook salt: `0x2950`.

PoolManager (canonical Unichain Sepolia): `0x00B036B58a818B1BC34d502D3fE730Db729e62AC`.

## Demo run on testnet

### Demo.s.sol — direct hook flow (no pool)

1. `oracle.updatePrice(WBTC, USDC, 60_000e18)` — push BTC=$60K
2. `hook.setMarketPrice(0.99e18)` — simulate GRIT 1% depeg below peg
3. `hook.update()` — propagates collateral price to engine, fires `pid.computeRate`, engine.updateRedemptionRate
4. `guard.proposeParameters(KP+10%, ki, false)` — agent governance bumps KP

Result: `engine.redemptionRate()` moved from `RAY` to `RAY + 6.67e18` (exactly `swmul(KP, 1pct_RAY)` math). `guard.updateCount` = 1.

### SetupPool + TestSwap — full V4 loop ✓

Pool initialized at `sqrtPriceX96 = 79228162514264337593544` (= `1e-6 * 2^96`, correct for GRIT-as-currency0 with 18d/6d decimals). Tick range `[-276375, -276275]`, liquidity `2e18`. ~10K GRIT + ~10K USDC seeded.

After two real swaps (USDC → GRIT, 100 USDC each):
- Market price (from delta, WAD): `1.000250015` (~$1.0003 — swap pushed peg up)
- Redemption price (RAY): `1.0000253` (drifted from 1.0 RAY due to prior rate > RAY)
- Redemption rate (RAY): `0.999999999921…` (PID pulling rate down since market > redemption)
- `pid.kp`: `7.337e11` (post-agent bump)

The full feedback loop (`swap → afterSwap → hook delta-price → PID computeRate → engine.updateRedemptionRate → redemption price drift`) is verified live on Unichain Sepolia.

---

## Reproducing the deploy



## Prerequisites

1. **Unichain Sepolia RPC:** `https://sepolia.unichain.org`
2. **Testnet ETH:** Get from faucet (search "Unichain Sepolia faucet")
3. **Etherscan API Key:** For verification (optional)

## Step 1: Update Foundry Config

Edit `contracts/foundry.toml`:

```toml
[rpc_endpoints]
unichain_sepolia = "https://sepolia.unichain.org"

[etherscan]
unichain_sepolia = { key = "${ETHERSCAN_API_KEY}" }
```

## Step 2: Deploy Contracts

```bash
cd contracts

# Set your private key (wallet with testnet ETH)
export PRIVATE_KEY=0xyour_private_key_here

# Deploy
forge script script/Deploy.s.sol --rpc-url unichain_sepolia --broadcast --private-key $PRIVATE_KEY
```

**Output should show:**
```
GrintaEngine:      0x...
PIDController:   0x...
ParameterGuard:  0x...
```

## Step 3: Configure Agent

Create `agent/.env`:

```bash
# RPC
RPC_URL=https://sepolia.unichain.org

# Wallet (same as deployer or separate)
AGENT_PRIVATE_KEY=0xyour_private_key_here
AGENT_ADDRESS=0xyour_address

# Contracts (from deployment output)
PARAMETER_GUARD_ADDRESS=0x...
PID_CONTROLLER_ADDRESS=0x...
GRINTA_ENGINE_ADDRESS=0x...

# LLM (optional - uses rule-based fallback if not set)
# OPENAI_API_KEY=sk-...

# Sponsors (optional)
# ZEROG_COMPUTE_URL=
# KEEPERHUB_API_KEY=
```

## Step 4: Run Agent

```bash
cd agent

# Monitor only (no execution)
node src/run.cjs monitor

# Full agent loop
node src/run.cjs
```

## Step 5: Trigger Demo

### Option A: Oracle Update (Simulate Price Crash)

1. Deploy mock oracle or use existing
2. Call `OracleRelayer.updateCollateralPrice(price)` with lower price
3. Watch agent detect deviation and propose

### Option B: Direct Deviation

1. Lower collateral ratio to trigger depeg
2. Execute large borrow to affect system
3. Watch agent respond

## Verification

### Check Contracts on Explorer
- Unichain Sepolia Explorer: `https://sepolia.uniscan.xyz`

### Verify ParameterGuard
```bash
cast call $PARAMETER_GUARD_ADDRESS "proposer()" --rpc-url $RPC_URL
# Should return agent address

cast call $PARAMETER_GUARD_ADDRESS "policyKpMin()" --rpc-url $RPC_URL
# Should return min KP
```

### Check Agent Execution
```bash
# Get update count
cast call $PARAMETER_GUARD_ADDRESS "updateCount()" --rpc-url $RPC_URL

# Get last timestamp  
cast call $PARAMETER_GUARD_ADDRESS "lastUpdateTimestamp()" --rpc-url $RPC_URL
```

## Troubleshooting

### "Insufficient funds"
- Get more testnet ETH from faucet

### "Permission denied"
- Check `proposer()` on ParameterGuard matches agent address
- Check `guardian` on PIDController matches ParameterGuard address

### "Execution reverted"
- Check cooldown not active: `lastUpdateTimestamp + cooldown > now`
- Check delta caps: `abs(newKp - currentKp) <= maxKpDelta`

## Demo Checklist

- [ ] Deploy contracts to Unichain Sepolia
- [ ] Verify ParameterGuard proposer
- [ ] Configure agent .env
- [ ] Run monitor to confirm state reads
- [ ] Trigger deviation (oracle crash)
- [ ] Watch agent proposeParameters()
- [ ] Verify proposal in explorer
- [ ] Show "peg held" on dashboard

## Key Addresses (After Deployment)

| Contract | Purpose |
|----------|---------|
| GrintaEngine | Safe + ERC20 (GRIT) |
| PIDController | Redemption rate |
| ParameterGuard | Governance |
| OracleRelayer | Price feed |

## Preset Policy (Conservative)

```solidity
kp_min:    3.33e-7 WAD
kp_max:   1e-6 WAD  
ki_min:   3.33e-13 WAD
ki_max:   1e-12 WAD
max_kp_delta:   6.67e-8 WAD (10% of baseline)
max_ki_delta:   6.67e-14 WAD
cooldown:       5 seconds
emergency:    3 seconds
max_updates:  1000
```