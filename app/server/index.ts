/**
 * Horoi Governance Server — EVM port (Unichain Sepolia)
 *
 * Mirrors the Cairo `pid/app/server/index.ts` API surface, ported to viem.
 *
 * Endpoints:
 *   GET  /api/identity        — agent metadata (no ERC-8004 yet, returns null shape)
 *   GET  /api/state           — current protocol state (BTC/GRIT/redemption/rate/kp/ki/dev)
 *   GET  /api/history         — decisions JSONL from agent/decisions.jsonl
 *   GET  /api/stream          — SSE: log / state / decision / tx / archive events
 *   POST /api/cheat/crash     — oracle.updatePrice * (1 - pct/100)
 *   POST /api/cheat/pump      — oracle.updatePrice * (1 + pct/100)
 *   POST /api/cheat/reset     — oracle.updatePrice = $60,000
 *   POST /api/agent/trigger   — read state → ask LLM → propose via ParameterGuard
 *   POST /api/swap/trigger    — small swap on V4 GRIT/USDC pool to fire afterSwap → PID
 *   POST /api/demo/crash      — full sequence: crash → agent → swap → archive
 */

import express from "express";
import cors from "cors";
import OpenAI from "openai";
import dotenv from "dotenv";
import { fileURLToPath } from "url";
import { dirname, join } from "path";
import { existsSync, readFileSync, writeFileSync, appendFileSync } from "fs";
import {
  createPublicClient,
  createWalletClient,
  http,
  parseAbi,
  type PublicClient,
  type WalletClient,
  type Chain,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";

const __dirname = dirname(fileURLToPath(import.meta.url));

// Load env: contracts/.env (PRIVATE_KEY) → app/.env (everything else)
dotenv.config({ path: join(__dirname, "..", "..", "contracts", ".env") });
dotenv.config({ path: join(__dirname, "..", ".env"), override: false });

function req(key: string): string {
  const v = process.env[key];
  if (!v) throw new Error(`Missing env var: ${key}`);
  return v;
}

const WAD = 10n ** 18n;
const RAY = 10n ** 27n;

// ── Config ────────────────────────────────────────────────────────────────
const CFG = {
  RPC_URL: process.env.RPC_URL ?? "https://sepolia.unichain.org",
  CHAIN_ID: Number(process.env.CHAIN_ID ?? 1301),
  PRIVATE_KEY: req("PRIVATE_KEY") as `0x${string}`,
  AGENT_ADDRESS: req("AGENT_ADDRESS") as `0x${string}`,

  LLM_API_KEY: req("LLM_API_KEY"),
  LLM_BASE_URL: process.env.LLM_BASE_URL ?? "https://openrouter.ai/api/v1",
  LLM_MODEL: process.env.LLM_MODEL ?? "minimax/minimax-m2.5:free",

  // 0G Compute (testnet) — optional
  ZEROG_COMPUTE_URL: process.env.ZEROG_COMPUTE_URL,
  ZEROG_COMPUTE_API_KEY: process.env.ZEROG_COMPUTE_API_KEY,
  ZEROG_COMPUTE_MODEL: process.env.ZEROG_COMPUTE_MODEL ?? "qwen/qwen-2.5-7b-instruct",
  LLM_PROVIDER: process.env.LLM_PROVIDER ?? "openrouter",

  ORACLE_RELAYER_ADDRESS: req("ORACLE_RELAYER_ADDRESS") as `0x${string}`,
  GRINTA_ENGINE_ADDRESS: req("GRINTA_ENGINE_ADDRESS") as `0x${string}`,
  PID_CONTROLLER_ADDRESS: req("PID_CONTROLLER_ADDRESS") as `0x${string}`,
  GRINTA_HOOK_ADDRESS: req("GRINTA_HOOK_ADDRESS") as `0x${string}`,
  PARAMETER_GUARD_ADDRESS: req("PARAMETER_GUARD_ADDRESS") as `0x${string}`,
  WBTC_ADDRESS: req("WBTC_ADDRESS") as `0x${string}`,
  USDC_ADDRESS: req("USDC_ADDRESS") as `0x${string}`,
  SWAP_HELPER_ADDRESS: req("SWAP_HELPER_ADDRESS") as `0x${string}`,

  POOL_FEE: Number(process.env.POOL_FEE ?? 100),
  POOL_TICK_SPACING: Number(process.env.POOL_TICK_SPACING ?? 1),

  LIGHTHOUSE_API_KEY: process.env.LIGHTHOUSE_API_KEY ?? "",
};

const chain: Chain = {
  id: CFG.CHAIN_ID,
  name: "Unichain Sepolia",
  nativeCurrency: { name: "ETH", symbol: "ETH", decimals: 18 },
  rpcUrls: { default: { http: [CFG.RPC_URL] } },
};

const account = privateKeyToAccount(CFG.PRIVATE_KEY);
const pub: PublicClient = createPublicClient({ chain, transport: http(CFG.RPC_URL) });
const wallet: WalletClient = createWalletClient({
  account,
  chain,
  transport: http(CFG.RPC_URL),
});

const llm = new OpenAI({ apiKey: CFG.LLM_API_KEY, baseURL: CFG.LLM_BASE_URL });

// ── Helper: LLM chat with 0G support ─────────────────────────────────────
async function chatWithLLM(messages: { role: string; content: string }[], model?: string): Promise<string> {
  const provider = CFG.LLM_PROVIDER;
  
  if (provider === "zerog" && CFG.ZEROG_COMPUTE_URL && CFG.ZEROG_COMPUTE_API_KEY) {
    const res = await fetch(`${CFG.ZEROG_COMPUTE_URL}/v1/proxy/chat/completions`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "Authorization": `Bearer ${CFG.ZEROG_COMPUTE_API_KEY}`,
      },
      body: JSON.stringify({
        model: model || CFG.ZEROG_COMPUTE_MODEL,
        messages,
        temperature: 0.1,
        max_tokens: 2000,
      }),
    });
    
    if (!res.ok) {
      const err = await res.text();
      throw new Error(`0G fetch failed: ${res.status} ${err}`);
    }
    
    const data = await res.json();
    return data.choices[0]?.message?.content ?? "";
  }
  
  // Default: OpenRouter
  const response = await llm.chat.completions.create({
    model: model || CFG.LLM_MODEL,
    messages,
    temperature: 0.1,
    max_tokens: 2000,
  });
  
  return response.choices[0]?.message?.content ?? "";
}

// ── ABIs (parseAbi for compactness) ───────────────────────────────────────
const ORACLE_ABI = parseAbi([
  "function updatePrice(address baseToken, address quoteToken, uint256 priceUsdWad)",
  "function getPriceWad(address baseToken, address quoteToken) view returns (uint256)",
]);
const HOOK_ABI = parseAbi([
  "function getMarketPrice() view returns (uint256)",
  "function getCollateralPrice() view returns (uint256)",
  "function setMarketPrice(uint256 price)",
  "function update()",
]);
const ENGINE_ABI = parseAbi([
  "function collateralPrice() view returns (uint256)",
  "function getRedemptionPrice() view returns (uint256)",
  "function redemptionRate() view returns (uint256)",
  "function totalDebt() view returns (uint256)",
  "function totalCollateral() view returns (uint256)",
]);
const PID_ABI = parseAbi([
  "function kp() view returns (int128)",
  "function ki() view returns (int128)",
  "function deviationProportional() view returns (int128)",
  "function deviationIntegral() view returns (int128)",
  "function deviationTimestamp() view returns (uint64)",
]);
const GUARD_ABI = parseAbi([
  "function stopped() view returns (bool)",
  "function updateCount() view returns (uint32)",
  "function lastUpdateTimestamp() view returns (uint64)",
  "function proposeParameters(int128 newKp, int128 newKi, bool isEmergency)",
]);
const ERC20_ABI = parseAbi([
  "function mint(address to, uint256 amount)",
  "function approve(address spender, uint256 amount) returns (bool)",
  "function balanceOf(address) view returns (uint256)",
]);
const SWAP_HELPER_ABI = parseAbi([
  "function swap((address,address,uint24,int24,address) key, bool zeroForOne, int256 amountSpecified, uint160 sqrtPriceLimitX96, address payer) returns (int256)",
]);

const MIN_SQRT_PRICE = 4295128739n;
const MAX_SQRT_PRICE = 1461446703485210103287273052203988822378723970341n;

// ── SSE log broadcast ─────────────────────────────────────────────────────
type SSEClient = { id: number; res: express.Response };
let sseClients: SSEClient[] = [];
let sseId = 0;

function broadcast(event: string, data: unknown) {
  const payload = `event: ${event}\ndata: ${JSON.stringify(data)}\n\n`;
  sseClients.forEach((c) => c.res.write(payload));
}

function log(msg: string, data?: Record<string, unknown>) {
  const entry = { ts: new Date().toISOString(), msg, ...data };
  console.log(`[server] ${msg}`);
  broadcast("log", entry);
}

// ── Read state ────────────────────────────────────────────────────────────
// Shared with the agent CLI (agent/src/monitor.ts) — persistent baseline
// for computing btcChangePct = (current - last) / last between updates.
const AGENT_STATE_PATH = join(__dirname, "..", "..", "agent", "state.json");

interface PersistedAgentState {
  lastBtcPrice: number;
  lastBtcAt: string;
}

function loadLastBtc(): number | null {
  try {
    if (!existsSync(AGENT_STATE_PATH)) return null;
    const parsed = JSON.parse(readFileSync(AGENT_STATE_PATH, "utf-8"));
    return typeof parsed.lastBtcPrice === "number" && parsed.lastBtcPrice > 0
      ? parsed.lastBtcPrice
      : null;
  } catch {
    return null;
  }
}

function persistLastBtc(price: number) {
  const data: PersistedAgentState = { lastBtcPrice: price, lastBtcAt: new Date().toISOString() };
  try {
    writeFileSync(AGENT_STATE_PATH, JSON.stringify(data, null, 2));
  } catch (e) {
    console.error("[server] failed to persist lastBtcPrice:", e);
  }
}

async function readState() {
  const r = <T>(addr: `0x${string}`, abi: any, fn: string, args?: any[]) =>
    pub.readContract({ address: addr, abi, functionName: fn, args: args as any }) as Promise<T>;

  // Read collateral price DIRECTLY from oracle (not engine cache).
  // engine.collateralPrice only updates when the hook fires (every 60s or on swap),
  // which would make the agent see stale data between cheat-oracle and trigger-swap.
  const [marketPriceWad, oraclePriceWad, redemptionPriceRay, redemptionRateRay, kp, ki, lastProp] =
    await Promise.all([
      r<bigint>(CFG.GRINTA_HOOK_ADDRESS, HOOK_ABI, "getMarketPrice"),
      r<bigint>(CFG.ORACLE_RELAYER_ADDRESS, ORACLE_ABI, "getPriceWad", [CFG.WBTC_ADDRESS, CFG.USDC_ADDRESS]),
      r<bigint>(CFG.GRINTA_ENGINE_ADDRESS, ENGINE_ABI, "getRedemptionPrice"),
      r<bigint>(CFG.GRINTA_ENGINE_ADDRESS, ENGINE_ABI, "redemptionRate"),
      r<bigint>(CFG.PID_CONTROLLER_ADDRESS, PID_ABI, "kp"),
      r<bigint>(CFG.PID_CONTROLLER_ADDRESS, PID_ABI, "ki"),
      r<bigint>(CFG.PID_CONTROLLER_ADDRESS, PID_ABI, "deviationProportional"),
    ]);

  const mpUsd = Number(marketPriceWad) / 1e18;
  const cpUsd = Number(oraclePriceWad) / 1e18;
  const rpRaw = Number(redemptionPriceRay) / 1e27;
  const rpUsd = rpRaw > 0.5 && rpRaw < 2.0 ? rpRaw : 1.0;
  const deviationPct = rpUsd > 0 ? ((rpUsd - mpUsd) / rpUsd) * 100 : 0;

  // PRIMARY signal: change since last observation (delta-based, demo-controlled).
  // Falls back to 0 on first run when no baseline exists.
  const lastBtc = loadLastBtc();
  const isFirstCycle = lastBtc === null;
  const btcChangePct = lastBtc != null && lastBtc > 0 ? ((cpUsd - lastBtc) / lastBtc) * 100 : 0;

  // SECONDARY/legacy signal: drop from $60K baseline.
  const btcDropPct = cpUsd > 0 ? ((60000 - cpUsd) / 60000) * 100 : 0;

  return {
    marketPrice: mpUsd,
    collateralPrice: cpUsd,
    redemptionPrice: rpUsd,
    redemptionRate: Number(redemptionRateRay) / 1e27,
    kp: Number(kp) / 1e18,
    ki: Number(ki) / 1e18,
    kpRaw: kp.toString(),
    kiRaw: ki.toString(),
    deviationPct: Number(deviationPct.toFixed(4)),
    btcChangePct: Number(btcChangePct.toFixed(2)),
    btcDropPct: Number(btcDropPct.toFixed(2)),
    isFirstCycle,
    lastBtcPrice: lastBtc ?? 0,
    lastProportional: Number(lastProp) / 1e27, // RAY-domain post-fix
  };
}

// ── LLM reasoning ─────────────────────────────────────────────────────────
const SYSTEM_PROMPT = `You are the Horoi PID Agent — an AI governor for a CDP stablecoin protocol.

Your role: monitor BTC collateral price AND the GRIT stablecoin peg, then adjust PID controller gains (KP, KI) to maintain the peg during market crashes AND pumps.

## How the system works
- GRIT is a stablecoin backed by BTC (WBTC) collateral.
- When BTC crashes, GRIT tends to depeg DOWN. When BTC pumps, GRIT tends to depeg UP. The PID controller computes a redemption rate to correct either direction.
- **KP** (proportional gain): Controls immediate response to current deviation.
- **KI** (integral gain): Controls accumulated error. Conservative — overshooting causes oscillation.
- Gains are tiny on purpose (HAI-style): internal RAY scaling means KP ~6.67e-7 already gives ~20% annualized rate for 1% deviation. The per-call delta cap is 10% of baseline — meaningful adjustments are built across MULTIPLE cycles, not in one shot.

## Your bounds (enforced on-chain by ParameterGuard — conservative policy)
- KP range: [3.33e-7, 1e-6] WAD (baseline 6.67e-7, ±50% headroom)
- KI range: [3.33e-13, 1e-12] WAD (baseline 6.67e-13)
- Max KP delta per update: 6.67e-8 WAD (10% of baseline — needs ~5 cycles to reach either bound)
- Max KI delta per update: 6.67e-14 WAD (10% of baseline)
- Normal cooldown: 5s. Emergency cooldown: 3s.

## Decision framework — SYMMETRIC, scaled by severity
"BTC change" = the change in BTC price BETWEEN the previous oracle observation and the current one (NOT vs an absolute baseline). The MAGNITUDE of your adjustment scales with severity; the SIGN follows the move. Each call moves at most ±10% of baseline, so multi-step positions take multiple cycles.

Tier 1 — HOLD: |BTC change| < 3% AND |peg deviation| < 1%
Tier 2 — PROACTIVE: 3% ≤ |BTC change| < 5% → step KP one delta (~10% of baseline)
Tier 3 — ACTIVE: 5% ≤ |BTC change| < 10%, OR 1% ≤ |deviation| < 3% → walk KP toward 8-9e-7
Tier 4 — EMERGENCY: |BTC change| ≥ 10% OR |deviation| ≥ 3% → "adjust_emergency", same delta cap

Rules:
- BTC DROPPING ⇒ INCREASE KP magnitude. BTC PUMPING ⇒ DECREASE KP magnitude. Behavior is SYMMETRIC.
- **NEGATIVE DEVIATION means GRIT is ABOVE peg and the rate is already pushing DOWN.** If KP is already elevated (> 8.33e-7) when deviation is negative, REDUCE KP regardless of BTC direction.
- NEVER call the CURRENT value "at max". The user prompt shows explicit headroom — read those fields.
- ALWAYS propose values RELATIVE to current (current ± small step) and within the per-update cap.
- RECOVERY (BTC pumping after a crash) ⇒ step KP back DOWN toward 6.67e-7 baseline.
- **First cycle**: if isFirstCycle = true, you have no prior BTC observation — return HOLD.

## Response format
Respond ONLY with valid JSON.
Values for new_kp and new_ki are human-readable floats (e.g. 1.2e-6, 1.3e-12).

Example HOLD: {"action":"hold","reasoning":"BTC stable, deviation small."}
Example PROACTIVE: {"action":"adjust","new_kp":7.33e-7,"new_ki":7.33e-13,"reasoning":"BTC −4%, +10% KP step."}
Example EMERGENCY: {"action":"adjust_emergency","new_kp":8.67e-7,"new_ki":8.67e-13,"reasoning":"BTC −12%, emergency."}`;

interface LLMResponse {
  choices: Array<{ message: { content: string }; finish_reason?: string }>;
}

async function callLLM(messages: { role: "system" | "user"; content: string }[]): Promise<LLMResponse> {
  const maxRetries = 4;
  const baseDelay = 1000;
  const model = CFG.LLM_PROVIDER === "zerog" ? CFG.ZEROG_COMPUTE_MODEL : CFG.LLM_MODEL;
  let lastError: Error | null = null;

  for (let attempt = 0; attempt < maxRetries; attempt++) {
    try {
      const content = await chatWithLLM(messages, model);
      return { choices: [{ message: { content } }] } as unknown as LLMResponse;
    } catch (error) {
      lastError = error instanceof Error ? error : new Error(String(error));
      if (lastError.message.includes("429") || lastError.message.toLowerCase().includes("rate")) {
        const delay = baseDelay * Math.pow(2, attempt);
        log(`LLM rate limited, retry ${attempt + 1}/${maxRetries} in ${delay}ms…`);
        await new Promise((r) => setTimeout(r, delay));
        continue;
      }
      if (attempt < maxRetries - 1) {
        log(`LLM error: ${lastError.message} — retrying`);
        await new Promise((r) => setTimeout(r, baseDelay));
        continue;
      }
      throw lastError;
    }
  }
  throw lastError ?? new Error("LLM call failed");
}

async function runAgentCycle() {
  log("Reading on-chain state…");
  const state = await readState();
  broadcast("state", state);
  log(
    `State: BTC $${state.collateralPrice.toFixed(0)} ` +
      `(Δ vs last ${state.btcChangePct >= 0 ? "+" : ""}${state.btcChangePct}%), ` +
      `GRIT $${state.marketPrice.toFixed(4)}, dev ${state.deviationPct}%, kp ${state.kp.toExponential(2)}`,
  );

  // Short-circuit on first cycle: no baseline → cannot compute btcChangePct → HOLD
  if (state.isFirstCycle) {
    const decision = {
      action: "hold",
      reasoning: "First cycle — no prior BTC observation; setting baseline for next cycle.",
    };
    broadcast("decision", decision);
    log("First cycle — recording baseline, deferring action.");
    persistLastBtc(state.collateralPrice);
    return decision;
  }

  const KP_CEIL = 1e-6, KP_FLOOR = 3.333e-7;
  const KI_CEIL = 1e-12, KI_FLOOR = 3.333e-13;
  const kpHeadroomUp = Math.max(0, KP_CEIL - state.kp);
  const kpHeadroomDown = Math.max(0, state.kp - KP_FLOOR);
  const kiHeadroomUp = Math.max(0, KI_CEIL - state.ki);
  const kiHeadroomDown = Math.max(0, state.ki - KI_FLOOR);
  const overCorrecting = state.deviationPct < 0 && state.kp > 8.33e-7;
  const btcDirection =
    state.btcChangePct < -1 ? "DROPPING" : state.btcChangePct > 1 ? "PUMPING" : "STABLE";

  const userPrompt = `## Current Protocol State
- BTC Price (oracle now): $${state.collateralPrice.toFixed(2)}
- BTC Last Observation: $${state.lastBtcPrice.toFixed(2)}
- **BTC Change since last observation: ${state.btcChangePct >= 0 ? "+" : ""}${state.btcChangePct}%** ← PRIMARY signal
- BTC Drop vs $60K baseline (context only): ${state.btcDropPct.toFixed(2)}%
- BTC Direction: **${btcDirection}**
- GRIT Market Price: $${state.marketPrice.toFixed(6)}
- GRIT Redemption Price: $${state.redemptionPrice.toFixed(6)}
- Peg Deviation: ${state.deviationPct}% ${state.deviationPct < 0 ? "(GRIT ABOVE peg)" : state.deviationPct > 0 ? "(GRIT BELOW peg)" : "(on peg)"}
- Current KP: ${state.kp.toExponential(3)} WAD
- Current KI: ${state.ki.toExponential(3)} WAD
- KP headroom: up ${kpHeadroomUp.toExponential(2)}, down ${kpHeadroomDown.toExponential(2)}
- KI headroom: up ${kiHeadroomUp.toExponential(2)}, down ${kiHeadroomDown.toExponential(2)}
- Last Proportional (RAY-domain): ${state.lastProportional.toExponential(3)}
${overCorrecting ? "\n## ALERT: OVER-CORRECTION DETECTED — REDUCE KP regardless of BTC direction.\n" : ""}
## DECISION RULE
- Use **BTC Change since last observation** as the PRIMARY trigger; baseline drop is context only.
- Negative change = BTC dropped vs last observation → DROPPING.
- Positive change = BTC pumped vs last observation → PUMPING (recovery if it follows a crash).
- DROPPING ⇒ raise KP magnitude. PUMPING ⇒ lower KP magnitude (step toward baseline 6.67e-7).

What is your decision? (Respond ONLY with valid JSON.)`;

  log("Asking LLM for decision…");
  const response = await callLLM([
    { role: "system", content: SYSTEM_PROMPT },
    { role: "user", content: userPrompt },
  ]);

  const content = response.choices[0]?.message?.content ?? "";
  const finishReason = response.choices[0]?.finish_reason;
  const jsonMatch = content.match(/\{[\s\S]*\}/);
  if (!jsonMatch) {
    log(`LLM returned no JSON (finish=${finishReason})`);
    return { action: "hold", reasoning: "LLM parse failure" };
  }

  const decision = JSON.parse(jsonMatch[0]);
  log(`LLM decision: ${decision.action.toUpperCase()}`, { reasoning: decision.reasoning });
  broadcast("decision", decision);

  if (decision.action === "hold") return decision;

  let newKp = BigInt(Math.round((decision.new_kp ?? 6.667e-7) * 1e18));
  let newKi = BigInt(Math.round((decision.new_ki ?? 6.667e-13) * 1e18));
  const isEmergency = decision.action === "adjust_emergency";

  // Clamp against on-chain policy (mirror deployed values)
  const POLICY = {
    KP_MIN: 333_333_333_333n, KP_MAX: 1_000_000_000_000n,
    KI_MIN: 333_333n, KI_MAX: 1_000_000n,
    MAX_KP_DELTA: 66_700_000_000n, // 6.67e10 (matches Deploy.s.sol)
    MAX_KI_DELTA: 66_700n,
  };
  const currentKp = BigInt(state.kpRaw);
  const currentKi = BigInt(state.kiRaw);
  const clampDelta = (proposed: bigint, current: bigint, max: bigint): bigint => {
    const d = proposed > current ? proposed - current : current - proposed;
    if (d <= max) return proposed;
    return proposed > current ? current + max : current - max;
  };
  const clampBounds = (v: bigint, lo: bigint, hi: bigint): bigint => (v < lo ? lo : v > hi ? hi : v);
  const kpClamped = clampBounds(clampDelta(newKp, currentKp, POLICY.MAX_KP_DELTA), POLICY.KP_MIN, POLICY.KP_MAX);
  const kiClamped = clampBounds(clampDelta(newKi, currentKi, POLICY.MAX_KI_DELTA), POLICY.KI_MIN, POLICY.KI_MAX);
  if (kpClamped !== newKp) log(`Clamped KP: ${newKp} → ${kpClamped}`);
  if (kiClamped !== newKi) log(`Clamped KI: ${newKi} → ${kiClamped}`);
  newKp = kpClamped;
  newKi = kiClamped;

  log(`Proposing KP=${decision.new_kp}, KI=${decision.new_ki}, emergency=${isEmergency}`);
  const hash = await wallet.writeContract({
    address: CFG.PARAMETER_GUARD_ADDRESS,
    abi: GUARD_ABI,
    functionName: "proposeParameters",
    args: [newKp, newKi, isEmergency],
    chain,
    account,
  });
  log(`Tx submitted: ${hash}`);
  broadcast("tx", { hash, type: "propose_parameters" });
  await pub.waitForTransactionReceipt({ hash });
  log("Tx confirmed!");

  const result = { ...decision, txHash: hash };
  // Append to decisions.jsonl so /api/history picks it up
  appendDecisionLog({
    timestamp: new Date().toISOString(),
    cycle: 0,
    action: decision.action,
    reasoning: decision.reasoning,
    btc_price_usd: state.collateralPrice.toFixed(2),
    btc_change_pct: state.btcChangePct.toFixed(2),
    btc_drop_baseline_pct: state.btcDropPct.toFixed(2),
    market_price_usd: state.marketPrice.toFixed(6),
    redemption_price_usd: state.redemptionPrice.toFixed(6),
    deviation_pct: state.deviationPct.toFixed(4),
    current_kp: state.kpRaw,
    current_ki: state.kiRaw,
    proposed_kp: newKp.toString(),
    proposed_ki: newKi.toString(),
    is_emergency: isEmergency,
    tx_hash: hash,
  });

  // Persist the new BTC baseline so the NEXT cycle's btcChangePct is delta vs THIS price
  persistLastBtc(state.collateralPrice);

  return result;
}

function appendDecisionLog(rec: Record<string, unknown>) {
  const path = join(__dirname, "..", "..", "agent", "decisions.jsonl");
  try {
    appendFileSync(path, JSON.stringify(rec) + "\n");
  } catch (e) {
    console.error("[server] could not append decision log:", e);
  }
}

// ── Oracle nudge ──────────────────────────────────────────────────────────
async function nudgeOracle(pctSigned: number) {
  const currentWad = (await pub.readContract({
    address: CFG.ORACLE_RELAYER_ADDRESS,
    abi: ORACLE_ABI,
    functionName: "getPriceWad",
    args: [CFG.WBTC_ADDRESS, CFG.USDC_ADDRESS],
  })) as bigint;
  if (currentWad === 0n) throw new Error("oracle returned 0 — call /cheat/reset first");

  const bp = BigInt(Math.round(pctSigned * 100));
  const newWad = (currentWad * (10000n + bp)) / 10000n;

  const oldUsd = Number(currentWad / WAD);
  const newUsd = Number(newWad / WAD);
  log(`CHEAT: BTC ${pctSigned >= 0 ? "+" : ""}${pctSigned}% → $${oldUsd} → $${newUsd}`);

  const hash = await wallet.writeContract({
    address: CFG.ORACLE_RELAYER_ADDRESS,
    abi: ORACLE_ABI,
    functionName: "updatePrice",
    args: [CFG.WBTC_ADDRESS, CFG.USDC_ADDRESS, newWad],
    chain,
    account,
  });
  log(`Oracle tx: ${hash}`);
  broadcast("tx", { hash, type: "oracle_update" });
  await pub.waitForTransactionReceipt({ hash });

  // RPC propagation safety: poll the oracle until the read reflects the new
  // value before continuing. Without this, downstream calls (agent cycle)
  // can hit a stale RPC node and see the OLD price for ~1-2 seconds.
  await waitForOracleSettled(newWad);
  log("Oracle updated and settled!");

  const state = await readState();
  broadcast("state", state);
  return { txHash: hash, newPrice: newUsd, oldPrice: oldUsd };
}

/**
 * Wait until the oracle reads the expected value CONSISTENTLY.
 *
 * Why this is needed: https://sepolia.unichain.org is a load-balanced endpoint
 * — sequential requests can hit different backend nodes that have slightly
 * different views of "latest" state. A single read returning the new value is
 * not enough; we need MULTIPLE consecutive matches to be confident every node
 * in the LB pool has caught up.
 */
async function waitForOracleSettled(expectedWad: bigint, timeoutMs = 15000) {
  const REQUIRED_CONSECUTIVE = 3;
  const start = Date.now();
  let lastRead = 0n;
  let stableCount = 0;
  while (Date.now() - start < timeoutMs) {
    try {
      lastRead = (await pub.readContract({
        address: CFG.ORACLE_RELAYER_ADDRESS,
        abi: ORACLE_ABI,
        functionName: "getPriceWad",
        args: [CFG.WBTC_ADDRESS, CFG.USDC_ADDRESS],
      })) as bigint;
      if (lastRead === expectedWad) {
        stableCount++;
        if (stableCount >= REQUIRED_CONSECUTIVE) {
          // One last buffer to let any remaining node catch up
          await new Promise((r) => setTimeout(r, 800));
          return;
        }
      } else {
        stableCount = 0;
      }
    } catch {
      stableCount = 0;
    }
    await new Promise((r) => setTimeout(r, 400));
  }
  log(`Oracle settle timeout — RPC last reported ${lastRead}, expected ${expectedWad}. Continuing anyway.`);
}

// ── Trigger a tiny swap on the V4 pool to fire afterSwap → PID ────────────
// Mirrors Cairo's `triggerSwap`: 1 GRIT in, USDC out. Tiny price impact, just
// enough to fire the hook's afterSwap callback.
async function triggerSwap() {
  const amountIn = WAD; // 1 GRIT raw (18 decimals)

  // Sort currencies (mirror SetupPool.s.sol logic)
  const grit = CFG.GRINTA_ENGINE_ADDRESS.toLowerCase();
  const usdc = CFG.USDC_ADDRESS.toLowerCase();
  const c0 = grit < usdc ? CFG.GRINTA_ENGINE_ADDRESS : CFG.USDC_ADDRESS;
  const c1 = grit < usdc ? CFG.USDC_ADDRESS : CFG.GRINTA_ENGINE_ADDRESS;
  // GRIT is the input token; if GRIT is c0 → zeroForOne=true, else false
  const gritIsC0 = grit < usdc;
  const zeroForOne = gritIsC0;
  const sqrtLimit = zeroForOne ? MIN_SQRT_PRICE + 1n : MAX_SQRT_PRICE - 1n;

  log("Approving SwapHelper for 1 GRIT…");
  const approveHash = await wallet.writeContract({
    address: CFG.GRINTA_ENGINE_ADDRESS, // GRIT lives in GrintaEngine (embedded ERC20)
    abi: ERC20_ABI,
    functionName: "approve",
    args: [CFG.SWAP_HELPER_ADDRESS, 2n ** 256n - 1n],
    chain,
    account,
  });
  await pub.waitForTransactionReceipt({ hash: approveHash });

  log("Swapping 1 GRIT → USDC…");
  const swapHash = await wallet.writeContract({
    address: CFG.SWAP_HELPER_ADDRESS,
    abi: SWAP_HELPER_ABI,
    functionName: "swap",
    args: [
      [c0, c1, CFG.POOL_FEE, CFG.POOL_TICK_SPACING, CFG.GRINTA_HOOK_ADDRESS] as const,
      zeroForOne,
      -amountIn,
      sqrtLimit,
      account.address,
    ],
    chain,
    account,
  });
  log(`Swap tx: ${swapHash}`);
  broadcast("tx", { hash: swapHash, type: "swap" });
  await pub.waitForTransactionReceipt({ hash: swapHash });
  log("Swap confirmed — afterSwap fired, PID rate updated.");

  return swapHash;
}

// ── Filecoin archive (optional) ───────────────────────────────────────────
const IPNS_CACHE_FILE = join(__dirname, "..", "lighthouse-ipns.json");

function getIpnsName(): string | null {
  try {
    if (existsSync(IPNS_CACHE_FILE)) {
      return JSON.parse(readFileSync(IPNS_CACHE_FILE, "utf-8")).ipnsName;
    }
  } catch {}
  return null;
}

function saveIpnsName(ipnsName: string) {
  writeFileSync(IPNS_CACHE_FILE, JSON.stringify({ ipnsName, updated: new Date().toISOString() }));
}

async function archiveToFilecoin(): Promise<{ cid: string; ipns: string; url: string } | null> {
  if (!CFG.LIGHTHOUSE_API_KEY) return null;
  let lighthouse: any;
  try {
    lighthouse = (await import("@lighthouse-web3/sdk")).default;
  } catch {
    log("LIGHTHOUSE_API_KEY set but @lighthouse-web3/sdk not installed");
    return null;
  }

  try {
    const jsonlPath = join(__dirname, "..", "..", "agent", "decisions.jsonl");
    if (!existsSync(jsonlPath)) return null;
    const lines = readFileSync(jsonlPath, "utf-8").trim().split("\n").filter(Boolean);
    if (lines.length === 0) return null;
    const records = lines.map((l) => JSON.parse(l));

    const blob = new Blob([JSON.stringify(records, null, 2)], { type: "application/json" });
    const cidResp: any = await lighthouse.uploadBuffer(
      Buffer.from(await blob.arrayBuffer()),
      CFG.LIGHTHOUSE_API_KEY,
    );
    const cid = cidResp.data?.cid || cidResp.cid || String(cidResp);

    let ipnsKey = getIpnsName();
    if (!ipnsKey) {
      const keyResp: any = await lighthouse.generateKey(CFG.LIGHTHOUSE_API_KEY);
      ipnsKey = keyResp.data.ipnsName;
      saveIpnsName(ipnsKey!);
    }
    await lighthouse.publishRecord(cid, ipnsKey, CFG.LIGHTHOUSE_API_KEY);
    const url = `https://ipfs.io/ipns/${ipnsKey}`;
    log(`Archived to Filecoin: ${url}`);
    return { cid, ipns: ipnsKey!, url };
  } catch (e: any) {
    log(`Filecoin archive error: ${e.message}`);
    return null;
  }
}

// ── Express ───────────────────────────────────────────────────────────────
const app = express();
app.use(cors());
app.use(express.json());

app.get("/api/identity", (_req, res) => {
  // No ERC-8004 identity on EVM yet — return shape the frontend understands as "no identity"
  res.status(404).json({ error: "agent identity not configured" });
});

app.get("/api/state", async (_req, res) => {
  try {
    res.json(await readState());
  } catch (e: any) {
    res.status(500).json({ error: e.message });
  }
});

app.post("/api/cheat/crash", async (req, res) => {
  try {
    const pct = Number(req.body.percent ?? 10);
    res.json(await nudgeOracle(-pct));
  } catch (e: any) {
    log(`CHEAT ERROR: ${e.message}`);
    res.status(500).json({ error: e.message });
  }
});

app.post("/api/cheat/pump", async (req, res) => {
  try {
    const pct = Number(req.body.percent ?? 10);
    res.json(await nudgeOracle(pct));
  } catch (e: any) {
    log(`CHEAT ERROR: ${e.message}`);
    res.status(500).json({ error: e.message });
  }
});

app.post("/api/cheat/reset", async (_req, res) => {
  try {
    const baseline = 60_000n * WAD;
    log("CHEAT: Resetting BTC to $60,000");
    const hash = await wallet.writeContract({
      address: CFG.ORACLE_RELAYER_ADDRESS,
      abi: ORACLE_ABI,
      functionName: "updatePrice",
      args: [CFG.WBTC_ADDRESS, CFG.USDC_ADDRESS, baseline],
      chain,
      account,
    });
    broadcast("tx", { hash, type: "oracle_reset" });
    await pub.waitForTransactionReceipt({ hash });
    log("Oracle reset!");
    const state = await readState();
    broadcast("state", state);
    res.json({ txHash: hash });
  } catch (e: any) {
    res.status(500).json({ error: e.message });
  }
});

app.post("/api/agent/trigger", async (_req, res) => {
  try {
    res.json(await runAgentCycle());
  } catch (e: any) {
    log(`AGENT ERROR: ${e.message}`);
    res.status(500).json({ error: e.message });
  }
});

app.post("/api/swap/trigger", async (_req, res) => {
  try {
    const txHash = await triggerSwap();
    const state = await readState();
    broadcast("state", state);
    res.json({ txHash });
  } catch (e: any) {
    log(`SWAP ERROR: ${e.message}`);
    res.status(500).json({ error: e.message });
  }
});

app.post("/api/demo/crash", async (req, res) => {
  try {
    const pct = Number(req.body.percent ?? 10);
    log(`DEMO: full crash sequence — BTC -${pct}%`);
    const { txHash: oracleTx } = await nudgeOracle(-pct);
    log("Step 1/3: Oracle updated");
    const decision = await runAgentCycle();
    log("Step 2/3: Agent decision complete");
    const swapTx = await triggerSwap();
    log("Step 3/3: Rate recalculated");
    const archive = await archiveToFilecoin();
    if (archive) broadcast("archive", archive);
    const finalState = await readState();
    broadcast("state", finalState);
    res.json({ oracleTx, decision, swapTx, finalState, archive });
  } catch (e: any) {
    log(`DEMO ERROR: ${e.message}`);
    res.status(500).json({ error: e.message });
  }
});

app.get("/api/history", async (_req, res) => {
  try {
    const jsonlPath = join(__dirname, "..", "..", "agent", "decisions.jsonl");
    if (!existsSync(jsonlPath)) return res.json({ rows: [], archiveUrl: null });
    const lines = readFileSync(jsonlPath, "utf-8").trim().split("\n").filter(Boolean);
    const decisions = lines.map((l) => JSON.parse(l)).reverse();
    let archiveUrl: string | null = null;
    try {
      if (existsSync(IPNS_CACHE_FILE)) {
        const cache = JSON.parse(readFileSync(IPNS_CACHE_FILE, "utf-8"));
        archiveUrl = `https://ipfs.io/ipns/${cache.ipnsName}`;
      }
    } catch {}
    res.json({ rows: decisions, archiveUrl });
  } catch (e: any) {
    res.status(500).json({ error: e.message });
  }
});

app.get("/api/stream", (req, res) => {
  res.writeHead(200, {
    "Content-Type": "text/event-stream",
    "Cache-Control": "no-cache",
    Connection: "keep-alive",
  });
  res.write("event: connected\ndata: {}\n\n");
  const clientId = ++sseId;
  sseClients.push({ id: clientId, res });
  console.log(`[SSE] Client ${clientId} connected (total: ${sseClients.length})`);
  req.on("close", () => {
    sseClients = sseClients.filter((c) => c.id !== clientId);
    console.log(`[SSE] Client ${clientId} disconnected (total: ${sseClients.length})`);
  });
});

// Serve frontend build in production
const distPath = join(__dirname, "..", "dist");
if (existsSync(distPath)) {
  app.use(express.static(distPath));
  app.get("*", (_req, res) => res.sendFile(join(distPath, "index.html")));
}

const PORT = Number(process.env.API_PORT ?? process.env.PORT ?? 3001);
app.listen(PORT, "0.0.0.0", () => {
  console.log(`\n  Horoi Governance API on http://0.0.0.0:${PORT}`);
  console.log(`  Wallet:   ${account.address}`);
  console.log(`  PID:      ${CFG.PID_CONTROLLER_ADDRESS}`);
  console.log(`  Guard:    ${CFG.PARAMETER_GUARD_ADDRESS}`);
  console.log(`  LLM:      ${CFG.LLM_MODEL}\n`);
});
