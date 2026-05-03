# Horoi Protocol EVM Port — Specifications

## Domain Overview

This specification defines the EVM port of Horoi Protocol's agentic governance mechanism from Cairo to Unichain, enabling an off-chain agent to propose PID parameter updates within admin-defined bounds. Three new capabilities are specified: ParameterGuard.sol governance guard, Agent Runtime off-chain execution, and Sponsor Integrations for external services. The port simplifies from Cairo by replacing ERC-8004 identity validation with direct proposer address configuration.

---

## Specification 1: ParameterGuard.sol

### Purpose

ParameterGuard.sol is the core governance smart contract that controls agent-driven PID parameter updates. It enforces multi-layer protection: proposer identity validation (direct address), absolute bounds checking, per-call delta caps, rate limiting (cooldown + budget), and emergency stop capability. The contract emits PDR (Policy Decision Record) events for every action, enabling off-chain indexers to reconstruct governance decisions.

### Requirements

#### Requirement: Policy Storage and Validation

The system MUST store a Policy struct containing kp_min, kp_max, ki_min, ki_max (absolute bounds in WAD), max_kp_delta, max_ki_delta (per-call caps), cooldown_seconds, emergency_cooldown_seconds, and max_updates (budget). The system SHALL validate on setPolicy() that kp_min ≤ kp_max, ki_min ≤ ki_max, and emergency_cooldown_seconds ≤ cooldown_seconds.

#### Requirement: Proposer Identity Enforcement

The system SHALL validate that only the configured proposer address may call proposeParameters(). The proposer address MUST be set in constructor and rotatable via setProposer() by admin. Calls from non-proposer addresses MUST revert with "GUARD: not proposer".

#### Requirement: Bounds Enforcement

The system MUST reject any proposeParameters() call where new_kp < policy_kp_min or new_kp > policy_kp_max. The system MUST reject where new_ki < policy_ki_min or new_ki > policy_ki_max. Reverts MUST include "GUARD: kp below min", "GUARD: kp above max", "GUARD: ki below min", "GUARD: ki above max".

#### Requirement: Delta Cap Enforcement

The system MUST compute absolute difference between new and current kp/ki values. The system MUST reject if |new_kp - current_kp| > policy_max_kp_delta or |new_ki - current_ki| > policy_max_ki_delta. Reverts MUST include "GUARD: kp delta too large", "GUARD: ki delta too large".

#### Requirement: Cooldown Rate Limiting

The system MUST enforce that time since last update ≥ cooldown_seconds for normal proposals. The system MUST enforce that time since last update ≥ emergency_cooldown_seconds when is_emergency=true. The system SHALL use shorter emergency cooldown when agent declares emergency mode. Reverts MUST include "GUARD: cooldown active".

#### Requirement: Budget Limiting

The system MUST track update_count incrementing on each successful proposeParameters(). The system MUST reject when update_count ≥ policy_max_updates (if max_updates > 0). Reverts MUST include "GUARD: budget exhausted".

#### Requirement: Emergency Stop

The system MUST allow admin to call emergency_stop() which sets stopped=true. When stopped=true, all proposeParameters() calls MUST revert with "GUARD: stopped". The system MUST allow admin to call resume() which sets stopped=false.

#### Requirement: PIDController Integration

The system MUST call PIDController.setKp(new_kp) and PIDController.setKi(new_ki) after all validations pass. The system MUST query current gains via PIDController.getControllerGains() before applying delta checks. The ParameterGuard MUST be the admin of PIDController (or authorized proposer).

#### Requirement: PDR Events

The system MUST emit ParameterUpdate(agent, old_kp, new_kp, old_ki, new_ki, update_number, emergency_mode, timestamp) on each successful proposal. The system MUST emit EmergencyStop(admin, timestamp) on emergency_stop(). The system MUST emit Resumed(admin, timestamp) on resume(). The system MUST emit PolicyUpdated(admin, timestamp) on setPolicy().

### Scenario: Normal Parameter Update

- GIVEN ParameterGuard deployed with proposer=agent, policy with kp_min=0.1e18, kp_max=1e18, max_kp_delta=0.2e18, cooldown=3600, max_updates=100
- WHEN agent calls proposeParameters(kp=0.5e18, ki=0.1e18, is_emergency=false)
- THEN update_count becomes 1, last_update_timestamp set to block.timestamp, PIDController.kp updated to 0.5e18, ParameterUpdate event emitted
- AND call succeeds (updates applied within bounds, cooldown satisfied)

### Scenario: Delta Cap Rejection

- GOUND ParameterGuard with current kp=0.8e18, policy max_kp_delta=0.2e18
- WHEN agent calls proposeParameters(kp=1.1e18, ki=0.1e18, is_emergency=false)
- THEN call reverts with "GUARD: kp delta too large"

### Scenario: Emergency Mode Uses Shorter Cooldown

- GIVEN last_update_timestamp=block.timestamp-1800 (30 min ago), normal cooldown=3600, emergency_cooldown=600
- WHEN agent calls proposeParameters(kp=0.5e18, ki=0.1e18, is_emergency=true)
- THEN call succeeds (emergency cooldown satisfied at 30min > 10min)

### Scenario: Emergency Stop Blocks All Proposals

- GIVEN ParameterGuard with stopped=true
- WHEN agent calls proposeParameters(kp=0.5e18, ki=0.1e18, is_emergency=false)
- THEN call reverts with "GUARD: stopped"

---

## Specification 2: Agent Runtime

### Purpose

Agent Runtime is the off-chain TypeScript component that monitors oracle data, reasons about parameter adjustments, and executes proposals via ParameterGuard. It consists of four modules: monitor.ts (oracle polling), reasoning.ts (decision logic), executor.ts (Blockchain interaction), and config.ts (configuration).

### Requirements

#### Requirement: Oracle Monitoring

monitor.ts MUST poll oracle price data at configurable interval (default: 30 seconds). monitor.ts MUST compute deviation between market price and redemption price. monitor.ts MUST detect deviation threshold breach (|market - redemption| / redemption > noiseBarrier). monitor.ts MUST emit Health deviation metrics for reasoning module.

#### Requirement: Decision Logic

reasoning.ts MUST receive current deviation metrics from monitor.ts. reasoning.ts MUST read current PID gains via executor.ts. reasoning.ts MUST compute new kp/ki values based on deviation magnitude and direction. reasoning.ts MUST apply policy bounds from config.ts before outputting proposal. reasoning.ts MAY use simple threshold logic or LLM-based reasoning (configurable).

#### Requirement: Parameter Proposal Execution

executor.ts MUST connect to ParameterGuard via JSON-RPC (ethers.js/hardhat). executor.ts MUST call proposeParameters(new_kp, new_ki, is_emergency) with signed transaction. executor.ts MUST handle revert errors and log rejected proposals with reason. executor.ts MUST track local state: last_proposal_timestamp, proposal_count, last_success.

#### Requirement: Configuration Management

config.ts MUST export: RPC_URL, PARAMETER_GUARD_ADDRESS, PID_CONTROLLER_ADDRESS, POLLER_INTERVAL_MS, COOLDOWN_BUFFER_SEC, PROPOSER_PRIVATE_KEY. config.ts MAY support environment variable overrides. config.ts MUST validate required fields on load.

#### Requirement: Error Handling

Agent Runtime MUST log all errors with timestamp and stack trace. Agent Runtime MUST continue operation on single-execution failure (resilient). Agent Runtime MUST implement circuit breaker: after N consecutive failures, pause and alert.

### Scenario: Normal Monitoring Cycle

- GIVEN config loaded with RPC_URL, PARAMETER_GUARD_ADDRESS set, oracle price at 50000 USD, redemption price at 50100 USD
- WHEN monitor polls and computes deviation = (50100-50000)/50100 ≈ 0.2%
- THEN if deviation > noiseBarrier (0.5%), emit deviation event to reasoning
- AND if deviation ≤ noiseBarrier, log "within bounds, no action"

### Scenario: Reasoning Proposes Within Bounds

- GIVEN deviation of 2%, current kp=0.3e18, policy bounds kp_min=0.1e18, kp_max=1e18, max_kp_delta=0.2e18
- WHEN reasoning computes new_kp = 0.3e18 + 0.1e18 = 0.4e18
- THEN output {new_kp: 0.4e18, new_ki: current_ki, is_emergency: false}
- AND validate against bounds: 0.4e18 in [0.1e18, 1e18] ✓, delta 0.1e18 ≤ 0.2e18 ✓

### Scenario: Executor Handles Revert

- GIVEN proposeParameters reverts due to cooldown active
- WHEN executor receives revert "GUARD: cooldown active"
- THEN log error with revert reason, increment failure_count, continue to next cycle
- AND do not crash

---

## Specification 3: Sponsor Integrations

### Purpose

Sponsor Integrations define the interface layer for connecting to external services required by the Agent Runtime: Uniswap API (price oracle), 0G (compute + PDR storage), KeeperHub (gasless transaction execution). This is the integration contract, not the production implementation.

### Requirements

#### Requirement: Uniswap API Integration

System MUST support querying Uniswap V4 pool prices via Foundation API or pool contract reads. System MUST map token pair (e.g., WETH/GRT) to pool address. System MUST return price as WAD (18 decimals). System MUST handle stale price: if block timestamp - price_timestamp > MAX_AGE_SEC, log warning.

#### Requirement: 0G Integration

System MUST support storing PDR (Policy Decision Records) to 0G storage for persistence. System MUST support fetching historical PDRs for analysis. System MUST support optional compute: send deviation data to 0G-enabled inference for LLM reasoning.

#### Requirement: KeeperHub Integration

System MUST support gasless transactions via KeeperHub relayer. System MUST construct parameterized proposal calldata for relay. System MUST handle relayer unavailability: fallback to EOA with private key.

### Scenario: Uniswap Returns Price

- GIVEN Uniswap V4 pool for WETH/USDC at 0x00b036b58a818b1bc34d502d3fe730db729e62ac
- WHEN queryPrice(WETH, USDC) invoked
- THEN return {price: 3300000000000000000000 (3300 USD), timestamp: block.timestamp}

### Scenario: 0G Stores PDR

- GIVEN proposal executed: kp 0.3→0.4, ki 0.1→0.1
- WHEN storePDR({proposer, kp, ki, timestamp, txHash})
- THEN transaction to 0G storage emits stored event with PDR_ID
- AND future fetchPDR(PDR_ID) returns record

### Scenario: KeeperHub Relays Transaction

- GIVEN ParameterGuard needs gasless proposal from agent address
- WHEN executor.prepareCalldata(proposeParameters, new_kp, new_ki) sends to KeeperHub
- THEN KeeperHub relayer broadcasts with deposit payment
- AND if KeeperHub unavailable, fallback to direct eth_sendTransaction

---

## Cross-Cutting Requirements

#### Integration: Agent Runtime ↔ ParameterGuard

executor.ts MUST read current gains from PIDController before proposing (to compute delta). executor.ts MUST estimate gas and set appropriate gas limit. executor.ts MUST handle ParameterGuard being stopped (emergency_stop called externally).

#### Integration: Agent Runtime ↔ Sponsor Services

If Uniswap unavailable: use cached last_price with warning. If 0G unavailable: write to local JSON log (buffer). If KeeperHub unavailable: use private key fallback via config.

#### Security: Private Key Security

PROPOSER_PRIVATE_KEY MUST NOT be committed to version control. Agent Runtime MUST support external signer (AWS Secrets, HashiCorp Vault). Agent Runtime MUST validate signer address matches config before execution.

---

## Acceptance Criteria

| Capability | Criterion |
|-----------|-----------|
| ParameterGuard | All unit tests pass, bounds enforced, cooldown works, emergency_stop blocks |
| Agent Runtime | Monitors, reasons, executes without crash, handles errors gracefully |
| Sponsor Integration | Uniswap price available, 0G stores, KeeperHub relays (or fallback) |
| End-to-End | Oracle crash → agent detects → proposes → PID updates → peg holds |