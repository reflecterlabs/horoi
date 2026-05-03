# Uniswap API Feedback

## Project: Horoi Protocol (OpenAgents ETHGlobal)

**Date:** 2025-04-29  
**Integrator:** Horoi Agent (EVM/Unichain)

## Integration Summary

We integrated the Uniswap API to enhance the agent's decision-making with real-time pool state data:

### What We Built

1. **Pool State Fetching** (`agent/src/adapters/uniswap.ts`)
   - Endpoint: `POST /pool/info`
   - Fetches: liquidity, sqrtPriceX96, fee tier, tick data
   - For: ETH/USDC pool on Unichain

2. **Swap Simulation** (placeholder)
   - Estimates slippage based on pool depth
   - Would use Routing API for full simulation

3. **Integration in Reasoning**
   - Before proposing: agent checks pool liquidity
   - Decision consideration: "if I adjust KP 10%, next swap has Y slippage"

## Experience

### What Worked Well
- API response structure matches docs
- Support for V2/V3/V4 pools
- Chain ID 1301 (Unichain Sepolia) supported

### What Could Be Improved
1. **Missing**: Pool discovery endpoint — have to know pool address upfront
2. **Missing**: Real-time swap simulation endpoint (quote API)
3. **Issue**: No Unichain-specific docs — inferred chain ID from Base

### Suggestions
- Add `GET /pool/find?tokenA=X&tokenB=Y` endpoint
- Add swap simulation to Routing API response
- Document Unichain chain ID explicitly

## Code Snippet

```typescript
const pool = await fetchPoolState(poolAddress, "v4");
console.log(`Liquidity: ${pool.liquidity}, Slippage: ${pool.slippageBps}bps`);
```

## Prize Consideration

This integration demonstrates:
- ✅ Real API usage (not mock)
- ✅ Pool state in agent decision flow
- ✅ Documented experience (this file)
- ✅ EVM + Uniswap V4 on Unichain

---

For questions: reach out to the Horoi team or check `agent/src/adapters/uniswap.ts`