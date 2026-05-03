/**
 * On-Chain Monitor — reads protocol state from Unichain Sepolia
 *
 * Reads:
 *   - Market price (GRIT/USD) from GrintaHook
 *   - Collateral price (BTC/USD) from GrintaEngine (set by hook from oracle)
 *   - Redemption price + rate from GrintaEngine
 *   - Current KP/KI + last deviation from PIDController
 *   - Guard state (stopped, update count) from ParameterGuard
 *
 * Computes:
 *   - btcChangePct  = (current - lastSeen) / lastSeen * 100  ← PRIMARY signal
 *   - collateralDropPct = (BASELINE_60K - current) / BASELINE_60K * 100  ← context
 *   - deviationPct  = (redemption - market) / redemption * 100
 *
 * Persists `lastBtcPrice` to state.json so cycles compare deltas, not absolutes.
 */

import { createPublicClient, http, parseAbi } from "viem";
import { readFileSync, writeFileSync, existsSync } from "fs";
import { CONFIG, WAD, RAY, STATE_FILE_PATH } from "./config.js";

// ---- ABIs ----

const HOOK_ABI = parseAbi([
  "function getMarketPrice() view returns (uint256)",
  "function getCollateralPrice() view returns (uint256)",
]);

const ORACLE_ABI = parseAbi([
  "function getPriceWad(address baseToken, address quoteToken) view returns (uint256)",
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
]);

// ---- Types ----

export interface ProtocolState {
  // Raw on-chain
  marketPrice: bigint; // WAD
  collateralPrice: bigint; // WAD — BTC/USD
  redemptionPrice: bigint; // RAY
  redemptionRate: bigint; // RAY
  kp: bigint; // int128 signed
  ki: bigint; // int128 signed
  lastProportional: bigint; // int128 signed (RAY-scale post-fix)
  lastIntegral: bigint; // int128 signed
  lastDeviationTimestamp: bigint;
  guardStopped: boolean;
  guardUpdateCount: number;
  guardLastUpdate: bigint;

  // Derived
  collateralPriceUsd: number;
  marketPriceUsd: number;
  redemptionPriceUsd: number;
  deviationPct: number;        // (redemption - market)/redemption * 100
  btcChangePct: number;        // PRIMARY: change from last observed BTC
  collateralDropPct: number;   // SECONDARY: drop from $60k baseline
  isFirstCycle: boolean;       // true when no prior lastBtcPrice persisted
}

interface PersistedState {
  lastBtcPrice: number;
  lastBtcAt: string;
}

// ---- Monitor ----

export class Monitor {
  private client = createPublicClient({
    chain: {
      id: CONFIG.CHAIN_ID,
      name: "Unichain Sepolia",
      nativeCurrency: { name: "ETH", symbol: "ETH", decimals: 18 },
      rpcUrls: { default: { http: [CONFIG.RPC_URL] } },
    },
    transport: http(CONFIG.RPC_URL),
  });

  async getState(knownGains?: { kp: bigint; ki: bigint }): Promise<ProtocolState> {
    // Parallel readContract — robust across chains (no multicall3 dependency)
    const read = <T>(address: `0x${string}`, abi: any, fn: string, args?: any[]) =>
      this.client.readContract({ address, abi, functionName: fn, args: args as any }) as Promise<T>;

    // Read BTC price DIRECTLY from oracle, not engine.collateralPrice (which lags
    // until the hook propagates on swap or after its 60s throttle).
    const [
      marketPrice,
      collateralPrice,
      redemptionPrice,
      redemptionRate,
      kpRaw,
      kiRaw,
      lastProportional,
      lastIntegral,
      lastDeviationTimestamp,
      guardStopped,
      guardUpdateCount,
      guardLastUpdate,
    ] = await Promise.all([
      read<bigint>(CONFIG.GRINTA_HOOK_ADDRESS, HOOK_ABI, "getMarketPrice"),
      read<bigint>(CONFIG.ORACLE_RELAYER_ADDRESS, ORACLE_ABI, "getPriceWad", [CONFIG.WBTC_ADDRESS, CONFIG.USDC_ADDRESS]),
      read<bigint>(CONFIG.GRINTA_ENGINE_ADDRESS, ENGINE_ABI, "getRedemptionPrice"),
      read<bigint>(CONFIG.GRINTA_ENGINE_ADDRESS, ENGINE_ABI, "redemptionRate"),
      read<bigint>(CONFIG.PID_CONTROLLER_ADDRESS, PID_ABI, "kp"),
      read<bigint>(CONFIG.PID_CONTROLLER_ADDRESS, PID_ABI, "ki"),
      read<bigint>(CONFIG.PID_CONTROLLER_ADDRESS, PID_ABI, "deviationProportional"),
      read<bigint>(CONFIG.PID_CONTROLLER_ADDRESS, PID_ABI, "deviationIntegral"),
      read<bigint>(CONFIG.PID_CONTROLLER_ADDRESS, PID_ABI, "deviationTimestamp"),
      read<boolean>(CONFIG.PARAMETER_GUARD_ADDRESS, GUARD_ABI, "stopped"),
      read<bigint>(CONFIG.PARAMETER_GUARD_ADDRESS, GUARD_ABI, "updateCount"),
      read<bigint>(CONFIG.PARAMETER_GUARD_ADDRESS, GUARD_ABI, "lastUpdateTimestamp"),
    ]);

    // Use write-through gains if just-confirmed (RPC may return stale)
    const kp = knownGains?.kp ?? (kpRaw as bigint);
    const ki = knownGains?.ki ?? (kiRaw as bigint);

    const mp = marketPrice as bigint;
    const cp = collateralPrice as bigint;
    const rp = redemptionPrice as bigint;

    // Human values
    const mpUsd = Number(mp) / Number(WAD);
    const cpUsd = Number(cp) / Number(WAD);
    const rpRaw = Number(rp) / Number(RAY);
    const rpUsd = rpRaw > 0.5 && rpRaw < 2.0 ? rpRaw : 1.0;

    // Deviation: (redemption - market) / redemption — POSITIVE means GRIT below peg
    const deviationPct = rpUsd > 0 ? ((rpUsd - mpUsd) / rpUsd) * 100 : 0;

    // BTC change vs persisted last price
    const persisted = loadPersistedState();
    const isFirstCycle = persisted === null;
    const btcChangePct =
      persisted && persisted.lastBtcPrice > 0
        ? ((cpUsd - persisted.lastBtcPrice) / persisted.lastBtcPrice) * 100
        : 0;

    // Drop vs absolute baseline
    const collateralDropPct =
      cpUsd > 0 ? ((CONFIG.BTC_BASELINE - cpUsd) / CONFIG.BTC_BASELINE) * 100 : 0;

    return {
      marketPrice: mp,
      collateralPrice: cp,
      redemptionPrice: rp,
      redemptionRate: redemptionRate as bigint,
      kp,
      ki,
      lastProportional: lastProportional as bigint,
      lastIntegral: lastIntegral as bigint,
      lastDeviationTimestamp: BigInt(lastDeviationTimestamp as bigint),
      guardStopped: guardStopped as boolean,
      guardUpdateCount: Number(guardUpdateCount as bigint),
      guardLastUpdate: BigInt(guardLastUpdate as bigint),
      collateralPriceUsd: cpUsd,
      marketPriceUsd: mpUsd,
      redemptionPriceUsd: rpUsd,
      deviationPct,
      btcChangePct,
      collateralDropPct,
      isFirstCycle,
    };
  }

  /**
   * Persist the current BTC price as `lastBtcPrice` so the next cycle can compute the delta.
   * Call this AFTER a cycle completes (regardless of whether the agent acted).
   */
  persistBtcPrice(cpUsd: number): void {
    const data: PersistedState = {
      lastBtcPrice: cpUsd,
      lastBtcAt: new Date().toISOString(),
    };
    writeFileSync(STATE_FILE_PATH, JSON.stringify(data, null, 2));
  }
}

// ---- Helpers ----

function loadPersistedState(): PersistedState | null {
  if (!existsSync(STATE_FILE_PATH)) return null;
  try {
    const raw = readFileSync(STATE_FILE_PATH, "utf-8");
    const parsed = JSON.parse(raw);
    if (typeof parsed.lastBtcPrice === "number") return parsed as PersistedState;
    return null;
  } catch {
    return null;
  }
}

/** Reset the persisted baseline so the next cycle treats current price as the new "last". */
export function resetPersistedBaseline(): void {
  if (existsSync(STATE_FILE_PATH)) {
    writeFileSync(STATE_FILE_PATH, JSON.stringify({ lastBtcPrice: 0, lastBtcAt: new Date().toISOString() }, null, 2));
  }
}
