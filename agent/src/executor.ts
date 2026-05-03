/**
 * Executor — calls ParameterGuard.proposeParameters(int128, int128, bool)
 *
 * Selector is int128-based (matches the contract). Previous version used int256,
 * which produced a wrong selector and silently reverted on the first proposal.
 */

import { createWalletClient, createPublicClient, http, parseAbi } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { CONFIG } from "./config.js";

export interface ExecutionResult {
  txHash: `0x${string}`;
  confirmedKp: bigint;
  confirmedKi: bigint;
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
    isEmergency: boolean
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

    return {
      txHash: hash,
      confirmedKp: newKp,
      confirmedKi: newKi,
    };
  }
}
