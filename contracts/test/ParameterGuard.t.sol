// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ParameterGuard} from "../src/ParameterGuard.sol";
import {PIDController} from "../src/PIDController.sol";

contract ParameterGuardTest is Test {
    PIDController internal pid;
    ParameterGuard internal guard;

    // Realistic post-RAY-fix params
    int128 internal constant KP_BASELINE = 6.67e11;
    int128 internal constant KI_BASELINE = 6.67e5;
    int128 internal constant KP_MIN = 3.33e11;
    int128 internal constant KP_MAX = 1e12;
    int128 internal constant KI_MIN = 3.33e5;
    int128 internal constant KI_MAX = 1e6;
    uint256 internal constant MAX_KP_DELTA = 6.67e10;
    uint256 internal constant MAX_KI_DELTA = 6.67e4;
    uint64 internal constant COOLDOWN = 5;
    uint64 internal constant EMERGENCY_COOLDOWN = 3;
    uint32 internal constant MAX_UPDATES = 1000;

    address internal proposer = address(0xA1);
    address internal admin = address(this);

    function setUp() public {
        // PID with this test as admin; guardian set to ParameterGuard after deploy
        pid = new PIDController(
            admin,
            address(0), // guardian (set later)
            address(0), // seedProposer (not exercised here)
            KP_BASELINE,
            KI_BASELINE,
            1e18, // noise barrier
            5, // integral period
            1e27, // upper bound
            -int128(int256(1e27)), // lower bound
            1e27 // leak
        );

        guard = new ParameterGuard(
            admin,
            address(pid),
            proposer,
            KP_MIN,
            KP_MAX,
            KI_MIN,
            KI_MAX,
            MAX_KP_DELTA,
            MAX_KI_DELTA,
            COOLDOWN,
            EMERGENCY_COOLDOWN,
            MAX_UPDATES
        );

        // Wire guard as PID guardian
        pid.setGuardian(address(guard));
    }

    // ========================================================================
    // Happy path
    // ========================================================================

    function test_inBoundsProposalApplies() public {
        int128 newKp = KP_BASELINE + int128(int256(MAX_KP_DELTA / 2));

        vm.prank(proposer);
        guard.proposeParameters(newKp, KI_BASELINE, false);

        assertEq(int256(pid.kp()), int256(newKp));
        assertEq(int256(pid.ki()), int256(KI_BASELINE));
        assertEq(uint256(guard.updateCount()), 1);
    }

    // ========================================================================
    // Authorization
    // ========================================================================

    function test_nonProposerReverts() public {
        vm.prank(address(0xDEAD));
        vm.expectRevert(ParameterGuard.GuardNotProposer.selector);
        guard.proposeParameters(KP_BASELINE, KI_BASELINE, false);
    }

    // ========================================================================
    // Bounds
    // ========================================================================

    function test_kpAboveMaxReverts() public {
        // Need a proposal that's in delta but above bound
        // Set baseline near KP_MAX so delta puts us over
        // First, push KP up to near KP_MAX
        vm.startPrank(proposer);
        for (uint256 i = 0; i < 5; i++) {
            int128 step = int128(int256(MAX_KP_DELTA));
            int128 cur = pid.kp();
            int128 nxt = cur + step;
            if (nxt > KP_MAX) nxt = KP_MAX;
            guard.proposeParameters(nxt, KI_BASELINE, false);
            vm.warp(block.timestamp + COOLDOWN + 1);
        }
        vm.stopPrank();

        // KP is now KP_MAX. Propose KP_MAX + small step → bound violation
        int128 over = KP_MAX + 1;
        vm.warp(block.timestamp + COOLDOWN + 1);
        vm.prank(proposer);
        vm.expectRevert(ParameterGuard.GuardKpAboveMax.selector);
        guard.proposeParameters(over, KI_BASELINE, false);
    }

    function test_kpBelowMinReverts() public {
        // Push KP down to just above KP_MIN by repeated proposals
        vm.startPrank(proposer);
        for (uint256 i = 0; i < 6; i++) {
            int128 step = int128(int256(MAX_KP_DELTA));
            int128 cur = pid.kp();
            int128 nxt = cur - step;
            if (nxt < KP_MIN) nxt = KP_MIN;
            guard.proposeParameters(nxt, KI_BASELINE, false);
            vm.warp(block.timestamp + COOLDOWN + 1);
        }
        vm.stopPrank();

        int128 under = KP_MIN - 1;
        vm.warp(block.timestamp + COOLDOWN + 1);
        vm.prank(proposer);
        vm.expectRevert(ParameterGuard.GuardKpBelowMin.selector);
        guard.proposeParameters(under, KI_BASELINE, false);
    }

    function test_deltaTooLargeReverts() public {
        // current KP = baseline; propose baseline + 2*MAX_KP_DELTA → too big
        int128 tooBig = KP_BASELINE + int128(int256(MAX_KP_DELTA * 2));
        // This may also breach KP_MAX; cap below max but above delta
        if (tooBig > KP_MAX) tooBig = KP_MAX; // still exceeds delta cap
        vm.assume(uint256(int256(tooBig - KP_BASELINE)) > MAX_KP_DELTA);

        vm.prank(proposer);
        vm.expectRevert(ParameterGuard.GuardKpDeltaTooLarge.selector);
        guard.proposeParameters(tooBig, KI_BASELINE, false);
    }

    // ========================================================================
    // Cooldown
    // ========================================================================

    function test_cooldownActiveReverts() public {
        int128 newKp = KP_BASELINE + int128(int256(MAX_KP_DELTA / 2));
        vm.prank(proposer);
        guard.proposeParameters(newKp, KI_BASELINE, false);

        // Same block — cooldown active
        vm.prank(proposer);
        vm.expectRevert(ParameterGuard.GuardCooldownActive.selector);
        guard.proposeParameters(newKp, KI_BASELINE, false);
    }

    function test_emergencyCooldownShorterApplies() public {
        int128 newKp = KP_BASELINE + int128(int256(MAX_KP_DELTA / 2));
        vm.prank(proposer);
        guard.proposeParameters(newKp, KI_BASELINE, false);

        // Advance past EMERGENCY_COOLDOWN but not COOLDOWN
        vm.warp(block.timestamp + EMERGENCY_COOLDOWN + 1);

        // Normal mode would still revert (cooldown not elapsed)
        vm.prank(proposer);
        vm.expectRevert(ParameterGuard.GuardCooldownActive.selector);
        guard.proposeParameters(newKp + 1, KI_BASELINE, false);

        // Emergency mode succeeds
        vm.prank(proposer);
        guard.proposeParameters(newKp + 1, KI_BASELINE, true);
        assertEq(uint256(guard.updateCount()), 2);
    }

    // ========================================================================
    // Budget
    // ========================================================================

    function test_budgetExhaustedReverts() public {
        // Deploy a guard with budget = 1
        ParameterGuard small = new ParameterGuard(
            admin,
            address(pid),
            proposer,
            KP_MIN,
            KP_MAX,
            KI_MIN,
            KI_MAX,
            MAX_KP_DELTA,
            MAX_KI_DELTA,
            COOLDOWN,
            EMERGENCY_COOLDOWN,
            1 // maxUpdates
        );
        // Re-wire PID guardian to small guard for this test
        pid.setGuardian(address(small));

        int128 newKp = KP_BASELINE + int128(int256(MAX_KP_DELTA / 2));
        vm.prank(proposer);
        small.proposeParameters(newKp, KI_BASELINE, false);

        vm.warp(block.timestamp + COOLDOWN + 1);
        vm.prank(proposer);
        vm.expectRevert(ParameterGuard.GuardBudgetExhausted.selector);
        small.proposeParameters(newKp + 1, KI_BASELINE, false);
    }

    // ========================================================================
    // Emergency stop / resume
    // ========================================================================

    function test_emergencyStopHaltsProposals() public {
        guard.emergencyStop();

        vm.prank(proposer);
        vm.expectRevert(ParameterGuard.GuardStopped.selector);
        guard.proposeParameters(KP_BASELINE, KI_BASELINE, false);
    }

    function test_resumeAllowsProposals() public {
        guard.emergencyStop();
        guard.resume();

        int128 newKp = KP_BASELINE + int128(int256(MAX_KP_DELTA / 2));
        vm.prank(proposer);
        guard.proposeParameters(newKp, KI_BASELINE, false);
        assertEq(uint256(guard.updateCount()), 1);
    }
}
