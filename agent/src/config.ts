/**
 * Agent Configuration — Unichain Sepolia
 *
 * Loads:
 *   1. ../contracts/.env  — for PRIVATE_KEY (shared with the deployer)
 *   2. ./.env             — for everything else (RPC, addresses, LLM)
 */

import dotenv from "dotenv";
import { fileURLToPath } from "url";
import { dirname, join } from "path";

const __dirname = dirname(fileURLToPath(import.meta.url));

// Load PK from contracts/.env first (so we don't duplicate the secret)
dotenv.config({ path: join(__dirname, "..", "..", "contracts", ".env") });
// Override / extend with agent's own .env
dotenv.config({ path: join(__dirname, "..", ".env"), override: false });

function requireEnv(key: string): string {
  const v = process.env[key];
  if (!v) throw new Error(`Missing env var: ${key}`);
  return v;
}

function envBool(key: string): boolean {
  return process.env[key] === "true" || process.env[key] === "1";
}

export const CONFIG = {
  // Network
  RPC_URL: process.env.RPC_URL ?? "https://sepolia.unichain.org",
  CHAIN_ID: Number(process.env.CHAIN_ID ?? 1301),

  // Agent wallet — PK shared with deployer via contracts/.env
  AGENT_PRIVATE_KEY: requireEnv("PRIVATE_KEY"),
  AGENT_ADDRESS: requireEnv("AGENT_ADDRESS"),

  // LLM (OpenAI-compatible: OpenRouter / Groq / CommonStack / etc.)
  LLM_API_KEY: requireEnv("LLM_API_KEY"),
  LLM_BASE_URL: process.env.LLM_BASE_URL ?? "https://openrouter.ai/api/v1",
  LLM_MODEL: process.env.LLM_MODEL ?? "minimax/minimax-m2.5:free",

  // 0G Compute (testnet) — optional, switched via LLM_PROVIDER
  ZEROG_COMPUTE_URL: process.env.ZEROG_COMPUTE_URL,
  ZEROG_COMPUTE_API_KEY: process.env.ZEROG_COMPUTE_API_KEY,
  ZEROG_COMPUTE_MODEL: process.env.ZEROG_COMPUTE_MODEL ?? "qwen/qwen-2.5-7b-instruct",
  
  // Provider switch: "openrouter" (default) or "zerog"
  LLM_PROVIDER: process.env.LLM_PROVIDER ?? "openrouter",

  // Contracts
  ORACLE_RELAYER_ADDRESS: requireEnv("ORACLE_RELAYER_ADDRESS") as `0x${string}`,
  GRINTA_ENGINE_ADDRESS: requireEnv("GRINTA_ENGINE_ADDRESS") as `0x${string}`,
  PID_CONTROLLER_ADDRESS: requireEnv("PID_CONTROLLER_ADDRESS") as `0x${string}`,
  GRINTA_HOOK_ADDRESS: requireEnv("GRINTA_HOOK_ADDRESS") as `0x${string}`,
  PARAMETER_GUARD_ADDRESS: requireEnv("PARAMETER_GUARD_ADDRESS") as `0x${string}`,
  WBTC_ADDRESS: requireEnv("WBTC_ADDRESS") as `0x${string}`,
  USDC_ADDRESS: requireEnv("USDC_ADDRESS") as `0x${string}`,

  // Behaviour
  CHECK_INTERVAL_MS: Number(process.env.CHECK_INTERVAL_MS ?? 15000),
  BTC_BASELINE: Number(process.env.BTC_BASELINE ?? 60000),
  MONITOR_ONLY: envBool("MONITOR_ONLY"),
} as const;

/** WAD = 1e18 */
export const WAD = 10n ** 18n;
/** RAY = 1e27 */
export const RAY = 10n ** 27n;

/** Path to persistent state file (lastBtcPrice, etc.) */
export const STATE_FILE_PATH = join(__dirname, "..", "state.json");

/** Path to JSONL log of decisions */
export const DECISIONS_LOG_PATH = join(__dirname, "..", "decisions.jsonl");
