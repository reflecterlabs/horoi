// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {PIDController} from "../src/PIDController.sol";

/// @title PIDControllerTest — RED-then-GREEN tests pinning the RAY-scale fix
/// @notice The pre-fix Solidity port computed proportional/integral in WAD;
///         these tests assert RAY semantics matching Cairo / HAI.
contract PIDControllerTest is Test {
    PIDController internal pid;

    // Demo-realistic params (post-fix scales)
    int128 internal constant KP = 6.67e11; // ~6.67e-7 WAD
    int128 internal constant KI = 6.67e5; // ~6.67e-13 WAD
    uint256 internal constant NOISE_BARRIER = 1e18; // == WAD → filter disabled
    uint64 internal constant INTEGRAL_PERIOD = 5;
    uint256 internal constant UPPER_BOUND = 1e27; // = RAY
    int128 internal constant LOWER_BOUND = -1e27; // -RAY (fits in int128)
    uint256 internal constant LEAK = 1e27; // RAY → no decay

    uint256 internal constant WAD = 1e18;
    uint256 internal constant RAY = 1e27;

    function setUp() public {
        // address(this) is admin AND seedProposer so we can call computeRate from tests
        pid = new PIDController(
            address(this),
            address(0),
            address(this),
            KP,
            KI,
            NOISE_BARRIER,
            INTEGRAL_PERIOD,
            UPPER_BOUND,
            LOWER_BOUND,
            LEAK
        );
    }

    // ========================================================================
    // RAY-scale proportional term — the killer test
    // ========================================================================

    /// 1% deviation: marketPrice 0.99 WAD vs redemptionPrice 1 RAY
    /// Expected (RAY): proportional = 1e25
    /// Bug   (WAD):   proportional = 1e16  ← will fail this test
    function test_proportionalTerm_isRayScaled_at1pctDeviation() public view {
        uint256 market = 0.99e18;
        uint256 redemption = 1e27;

        (, int128 proportional,) = pid.getNextRedemptionRate(market, redemption, RAY);

        // RAY-scale: 1% of RAY = 1e25
        assertEq(int256(proportional), int256(1e25), "proportional must be RAY-scaled");
    }

    /// 1% deviation produces a strictly-greater-than-RAY redemption rate
    /// (Bug path: piOutput so small that rate ≈ RAY)
    function test_computeRate_movesAboveRay_at1pctDeviation() public {
        uint256 market = 0.99e18; // 1% below peg
        uint256 redemption = 1e27;

        uint256 rate = pid.computeRate(market, redemption);

        assertGt(rate, RAY, "rate must increase when market < redemption");
    }

    /// On-peg: rate must equal RAY (no change)
    function test_computeRate_returnsRay_atZeroDeviation() public {
        uint256 market = 1e18;
        uint256 redemption = 1e27;

        uint256 rate = pid.computeRate(market, redemption);

        assertEq(rate, RAY, "rate must be RAY when market == redemption");
    }

    // ========================================================================
    // Authorization
    // ========================================================================

    function test_computeRate_revertsForNonSeedProposer() public {
        // Redeploy with a different seedProposer
        PIDController p = new PIDController(
            address(this),
            address(0),
            address(0xBEEF), // seedProposer
            KP,
            KI,
            NOISE_BARRIER,
            INTEGRAL_PERIOD,
            UPPER_BOUND,
            LOWER_BOUND,
            LEAK
        );

        vm.expectRevert(bytes("PID: only seed proposer"));
        p.computeRate(0.99e18, 1e27);
    }

    // ========================================================================
    // Cooldown
    // ========================================================================

    function test_computeRate_revertsOnCooldown() public {
        // First call seeds the deviation timestamp
        pid.computeRate(0.99e18, 1e27);

        // Second call within INTEGRAL_PERIOD must revert
        vm.expectRevert(bytes("PID: cooldown not elapsed"));
        pid.computeRate(0.99e18, 1e27);
    }

    function test_computeRate_succeedsAfterCooldown() public {
        pid.computeRate(0.99e18, 1e27);
        vm.warp(block.timestamp + INTEGRAL_PERIOD + 1);

        // Should not revert
        pid.computeRate(0.99e18, 1e27);
    }

    // ========================================================================
    // int128 overflow guard
    // ========================================================================

    /// Deploy with feedbackOutputUpperBound > int128.max. After fix, the
    /// internal cast must clip to int128.max instead of silently truncating.
    /// We verify by passing a piOutput value that would land safely after
    /// the clip but be incorrectly bounded if the cast wraps.
    function test_boundedPIOutput_clipsHugeUpperBound() public {
        uint256 hugeUpper = uint256(type(uint128).max) + 1; // > int128.max
        PIDController p = new PIDController(
            address(this),
            address(0),
            address(this),
            KP,
            KI,
            NOISE_BARRIER,
            INTEGRAL_PERIOD,
            hugeUpper,
            LOWER_BOUND,
            LEAK
        );

        // piOutput = int128.max — should pass through without overflow/wrap
        int128 piIn = type(int128).max;
        // After clip to int128.max, the bounded output equals piIn (rate caps)
        // The test passes if no revert / no wrap.
        uint256 rate = p.getBoundedRedemptionRate(piIn);
        assertGt(rate, 0, "rate must be a positive uint256");
    }

    // ========================================================================
    // Gain-adjusted PI output sanity
    // ========================================================================

    /// piOutput should be RAY-scaled (kp WAD * proportional RAY / WAD = RAY)
    function test_gainAdjustedPIOutput_isRayScaled() public view {
        // 1% deviation → proportional = 1e25 (RAY)
        // piOutput = swmul(KP, 1e25) = (6.67e11 * 1e25) / 1e18 = 6.67e18
        int128 piOutput = pid.getGainAdjustedPIOutput(int128(1e25), int128(0));

        // Expect ~6.67e18, allow small rounding window
        int256 expected = 6_670_000_000_000_000_000; // 6.67e18
        int256 actual = int256(piOutput);
        int256 diff = actual > expected ? actual - expected : expected - actual;
        assertLt(diff, 1e15, "piOutput must be RAY-scale (~6.67e18)");
    }
}
