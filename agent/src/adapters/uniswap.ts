/**
 * Uniswap API Adapter
 * 
 * Fetches pool state for the agent to use in decision making.
 * Required for Uniswap Foundation prize.
 * 
 * API docs: https://api-docs.uniswap.org/api-reference/liquidity_provisioning/pool_info
 */

import { CONFIG } from "./config.js";

export interface PoolState {
  poolId: string;
  protocol: "v2" | "v3" | "v4";
  token0: string;
  token1: string;
  token0Symbol: string;
  token1Symbol: string;
  feeTier?: number;
  liquidity: bigint;
  sqrtPriceX96: bigint;
  currentTick?: number;
  token0Reserves?: bigint;
  token1Reserves?: bigint;
  // Derived
  price0: number; // token1 per token0
  price1: number; // token0 per token1
  slippageBps: number; // estimated slippage for 1% swap
}

export interface SwapSimulation {
  inputAmount: bigint;
  outputAmount: bigint;
  priceImpact: number; // percentage
  slippageBps: number; // basis points
}

/**
 * Fetch pool info from Uniswap API
 */
export async function fetchPoolState(
  poolAddressOrId: string,
  protocol: "v2" | "v3" | "v4" = "v4"
): Promise<PoolState> {
  const response = await fetch(`${CONFIG.UNISWAP_API_URL}/pool/info`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      // API key if provided
      ...(process.env.UNISWAP_API_KEY && {
        "X-API-KEY": process.env.UNISWAP_API_KEY,
      }),
    },
    body: JSON.stringify({
      protocol,
      poolReferences: [{ poolReferenceIdentifier: poolAddressOrId }],
      chainId: 1301, // Unichain Sepolia
    }),
  });

  if (!response.ok) {
    throw new Error(`Uniswap API error: ${response.status} ${response.statusText}`);
  }

  const data = await response.json();
  const pool = data.pools?.[0];

  if (!pool) {
    throw new Error(`Pool not found: ${poolAddressOrId}`);
  }

  // Calculate prices from sqrtPriceX96
  const sqrtPriceX96 = BigInt(pool.sqrtRatioX96);
  const price0 = Number(sqrtPriceX96 ** 2n) / 1e64; // Simplified
  const price1 = 1 / price0;

  // Estimate slippage (simplified - in production use proper math)
  // More liquidity = less slippage
  const liquidity = BigInt(pool.poolLiquidity);
  const slippageBps = liquidity > 1_000_000n ? 5 : liquidity > 100_000n ? 20 : 100;

  return {
    poolId: pool.poolReferenceIdentifier,
    protocol,
    token0: pool.tokenAddressA,
    token1: pool.tokenAddressB,
    token0Symbol: pool.tokenSymbolA,
    token1Symbol: pool.tokenSymbolB,
    feeTier: pool.fee,
    liquidity,
    sqrtPriceX96,
    currentTick: pool.currentTick,
    price0,
    price1,
    slippageBps,
  };
}

/**
 * Simulate a swap to estimate impact
 * Note: This is a simplified version. In production, use the Routing API.
 */
export async function simulateSwap(
  poolAddressOrId: string,
  tokenIn: "token0" | "token1",
  amountIn: bigint
): Promise<SwapSimulation> {
  // Get pool state
  const pool = await fetchPoolState(poolAddressOrId);
  
  // Simplified slippage calculation
  // In reality, you'd use the Routing API or swap simulation
  const poolDepth = Number(pool.liquidity);
  const inputAmountNum = Number(amountIn);
  
  // Linear slippage model
  const priceImpact = (inputAmountNum / poolDepth) * 100;
  const slippageBps = Math.round(priceImpact * 100); // Convert to basis points
  
  // Output amount (simplified - assumes constant product)
  const outputAmount = amountIn * BigInt(Math.round(pool.price1 * 1e6)) / 1n;
  
  return {
    inputAmount,
    outputAmount,
    priceImpact,
    slippageBps,
  };
}

/**
 * Get pool for a token pair
 * Note: Requires knowing the pool address first
 */
export async function getPoolForTokens(
  tokenA: string,
  tokenB: string,
  protocol: "v2" | "v3" | "v4" = "v4"
): Promise<string | null> {
  // In production, use the subgraph or a pool finder API
  // This is a placeholder - you'dneed to query the PoolManager or subgraph
  throw new Error("Use subgraph to find pool address first");
}