/**
 * 0G Adapter — Compute Network + Storage
 * 
 * 0G Compute Network: serve the Qwen model for decentralized inference
 * 0G Storage: store PDR (Policy Decision Records) for auditability
 * 
 * Docs: https://docs.0g.ai (placeholder — check their docs for actual endpoints)
 */

import { CONFIG } from "../config.js";

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

/**
 * Store data to 0G Storage (returns CID)
 */
export async function storeToStorage(data: string): Promise<string> {
  if (!CONFIG.ZEROG_STORAGE_URL) {
    throw new Error("0G Storage URL not configured");
  }

  const response = await fetch(`${CONFIG.ZEROG_STORAGE_URL}/store`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      data,
    }),
  });

  if (!response.ok) {
    throw new Error(`0G Storage error: ${response.status}`);
  }

  const result = await response.json();
  return result.cid;
}

/**
 * Retrieve data from 0G Storage by CID
 */
export async function retrieveFromStorage(cid: string): Promise<string> {
  if (!CONFIG.ZEROG_STORAGE_URL) {
    throw new Error("0G Storage URL not configured");
  }

  const response = await fetch(`${CONFIG.ZEROG_STORAGE_URL}/retrieve/${cid}`, {
    method: "GET",
  });

  if (!response.ok) {
    throw new Error(`0G Storage error: ${response.status}`);
  }

  const result = await response.json();
  return result.data;
}

/**
 * Store PDR (Policy Decision Record)
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
}

export async function storePDR(pdr: PDR): Promise<string> {
  const data = JSON.stringify(pdr);
  return storeToStorage(data);
}

/**
 * Retrieve PDR from storage
 */
export async function getPDR(cid: string): Promise<PDR> {
  const data = await retrieveFromStorage(cid);
  return JSON.parse(data);
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