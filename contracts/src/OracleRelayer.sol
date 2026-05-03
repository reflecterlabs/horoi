// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {GrintaMath} from "./libraries/GrintaMath.sol";

/// @title OracleRelayer — Accepts USD prices from anyone, converts to x128, serves to GrintaHook
/// @notice MVP: no access control, no staleness checks — anyone can push a price
contract OracleRelayer {
    using GrintaMath for uint256;

    // 2^128 for WAD → x128 conversion
    uint256 constant TWO_POW_128 = 0x100000000000000000000000000000000;

    // (base, quote) → price in x128 format (for hook compatibility)
    mapping(address => mapping(address => uint256)) public pricesX128;

    // (base, quote) → price in WAD format (human-readable)
    mapping(address => mapping(address => uint256)) public pricesWad;

    uint64 public lastUpdateTime;

    event PriceUpdated(
        address indexed baseToken,
        address indexed quoteToken,
        uint256 priceWad,
        uint64 timestamp
    );

    /// @notice Push a price update — anyone can call (MVP, no access control)
    /// @param baseToken The base token address (e.g., WBTC)
    /// @param quoteToken The quote token address (e.g., USDC)
    /// @param priceUsdWad Price with 18 decimals (e.g., 60000 * 1e18 for $60,000)
    function updatePrice(
        address baseToken,
        address quoteToken,
        uint256 priceUsdWad
    ) external {
        require(priceUsdWad > 0, "ORACLE: price must be > 0");

        // Convert WAD → x128: price_x128 = price_wad * 2^128 / 1e18
        uint256 priceX128 = (priceUsdWad * TWO_POW_128) / GrintaMath.WAD;

        pricesX128[baseToken][quoteToken] = priceX128;
        pricesWad[baseToken][quoteToken] = priceUsdWad;

        uint64 now64 = uint64(block.timestamp);
        lastUpdateTime = now64;

        emit PriceUpdated(baseToken, quoteToken, priceUsdWad, now64);
    }

    /// @notice Read price in WAD format (human-readable)
    function getPriceWad(
        address baseToken,
        address quoteToken
    ) external view returns (uint256) {
        return pricesWad[baseToken][quoteToken];
    }

    /// @notice Read price in x128 format (for hook consumption)
    /// @dev Mimics IEkuboOracleExtension.get_price_x128_over_last() from Cairo version
    function getPriceX128OverLast(
        address baseToken,
        address quoteToken,
        uint64 /* period */
    ) external view returns (uint256) {
        return pricesX128[baseToken][quoteToken];
    }
}
