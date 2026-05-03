// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {GrintaTypes} from "./libraries/GrintaTypes.sol";
import {GrintaMath} from "./libraries/GrintaMath.sol";

/// @title ParameterGuard — Bounded parameter governance for PIDController
/// @notice Allows a configurable proposer address to modify Kp/Ki within safe bounds
///         defined by a human admin. Simplified from Cairo (no ERC-8004 identity).
///
/// Enforcement layers:
///   1. Authorization: proposer address must match caller
///   2. Bounds: new values within absolute min/max AND per-call delta cap
///   3. Rate limit: cooldown + call budget
///
/// PDR (Policy Decision Record) events emitted for every action.
contract ParameterGuard {
    using GrintaMath for uint256;

    // ========================================================================
    // Storage
    // ========================================================================

    address public admin;
    address public proposer; // Simplified: direct address, not ERC-8004 agent ID
    address public pidController;

    // Policy bounds (WAD-scaled, 18 decimals)
    int128 public policyKpMin;
    int128 public policyKpMax;
    int128 public policyKiMin;
    int128 public policyKiMax;

    // Per-call delta caps
    uint256 public policyMaxKpDelta;
    uint256 public policyMaxKiDelta;

    // Rate limiting
    uint64 public policyCooldownSeconds;
    uint64 public policyEmergencyCooldownSeconds;
    uint32 public policyMaxUpdates;

    // State
    bool public stopped;
    uint32 public updateCount;
    uint64 public lastUpdateTimestamp;

    // ========================================================================
    // Events — PDR (Policy Decision Record) pattern
    // ========================================================================

    /// @notice Emitted when proposer successfully updates Kp/Ki
    event ParameterUpdate(
        address indexed proposer,
        int128 oldKp,
        int128 newKp,
        int128 oldKi,
        int128 newKi,
        uint32 updateNumber,
        bool emergencyMode,
        uint64 timestamp
    );

    /// @notice Emitted when admin triggers emergency stop
    event EmergencyStop(address indexed admin, uint64 timestamp);

    /// @notice Emitted when admin resumes after emergency stop
    event Resumed(address indexed admin, uint64 timestamp);

    /// @notice Emitted when admin updates policy bounds
    event PolicyUpdated(address indexed admin, uint64 timestamp);

    /// @notice Emitted on every successful proposal with full attribution
    event ProposalAttributed(
        address indexed proposer,
        int128 newKp,
        int128 newKi,
        bool isEmergency,
        uint64 timestamp
    );

    /// @notice Emitted when proposer address is rotated
    event ProposerUpdated(
        address indexed admin,
        address oldProposer,
        address newProposer,
        uint64 timestamp
    );

    /// @notice Emitted when PID controller reference is updated
    event PidControllerUpdated(
        address indexed admin,
        address oldController,
        address newController,
        uint64 timestamp
    );

    // ========================================================================
    // Errors
    // ========================================================================

    error GuardNotAdmin();
    error GuardNotProposer();
    error GuardStopped();
    error GuardBudgetExhausted();
    error GuardCooldownActive();
    error GuardKpBelowMin();
    error GuardKpAboveMax();
    error GuardKiBelowMin();
    error GuardKiAboveMax();
    error GuardKpDeltaTooLarge();
    error GuardKiDeltaTooLarge();
    error GuardZeroAddress();
    error GuardZeroProposer();
    error GuardInvalidPolicy();
    error GuardEmergencyCooldownExceedsNormal();

    // ========================================================================
    // Constructor
    // ========================================================================

    constructor(
        address _admin,
        address _pidController,
        address _proposer,
        int128 _kpMin,
        int128 _kpMax,
        int128 _kiMin,
        int128 _kiMax,
        uint256 _maxKpDelta,
        uint256 _maxKiDelta,
        uint64 _cooldownSeconds,
        uint64 _emergencyCooldownSeconds,
        uint32 _maxUpdates
    ) {
        if (_admin == address(0)) revert GuardZeroAddress();
        if (_pidController == address(0)) revert GuardZeroAddress();
        if (_proposer == address(0)) revert GuardZeroProposer();

        // Validate policy coherence
        if (_kpMin > _kpMax) revert GuardInvalidPolicy();
        if (_kiMin > _kiMax) revert GuardInvalidPolicy();
        if (_emergencyCooldownSeconds > _cooldownSeconds) {
            revert GuardEmergencyCooldownExceedsNormal();
        }

        admin = _admin;
        pidController = _pidController;
        proposer = _proposer;

        policyKpMin = _kpMin;
        policyKpMax = _kpMax;
        policyKiMin = _kiMin;
        policyKiMax = _kiMax;
        policyMaxKpDelta = _maxKpDelta;
        policyMaxKiDelta = _maxKiDelta;
        policyCooldownSeconds = _cooldownSeconds;
        policyEmergencyCooldownSeconds = _emergencyCooldownSeconds;
        policyMaxUpdates = _maxUpdates;

        stopped = false;
        updateCount = 0;
        lastUpdateTimestamp = 0;
    }

    // ========================================================================
    // Proposer Functions
    // ========================================================================

    /// @notice Propose new Kp/Ki values within policy bounds
    /// @param newKp New proportional gain (WAD)
    /// @param newKi New integral gain (WAD)
    /// @param isEmergency Whether this is an emergency proposal (uses shorter cooldown)
    function proposeParameters(int128 newKp, int128 newKi, bool isEmergency) external {
        // Layer 1: Authorization
        if (msg.sender != proposer) revert GuardNotProposer();

        // Layer 1: Check stopped
        if (stopped) revert GuardStopped();

        // Layer 3: Rate limit — budget
        uint32 count = updateCount;
        uint32 max = policyMaxUpdates;
        if (max > 0 && count >= max) revert GuardBudgetExhausted();

        // Layer 3: Rate limit — two-tier cooldown
        uint64 nowTs = uint64(block.timestamp);
        uint64 last = lastUpdateTimestamp;

        if (last > 0) {
            uint64 cooldown = isEmergency
                ? policyEmergencyCooldownSeconds
                : policyCooldownSeconds;
            if (nowTs < last + cooldown) revert GuardCooldownActive();
        }

        // Layer 2: Absolute bounds
        if (newKp < policyKpMin) revert GuardKpBelowMin();
        if (newKp > policyKpMax) revert GuardKpAboveMax();
        if (newKi < policyKiMin) revert GuardKiBelowMin();
        if (newKi > policyKiMax) revert GuardKiAboveMax();

        // Layer 2: Per-call delta cap
        (, int128 currentKi) = _getCurrentGains();
        int128 currentKp = _getCurrentKp();

        uint256 kpDelta = _absDiff(newKp, currentKp);
        uint256 kiDelta = _absDiff(newKi, currentKi);

        if (kpDelta > policyMaxKpDelta) revert GuardKpDeltaTooLarge();
        if (kiDelta > policyMaxKiDelta) revert GuardKiDeltaTooLarge();

        // Effects before interactions (CEI pattern)
        uint32 newCount = count + 1;
        updateCount = newCount;
        lastUpdateTimestamp = nowTs;

        // Interact — forward to PIDController
        _setPidGains(newKp, newKi);

        // Emit PDR events
        emit ParameterUpdate(
            msg.sender,
            currentKp,
            newKp,
            currentKi,
            newKi,
            newCount,
            isEmergency,
            nowTs
        );

        emit ProposalAttributed(
            msg.sender,
            newKp,
            newKi,
            isEmergency,
            nowTs
        );
    }

    // ========================================================================
    // Admin Functions
    // ========================================================================

    /// @notice Update policy bounds
    function setPolicy(
        int128 _kpMin,
        int128 _kpMax,
        int128 _kiMin,
        int128 _kiMax,
        uint256 _maxKpDelta,
        uint256 _maxKiDelta,
        uint64 _cooldownSeconds,
        uint64 _emergencyCooldownSeconds,
        uint32 _maxUpdates
    ) external {
        if (msg.sender != admin) revert GuardNotAdmin();

        if (_kpMin > _kpMax) revert GuardInvalidPolicy();
        if (_kiMin > _kiMax) revert GuardInvalidPolicy();
        if (_emergencyCooldownSeconds > _cooldownSeconds) {
            revert GuardEmergencyCooldownExceedsNormal();
        }

        policyKpMin = _kpMin;
        policyKpMax = _kpMax;
        policyKiMin = _kiMin;
        policyKiMax = _kiMax;
        policyMaxKpDelta = _maxKpDelta;
        policyMaxKiDelta = _maxKiDelta;
        policyCooldownSeconds = _cooldownSeconds;
        policyEmergencyCooldownSeconds = _emergencyCooldownSeconds;
        policyMaxUpdates = _maxUpdates;

        emit PolicyUpdated(msg.sender, uint64(block.timestamp));
    }

    /// @notice Rotate the active proposer to a different address
    function setProposer(address newProposer) external {
        if (msg.sender != admin) revert GuardNotAdmin();
        if (newProposer == address(0)) revert GuardZeroProposer();

        address oldProposer = proposer;
        proposer = newProposer;

        emit ProposerUpdated(msg.sender, oldProposer, newProposer, uint64(block.timestamp));
    }

    /// @notice Redirect the Guard's PID reference to a new PIDController contract
    function setPidController(address controller) external {
        if (msg.sender != admin) revert GuardNotAdmin();
        if (controller == address(0)) revert GuardZeroAddress();

        address oldController = pidController;
        pidController = controller;

        emit PidControllerUpdated(msg.sender, oldController, controller, uint64(block.timestamp));
    }

    /// @notice Emergency stop — halts all proposeParameters calls
    function emergencyStop() external {
        if (msg.sender != admin) revert GuardNotAdmin();

        stopped = true;
        emit EmergencyStop(msg.sender, uint64(block.timestamp));
    }

    /// @notice Resume from emergency stop
    function resume() external {
        if (msg.sender != admin) revert GuardNotAdmin();

        stopped = false;
        emit Resumed(msg.sender, uint64(block.timestamp));
    }

    // ========================================================================
    // View Functions
    // ========================================================================

    /// @notice Get current policy configuration
    function getPolicy()
        external
        view
        returns (
            int128 kpMin,
            int128 kpMax,
            int128 kiMin,
            int128 kiMax,
            uint256 maxKpDelta,
            uint256 maxKiDelta,
            uint64 cooldownSeconds,
            uint64 emergencyCooldownSeconds,
            uint32 maxUpdates
        )
    {
        return (
            policyKpMin,
            policyKpMax,
            policyKiMin,
            policyKiMax,
            policyMaxKpDelta,
            policyMaxKiDelta,
            policyCooldownSeconds,
            policyEmergencyCooldownSeconds,
            policyMaxUpdates
        );
    }

    /// @notice Get current PID gains from controller
    function getCurrentGains() external view returns (int128 kp, int128 ki) {
        return _getCurrentGains();
    }

    /// @notice Check if cooldown is active
    function isCooldownActive() external view returns (bool) {
        if (lastUpdateTimestamp == 0) return false;
        uint64 elapsed = uint64(block.timestamp) - lastUpdateTimestamp;
        return elapsed < policyCooldownSeconds;
    }

    /// @notice Get remaining budget (0 if exhausted or unlimited)
    function getRemainingBudget() external view returns (uint32) {
        if (policyMaxUpdates == 0) return 0;
        if (updateCount >= policyMaxUpdates) return 0;
        return policyMaxUpdates - updateCount;
    }

    // ========================================================================
    // Internal Helpers
    // ========================================================================

    /// @dev Compute absolute difference between two signed values
    function _absDiff(int128 a, int128 b) internal pure returns (uint256) {
        int256 diff = int256(a) - int256(b);
        return diff < 0 ? uint256(-diff) : uint256(diff);
    }

    /// @dev Get current Kp from PID controller
    function _getCurrentKp() internal view returns (int128) {
        (int128 kp, ) = _getCurrentGains();
        return kp;
    }

    /// @dev Call PIDController to get current gains
    function _getCurrentGains() internal view returns (int128 kp, int128 ki) {
        // slither-disable-next-line delegate-call-low-level
        (bool success, bytes memory data) = pidController.staticcall(
            abi.encodeWithSignature("getControllerGains()")
        );
        require(success, "PID: call failed");
        GrintaTypes.ControllerGains memory gains = abi.decode(data, (GrintaTypes.ControllerGains));
        return (gains.kp, gains.ki);
    }

    /// @dev Call PIDController to set new gains
    function _setPidGains(int128 newKp, int128 newKi) internal {
        // slither-disable-next-line delegate-call-low-level
        (bool success, ) = pidController.call(
            abi.encodeWithSignature("setKp(int128)", newKp)
        );
        require(success, "PID: setKp failed");

        (success, ) = pidController.call(
            abi.encodeWithSignature("setKi(int128)", newKi)
        );
        require(success, "PID: setKi failed");
    }
}