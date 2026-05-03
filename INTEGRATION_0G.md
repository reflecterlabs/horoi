# 0G Integration Plan — Compute + Storage

**Status**: PLANNED. Code NOT modified yet. Current Unichain Sepolia deployment stays as-is.

**Scope**: Two 0G touchpoints — **0G Compute** for agent reasoning, **0G Storage** for Policy Decision Records (PDRs) and Qwen RL model manifest.

**Out of scope** (decided 2026-05-03):
- KeeperHub — dropped for time. Unichain Sepolia not supported by KeeperHub anyway, would have required full chain migration.
- Base Sepolia migration — cancelled. 0G is chain-agnostic, no reason to redeploy.
- Gensyn AXL — single-agent system, no narrative gain.
- Running custom Qwen on 0G Compute — would require running own 0G provider node. Not feasible for hackathon.

**Final prize targets**: Uniswap Foundation (already done) + 0G Compute + 0G Storage = 3 prize tracks.

---

## Phase 1 — 0G Compute Router (~30 min)

### 1.1 Get API key

1. Sign up at https://pc.0g.ai
2. Generate API key
3. List available models from dashboard (likely Llama 3.3 70B, DeepSeek R1 family — verify exact name strings)
4. Add to `agent/.env`:
   ```
   ZEROG_COMPUTE_API_KEY=<key>
   ZEROG_COMPUTE_MODEL=<verified model name>
   LLM_PROVIDER=zerog
   ```

### 1.2 Smoke test the router

```bash
curl https://router-api.0g.ai/v1/models \
  -H "Authorization: Bearer $ZEROG_COMPUTE_API_KEY"
```

Should return a model list. If 401/404 → fix auth before touching code.

### 1.3 Wire into reasoning

**File to modify**: `agent/src/reasoning.ts` (or wherever the OpenAI client is constructed — currently uses OpenRouter per `agent/.env`).

Add a provider switch:

```typescript
const provider = process.env.LLM_PROVIDER || "openrouter";
const llm = new OpenAI({
  baseURL: provider === "zerog"
    ? "https://router-api.0g.ai/v1"
    : process.env.LLM_BASE_URL,
  apiKey: provider === "zerog"
    ? process.env.ZEROG_COMPUTE_API_KEY
    : process.env.LLM_API_KEY,
});

const model = provider === "zerog"
  ? process.env.ZEROG_COMPUTE_MODEL
  : process.env.LLM_MODEL;
```

Keep OpenRouter as fallback so we can A/B during demo.

### 1.4 Verify

```bash
cd agent
LLM_PROVIDER=zerog node src/run.cjs monitor
```

Should connect, fetch state, run reasoning via 0G Compute. Log includes "reasoning powered by 0G Compute" label.

### 1.5 Cleanup

Delete unused placeholder code in `agent/src/adapters/zerog.ts`:
- `requestInference` (~line 45)
- `chatCompletion` (~line 80)
- `ZGInferenceRequest`, `ZGInferenceResponse` types

Keep storage section for Phase 2.

### 1.6 Acceptance

- [ ] `curl /v1/models` returns 200 with model list
- [ ] Agent monitor loop runs without errors using `LLM_PROVIDER=zerog`
- [ ] Reasoning output is coherent (not garbage from wrong model name)
- [ ] Single commit: `feat(agent): wire 0G Compute Router for reasoning`

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
+ | 0G Compute | Agent reasoning via Router (OpenAI-compatible) | ✅ |
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

## Recovery checklist (if session ends mid-work)

1. `git status` — see what's committed
2. Check `agent/.env` for `ZEROG_COMPUTE_API_KEY` and `ZEROG_STORAGE_PRIVATE_KEY` presence
3. If Phase 1 not committed but env set → resume at 1.3
4. If Phase 2 SDK installed but no roundtrip commit → resume at 2.3
5. Each phase is independently shippable. Do not start Phase 2 until Phase 1 is committed.

## Engram pointer

Plan saved at `topic_key = sdd/openagents/integration-0g` for cross-session recovery.
