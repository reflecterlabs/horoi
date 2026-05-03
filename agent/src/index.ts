/**
 * Horoi PID Agent — Entry Point
 *
 * Loop: Monitor → Reason (CommonStack/GLM) → Execute → Log
 */

import { CONFIG } from "./config.js";
import { Monitor, type ProtocolState } from "./monitor.js";
import { ReasoningEngine, type AgentDecision } from "./reasoning.js";
import { Executor } from "./executor.js";
import { logDecision, nextCycle, type DecisionRecord } from "./logger.js";

class HoroiAgent {
  private monitor = new Monitor();
  private reasoning = new ReasoningEngine();
  private executor = new Executor();
  private isRunning = false;
  private lastConfirmedGains: { kp: bigint; ki: bigint } | undefined;

  async start(monitorOnly = false): Promise<void> {
    console.log("=".repeat(64));
    console.log("  Horoi PID Agent — agent-as-governor (Unichain Sepolia)");
    console.log("=".repeat(64));
    console.log(`  Agent address  : ${this.executor.address}`);
    console.log(`  LLM model      : ${CONFIG.LLM_MODEL}`);
    console.log(`  ParameterGuard : ${CONFIG.PARAMETER_GUARD_ADDRESS}`);
    console.log(`  PIDController  : ${CONFIG.PID_CONTROLLER_ADDRESS}`);
    console.log(`  GrintaHook     : ${CONFIG.GRINTA_HOOK_ADDRESS}`);
    console.log(`  OracleRelayer  : ${CONFIG.ORACLE_RELAYER_ADDRESS}`);
    console.log(`  Check interval : ${CONFIG.CHECK_INTERVAL_MS / 1000}s`);
    console.log(`  Mode           : ${monitorOnly ? "MONITOR-ONLY (no tx)" : "FULL"}`);
    console.log("=".repeat(64));
    console.log("");

    this.isRunning = true;
    while (this.isRunning) {
      await this.runCycle(monitorOnly);
      await sleep(CONFIG.CHECK_INTERVAL_MS);
    }
  }

  stop(): void {
    this.isRunning = false;
    console.log("\n[Agent] Stopped.");
  }

  private async runCycle(monitorOnly: boolean): Promise<void> {
    const cycle = nextCycle();
    const timestamp = new Date().toISOString();

    let state: ProtocolState;
    try {
      state = await this.monitor.getState(this.lastConfirmedGains);
      this.lastConfirmedGains = undefined;
    } catch (e) {
      console.error(`[c${cycle}] Failed to read state:`, e);
      return;
    }

    if (state.guardStopped) {
      console.log(`[c${cycle}] Guard STOPPED — skip`);
      this.monitor.persistBtcPrice(state.collateralPriceUsd);
      return;
    }

    let decision: AgentDecision;
    try {
      decision = await this.reasoning.analyze(state);
    } catch (e) {
      console.error(`[c${cycle}] Reasoning failed:`, e);
      this.monitor.persistBtcPrice(state.collateralPriceUsd);
      return;
    }

    const record: DecisionRecord = {
      timestamp,
      cycle,
      action: decision.action,
      reasoning: decision.reasoning,
      btc_price_usd: state.collateralPriceUsd.toFixed(2),
      btc_change_pct: state.btcChangePct.toFixed(2),
      btc_drop_baseline_pct: state.collateralDropPct.toFixed(2),
      market_price_usd: state.marketPriceUsd.toFixed(6),
      redemption_price_usd: state.redemptionPriceUsd.toFixed(6),
      deviation_pct: state.deviationPct.toFixed(4),
      current_kp: state.kp.toString(),
      current_ki: state.ki.toString(),
      is_emergency: decision.is_emergency,
    };

    if (
      !monitorOnly &&
      decision.action !== "hold" &&
      decision.new_kp != null &&
      decision.new_ki != null &&
      decision.new_kp > 0n &&
      decision.new_ki > 0n
    ) {
      record.proposed_kp = decision.new_kp.toString();
      record.proposed_ki = decision.new_ki.toString();
      try {
        const result = await this.executor.proposeParameters(
          decision.new_kp,
          decision.new_ki,
          decision.is_emergency,
          decision.reasoning,
          state.deviationPct
        );
        record.tx_hash = result.txHash;
        this.lastConfirmedGains = { kp: result.confirmedKp, ki: result.confirmedKi };
      } catch (e) {
        record.error = e instanceof Error ? e.message : String(e);
      }
    }

    logDecision(record);
    // Persist current price as the new baseline for the next cycle's delta calc
    this.monitor.persistBtcPrice(state.collateralPriceUsd);
  }
}

function sleep(ms: number): Promise<void> {
  return new Promise(r => setTimeout(r, ms));
}

async function main(): Promise<void> {
  const monitorOnly = process.argv.includes("--monitor-only");
  const agent = new HoroiAgent();
  process.on("SIGINT", () => {
    agent.stop();
    process.exit(0);
  });
  await agent.start(monitorOnly);
}

main().catch(e => {
  console.error("Fatal:", e);
  process.exit(1);
});
