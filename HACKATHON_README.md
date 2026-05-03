# Horoi Protocol — OpenAgents ETHGlobal Hackathon

Agentic CDP governance via PID controller + ParameterGuard + RL-trained model. Ported from Cairo to EVM (Unichain).

## Project Overview

**Demo Flow:**
```
[Oracle] → [Agent monitors] → [Decision + Uniswap API] → [ParameterGuard.proposeParameters(KP, KI)] → [PID adjusts] → [Peg held]
```

**Sponsors Integrated:**
- ✅ Uniswap Foundation — API integration + FEEDBACK.md
- ⏳ 0G — Compute Network + Storage (placeholders)
- ⏳ KeeperHub — Tx execution (placeholder)

---

## Project Structure

```
openagents/
├── PLAN.md                    # Original plan from analysis
├── FEEDBACK.md                # Uniswap API feedback (prize requirement)
├── sdd/                      # SDD workflow artifacts
│   └── horoi-evm-port/
├── contracts/                 # Solidity contracts
│   ├── foundry.toml
│   ├── src/
│   │   ├── GrintaEngine.sol      # Core safe engine + ERC20
│   │   ├── PIDController.sol    # PI controller with guardian
│   │   ├── ParameterGuard.sol   # Governance guard (NEW)
│   │   └── libraries/
│   └── script/
│       └── Deploy.s.sol       # Deployment script
├── agent/                    # TypeScript agent
│   ├── package.json
│   ├── src/
│   │   ├── config.ts          # Configuration
│   │   ├── executor.ts       # On-chain executor
│   │   ├── monitor.ts        # State monitor
│   │   ├── reasoning.ts    # LLM + rule-based reasoning
│   │   ├── run.ts          # Main loop (TypeScript)
│   │   └── adapters/
│   │       ├── uniswap.ts    # Uniswap API
│   │       ├── zerog.ts    # 0G Compute/Storage
│   │       └── keeperhub.ts # KeeperHub
│   └── .env.example
└── HACKATHON_README.md         # This file
```

---

## Contracts

### ParameterGuard.sol (NEW)
- **Purpose:** On-chain governance guardrails for PID parameters
- **Features:**
  - Policy bounds: `kp_min`, `kp_max`, `ki_min`, `ki_max`
  - Delta caps: `max_kp_delta`, `max_ki_delta` per call
  - Rate limiting: `cooldown_seconds`, `max_updates`
  - PDR events for every decision
  - Emergency stop capability
  - Simple proposer address (upgradeable from ERC-8004)

### PIDController.sol (MODIFIED)
- Added `guardian` address pattern
- `setKp/setKi` callable by both `admin` OR `guardian`
- `setGuardian()` for admin

### GrintaEngine.sol
- Unchanged from grinta-unichain blueprint
- Safe creation, borrow/repay, redemption mechanism

---

## Agent

### Flow
```
Monitor → fetch protocol state (oracle, PID, Guard)
    ↓
Reasoning → LLM (OpenAI) OR rule-based fallback
    ↓
Executor → proposeParameters(KP, KI, isEmergency)
    ↓
ParameterGuard → validates bounds → applies to PID
```

### Rule-Based Logic
```javascript
if (deviation > 0.05) → EMERGENCY mode
else if (deviation > 0.03) → ADJUST mode  
else → HOLD
```

### Sponsor Integration Labels
- "Model served via 0G Compute" (if configured)
- "Txs via KeeperHub" (if configured)

---

## Deployment

### Local (Anvil) — three-script flow

```bash
# Terminal 1
anvil

# Terminal 2 — deploy entire stack
cd contracts
forge script script/Deploy.s.sol:Deploy --broadcast --rpc-url http://localhost:8545

# Capture printed addresses, then:
export HOROI_POOL_MANAGER=0x...
export HOROI_ORACLE=0x...
export HOROI_ENGINE=0x...
export HOROI_HOOK=0x...
export HOROI_LIQUIDITY_HELPER=0x...
export HOROI_SWAP_HELPER=0x...
export HOROI_WBTC=0x...
export HOROI_USDC=0x...

# Initialize V4 pool + push prices + add liquidity
forge script script/SetupPool.s.sol:SetupPool --broadcast --rpc-url http://localhost:8545

# Swap and read system state (collateral / redemption / market price + rate)
forge script script/TestSwap.s.sol:TestSwap --broadcast --rpc-url http://localhost:8545
```

### Unichain Sepolia
See `DEPLOYMENT.md`. Same script flow, replace `--rpc-url http://localhost:8545` with `--rpc-url https://sepolia.unichain.org` and set `PRIVATE_KEY`.

---

## Testing

### Contract test suite

```bash
cd contracts
forge test
# Expected: 20 tests passing
#   - PIDController.t.sol  (8 tests — RAY-scale invariants)
#   - ParameterGuard.t.sol (10 tests — bounds + cooldown + budget + emergency stop)
#   - Integration.t.sol    (2 tests — E2E rate-moves-on-depeg + agent KP rotation)
```

**Status:** ✅ Compilation clean, 20/20 tests passing, end-to-end Anvil flow verified (deploy → setup → swap → rate moved from RAY to 0.99999999989… RAY in response to a +0.025% market push).

### Agent

```bash
cd agent
node src/run.cjs monitor
```

---

## Next Steps (Unichain Sepolia)

1. **Deploy to testnet**
   - Get Unichain Sepolia RPC
   - Get testnet ETH (faucet)
   - Run deployment script

2. **Configure agent**
   - Update `.env` with addresses
   - Set wallet private key

3. **Run demo**
   - Monitor state
   - Trigger deviation via oracle
   - Execute proposal
   - Show "peg held"

---

## Reference

### Cairo Original
- `desktop/pid/` — Complete (87/87 tests)
- ParameterGuard + PID + RL agent + Qwen 2.5 1.5B

### EVM Blueprint
- `desktop/grinta-unichain/` — Halfway
- PIDController, GrintaEngine, GrintaHook (V4)

### Integrations

| Sponsor | Integration | Status |
|---------|-------------|--------|
| Uniswap | API pool state | ✅ + FEEDBACK.md |
| 0G | Compute + Storage | ⏳ Placeholder |
| KeeperHub | Tx execution | ⏳ Placeholder |
| Gensyn | Multi-agent | ❌ Deferred |

---

## Prize Eligibility

| Requirement | Status |
|------------|--------|
| Working CDP | ✅ |
| Agentic governance | ✅ |
| Uniswap API integration | ✅ + FEEDBACK.md |
| 0G integration | ⏳ Placeholder |
| KeeperHub integration | ⏳ Placeholder |

---

## Notes for Demo

1. **ParameterGuard is the key:**
   - It's model-agnostic (RL model runs off-chain, chain doesn't know)
   - Human votes policies, not parameters
   - Agent executes within bounds

2. **Demo flow:**
   - Crash oracle → agent detects → proposes → peg holds
   - Show dashboard with "deviation -3% → 0.02%"

3. **Key differentiator:**
   - Zero/Low inference cost (Qwen 2.5 1.5B)
   - Private (ParameterGuard on-chain)
   - Upgradeable model without contract changes