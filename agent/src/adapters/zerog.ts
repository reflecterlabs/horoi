/**
 * 0G Adapter — Compute Network + Storage
 * 
 * 0G Compute Network: serve the Qwen model for decentralized inference
 * 0G Storage: store PDR (Policy Decision Records) for auditability
 * 
 * Docs: https://docs.0g.ai
 */

import { CONFIG } from "../config.js";
import { Indexer, ZgFile } from "@0gfoundation/0g-storage-ts-sdk";
import { ethers } from "ethers";
import { readFile, writeFile, unlink } from "fs/promises";

// ---- Types ----

export interface ZGInferenceRequest {
  model: string;
  prompt: string;
  max_tokens?: number;
  temperature?: number;
}

export interface ZGInferenceResponse {
  id: string;
  output: string;
  usage: {
    prompt_tokens: number;
    completion_tokens: number;
    total_tokens: number;
  };
  latency_ms: number;
}

export interface ZGStorageRecord {
  cid: string; // IPFS-style content identifier
  data: string;
  timestamp: number;
}

// ---- Compute Network Adapter ----

/**
 * Request inference from 0G Compute Network
 * 
 * Currently placeholder — need actual endpoint from 0G docs
 */
export async function requestInference(
  prompt: string,
  options?: {
    model?: string;
    max_tokens?: number;
    temperature?: number;
  }
): Promise<ZGInferenceResponse> {
  if (!CONFIG.ZEROG_COMPUTE_URL) {
    throw new Error("0G Compute URL not configured");
  }

  const response = await fetch(`${CONFIG.ZEROG_COMPUTE_URL}/inference`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      model: options?.model || "qwen2.5-1.5b-instruct",
      prompt,
      max_tokens: options?.max_tokens || 500,
      temperature: options?.temperature || 0.1,
    }),
  });

  if (!response.ok) {
    throw new Error(`0G Compute error: ${response.status}`);
  }

  return response.json();
}

/**
 * Simple chat completion via 0G Compute
 */
export async function chatCompletion(
  messages: { role: "system" | "user"; content: string }[],
  options?: {
    model?: string;
    temperature?: number;
  }
): Promise<string> {
  // Build prompt from messages
  const prompt = messages
    .map((m) => `${m.role}: ${m.content}`)
    .join("\n");

  const result = await requestInference(prompt, options);
  return result.output;
}

// ---- Storage Adapter ----

// Lazy-initialized storage components
let _indexer: Indexer | null = null;
let _signer: ethers.Wallet | null = null;

function getStorageSigner(): ethers.Wallet {
  if (!_signer) {
    if (!CONFIG.ZEROG_STORAGE_PRIVATE_KEY) {
      throw new Error("ZEROG_STORAGE_PRIVATE_KEY not configured");
    }
    const provider = new ethers.JsonRpcProvider(CONFIG.ZEROG_STORAGE_RPC);
    _signer = new ethers.Wallet(CONFIG.ZEROG_STORAGE_PRIVATE_KEY, provider);
  }
  return _signer;
}

function getIndexer(): Indexer {
  if (!_indexer) {
    _indexer = new Indexer(CONFIG.ZEROG_STORAGE_INDEXER);
  }
  return _indexer;
}

/**
 * Store PDR (Policy Decision Record) to 0G Storage
 */
export interface PDR {
  id: string;
  timestamp: number;
  agent: string;
  newKp: bigint;
  newKi: bigint;
  isEmergency: boolean;
  deviation: number;
  reasoning: string;
  txHash?: string;
}

export async function storePDR(pdr: PDR): Promise<string> {
  const indexer = getIndexer();
  const signer = getStorageSigner();
  
  const tmp = `/tmp/pdr-${pdr.id}.json`;
  await writeFile(tmp, JSON.stringify(pdr));
  
  try {
    const file = await ZgFile.fromFilePath(tmp);
    const [tx, err] = await indexer.upload(file, CONFIG.ZEROG_STORAGE_RPC, signer);
    await file.close();
    if (err) throw err;
    return tx.rootHash;
  } finally {
    await unlink(tmp).catch(() => {});
  }
}

/**
 * Retrieve PDR from 0G Storage by rootHash
 */
export async function getPDR(rootHash: string): Promise<PDR> {
  const indexer = getIndexer();
  const tmp = `/tmp/pdr-fetch-${Date.now()}.json`;
  
  try {
    await indexer.download(rootHash, tmp, true);
    const data = await readFile(tmp, "utf-8");
    return JSON.parse(data);
  } finally {
    await unlink(tmp).catch(() => {});
  }
}

export async function storeToStorage(data: string): Promise<string> {
  // Simple wrapper for generic data (uses PDR internally)
  const pdr: PDR = {
    id: `generic-${Date.now()}`,
    timestamp: Date.now(),
    agent: CONFIG.AGENT_ADDRESS,
    newKp: 0n,
    newKi: 0n,
    isEmergency: false,
    deviation: 0,
    reasoning: data,
  };
  return storePDR(pdr);
}

export async function retrieveFromStorage(rootHash: string): Promise<string> {
  const pdr = await getPDR(rootHash);
  return pdr.reasoning;
}

// ---- Fallback utilities ----

/**
 * Log to console with 0G label (when not configured)
 */
export function logToZG(label: string, data: unknown): void {
  if (CONFIG.ZEROG_COMPUTE_URL || CONFIG.ZEROG_STORAGE_URL) {
    console.log(`[0G ${label}]`, data);
  }
}