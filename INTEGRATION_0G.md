# 0G Integration Plan — Compute + Storage

**Status**: Phase 1 DONE. Phase 2 pending.

**Scope**: Two 0G touchpoints — **0G Compute** for agent reasoning, **0G Storage** for Policy Decision Records (PDRs) and Qwen RL model manifest.

**Out of scope** (decided 2026-05-03):
- KeeperHub — dropped for time. Unichain Sepolia not supported by KeeperHub anyway, would have required full chain migration.
- Base Sepolia migration — cancelled. 0G is chain-agnostic, no reason to redeploy.
- Gensyn AXL — single-agent system, no narrative gain.
- Running custom Qwen on 0G Compute — would require running own 0G provider node. Not feasible for hackathon.

**Final prize targets**: Uniswap Foundation (already done) + 0G Compute + 0G Storage = 3 prize tracks.

---

## Phase 1 — 0G Compute Router ✅ DONE (2026-05-03)

### What we learned

1. **No API key** — 0G Compute uses wallet-based authentication, NOT API keys.
2. **CLI workflow** — Use `0g-compute-cli` to setup, deposit, and generate bearer tokens (`app-sk-...`).
3. **OpenAI SDK has issues** — Use native `fetch` instead of OpenAI SDK due to auth header differences.
4. **Provider must be acknowledged** — You MUST transfer funds and acknowledge the provider before getting a working token.

### 1.1 CLI workflow (how to generate token)

```bash
# Install CLI
pnpm add @0gfoundation/0g-compute-ts-sdk -g

# Setup with wallet that has 0G testnet tokens (from faucet.0g.ai)
0g-compute-cli setup-network
0g-compute-cli deposit --amount 3  # minimum for ledger

# List available providers
0g-compute-cli inference list-providers

# Pick one (Qwen 2.5 7B testnet):
export PROVIDER=0xa48f01287233509FD694a22Bf840225062E67836

# Transfer funds and acknowledge
0g-compute-cli transfer-fund --provider $PROVIDER --amount 1
0g-compute-cli inference acknowledge-provider --provider $PROVIDER
0g-compute-cli inference get-secret --provider $PROVIDER
```

The `get-secret` command returns:
- `ZG_SERVICE_URL`: e.g., `https://compute-network-6.integratenetwork.work`
- `ZG_API_SECRET`: e.g., `app-sk-eyJhZGRyZXNzIjoi...`

### 1.2 Add to `agent/.env`

```
# 0G Compute (testnet)
ZEROG_COMPUTE_URL=https://compute-network-6.integratenetwork.work
ZEROG_COMPUTE_API_KEY=app-sk-eyJhZGRyZXNzIjoiMHg4QTBhYzA5NkQ5NDk0ZDY5ZTQ3QkMzYWQxMjA2MGYwYTcyN2ZhQUU0IiwicHJvdmlkZXIiOiIweGE0OGYwMTI4NzIzMzUwOUZENjk0YTIyQmY4NDAyMjUwNjJFNjc4MzYiLCJ0aW1lc3RhbXAiOjE3Nzc3OTc4ODk0NTMsImV4cGlyZXNBdCI6MTc4MDM4OTg4OTQ1Mywibm9uY2UiOiIxNzc3Nzk3ODg5NDUzLWIzeWd3b2RqOGg5MDAwMDAwMCIsImdlbmVyYXRpb24iOjAsInRva2VuSWQiOjB9fDB4NjFjZjEyMTdkOGZhOGJhOWFiZjI0ZTgyNDg2NjY0ZjM3OWJiNTE4MGZjNmM2YWU4MWViYjU5MjJkNzk2N2MyMTA0MTIwMWVlZDA3ODdhOGRmMDEzNzczZTI2OWQ3Y2ExZmVmN2E4MGM4ZDllZWY5MTk4OTM2M2ZkZmMzY2ExNDAxYg==
ZEROG_COMPUTE_MODEL=qwen/qwen-2.5-7b-instruct

# Provider switch: "openrouter" (default) or "zerog"
LLM_PROVIDER=zerog
```

### 1.3 Code changes

**File**: `agent/src/reasoning.ts`

- Added provider switch in constructor (`LLM_PROVIDER` env var)
- Use native `fetch` instead of OpenAI SDK for 0G (auth header issues)
- Model: `qwen/qwen-2.5-7b-instruct` (from provider)

**File**: `agent/src/config.ts`

Added:
- `ZEROG_COMPUTE_URL`
- `ZEROG_COMPUTE_API_KEY`
- `ZEROG_COMPUTE_MODEL`
- `ZEROG_PRIVATE_KEY` (optional, for wallet-based validation)
- `LLM_PROVIDER` (switch: "openrouter" | "zerog")

### 1.4 Verification

```bash
cd agent
LLM_PROVIDER=zerog npx tsx src/index.ts --monitor-only
```

Should log reasoning via 0G Compute without errors.

### 1.5 Acceptance

- [x] CLI generates working `app-sk-...` token
- [x] `fetch` call to `/v1/proxy/chat/completions` returns coherent response
- [x] Agent monitor runs without errors using `LLM_PROVIDER=zerog`
- [x] Commit: `feat(agent): 0G Compute works - fetch-based, direct auth`

---

## Phase 2 — 0G Storage SDK (~1.5 hr)

### 2.1 Install SDK + fund storage wallet

```bash
cd agent
npm install @0gfoundation/0g-storage-ts-sdk ethers
```

Storage uploads cost gas on 0G Galileo testnet (chainId 16602). Need a separate funded wallet:

1. Generate or reuse an EOA → put private key in `agent/.env` as `ZEROG_STORAGE_PRIVATE_KEY`
2. Faucet 0G testnet tokens at https://faucet.0g.ai (Galileo testnet)
3. Need ~1 0G token for the demo run

### 2.2 Rewrite `agent/src/adapters/zerog.ts` storage section

Replace current placeholder `storeToStorage` / `retrieveFromStorage` with real SDK:

```typescript
import { ZgFile, Indexer } from '@0gfoundation/0g-storage-ts-sdk';
import { ethers } from 'ethers';
import { writeFile, unlink } from 'fs/promises';
import { readFile } from 'fs/promises';

const STORAGE_RPC = 'https://evmrpc-testnet.0g.ai';
const INDEXER = 'https://indexer-storage-testnet-turbo.0g.ai';

const provider = new ethers.JsonRpcProvider(STORAGE_RPC);
const signer = new ethers.Wallet(process.env.ZEROG_STORAGE_PRIVATE_KEY!, provider);
const indexer = new Indexer(INDEXER);

export async function storePDR(pdr: PDR): Promise<string> {
  const tmp = `/tmp/pdr-${pdr.id}.json`;
  await writeFile(tmp, JSON.stringify(pdr));
  try {
    const file = await ZgFile.fromFilePath(tmp);
    const [tx, err] = await indexer.upload(file, STORAGE_RPC, signer);
    await file.close();
    if (err) throw err;
    return tx.rootHash;
  } finally {
    await unlink(tmp).catch(() => {});
  }
}

export async function getPDR(rootHash: string): Promise<PDR> {
  const tmp = `/tmp/pdr-fetch-${Date.now()}.json`;
  try {
    await indexer.download(rootHash, tmp, true);
    const data = await readFile(tmp, 'utf-8');
    return JSON.parse(data);
  } finally {
    await unlink(tmp).catch(() => {});
  }
}
```

### 2.3 Roundtrip test BEFORE wiring into agent

Write `agent/scripts/test-0g-storage.ts`:

```typescript
import { storePDR, getPDR } from '../src/adapters/zerog.js';

const fakePdr = {
  id: 'test-' + Date.now(),
  timestamp: Date.now(),
  agent: '0xtest',
  newKp: 1n,
  newKi: 1n,
  isEmergency: false,
  deviation: 0.05,
  reasoning: 'roundtrip test',
};

const hash = await storePDR(fakePdr);
console.log('rootHash:', hash);

const fetched = await getPDR(hash);
console.log('roundtrip ok:', fetched.id === fakePdr.id);
```

Run it. **If roundtrip fails, do NOT wire into the agent.** Debug first.

### 2.4 Wire into executor

**File**: `agent/src/executor.ts`

After `proposeParameters` tx confirms, call `storePDR` with the decision record + tx hash. Log the rootHash:

```typescript
const txReceipt = await sendProposal(...);
const pdr = buildPDR(decision, txReceipt.transactionHash);
const rootHash = await storePDR(pdr).catch(e => {
  console.warn('0G Storage failed (non-blocking):', e.message);
  return null;
});
if (rootHash) console.log(`[0G Storage] PDR stored: 0g://${rootHash}`);
```

**Non-blocking** — if 0G storage fails, agent keeps working. Storage is for audit trail, not critical path.

### 2.5 Bonus: Qwen model manifest upload (one-time, ~10 min)

Create a JSON manifest of your trained Qwen 2.5 1.5B and upload once:

```json
{
  "model": "qwen-2.5-1.5b-horoi-rl",
  "base_model": "Qwen/Qwen2.5-1.5B-Instruct",
  "training": "GRPO on Cairo PID environment",
  "training_repo": "github.com/.../pid_rl",
  "huggingface": "huggingface.co/<your-handle>/<model>",
  "training_hash": "<commit hash>",
  "reward_function": "deviation_reduction + bounds_compliance",
  "uploaded_by": "0x8A0ac096D9494d69e47BC3ad12060f0a727faAE4",
  "uploaded_at": "<ISO date>"
}
```

`storeToStorage(JSON.stringify(manifest))` → save the rootHash in `HACKATHON_README.md` as: "Qwen RL model manifest: `0g://<rootHash>`". Citable in demo.

### 2.6 Acceptance

- [ ] `npm install` succeeds
- [ ] Roundtrip test (`scripts/test-0g-storage.ts`) prints rootHash and `roundtrip ok: true`
- [ ] Agent runs E2E with `proposeParameters` → tx lands → PDR stored → rootHash logged
- [ ] Manifest uploaded once, rootHash in `HACKATHON_README.md`
- [ ] Single commit: `feat(agent): persist PDRs to 0G Storage`

---

## Update HACKATHON_README.md (final step)

After both phases ship:

```diff
| Sponsor | Integration | Status |
|---------|-------------|--------|
| Uniswap | API pool state | ✅ + FEEDBACK.md |
- | 0G | Compute + Storage | ⏳ Placeholder |
- | KeeperHub | Tx execution | ⏳ Placeholder |
+ | 0G Compute | Agent reasoning via Router (fetch-based, Qwen 2.5 7B) | ✅ |
+ | 0G Storage | PDRs + model manifest | ✅ |
- | Gensyn | Multi-agent | ❌ Deferred |
+ | KeeperHub | — | ❌ Dropped (Unichain not supported) |
+ | Gensyn | — | ❌ Deferred (single-agent) |
```

Add demo talking points:
- "Every governance decision is auditable — PDR stored on 0G Storage, citable by rootHash"
- "Reasoning runs on 0G Compute Network — decentralized GPU marketplace, OpenAI-compatible interface"
- "Qwen 2.5 1.5B RL-trained alternative model — weights manifest published on 0G Storage"

---

## Engram pointer

Plan saved at `topic_key = sdd/openagents/integration-0g` for cross-session recovery.