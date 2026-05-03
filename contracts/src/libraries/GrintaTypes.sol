// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title GrintaTypes — Data structures for the Grinta protocol
library GrintaTypes {
    /// @notice A safe (vault/trove) holding collateral and debt
    struct Safe {
        uint256 collateral; // WBTC collateral in internal units (WAD, 18 decimals)
        uint256 debt;       // Outstanding Grit debt (WAD)
    }

    /// @notice Health metrics for a safe or the system
    struct Health {
        uint256 collateralValue; // USD value of collateral (WAD)
        uint256 debt;            // Outstanding debt (WAD)
        uint256 ltv;             // Loan-to-value ratio (WAD, 0.5e18 = 50%)
        uint256 liquidationPrice; // BTC price at which position is liquidatable (WAD)
    }

    /// @notice PID controller state observation
    struct DeviationObservation {
        uint64 timestamp;
        int128 proportional; // Current proportional term (RAY-scaled — matches HAI/Cairo)
        int128 integral;     // Accumulated integral term (RAY * seconds)
    }

    /// @notice PID controller parameters
    struct PIDControllerParams {
        uint256 noiseBarrier;               // Min deviation to trigger (WAD)
        uint64 integralPeriodSize;          // Min seconds between updates
        uint256 feedbackOutputUpperBound;   // Max positive rate adjustment (RAY)
        int128 feedbackOutputLowerBound;    // Max negative rate adjustment (RAY)
        uint256 perSecondCumulativeLeak;    // Integral decay per second (RAY)
    }

    /// @notice PID controller gains
    struct ControllerGains {
        int128 kp; // Proportional gain (WAD)
        int128 ki; // Integral gain (WAD)
    }
}
