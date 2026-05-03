// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {GrintaMath} from "./libraries/GrintaMath.sol";
import {GrintaEngine} from "./GrintaEngine.sol";
import {PIDController} from "./PIDController.sol";
import {OracleRelayer} from "./OracleRelayer.sol";

/// @title GrintaHook — Uniswap V4 hook that acts as the price oracle and rate updater
/// @notice Keeper-less: every swap computes GRIT/USDC price from delta, updates collateral price, and tries PID rate
/// @dev Dual throttle: price updates every 60s, rate updates every 3600s (matches PID cooldown)
/// @dev Only implements afterInitialize and afterSwap hooks
contract GrintaHook is IHooks {
    using GrintaMath for uint256;
    using BalanceDeltaLibrary for BalanceDelta;

    uint64 constant PRICE_UPDATE_INTERVAL = 60;
    uint64 constant RATE_UPDATE_INTERVAL = 3600;
    uint256 constant USDC_TO_WAD_SCALE = 1e30;
    uint256 constant MIN_MARKET_PRICE = 1e15;
    uint256 constant MAX_MARKET_PRICE = 1e21;

    address public admin;
    GrintaEngine public safeEngine;
    PIDController public pidController;
    OracleRelayer public oracleRelayer;

    Currency public gritCurrency;
    Currency public wbtcCurrency;
    Currency public usdcCurrency;

    uint256 public lastMarketPrice;
    uint256 public lastCollateralPrice;
    uint64 public lastPriceUpdateTime;
    uint64 public lastRateUpdateTime;

    event PricesUpdated(uint256 collateralPrice, uint64 timestamp);
    event MarketPriceUpdated(uint256 marketPrice, uint64 timestamp);
    event RateUpdated(uint256 newRate, uint64 timestamp);

    constructor(
        address _admin,
        address _safeEngine,
        address _pidController,
        address _oracleRelayer,
        Currency _gritCurrency,
        Currency _wbtcCurrency,
        Currency _usdcCurrency
    ) {
        admin = _admin;
        safeEngine = GrintaEngine(_safeEngine);
        pidController = PIDController(_pidController);
        oracleRelayer = OracleRelayer(_oracleRelayer);
        gritCurrency = _gritCurrency;
        wbtcCurrency = _wbtcCurrency;
        usdcCurrency = _usdcCurrency;
    }

    modifier onlyAdmin() {
        require(msg.sender == admin, "HOOK: not admin");
        _;
    }

    function _priceFromDelta(PoolKey calldata key, BalanceDelta delta) internal view returns (uint256) {
        int128 amount0 = delta.amount0();
        int128 amount1 = delta.amount1();

        uint256 amount0Mag = uint256(amount0 < 0 ? -int256(int128(amount0)) : int256(int128(amount0)));
        uint256 amount1Mag = uint256(amount1 < 0 ? -int256(int128(amount1)) : int256(int128(amount1)));

        if (amount0Mag == 0 || amount1Mag == 0) {
            return 0;
        }

        if (key.currency0 == gritCurrency) {
            return (amount1Mag * USDC_TO_WAD_SCALE) / amount0Mag;
        } else {
            return (amount0Mag * USDC_TO_WAD_SCALE) / amount1Mag;
        }
    }

    function _updateCollateralPrice() internal {
        uint64 now64 = uint64(block.timestamp);
        if (now64 - lastPriceUpdateTime < PRICE_UPDATE_INTERVAL) {
            return;
        }

        uint256 btcPriceWad = oracleRelayer.pricesWad(
            Currency.unwrap(wbtcCurrency),
            Currency.unwrap(usdcCurrency)
        );

        if (btcPriceWad == 0) {
            return;
        }

        lastCollateralPrice = btcPriceWad;
        lastPriceUpdateTime = now64;
        safeEngine.updateCollateralPrice(btcPriceWad);
        emit PricesUpdated(btcPriceWad, now64);
    }

    function _tryUpdateRate() internal {
        uint64 now64 = uint64(block.timestamp);
        if (now64 - lastRateUpdateTime < RATE_UPDATE_INTERVAL) {
            return;
        }

        uint256 marketPrice = lastMarketPrice;
        if (marketPrice == 0) {
            return;
        }

        uint256 redemptionPrice = safeEngine.getRedemptionPrice();
        if (redemptionPrice == 0) {
            return;
        }

        uint256 newRate = pidController.computeRate(marketPrice, redemptionPrice);
        safeEngine.updateRedemptionRate(newRate);
        lastRateUpdateTime = now64;
        emit RateUpdated(newRate, now64);
    }

    // ========================================================================
    // IHooks — Only implementing afterInitialize and afterSwap
    // ========================================================================

    function beforeInitialize(address, PoolKey calldata, uint160) external pure returns (bytes4) {
        return IHooks.beforeInitialize.selector;
    }

    function afterInitialize(address, PoolKey calldata, uint160, int24) external pure returns (bytes4) {
        return IHooks.afterInitialize.selector;
    }

    function beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        return IHooks.beforeAddLiquidity.selector;
    }

    function afterAddLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        return (IHooks.afterAddLiquidity.selector, BalanceDelta.wrap(0));
    }

    function beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        return IHooks.beforeRemoveLiquidity.selector;
    }

    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        return (IHooks.afterRemoveLiquidity.selector, BalanceDelta.wrap(0));
    }

    function beforeSwap(address, PoolKey calldata, SwapParams calldata, bytes calldata)
        external
        pure
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        return (IHooks.beforeSwap.selector, BeforeSwapDelta.wrap(0), 0);
    }

    function afterSwap(
        address,
        PoolKey calldata key,
        SwapParams calldata,
        BalanceDelta delta,
        bytes calldata
    ) external returns (bytes4, int128) {
        uint256 price = _priceFromDelta(key, delta);

        if (price >= MIN_MARKET_PRICE && price <= MAX_MARKET_PRICE) {
            lastMarketPrice = price;
            uint64 now64 = uint64(block.timestamp);
            emit MarketPriceUpdated(price, now64);
        }

        _updateCollateralPrice();
        _tryUpdateRate();

        return (IHooks.afterSwap.selector, 0);
    }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        return IHooks.beforeDonate.selector;
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        return IHooks.afterDonate.selector;
    }

    // ========================================================================
    // Manual interface
    // ========================================================================

    function update() external {
        _updateCollateralPrice();
        _tryUpdateRate();
    }

    function setMarketPrice(uint256 price) external {
        require(price >= MIN_MARKET_PRICE, "HOOK: price too low");
        require(price <= MAX_MARKET_PRICE, "HOOK: price too high");
        lastMarketPrice = price;
        uint64 now64 = uint64(block.timestamp);
        emit MarketPriceUpdated(price, now64);
    }

    function getMarketPrice() external view returns (uint256) {
        return lastMarketPrice;
    }

    function getCollateralPrice() external view returns (uint256) {
        return lastCollateralPrice;
    }

    function getLastUpdateTime() external view returns (uint64) {
        return lastPriceUpdateTime;
    }

    function setSafeEngine(address engine) external onlyAdmin {
        safeEngine = GrintaEngine(engine);
    }

    function setPidController(address controller) external onlyAdmin {
        pidController = PIDController(controller);
    }

    function setOracleRelayer(address oracle) external onlyAdmin {
        oracleRelayer = OracleRelayer(oracle);
    }
}
