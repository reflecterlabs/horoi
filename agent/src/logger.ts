/**
 * Decision Logger — JSONL append + console formatting.
 */

import { appendFileSync } from "fs";
import { DECISIONS_LOG_PATH } from "./config.js";
import type { AgentAction } from "./reasoning.js";

let cycleCounter = 0;
export function nextCycle(): number {
  cycleCounter += 1;
  return cycleCounter;
}

export interface DecisionRecord {
  timestamp: string;
  cycle: number;
  action: AgentAction;
  reasoning: string;
  btc_price_usd: string;
  btc_change_pct: string;
  btc_drop_baseline_pct: string;
  market_price_usd: string;
  redemption_price_usd: string;
  deviation_pct: string;
  current_kp: string;
  current_ki: string;
  proposed_kp?: string;
  proposed_ki?: string;
  is_emergency: boolean;
  tx_hash?: string;
  error?: string;
}

export function logDecision(record: DecisionRecord): void {
  // JSONL append for the dashboard / replay
  try {
    appendFileSync(DECISIONS_LOG_PATH, JSON.stringify(record) + "\n");
  } catch (e) {
    console.error("[Logger] Failed to append decision:", e);
  }

  // Pretty console line
  const tag =
    record.action === "hold"
      ? "[HOLD]"
      : record.action === "adjust_emergency"
        ? "[EMERG]"
        : "[ADJ]";
  const txTail = record.tx_hash ? ` tx=${record.tx_hash.slice(0, 10)}…` : "";
  const errTail = record.error ? ` ERR=${record.error.slice(0, 80)}` : "";
  const line =
    `[c${record.cycle.toString().padStart(3, "0")}] ${tag} ` +
    `BTC=$${record.btc_price_usd} (${record.btc_change_pct.startsWith("-") ? "" : "+"}${record.btc_change_pct}%) ` +
    `dev=${record.deviation_pct}% kp=${record.current_kp}` +
    txTail +
    errTail;
  console.log(line);
  if (record.reasoning) {
    console.log(`         → ${record.reasoning}`);
  }
}
