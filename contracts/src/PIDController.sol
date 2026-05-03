// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {GrintaMath} from "./libraries/GrintaMath.sol";
import {GrintaTypes} from "./libraries/GrintaTypes.sol";

/// @title PIDController — HAI-style PI controller with leaky integrator
/// @notice Ported from HAI's PIDController.sol via Cairo version
/// @dev Outputs a redemption rate that adjusts a continuously drifting redemption price
contract PIDController {
    using GrintaMath for uint256;
    using GrintaMath for int256;

    // Maximum positive rate: type(int128).max equivalent
    uint256 constant POSITIVE_RATE_LIMIT = 170141183460469231731687303715884105727; // 2^127 - 1
    // Minimum rate floor: ~0.9999999 RAY per second
    uint256 constant MIN_RATE_FLOOR = 999_999_930_000_000_000_000_000_000; // ~0.99999993 RAY

    address public admin;
    address public guardian; // ParameterGuard can adjust Kp/Ki
    address public seedProposer; // Only this address can call computeRate (the hook)

    // Controller gains
    int128 public kp; // Proportional gain (WAD)
    int128 public ki; // Integral gain (WAD)

    // Parameters
    uint256 public noiseBarrier; // Min deviation to act (WAD)
    uint64 public integralPeriodSize; // Min seconds between updates
    uint256 public feedbackOutputUpperBound; // Max positive adjustment (RAY)
    int128 public feedbackOutputLowerBound; // Max negative adjustment (RAY)
    uint256 public perSecondCumulativeLeak; // Integral decay per second (RAY)

    // State: last deviation observation
    uint64 public deviationTimestamp;
    int128 public deviationProportional;
    int128 public deviationIntegral;

    event UpdateDeviation(int128 proportional, int128 integral, int128 appliedDeviation);
    event RateComputed(uint256 marketPrice, uint256 redemptionPrice, uint256 redemptionRate);

    constructor(
        address _admin,
        address _guardian,
        address _seedProposer,
        int128 _kp,
        int128 _ki,
        uint256 _noiseBarrier,
        uint64 _integralPeriodSize,
        uint256 _feedbackOutputUpperBound,
        int128 _feedbackOutputLowerBound,
        uint256 _perSecondCumulativeLeak
    ) {
        admin = _admin;
        guardian = _guardian;
        seedProposer = _seedProposer;
        kp = _kp;
        ki = _ki;
        noiseBarrier = _noiseBarrier;
        integralPeriodSize = _integralPeriodSize;
        feedbackOutputUpperBound = _feedbackOutputUpperBound;
        feedbackOutputLowerBound = _feedbackOutputLowerBound;
        perSecondCumulativeLeak = _perSecondCumulativeLeak;
    }

    // ========================================================================
    // Internal functions
    // ========================================================================

    function _assertAdmin() internal view {
        require(msg.sender == admin, "PID: not admin");
    }

    function _assertGuardian() internal view {
        require(msg.sender == guardian, "PID: not guardian");
    }

    function _timeSinceLastUpdate() internal view returns (uint64) {
        uint64 ts = deviationTimestamp;
        if (ts == 0) return 0;
        return uint64(block.timestamp) - ts;
    }

    /// @notice Proportional term = (redemptionPrice - scaledMarketPrice) / redemptionPrice
    /// @dev Result is RAY-scaled (27 decimals) — matches Cairo / HAI rdiv semantics
    function _getProportionalTerm(
        uint256 marketPrice,
        uint256 redemptionPrice
    ) internal pure returns (int128) {
        // Market price is WAD (18 dec), redemption price is RAY (27 dec)
        // Scale market price to RAY
        uint256 scaledMarket = marketPrice * 1e9; // WAD -> RAY

        // Compute deviation: (redemptionPrice - scaledMarket) / redemptionPrice  → RAY
        if (scaledMarket <= redemptionPrice) {
            // Positive deviation (market below target)
            uint256 diff = redemptionPrice - scaledMarket;
            uint256 ratio = (diff * GrintaMath.RAY) / redemptionPrice;
            return int128(int256(ratio));
        } else {
            // Negative deviation (market above target)
            uint256 diff = scaledMarket - redemptionPrice;
            uint256 ratio = (diff * GrintaMath.RAY) / redemptionPrice;
            return -int128(int256(ratio));
        }
    }

    /// @notice Check if |piOutput| breaks the noise barrier
    /// @dev All RAY-domain (mirrors Cairo). noiseBarrier is WAD-scaled (e.g. 0.95e18).
    ///      noise_barrier == WAD disables the filter (every nonzero deviation acts).
    function _breaksNoiseBarrier(
        uint256 piSum,
        uint256 redemptionPrice
    ) internal view returns (bool) {
        if (piSum == 0) return false;

        uint256 deltaNoise = 2 * GrintaMath.WAD - noiseBarrier;
        uint256 threshold = (redemptionPrice * deltaNoise) / GrintaMath.WAD;

        if (threshold <= redemptionPrice) return true; // noise_barrier >= WAD → filter off
        return piSum >= threshold - redemptionPrice;
    }

    /// @notice Gain adjusted PI output: Kp * P + Ki * I
    function _getGainAdjustedPIOutput(
        int128 proportional,
        int128 integral
    ) internal view returns (int128) {
        int256 kpVal = int256(kp);
        int256 kiVal = int256(ki);
        int256 proportional256 = int256(proportional);
        int256 integral256 = int256(integral);
        int256 result = kpVal.swmul(proportional256) + kiVal.swmul(integral256);
        return int128(result);
    }

    /// @notice Bound the PI output between lower and upper bounds
    /// @dev Explicitly clip the upper bound to int128.max if it overflows
    ///      (uint256 storage can hold values larger than int128 can represent).
    function _getBoundedPIOutput(int128 piOutput) internal view returns (int128) {
        int128 lower = feedbackOutputLowerBound;
        uint256 upperU = feedbackOutputUpperBound;
        int128 upper = upperU > uint256(uint128(type(int128).max))
            ? type(int128).max
            : int128(int256(upperU));

        if (piOutput < lower) {
            return lower;
        } else if (piOutput > upper) {
            return upper;
        }
        return piOutput;
    }

    /// @notice Convert bounded PI output to a redemption rate
    /// @dev rate = RAY + boundedPIOutput (clamped to [MIN_RATE_FLOOR, POSITIVE_RATE_LIMIT])
    function _getBoundedRedemptionRate(int128 piOutput) internal view returns (uint256) {
        int128 bounded = _getBoundedPIOutput(piOutput);

        if (bounded < -int128(int256(GrintaMath.RAY))) {
            // Would make rate negative, clamp to floor
            return MIN_RATE_FLOOR;
        }

        int256 newRateI = int256(GrintaMath.RAY) + int256(bounded);
        if (newRateI <= 0) {
            return MIN_RATE_FLOOR;
        }

        uint256 rate = uint256(newRateI);
        return rate < MIN_RATE_FLOOR ? MIN_RATE_FLOOR : rate;
    }

    /// @notice Compute next integral term with leak
    function _getNextDeviationCumulative(
        int128 proportional,
        uint256 accumulatedLeak
    ) internal view returns (int128, int128) {
        int128 lastProportional = deviationProportional;
        uint64 timeElapsed = _timeSinceLastUpdate();

        // Trapezoidal integration: (current + last) / 2 * timeDelta
        int256 avgDeviation = int256(proportional).riemannSum(int256(lastProportional));
        int128 newTimeAdjusted = int128(avgDeviation * int256(uint256(timeElapsed)));

        // Apply leak to existing integral
        int128 oldIntegral = deviationIntegral;
        int256 leakedIntegral256 = int256(oldIntegral).srmul(accumulatedLeak);
        int128 leakedIntegral = int128(leakedIntegral256);

        return (leakedIntegral + newTimeAdjusted, newTimeAdjusted);
    }

    /// @notice Update deviation state
    function _updateDeviation(
        int128 proportional,
        uint256 accumulatedLeak
    ) internal returns (int128) {
        (int128 integral, int128 appliedDeviation) = _getNextDeviationCumulative(
            proportional,
            accumulatedLeak
        );

        deviationTimestamp = uint64(block.timestamp);
        deviationProportional = proportional;
        deviationIntegral = integral;

        emit UpdateDeviation(proportional, integral, appliedDeviation);
        return integral;
    }

    // ========================================================================
    // Public functions
    // ========================================================================

    /// @notice Main entry point: compute new redemption rate given market and redemption prices
    /// @dev Only callable by seedProposer (the GrintaHook)
    function computeRate(
        uint256 marketPrice,
        uint256 redemptionPrice
    ) external returns (uint256) {
        require(msg.sender == seedProposer, "PID: only seed proposer");

        uint64 timeSince = _timeSinceLastUpdate();
        // Enforce cooldown (except first update)
        if (deviationTimestamp != 0) {
            require(timeSince >= integralPeriodSize, "PID: cooldown not elapsed");
        }

        // 1. Compute proportional term
        int128 proportional = _getProportionalTerm(marketPrice, redemptionPrice);

        // 2. Compute accumulated leak for the integral
        uint256 leak = perSecondCumulativeLeak;
        uint256 accumulatedLeak = leak.rpow(uint256(timeSince));

        // 3. Update integral term
        int128 integral = _updateDeviation(proportional, accumulatedLeak);

        // 4. Apply gains and sum
        int128 piOutput = _getGainAdjustedPIOutput(proportional, integral);

        // 5. Check noise barrier
        uint256 absOutput = uint256(int256(piOutput < 0 ? -piOutput : piOutput));
        if (_breaksNoiseBarrier(absOutput, redemptionPrice)) {
            uint256 rate = _getBoundedRedemptionRate(piOutput);
            emit RateComputed(marketPrice, redemptionPrice, rate);
            return rate;
        } else {
            emit RateComputed(marketPrice, redemptionPrice, GrintaMath.RAY);
            return GrintaMath.RAY;
        }
    }

    function getNextRedemptionRate(
        uint256 marketPrice,
        uint256 redemptionPrice,
        uint256 accumulatedLeak
    ) external view returns (uint256, int128, int128) {
        int128 proportional = _getProportionalTerm(marketPrice, redemptionPrice);
        (int128 integral, ) = _getNextDeviationCumulative(proportional, accumulatedLeak);
        int128 piOutput = _getGainAdjustedPIOutput(proportional, integral);

        uint256 absOutput = uint256(int256(piOutput < 0 ? -piOutput : piOutput));
        if (_breaksNoiseBarrier(absOutput, redemptionPrice)) {
            return (_getBoundedRedemptionRate(piOutput), proportional, integral);
        }
        return (GrintaMath.RAY, proportional, integral);
    }

    function getBoundedRedemptionRate(int128 piOutput) external view returns (uint256) {
        return _getBoundedRedemptionRate(piOutput);
    }

    function getGainAdjustedPIOutput(
        int128 proportionalTerm,
        int128 integralTerm
    ) external view returns (int128) {
        return _getGainAdjustedPIOutput(proportionalTerm, integralTerm);
    }

    function breaksNoiseBarrier(uint256 piSum, uint256 redemptionPrice) external view returns (bool) {
        return _breaksNoiseBarrier(piSum, redemptionPrice);
    }

    function getDeviationObservation() external view returns (GrintaTypes.DeviationObservation memory) {
        return GrintaTypes.DeviationObservation(deviationTimestamp, deviationProportional, deviationIntegral);
    }

    function getControllerGains() external view returns (GrintaTypes.ControllerGains memory) {
        return GrintaTypes.ControllerGains(kp, ki);
    }

    function getParams() external view returns (GrintaTypes.PIDControllerParams memory) {
        return GrintaTypes.PIDControllerParams(
            noiseBarrier,
            integralPeriodSize,
            feedbackOutputUpperBound,
            feedbackOutputLowerBound,
            perSecondCumulativeLeak
        );
    }

    function timeSinceLastUpdate() external view returns (uint256) {
        return uint256(_timeSinceLastUpdate());
    }

    // ========================================================================
    // Admin
    // ========================================================================

    function setSeedProposer(address proposer) external {
        _assertAdmin();
        seedProposer = proposer;
    }

    function setKp(int128 _kp) external {
        require(msg.sender == admin || msg.sender == guardian, "PID: not authorized");
        kp = _kp;
    }

    function setKi(int128 _ki) external {
        require(msg.sender == admin || msg.sender == guardian, "PID: not authorized");
        ki = _ki;
    }

    function setNoiseBarrier(uint256 barrier) external {
        _assertAdmin();
        noiseBarrier = barrier;
    }

    function setGuardian(address _guardian) external {
        _assertAdmin();
        guardian = _guardian;
    }

    function setPerSecondCumulativeLeak(uint256 leak) external {
        _assertAdmin();
        perSecondCumulativeLeak = leak;
    }
}
