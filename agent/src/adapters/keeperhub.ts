/**
 * KeeperHub Adapter — Tx Execution via MCP
 * 
 * Routes agent → ParameterGuard transactions through KeeperHub for:
 * - Retry on failure (gas spikes, reorgs)
 * - Managed gas / nonce
 * - Full audit trail
 * 
 * Docs: https://docs.keeperhub.com/api
 */

import { CONFIG } from "../config.js";

export interface KeeperHubConfig {
  apiKey: string;
  orgId?: string;
  baseUrl?: string;
}

export interface ExecutionRequest {
  workflowId: string;
  input?: Record<string, unknown>;
}

export interface ExecutionStatus {
  id: string;
  status: "pending" | "running" | "completed" | "failed";
  result?: unknown;
  logs?: ExecutionLog[];
}

export interface ExecutionLog {
  nodeId: string;
  timestamp: number;
  message: string;
  transactionHash?: string;
}

// ========================================================================
// Direct Execution API (no workflow needed)
// ========================================================================

const BASE_URL = "https://app.keeperhub.com/api";

/**
 * Execute a contract write directly via KeeperHub API
 */
export async function executeContractWrite(params: {
  to: string;
  data: string;
  value?: string;
  network: number;
}): Promise<{ executionId: string; transactionHash?: string }> {
  const apiKey = process.env.KEEPERHUB_API_KEY;
  if (!apiKey) {
    throw new Error("KeeperHub API key not configured");
  }

  const response = await fetch(`${BASE_URL}/execute/contract`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${apiKey}`,
    },
    body: JSON.stringify({
      to: params.to,
      data: params.data,
      value: params.value || "0",
      network: params.network,
    }),
  });

  if (!response.ok) {
    const error = await response.text();
    throw new Error(`KeeperHub execution failed: ${error}`);
  }

  return response.json();
}

/**
 * Get execution status
 */
export async function getExecutionStatus(executionId: string): Promise<ExecutionStatus> {
  const apiKey = process.env.KEEPERHUB_API_KEY;
  if (!apiKey) {
    throw new Error("KeeperHub API key not configured");
  }

  const response = await fetch(`${BASE_URL}/executions/${executionId}/status`, {
    headers: {
      Authorization: `Bearer ${apiKey}`,
    },
  });

  if (!response.ok) {
    throw new Error(`KeeperHub status check failed: ${response.status}`);
  }

  return response.json();
}

/**
 * Get execution logs
 */
export async function getExecutionLogs(executionId: string): Promise<ExecutionLog[]> {
  const apiKey = process.env.KEEPERHUB_API_KEY;
  if (!apiKey) {
    throw new Error("KeeperHub API key not configured");
  }

  const response = await fetch(`${BASE_URL}/executions/${executionId}/logs`, {
    headers: {
      Authorization: `Bearer ${apiKey}`,
    },
  });

  if (!response.ok) {
    throw new Error(`KeeperHub logs check failed: ${response.status}`);
  }

  return response.json();
}

// ========================================================================
// Workflow-based execution (for automated triggers)
// ========================================================================

/**
 * List available workflows
 */
export async function listWorkflows(): Promise<
  { id: string; name: string; trigger: string; active: boolean }[]
> {
  const apiKey = process.env.KEEPERHUB_API_KEY;
  if (!apiKey) {
    throw new Error("KeeperHub API key not configured");
  }

  const response = await fetch(`${BASE_URL}/workflows`, {
    headers: {
      Authorization: `Bearer ${apiKey}`,
    },
  });

  if (!response.ok) {
    throw new Error(`KeeperHub list workflows failed: ${response.status}`);
  }

  return response.json();
}

/**
 * Execute a workflow by ID
 */
export async function executeWorkflow(
  workflowId: string,
  input?: Record<string, unknown>
): Promise<{ executionId: string }> {
  const apiKey = process.env.KEEPERHUB_API_KEY;
  if (!apiKey) {
    throw new Error("KeeperHub API key not configured");
  }

  const response = await fetch(`${BASE_URL}/workflows/${workflowId}/execute`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${apiKey}`,
    },
    body: JSON.stringify(input || {}),
  });

  if (!response.ok) {
    throw new Error(`KeeperHub workflow execution failed: ${response.status}`);
  }

  return response.json();
}

// ========================================================================
// Wrapper for the agent
// ========================================================================

/**
 * Execute ParameterGuard proposal via KeeperHub
 * Falls back to direct wallet if KeeperHub not configured
 */
export async function executeWithKeeperHub(params: {
  to: string;
  data: string;
  network: number;
  maxRetries?: number;
}): Promise<{ executionId: string; transactionHash?: string }> {
  if (!process.env.KEEPERHUB_API_KEY) {
    throw new Error("KeeperHub not configured — use direct wallet");
  }

  // Execute via KeeperHub
  const result = await executeContractWrite(params);
  
  // Poll for completion (max 2 minutes)
  const maxWait = 120000;
  const start = Date.now();
  
  while (Date.now() - start < maxWait) {
    const status = await getExecutionStatus(result.executionId);
    
    if (status.status === "completed") {
      return {
        executionId: result.executionId,
        transactionHash: status.logs?.[0]?.transactionHash,
      };
    }
    
    if (status.status === "failed") {
      throw new Error(`KeeperHub execution failed: ${JSON.stringify(status.result)}`);
    }
    
    await new Promise((r) => setTimeout(r, 2000));
  }
  
  throw new Error(`KeeperHub execution timeout: ${result.executionId}`);
}

/**
 * Check if KeeperHub is configured
 */
export function isKeeperHubConfigured(): boolean {
  return !!process.env.KEEPERHUB_API_KEY;
}