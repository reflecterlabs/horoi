/**
 * Executor — calls ParameterGuard.proposeParameters(int128, int128, bool)
 *
 * Selector is int128-based (matches the contract). Previous version used int256,
 * which produced a wrong selector and silently reverted on the first proposal.
 */

import { createWalletClient, createPublicClient, http, parseAbi } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { CONFIG } from "./config.js";
import { storePDR, type PDR } from "./adapters/zerog.js";

export interface ExecutionResult {
  txHash: `0x${string}`;
  confirmedKp: bigint;
  confirmedKi: bigint;
  pdrRootHash?: string;
}

const GUARD_ABI = parseAbi([
  "function proposeParameters(int128 newKp, int128 newKi, bool isEmergency)",
]);

export class Executor {
  private account = privateKeyToAccount(CONFIG.AGENT_PRIVATE_KEY as `0x${string}`);
  private chain = {
    id: CONFIG.CHAIN_ID,
    name: "Unichain Sepolia",
    nativeCurrency: { name: "ETH", symbol: "ETH", decimals: 18 },
    rpcUrls: { default: { http: [CONFIG.RPC_URL] } },
  } as const;

  private wallet = createWalletClient({
    account: this.account,
    chain: this.chain,
    transport: http(CONFIG.RPC_URL),
  });

  private pub = createPublicClient({
    chain: this.chain,
    transport: http(CONFIG.RPC_URL),
  });

  get address(): string {
    return this.account.address;
  }

  async proposeParameters(
    newKp: bigint,
    newKi: bigint,
    isEmergency: boolean,
    decisionReasoning?: string,
    deviation?: number
  ): Promise<ExecutionResult> {
    // Simulate first to surface revert reasons clearly
    const { request } = await this.pub.simulateContract({
      address: CONFIG.PARAMETER_GUARD_ADDRESS,
      abi: GUARD_ABI,
      functionName: "proposeParameters",
      args: [newKp, newKi, isEmergency],
      account: this.account,
    });

    const hash = await this.wallet.writeContract(request);
    const receipt = await this.pub.waitForTransactionReceipt({ hash });

    if (receipt.status === "reverted") {
      throw new Error(`Tx reverted: ${hash}`);
    }

    // Store PDR to 0G Storage (non-blocking)
    let pdrRootHash: string | undefined;
    if (decisionReasoning) {
      const pdr: PDR = {
        id: `pdr-${Date.now()}`,
        timestamp: Date.now(),
        agent: this.account.address,
        newKp,
        newKi,
        isEmergency,
        deviation: deviation ?? 0,
        reasoning: decisionReasoning,
        txHash: hash,
      };
      
      try {
        pdrRootHash = await storePDR(pdr);
        console.log(`[0G Storage] PDR stored: 0g://${pdrRootHash}`);
      } catch (e) {
        console.warn(`[0G Storage] Failed (non-blocking): ${e instanceof Error ? e.message : String(e)}`);
      }
    }

    return {
      txHash: hash,
      confirmedKp: newKp,
      confirmedKi: newKi,
      pdrRootHash,
    };
  }
}
