// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {GrintaMath} from "./libraries/GrintaMath.sol";
import {GrintaTypes} from "./libraries/GrintaTypes.sol";

/// @title GrintaEngine — Core ledger + embedded Grit ERC20 + redemption price mechanism
/// @notice Adapted from Cairo SAFEEngine with HAI-style redemption price instead of multiplier
contract GrintaEngine {
    using GrintaMath for uint256;
    using GrintaTypes for GrintaTypes.Safe;

    // ========================================================================
    // Constants
    // ========================================================================

    uint256 constant MIN_PRICE = GrintaMath.RAY / 100; // 0.01 RAY ($0.01)

    // ========================================================================
    // Storage
    // ========================================================================

    // Access control
    address public admin;
    address public safeManager;
    address public hook;
    address public collateralJoin;

    // Safe accounting
    mapping(uint256 => GrintaTypes.Safe) public safes;
    mapping(uint256 => address) public safeOwners;
    uint256 public safeCount;

    // System totals
    uint256 public totalCollateral;
    uint256 public totalDebt;

    // Collateral pricing
    uint256 public collateralPrice; // BTC/USD price (WAD)

    // Redemption price mechanism (HAI-style)
    uint256 public redemptionPrice; // Target price of Grit in USD (RAY)
    uint256 public redemptionRate; // Per-second rate applied to redemption price (RAY)
    uint64 public redemptionPriceUpdateTime;

    // System parameters
    uint256 public debtCeiling; // Max total debt (WAD)
    uint256 public liquidationRatio; // Min collateral ratio (WAD, e.g. 1.5e18 = 150%)

    // Grit ERC20 (embedded)
    mapping(address => uint256) public gritBalances;
    mapping(address => mapping(address => uint256)) public gritAllowances;
    uint256 public gritTotalSupply;

    // ========================================================================
    // Events
    // ========================================================================

    event SafeCreated(uint256 indexed safeId, address owner);
    event CollateralDeposited(uint256 indexed safeId, uint256 amount);
    event CollateralWithdrawn(uint256 indexed safeId, uint256 amount);
    event GritBorrowed(uint256 indexed safeId, uint256 amount);
    event GritRepaid(uint256 indexed safeId, uint256 amount);
    event CollateralPriceUpdated(uint256 price);
    event RedemptionRateUpdated(uint256 rate);
    event RedemptionPriceUpdated(uint256 price);
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    // ========================================================================
    // Constructor
    // ========================================================================

    constructor(
        address _admin,
        uint256 _debtCeiling,
        uint256 _liquidationRatio
    ) {
        admin = _admin;
        debtCeiling = _debtCeiling;
        liquidationRatio = _liquidationRatio;
        // Initialize redemption price at $1 (RAY) and rate at 1.0 (RAY = no change)
        redemptionPrice = GrintaMath.RAY;
        redemptionRate = GrintaMath.RAY;
        redemptionPriceUpdateTime = uint64(block.timestamp);
    }

    // ========================================================================
    // Internal: redemption price update
    // ========================================================================

    /// @notice Updates redemption price based on elapsed time and current rate
    /// @dev redemptionPrice = redemptionRate^timeDelta * oldPrice (all in RAY)
    function _updateRedemptionPrice() internal returns (uint256) {
        uint64 now64 = uint64(block.timestamp);
        uint64 lastUpdate = redemptionPriceUpdateTime;

        if (now64 <= lastUpdate) {
            return redemptionPrice;
        }

        uint256 timeDelta = uint256(now64 - lastUpdate);
        uint256 ratePow = redemptionRate.rpow(timeDelta);
        uint256 oldPrice = redemptionPrice;
        uint256 newPrice = ratePow.rmul(oldPrice);

        // Floor: never let redemption price drop below 0.01 RAY ($0.01)
        if (newPrice < MIN_PRICE) {
            newPrice = MIN_PRICE;
        }

        redemptionPrice = newPrice;
        redemptionPriceUpdateTime = now64;

        emit RedemptionPriceUpdated(newPrice);
        return newPrice;
    }

    function _assertAdmin() internal view {
        require(msg.sender == admin, "SAFE: not admin");
    }

    function _assertSafeManager() internal view {
        require(msg.sender == safeManager, "SAFE: not manager");
    }

    function _assertHook() internal view {
        require(msg.sender == hook, "SAFE: not hook");
    }

    /// @notice Check that a safe is healthy: collateral_value / debt >= liquidation_ratio
    function _isSafeHealthy(uint256 safeId) internal view returns (bool) {
        GrintaTypes.Safe memory safe = safes[safeId];
        if (safe.debt == 0) return true;

        uint256 colValue = safe.collateral.wmul(collateralPrice);

        // Debt in USD = debt * (redemption_price / RAY)
        // Since redemption_price is RAY-scaled, debt_usd = rmul(debt_wad_as_ray, redemption_price)
        uint256 debtRay = safe.debt * 1e9; // WAD -> RAY (multiply by 1e9)
        uint256 debtUsdRay = debtRay.rmul(redemptionPrice);
        uint256 debtUsd = debtUsdRay / 1e9; // RAY -> WAD

        // col_value / debt_usd >= liquidation_ratio
        // Rearranged: col_value * WAD >= debt_usd * liquidation_ratio
        return colValue * GrintaMath.WAD >= debtUsd * liquidationRatio;
    }

    function _computeHealth(uint256 safeId) internal view returns (GrintaTypes.Health memory) {
        GrintaTypes.Safe memory safe = safes[safeId];
        uint256 colValue = safe.collateral.wmul(collateralPrice);

        uint256 debtRay = safe.debt * 1e9;
        uint256 debtUsdRay = debtRay.rmul(redemptionPrice);
        uint256 debtUsd = debtUsdRay / 1e9;

        uint256 ltv = colValue > 0 ? debtUsd.wdiv(colValue) : 0;

        uint256 liqPrice = safe.collateral > 0
            ? debtUsd.wmul(liquidationRatio).wdiv(safe.collateral)
            : 0;

        return GrintaTypes.Health(colValue, safe.debt, ltv, liqPrice);
    }

    // Grit ERC20 internal
    function _mint(address to, uint256 amount) internal {
        gritBalances[to] += amount;
        gritTotalSupply += amount;
        emit Transfer(address(0), to, amount);
    }

    function _burn(address from, uint256 amount) internal {
        require(gritBalances[from] >= amount, "SAFE: insufficient grit");
        gritBalances[from] -= amount;
        gritTotalSupply -= amount;
        emit Transfer(from, address(0), amount);
    }

    // ========================================================================
    // Safe operations (called by SafeManager)
    // ========================================================================

    function createSafe(address _owner) external returns (uint256) {
        _assertSafeManager();
        safeCount++;
        uint256 id = safeCount;
        safeOwners[id] = _owner;
        safes[id] = GrintaTypes.Safe(0, 0);
        emit SafeCreated(id, _owner);
        return id;
    }

    function depositCollateral(uint256 safeId, uint256 amount) external {
        _assertSafeManager();
        safes[safeId].collateral += amount;
        totalCollateral += amount;
        emit CollateralDeposited(safeId, amount);
    }

    function withdrawCollateral(uint256 safeId, uint256 amount) external {
        _assertSafeManager();
        require(safes[safeId].collateral >= amount, "SAFE: insufficient collateral");
        safes[safeId].collateral -= amount;
        require(_isSafeHealthy(safeId), "SAFE: would be undercollateral");
        totalCollateral -= amount;
        emit CollateralWithdrawn(safeId, amount);
    }

    function borrow(uint256 safeId, uint256 amount) external {
        _assertSafeManager();
        _updateRedemptionPrice();

        safes[safeId].debt += amount;
        totalDebt += amount;

        require(totalDebt <= debtCeiling, "SAFE: debt ceiling exceeded");
        require(_isSafeHealthy(safeId), "SAFE: undercollateralized");

        address owner = safeOwners[safeId];
        _mint(owner, amount);
        emit GritBorrowed(safeId, amount);
    }

    function repay(uint256 safeId, uint256 amount) external {
        _assertSafeManager();
        _updateRedemptionPrice();

        uint256 repayAmount = amount > safes[safeId].debt ? safes[safeId].debt : amount;
        safes[safeId].debt -= repayAmount;
        totalDebt -= repayAmount;

        address owner = safeOwners[safeId];
        _burn(owner, repayAmount);
        emit GritRepaid(safeId, repayAmount);
    }

    // ========================================================================
    // Oracle/Hook updates
    // ========================================================================

    function updateCollateralPrice(uint256 price) external {
        _assertHook();
        collateralPrice = price;
        emit CollateralPriceUpdated(price);
    }

    function updateRedemptionRate(uint256 rate) external {
        _assertHook();
        // First update the redemption price to current time with the old rate
        _updateRedemptionPrice();
        // Then set the new rate
        redemptionRate = rate;
        emit RedemptionRateUpdated(rate);
    }

    // ========================================================================
    // View functions
    // ========================================================================

    function getSafe(uint256 safeId) external view returns (GrintaTypes.Safe memory) {
        return safes[safeId];
    }

    function getSafeOwner(uint256 safeId) external view returns (address) {
        return safeOwners[safeId];
    }

    function getSafeHealth(uint256 safeId) external view returns (GrintaTypes.Health memory) {
        return _computeHealth(safeId);
    }

    function getSystemHealth() external view returns (GrintaTypes.Health memory) {
        uint256 colValue = totalCollateral.wmul(collateralPrice);

        uint256 debtRay = totalDebt * 1e9;
        uint256 debtUsdRay = debtRay.rmul(redemptionPrice);
        uint256 debtUsd = debtUsdRay / 1e9;

        uint256 ltv = colValue > 0 ? debtUsd.wdiv(colValue) : 0;

        return GrintaTypes.Health(colValue, totalDebt, ltv, 0);
    }

    function getRedemptionPrice() external view returns (uint256) {
        // View function: compute current price without updating state
        uint64 now64 = uint64(block.timestamp);
        uint64 lastUpdate = redemptionPriceUpdateTime;

        if (now64 <= lastUpdate) {
            return redemptionPrice;
        }

        uint256 timeDelta = uint256(now64 - lastUpdate);
        uint256 ratePow = redemptionRate.rpow(timeDelta);
        uint256 price = ratePow.rmul(redemptionPrice);

        return price < MIN_PRICE ? MIN_PRICE : price;
    }

    // ========================================================================
    // Admin
    // ========================================================================

    function setDebtCeiling(uint256 ceiling) external {
        _assertAdmin();
        debtCeiling = ceiling;
    }

    function setLiquidationRatio(uint256 ratio) external {
        _assertAdmin();
        liquidationRatio = ratio;
    }

    function setCollateralJoin(address join) external {
        _assertAdmin();
        collateralJoin = join;
    }

    function setSafeManager(address manager) external {
        _assertAdmin();
        safeManager = manager;
    }

    function setHook(address _hook) external {
        _assertAdmin();
        hook = _hook;
    }

    function resetRedemptionPrice(uint256 price, uint256 rate) external {
        _assertAdmin();
        redemptionPrice = price;
        redemptionRate = rate;
        redemptionPriceUpdateTime = uint64(block.timestamp);
    }

    function mintGrit(address to, uint256 amount) external {
        _assertAdmin();
        _mint(to, amount);
    }

    // ========================================================================
    // ERC20 Implementation for Grit
    // ========================================================================

    function name() external pure returns (string memory) {
        return "Grit";
    }

    function symbol() external pure returns (string memory) {
        return "GRIT";
    }

    function decimals() external pure returns (uint8) {
        return 18;
    }

    function totalSupply() external view returns (uint256) {
        return gritTotalSupply;
    }

    function balanceOf(address account) external view returns (uint256) {
        return gritBalances[account];
    }

    function allowance(address owner, address spender) external view returns (uint256) {
        return gritAllowances[owner][spender];
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(gritBalances[msg.sender] >= amount, "GRIT: insufficient balance");
        gritBalances[msg.sender] -= amount;
        gritBalances[to] += amount;
        emit Transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(gritAllowances[from][msg.sender] >= amount, "GRIT: insufficient allowance");
        gritAllowances[from][msg.sender] -= amount;
        require(gritBalances[from] >= amount, "GRIT: insufficient balance");
        gritBalances[from] -= amount;
        gritBalances[to] += amount;
        emit Transfer(from, to, amount);
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        gritAllowances[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }
}
