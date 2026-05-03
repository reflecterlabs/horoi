// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title GrintaMath — Fixed-point math library for WAD (18 decimals) and RAY (27 decimals)
/// @notice Adapted from HAI/RAI math with half-unit rounding for banker's rounding behavior
library GrintaMath {
    uint256 constant WAD = 1e18;
    uint256 constant RAY = 1e27;
    int256 constant WAD_INT = 1e18;
    int256 constant RAY_INT = 1e27;

    // ========================================================================
    // Unsigned fixed-point math
    // ========================================================================

    /// @dev (a * b + WAD/2) / WAD
    function wmul(uint256 a, uint256 b) internal pure returns (uint256) {
        return (a * b + WAD / 2) / WAD;
    }

    /// @dev (a * WAD + b/2) / b
    function wdiv(uint256 a, uint256 b) internal pure returns (uint256) {
        return (a * WAD + b / 2) / b;
    }

    /// @dev (a * b + RAY/2) / RAY
    function rmul(uint256 a, uint256 b) internal pure returns (uint256) {
        return (a * b + RAY / 2) / RAY;
    }

    /// @dev (a * RAY + b/2) / b
    function rdiv(uint256 a, uint256 b) internal pure returns (uint256) {
        return (a * RAY + b / 2) / b;
    }

    /// @dev base^exp in RAY precision using binary exponentiation
    function rpow(uint256 base, uint256 exp) internal pure returns (uint256) {
        if (exp == 0) return RAY;
        if (base == 0) return 0;

        uint256 result = RAY;
        uint256 b = base;
        uint256 e = exp;

        while (e > 0) {
            if (e % 2 == 1) {
                result = rmul(result, b);
            }
            b = rmul(b, b);
            e /= 2;
        }

        return result;
    }

    // ========================================================================
    // Signed fixed-point math (int256)
    // ========================================================================

    /// @dev Absolute value of int256, returned as uint256
    function abs(int256 x) internal pure returns (uint256) {
        return x < 0 ? uint256(-x) : uint256(x);
    }

    /// @dev Signed wmul: (a * b) / WAD
    function swmul(int256 a, int256 b) internal pure returns (int256) {
        uint256 aU = abs(a);
        uint256 bU = abs(b);
        uint256 product = aU * bU;
        uint256 resultU = (product + WAD / 2) / WAD;
        bool neg = (a < 0) != (b < 0);
        return neg ? -int256(resultU) : int256(resultU);
    }

    /// @dev Signed rmul: (a * b) / RAY where b is RAY-scaled
    function srmul(int256 a, uint256 b) internal pure returns (int256) {
        uint256 aU = abs(a);
        uint256 resultU = (aU * b + RAY / 2) / RAY;
        return a < 0 ? -int256(resultU) : int256(resultU);
    }

    /// @dev Trapezoidal sum: (a + b) / 2
    function riemannSum(int256 a, int256 b) internal pure returns (int256) {
        return (a + b) / 2;
    }

    /// @dev Convert WAD to RAY (multiply by 1e9)
    function wadToRay(uint256 wad) internal pure returns (uint256) {
        return wad * 1e9;
    }

    /// @dev Convert RAY to WAD (divide by 1e9)
    function rayToWad(uint256 ray) internal pure returns (uint256) {
        return ray / 1e9;
    }
}
