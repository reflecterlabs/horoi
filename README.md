# Horoi Protocol

**Agentic Governance for CDP Stablecoins — Powered by Small Language Models**

---

## What is Horoi?

Horoi is an **agentic-first CDP (Collateralized Debt Position) protocol** where governance is performed by AI agents rather than centralized voting or timelocks. The protocol uses a **ParameterGuard** smart contract that enforces policies and bounds established by a DAO, company, or individual deployer — giving you complete control over what the agent can and cannot do.

The agent monitors BTC collateral and the GRIT stablecoin peg, then autonomously adjusts PID controller parameters (KP, KI) to maintain the peg during both crashes and pumps.

### Key Innovation: Small Model Governance

Most agentic protocols use large, expensive LLMs ($10+/1M tokens). Horoi is designed around **small models** (1.5B-7B parameters) that:

- Cost **~90% less** than GPT-4o or Claude
- Run on consumer GPUs or decentralized compute (0G Compute)
- Have **sub-second latency** — critical forDeFi crisis response
- Can be **fine-tuned with RL** for specific governance tasks

We trained a **Qwen 2.5 1.5B Instruct** model with GRPO (Gradient-Free Policy Optimization) on our PID environment to adjust parameters in crash scenarios. The model learned to:
- Recognize deviation patterns
- Propose bounded parameter changes
- Avoid overcorrection that causes oscillation

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                     Horoi Protocol                      │
├─────────────────────────────────────────────────────────────────┤
│                                                          │
│  ┌──────────────┐     ┌──────────────┐     ┌──────────────┐ │
│  │   Oracle    │────▶│   GrintaEngine│◀────│  PIDController│ │
│  │   (price)  │     │  (CDP)      │     │ (rate)      │ │
│  └──────────────┘     └──────────────┘     └──────────────┘ │
│         │                   │                   │              │
│         └───────────────────┴───────────────────┘              │
│                          │                           │
│                          ▼                           │
│                   ┌──────────────┐                    │
│                   │ParameterGuard│◀── Agent (LLM)     │
│                   │  (policy)   │                    │
│                   └──────────────┘                    │
│                                                        │
└─────────────────────────────────────────────────────────┘
```

### Contracts (Unichain Sepolia)

| Contract | Address | Purpose |
|----------|---------|---------|
| `OracleRelayer` | `0x8A7bA8e...` | Updates BTC price to oracle |
| `GrintaEngine` | `0x3Ca116a...` | CDP state & redemptions |
| `PIDController` | `0x908cfBA...` | Redemption rate computation |
| `ParameterGuard` | `0xC5e659...` | Enforces policy bounds on agent |
| `GrintaHook` | `0x63a1F8...` | Uniswap V4 afterSwap hook |

### ParameterGuard Policies

The agent can ONLY propose within these bounds:

- **KP** (proportional gain): `[3.33e-7, 1e-6]` WAD
- **KI** (integral gain): `[3.33e-13, 1e-12]` WAD
- **Max delta per update**: ±10% of baseline
- **Max proposals**: 1000 (then guard stops)

Everything else is REJECTED on-chain. The deployer sets the policies at deploy time.

---

## Sponsors & Integrations

### 0G Compute (Inference)

- **Provider**: 0G Labs (Build 2025)
- **Model**: Qwen 2.5 7B (testnet)
- **Use**: Agent reasoning via OpenAI-compatible API
- **Why**: Decentralized GPU marketplace, low cost

### 0G Storage (Persistence)

- **Provider**: 0G Labs
- **Use**: Policy Decision Records (PDRs) — every governance decision is stored on-chain with verifiable rootHash
- **Why**: Auditable governance trail

### Uniswap Foundation (Prize Sponsor)

- **Integration**: V4 pool state monitoring via API
- **Pool**: GRIT/USDC (Unichain)
- **Why**: Real-time market price feeds the protocol

### Harness (Build Sponsor)

- **Status**: Exploring for CI/CD for contract upgrades

---

## How It Works

1. **Oracle** updates BTC price (simulated via cheat buttons in demo)
2. **Agent** reads state: BTC price, GRIT market price, deviation %
3. **Agent** calls LLM (0G Compute or OpenRouter)
4. **LLM** returns: `hold` | `adjust` | `adjust_emergency`
5. If adjust → **Agent** proposes new KP/KI to ParameterGuard
6. ParameterGuard **validates** against policies → **accepts or rejects**
7. On accept → **PID** updates rate → **afterSwap** fires on swaps
8. **PDR** stored to 0G Storage for auditability

---

## Quick Start (Local)

```bash
# Clone & install
git clone https://github.com/reflecterlabs/horoi
cd horoi

# Start frontend + server
cd app
npm run start:dev
# Visit http://localhost:5173

# Or run the agent standalone
cd agent
npm run start
```

---

## Demo Flow

1. Open http://localhost:5173
2. Click **"Crash"** → simulates BTC -10%
3. Watch agent detect deviation
4. Agent calls 0G Compute → proposes parameters
5. ParameterGuard validates → accepts
6. PID rate updates → GRIT peg restores
7. PDR stored to 0G Storage (rootHash in logs)

---

## Tech Stack

- **Contracts**: Solidity (Foundry), Uniswap V4
- **Agent**: TypeScript, viem, OpenAI SDK
- **Frontend**: React, Vite, Recharts
- **LLM**: Qwen via 0G Compute (testnet)
- **Storage**: 0G Storage SDK
- **Chain**: Unichain Sepolia (1301)

---

## Model Training

We fine-tuned **Qwen 2.5 1.5B Instruct** with GRPO on our Cairo PID environment:

```python
# Training reward function
reward = deviation_reduction + bounds_compliance
```

- **Deviation reduction**: % improvement in peg deviation
- **Bounds compliance**: did the model stay within policy bounds?

Results showed the model learned conservative parameter adjustments within 500 episodes. Not used in production (timing) but demonstrates Horoi's small-model governance thesis.

---

## Why Horoi?

| Protocol | Governance | LLM Cost | Latency |
|----------|-----------|----------|--------|
| MakerDAO | Multisig | — | — |
| Curve | DAO voting | — | — |
| **Horoi** | **Agentic** | **~$0.50/1M** | **<500ms** |

Small models + decentralized compute = agentic governance that's economically viable for any DeFi protocol.

---

## Links

- **Live Demo**: (Render deploy coming soon)
- **Contracts**: Unichain Sepolia (see DEPLOYMENT.md)
- **0G Docs**: https://docs.0g.ai
- **Unichain**: https://unichain.org

---

Built at ETHGlobal OpenAgents 2025 🟣