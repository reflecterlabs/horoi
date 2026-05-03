# Horoi Protocol — OpenAgents ETHGlobal Hackathon Plan

## Overview

Port Horoi Protocol (agentic CDP governance via PID + ParameterGuard + RL model) from Cairo to EVM (Unichain), integrating 3 sponsors for the hackathon.

**Target chain:** Unichain Sepolia  
**Demo:** "crash oracle → agent detects → proposes KP/Ki boost → peg holds"

---

## Current State

### Cairo (desktop/pid) — Complete ✓
- ParameterGuard, PIDController, SafeEngine, LiquidationEngine, AccountingEngine, CollateralAuctionHouse
- Oracle, SafeManager, CollateralJoin, GrintaHook (Ekubo), ERC-8004 identity
- Agent TS + pid_rl/ with GRPO + Qwen 2.5 1.5B (87/87 tests passing)

### EVM Blueprint (desktop/grinta-unichain) — Halfway
|Contract|Status|Notes|
|--------|------|-----|
|PIDController.sol|Ready|No agent governance — admin-only|
|GrintaEngine.sol|Ready|Safe creation, borrow/repay, redemption mechanism|
|GrintaHook.sol (V4)|Ready|Uniswap V4 hook for rate updates|
|OracleRelayer.sol|Ready|Collateral price feed integration|
|SafeManager.sol|Ready|Entry point for safe operations|
|CollateralJoin.sol|Ready|Deposits from external|
|SwapHelper.sol|Ready|V4 swap integration|

**Missing for Horoi:**
1. **ParameterGuard.sol** — core piece, without it PID has admin-only control
2. **Agent runtime** — agents/ and proving/ directories are empty
3. **Sponsor integrations** — not integrated

---

## What to Build

### Phase 1: ParameterGuard.sol (Priority: Critical)

**Purpose:** On-chain governance guardrails that let an agent propose Kp/Ki changes within admin-defined bounds.

**Reference:** Cairo `ParameterGuard` (505 lines) → port to Solidity

**Key features:**
- Policy struct: `kp_min`, `kp_max`, `ki_min`, `ki_max`, `max_kp_delta`, `max_ki_delta`, `cooldown_seconds`, `max_updates`
- Agent authorization: configurable proposer (simplified from ERC-8004 for EVM)
- Bounds enforcement: absolute + per-call delta
- Rate limiting: cooldown + budget
- PDR events: emit every decision for auditability
- Emergency stop: admin can halt proposals
- Proxy functions: human retains PID control via Guard

**Simplifications for hackathon:**
- No ERC-8004 identity — use simple `proposer` address (can upgrade later)
- No proxy_set_* — unless needed for demo
- Emit PDR events but don't need off-chain storage for demo

**File:** `contracts/src/ParameterGuard.sol` (~250 lines)

```
ParameterGuard
├── proposeParameters(uint256 newKp, uint256 newKi)
├── setPolicy(AgentPolicy policy)
├── emergencyStop() / resume()
└── Views: getPolicy(), isStopped(), getUpdateCount()
```

---

### Phase 2: Agent Runtime (Priority: High)

**Purpose:** Off-chain agent that monitors oracle → decides → proposes to ParameterGuard.

**Architecture (simplified):**

```
agent/
├── src/
│   ├── monitor.ts      # Poll oracle, compute deviation
│   ├── reasoning.ts  # Decision logic (prompt + Qwen or fallback)
│   ├── executor.ts  # Call ParameterGuard.proposeParameters()
│   └── config.ts    # Policy bounds mirror on-chain
└── scripts/
    └── run.ts       # Loop: monitor → reason → execute
```

**For hackathon, two options:**

1. **Full RL agent** (if time permits):
   - Copy `pid_rl/` from Cairo, adapt paths, serve model via 0G Compute
   - High effort, high impact

2. **Simple LLM fallback** (recommended):
   - Use OpenAI or local Qwen API
   - Prompt with policy bounds from ParameterGuard
   - Simple loop: fetch oracle → ask LLM → submit tx

**Decision:** Start with option 2. If 0G Compute is ready, swap endpoint.

---

### Phase 3: Sponsor Integrations (Priority: High)

#### 3a. Uniswap Foundation — API Integration ✓

**What:** Agent queries Uniswap API before proposing parameter changes.

**Implementation:**
```typescript
// In reasoning.ts, before proposing:
const poolState = await fetch('https://api.uniswap.org/v1/pool/[poolId]')
const { price, depth, slippage } = poolState

// Add to prompt: "If I change KP by X, next swap has Y slippage"
```

**Requirement:** Write `FEEDBACK.md` in repo documenting API experience.

**Effort:** ~2 hours

---

#### 3b. 0G — Compute + Storage

**Option A (recommended):** Serve Qwen 2.5 1.5B via 0G Compute Network.
- Endpoint: TBD (need to sign up / find docs)
- Narrative: "Agent brain runs on decentralized inference"

**Option B (backup):** Store PDR events in 0G Storage.
- Each ParameterGuard proposal → emit IPFS CID as event
- Audit log in 0G Storage, cheap and simple

**Effort:** A: ~4 hours (needs endpoint). B: ~1 hour.

---

#### 3c. KeeperHub — Tx Execution

**What:** Route agent → ParameterGuard txs through KeeperHub.

**Implementation:**
```typescript
// Replace direct wallet.sendTransaction() with:
// keeper.submit({ to: ParameterGuard, data: calldata })
```

**Narrative:** "KeeperHub guarantees execution if gas spikes or reorg."

**Effort:** ~2 hours (MCP integration)

---

## What NOT to Build

- **LiquidationEngine.sol** — not needed for demo (peg holding without liquidations)
- **AccountingEngine.sol** — embedded in GrintaEngine
- **CollateralAuctionHouse** — not needed
- **Gensyn/AXL** — multi-agent comms (leave for stretch)

---

## Demo Flow (Final)

```
[Oracle] → [Agent monitors] → [Detects deviation]
    → [Queries Uniswap API] → [Simulates impact]
    → [Calls ParameterGuard.proposeParameters(KP, KI)]
    → [ParameterGuard validates bounds, applies to PID]
    → [PID adjusts redemption rate]
    → [Dashboard shows: "Peg held: deviation -0.2% → 0.01%" ]
    
    + Sponsor badges:
    - "Model served via 0G Compute"
    - "Txs via KeeperHub"
    - "PDR archived to 0G Storage"
```

---

## Files to Create / Modify

### New Contracts
- `contracts/src/ParameterGuard.sol` ← new

### Modified Contracts
- `contracts/src/PIDController.sol` → add `setKp/setKi` callable by ParameterGuard (not admin-only)
- `contracts/src/GrintaEngine.sol` → set ParameterGuard as admin, remove direct admin access

### New Agent
- `agent/src/monitor.ts`
- `agent/src/reasoning.ts`
- `agent/src/executor.ts`
- `agent/src/config.ts`
- `agent/package.json`
- `agent/.env.example`

### Sponsor Integration
- `agent/src/adapters/uniswap.ts`
- `agent/src/adapters/keeperhub.ts`
- `agent/src/adapters/0g.ts`

### Repo Files
- `FEEDBACK.md` (Uniswap API)
- `README.md` (horizontal for hackathon)

---

## Effort Estimate

| Task | Hours | Dependency |
|------|-------|----------|
| ParameterGuard.sol | 4 | — |
| Wire PID → Guard | 1 | ParameterGuard |
| Agent skeleton | 2 | ParameterGuard |
| Uniswap API integration | 2 | Agent |
| 0G integration | 4 | Agent |
| KeeperHub integration | 2 | Agent |
| Dashboard labels | 1 | All |
| **Total** | **~16** | — |

**Buffer:** +8 hours for issues = 24 hours max.

---

## Next Steps

1. **Write ParameterGuard.sol** — port from Cairo, simplify
2. **Wire to PIDController** — make Guard callable, not admin-only
3. **Boot agent runtime** — simple loop, test end-to-end
4. **Add sponsor integrations** — one by one
5. **Dashboard badges** — show integrations

---

## Questions for Implementation

1. Which 0G Compute endpoint to use? (need signup link)
2. KeeperHub MCP or SDK? (check docs)
3. Unichain Sepolia RPC and block explorer?