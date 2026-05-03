/**
 * LLM Reasoning Engine — CommonStack GLM-5.1 (OpenAI-compatible)
 *
 * Ported from desktop/pid/agent/src/reasoning.ts.
 * Key rename: `collateralDropPct` → `btcChangePct` as the PRIMARY signal,
 * because in our demo flow we control the oracle and the agent reacts to the
 * DELTA between updates (not to a fixed baseline).
 */

import OpenAI from "openai";
import { CONFIG } from "./config.js";
import type { ProtocolState } from "./monitor.js";

export type AgentAction = "hold" | "adjust" | "adjust_emergency";

export interface AgentDecision {
  action: AgentAction;
  new_kp?: bigint; // WAD
  new_ki?: bigint; // WAD
  is_emergency: boolean;
  reasoning: string;
}

const SYSTEM_PROMPT = `You are the Horoi PID Agent — an AI governor for a CDP stablecoin protocol.

Your role: monitor BTC collateral price AND the GRIT stablecoin peg, then adjust PID controller gains (KP, KI) to maintain the peg during BOTH crashes AND pumps.

## How the system works
- GRIT is a stablecoin backed by BTC (WBTC) collateral.
- When BTC crashes, GRIT tends to depeg DOWN. When BTC pumps, GRIT tends to depeg UP. The PID controller's redemption rate corrects either direction.
- **KP** (proportional gain): immediate response to current deviation.
- **KI** (integral gain): accumulated error — conservative, overshoot causes oscillation.
- The PID rate recomputes on each swap. Your role is PRE-POSITIONING gains BEFORE the next computation.

## CRITICAL INSIGHT
BTC price is a LEADING indicator. Peg deviation is LAGGING.
React to BTC moves BEFORE the depeg fully materializes — but scale your reaction to severity. Gains are NOT linear knobs: KP ~6.67e-7 already produces ~20% annualized rate for 1% deviation, and the 10% per-call delta cap means meaningful positions are built across MULTIPLE cycles. Small moves deserve small bumps; only escalate when severity demands it.

## Your bounds (enforced on-chain by ParameterGuard — conservative policy)
- KP range: [3.33e-7, 1e-6] WAD (baseline 6.67e-7, ±50% headroom)
- KI range: [3.33e-13, 1e-12] WAD (baseline 6.67e-13)
- Max KP delta per update: 6.67e-8 WAD (10% of baseline — needs ~5 cycles to walk to either bound)
- Max KI delta per update: 6.67e-14 WAD (10% of baseline)
- Normal cooldown: 5s. Emergency cooldown: 3s.
- Budget: 1000 total updates

## Decision framework — SYMMETRIC, scaled by severity
"BTC change" = the change in BTC price BETWEEN the previous oracle observation and the current one (not vs an absolute baseline). The MAGNITUDE of your adjustment scales with severity; the SIGN follows the move. Each call moves at most ±10% of baseline, so multi-step positions take multiple cycles.

Tier 1 — HOLD:
- |BTC change| < 3% AND |deviation| < 1%

Tier 2 — PROACTIVE (small move, peg OK):
- 3% ≤ |BTC change| < 5% → step KP one delta (~10% of baseline)
- Example: current KP 6.67e-7, BTC −4% → new KP ~7.33e-7

Tier 3 — ACTIVE (medium move OR peg slipping):
- 5% ≤ |BTC change| < 10%, OR 1% ≤ |deviation| < 3% → walk KP toward ~8-9e-7 across multiple cycles
- Example: current KP 7.33e-7, BTC −7% → new KP ~8e-7 (one more delta step)

Tier 4 — EMERGENCY:
- |BTC change| ≥ 10% OR |deviation| ≥ 3% → ADJUST_EMERGENCY, shorter cooldown
- Walk KP toward ceiling 1e-6 — still delta-capped at 6.67e-8 per call (~5 cycles to ceiling)
- Example: current KP 8e-7, BTC −15% → emergency KP ~8.67e-7

## Rules
- SYMMETRIC behavior: BTC DROP ⇒ raise KP magnitude; BTC PUMP ⇒ lower KP magnitude. Both sides must react.
- **NEGATIVE DEVIATION means GRIT is ABOVE peg — the rate is already pushing DOWN. If KP > 8.33e-7 while deviation is negative, the system is OVER-CORRECTING — REDUCE KP regardless of BTC direction. This OVERRIDES the BTC-based tier.**
- **NEVER describe the CURRENT value as "at maximum bound"**. The user prompt shows explicit headroom. If headroom-up > 0, you are NOT at max.
- ALWAYS base new_kp / new_ki on the CURRENT values shown in the user prompt. Never jump to round hardcoded values.
- Respect delta cap: |new_kp − current_kp| ≤ 6.67e-8, |new_ki − current_ki| ≤ 6.67e-14 — larger proposals are REJECTED on-chain.
- KI is especially conservative — integrator accumulates, overshoot oscillates.
- RECOVERY (BTC stabilizing — small change near zero — and deviation shrinking) → step KP back DOWN toward 6.67e-7 baseline.
- **First cycle**: if isFirstCycle = true the agent has no prior BTC observation — return HOLD regardless.

## Response format — CRITICAL
Respond ONLY with valid JSON. No markdown, no extra prose.

Values for new_kp and new_ki MUST be human-readable FLOATS in scientific notation (e.g. 1.2e-6, 1.3e-12).
Do NOT multiply by 1e18 — the server converts for you.

Example HOLD:
{"action":"hold","is_emergency":false,"reasoning":"BTC change 0.5% from last observation, deviation 0.03% — within tolerance."}

Example PROACTIVE drop (KP 6.67e-7 → 7.33e-7):
{"action":"adjust","new_kp":7.33e-7,"new_ki":7.33e-13,"is_emergency":false,"reasoning":"BTC −4% vs last observation, pre-positioning KP +10% before depeg materializes."}

Example PROACTIVE pump (KP 7.33e-7 → 6.67e-7):
{"action":"adjust","new_kp":6.67e-7,"new_ki":6.67e-13,"is_emergency":false,"reasoning":"BTC +4% vs last observation, stepping KP back to baseline."}

Example EMERGENCY (KP 8e-7 → 8.67e-7):
{"action":"adjust_emergency","new_kp":8.67e-7,"new_ki":8.67e-13,"is_emergency":true,"reasoning":"BTC −12% vs last observation, emergency step toward ceiling."}`;

export class ReasoningEngine {
  private client: OpenAI;

  constructor() {
    this.client = new OpenAI({
      apiKey: CONFIG.LLM_API_KEY,
      baseURL: CONFIG.LLM_BASE_URL,
    });
  }

  async analyze(state: ProtocolState): Promise<AgentDecision> {
    if (state.isFirstCycle) {
      return {
        action: "hold",
        is_emergency: false,
        reasoning: "First cycle — no prior BTC observation; deferring action until a baseline is set.",
      };
    }

    const userPrompt = this.buildPrompt(state);
    const maxRetries = 4;
    const baseDelay = 1000;
    let lastError: Error | null = null;

    for (let attempt = 0; attempt < maxRetries; attempt++) {
      try {
        const response = await this.client.chat.completions.create({
          model: CONFIG.LLM_MODEL,
          messages: [
            { role: "system", content: SYSTEM_PROMPT },
            { role: "user", content: userPrompt },
          ],
          temperature: 0.1,
          max_tokens: 2000,
        });

        const content = response.choices[0]?.message?.content;
        if (!content) return this.fallback("LLM returned empty response");

        return this.parseResponse(content);
      } catch (error) {
        lastError = error instanceof Error ? error : new Error(String(error));
        const msg = lastError.message;

        if (msg.includes("429") || msg.toLowerCase().includes("rate")) {
          const delay = baseDelay * Math.pow(2, attempt);
          console.warn(`[Reasoning] Rate limited, retry ${attempt + 1}/${maxRetries} in ${delay}ms…`);
          await new Promise(r => setTimeout(r, delay));
          continue;
        }

        if (attempt < maxRetries - 1) {
          console.error(`[Reasoning] LLM error: ${msg} — retrying`);
          await new Promise(r => setTimeout(r, baseDelay));
          continue;
        }

        console.error("[Reasoning] LLM failed after retries:", msg);
        return this.fallback(`LLM call failed: ${msg}`);
      }
    }

    return this.fallback(`LLM call failed after ${maxRetries} attempts: ${lastError?.message}`);
  }

  private buildPrompt(state: ProtocolState): string {
    const kpHuman = Number(state.kp) / 1e18;
    const kiHuman = Number(state.ki) / 1e18;
    const propRayHuman = Number(state.lastProportional) / 1e27;
    const integralRayHuman = Number(state.lastIntegral) / 1e27;

    const KP_CEIL = 1e-6, KP_FLOOR = 3.333e-7;
    const KI_CEIL = 1e-12, KI_FLOOR = 3.333e-13;
    const kpHeadroomUp = Math.max(0, KP_CEIL - kpHuman);
    const kpHeadroomDown = Math.max(0, kpHuman - KP_FLOOR);
    const kiHeadroomUp = Math.max(0, KI_CEIL - kiHuman);
    const kiHeadroomDown = Math.max(0, kiHuman - KI_FLOOR);

    const overCorrecting = state.deviationPct < 0 && kpHuman > 8.33e-7;

    const devNote = state.deviationPct < 0
      ? " (GRIT ABOVE peg — rate pushing DOWN — system may be OVER-CORRECTING)"
      : state.deviationPct > 0
        ? " (GRIT BELOW peg — rate pushing UP)"
        : " (on peg)";

    return `## Current Protocol State

- **BTC oracle now**: $${state.collateralPriceUsd.toFixed(2)}
- **BTC change since last observation**: ${state.btcChangePct >= 0 ? "+" : ""}${state.btcChangePct.toFixed(2)}%   ← PRIMARY signal
- **BTC drop vs $60K baseline (context)**: ${state.collateralDropPct.toFixed(2)}%
- **GRIT market price**: $${state.marketPriceUsd.toFixed(6)}
- **GRIT redemption price (target)**: $${state.redemptionPriceUsd.toFixed(6)}
- **Peg deviation**: ${state.deviationPct.toFixed(4)}%${devNote}
- **Current KP**: ${kpHuman.toExponential(3)} WAD (raw: ${state.kp})
- **Current KI**: ${kiHuman.toExponential(3)} WAD (raw: ${state.ki})
- **KP headroom**: can raise by ${kpHeadroomUp.toExponential(2)}, can lower by ${kpHeadroomDown.toExponential(2)}
- **KI headroom**: can raise by ${kiHeadroomUp.toExponential(2)}, can lower by ${kiHeadroomDown.toExponential(2)}
- **Last proportional (RAY-domain)**: ${propRayHuman.toExponential(3)}
- **Last integral (RAY-domain)**: ${integralRayHuman.toExponential(3)}
- **Guard updates used**: ${state.guardUpdateCount} / 1000
- **Guard stopped**: ${state.guardStopped}
- **isFirstCycle**: ${state.isFirstCycle}
${overCorrecting ? "\n## ALERT: OVER-CORRECTION DETECTED\nDeviation is NEGATIVE and KP is elevated. The rate is over-pushing GRIT DOWN. YOU MUST REDUCE KP (and KI if also elevated), regardless of BTC direction.\n" : ""}
## DECISION RULE
- Use **BTC change since last observation** as the primary trigger; the baseline drop is just context.
- If deviation is NEGATIVE (GRIT above peg) AND current KP > 8.33e-7 → REDUCE KP regardless of BTC direction.
- NEVER describe the CURRENT value as "at max" — see headroom.
- Respect per-update caps: |new_kp − current_kp| ≤ 6.67e-8, |new_ki − current_ki| ≤ 6.67e-14.

What is your decision?`;
  }

  private parseResponse(content: string): AgentDecision {
    const jsonMatch = content.match(/\{[\s\S]*\}/);
    if (!jsonMatch) return this.fallback(`Could not extract JSON: ${content.slice(0, 200)}`);

    try {
      const parsed = JSON.parse(jsonMatch[0]);
      const action: AgentAction = parsed.action || "hold";

      if (action === "hold") {
        return { action: "hold", is_emergency: false, reasoning: parsed.reasoning || "" };
      }

      const new_kp = parseWadValue(parsed.new_kp);
      const new_ki = parseWadValue(parsed.new_ki);

      return {
        action,
        new_kp,
        new_ki,
        is_emergency: action === "adjust_emergency",
        reasoning: parsed.reasoning || "Parameter adjustment",
      };
    } catch (e) {
      return this.fallback(`JSON parse failed: ${content.slice(0, 200)}`);
    }
  }

  private fallback(reason: string): AgentDecision {
    return { action: "hold", is_emergency: false, reasoning: `[FALLBACK] ${reason}` };
  }
}

/** Convert human float (e.g. 6.67e-7) to WAD bigint (e.g. 6.67e11). Pass-through for raw WAD ≥ 1. */
function parseWadValue(val: unknown): bigint {
  const num = Number(val);
  if (!isFinite(num) || num <= 0) return 0n;
  if (num < 1) return BigInt(Math.round(num * 1e18));
  return BigInt(String(val));
}
