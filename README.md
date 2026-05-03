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

We fine-tuned **Qwen 2.5 1.5B Instruct** with GRPO on our PID environment:

### Trained Models

| Model | Steps | Link |
|-------|-------|------|
| `qwen2.5-1.5B-pid-v1` | 50 | [HuggingFace](https://huggingface.co/Fenryr/qwen2.5-1.5B-pid-v1) |
| `qwen2.5-1.5B-pid-v2` (recommended) | 200 | [HuggingFace](https://huggingface.co/Fenryr/qwen2.5-1.5B-pid-v2) |

```python
# Training reward function
reward = deviation_reduction + bounds_compliance
```

- **Deviation reduction**: % improvement in peg deviation
- **Bounds compliance**: did the model stay within policy bounds?

Not used in production (timing) but demonstrates Horoi's small-model governance thesis: a 1.5B model can learn to adjust PID parameters within bounded policies.

---

## Research Foundation

Horoi builds on peer-reviewed research in agentic DeFi governance:

### 1. Hyper-Heuristic Driven Smart Contracts for DeFi
- **Fonte**: Frontiers in Blockchain, 2025
- **Link**: [https://www.frontiersin.org/journals/blockchain/articles/10.3389/fbloc.2025.1730114/full](https://www.frontiersin.org/journals/blockchain/articles/10.3389/fbloc.2025.1730114/full)
- **Resumen**: RL controller selecting heuristics for DeFi params. Results: **45.6% more transaction success**, **28.3% less gas**, **38.4% less liquidations** under stress.

### 2. Stablecoin Design with Adversarial-Robust Multi-Agent Systems (MVF-Composer)
- **Authors**: Shengwei You, Aditya Joshi, Andrey Kuehlkamp, Jarek Nabrzyski
- **Link**: [https://arxiv.org/abs/2601.22168](https://arxiv.org/abs/2601.22168)
- **Resumen**: Stress-testing framework for stablecoins. Trust scores filter manipulator signals. **57% less max peg deviation**, **3.1x faster recovery**.

### 3. Who Restores the Peg? A Mean-Field Game Approach
- **Link**: [https://arxiv.org/abs/2601.18991](https://arxiv.org/abs/2601.18991)
- **Resumen**: Primary market friction (mint/redeem) matters MORE than secondary liquidity. Validated against USDC March 2023, USDT May/July 2023.

### 4. Hybrid Stabilization Protocol with AI-Driven Arbitrage
- **Authors**: You, Kuehlkamp, Nabrzyski (Notre Dame)
- **Link**: [https://arxiv.org/abs/2506.05708](https://arxiv.org/abs/2506.05708)
- **Resumen**: PID + RL adapting gains based on volatility. **RL risk-aware with adaptive boost/damping**.

### 5. Autonomous Agents on Blockchains
- **Link**: [https://arxiv.org/abs/2601.04583](https://arxiv.org/abs/2601.04583)
- **Resumen**: 317 papers review. Defines **TIS (Transaction Intent Schema)** and **PDR (Policy Decision Record)** for auditability. Threat models: prompt injection, key compromise, MEV.

### 6. When AI Meets Stablecoin: Dissecting De-pegging Risk with LLM Agents
- **Authors**: Congcong Bo, Dehua Shen (Nankai University)
- **Link**: [https://papers.ssrn.com/sol3/papers.cfm?abstract_id=6121746](https://papers.ssrn.com/sol3/papers.cfm?abstract_id=6121746)
- **Resumen**: Multi-agent LLMs analyzing and **predicting de-pegging risk** from on-chain + sentiment signals.

### 7. Autonomous AI Agents in Decentralized Finance
- **Authors**: Lennart Ante, Technological Forecasting & Social Change, 2026
- **Link**: [https://papers.ssrn.com/sol3/papers.cfm?abstract_id=5055677](https://papers.ssrn.com/sol3/papers.cfm?abstract_id=5055677)
- **Resumen**: Taxonomy of 306 AI agents in DeFi. 68% of new DeFi protocols in Q1 2026 include AI — but **NONE in CDP risk governance**. That's our empty space.

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