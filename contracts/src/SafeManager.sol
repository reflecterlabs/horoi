// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {GrintaMath} from "./libraries/GrintaMath.sol";
import {GrintaTypes} from "./libraries/GrintaTypes.sol";
import {GrintaEngine} from "./GrintaEngine.sol";
import {CollateralJoin} from "./CollateralJoin.sol";

/// @title SafeManager — User and agent-facing safe management
/// @notice Handles open/close/deposit/withdraw/borrow/repay
/// @dev Keeper-less: calls hook.update() before every SAFE operation that needs fresh prices
contract SafeManager {
    using GrintaMath for uint256;

    address public admin;
    GrintaEngine public safeEngine;
    CollateralJoin public collateralJoin;
    address public hook;

    event SafeOpened(uint256 indexed safeId, address indexed owner);
    event SafeClosed(uint256 indexed safeId);

    constructor(
        address _admin,
        address _safeEngine,
        address _collateralJoin,
        address _hook
    ) {
        admin = _admin;
        safeEngine = GrintaEngine(_safeEngine);
        collateralJoin = CollateralJoin(_collateralJoin);
        hook = _hook;
    }

    modifier onlyAdmin() {
        require(msg.sender == admin, "MGR: not admin");
        _;
    }

    /// @notice Call hook.update() to refresh prices before SAFE operations
    function _updatePrices() internal {
        if (hook != address(0)) {
            // Call the hook's update function
            (bool success, ) = hook.call(abi.encodeWithSignature("update()"));
            // Don't revert if hook fails - it's optional
            (success);
        }
    }

    function openSafe() external returns (uint256) {
        uint256 safeId = safeEngine.createSafe(msg.sender);
        emit SafeOpened(safeId, msg.sender);
        return safeId;
    }

    function closeSafe(uint256 safeId) external {
        _updatePrices();
        GrintaTypes.Safe memory safe = safeEngine.getSafe(safeId);
        require(msg.sender == safeEngine.getSafeOwner(safeId), "MGR: not authorized");
        require(safe.debt == 0, "MGR: safe has debt");

        if (safe.collateral > 0) {
            safeEngine.withdrawCollateral(safeId, safe.collateral);
            collateralJoin.exit(msg.sender, safe.collateral);
        }
        emit SafeClosed(safeId);
    }

    function deposit(uint256 safeId, uint256 amount) external {
        _updatePrices();
        require(msg.sender == safeEngine.getSafeOwner(safeId), "MGR: not authorized");
        uint256 internalAmount = collateralJoin.join(msg.sender, amount);
        safeEngine.depositCollateral(safeId, internalAmount);
    }

    function withdraw(uint256 safeId, uint256 amount) external {
        _updatePrices();
        require(msg.sender == safeEngine.getSafeOwner(safeId), "MGR: not authorized");
        safeEngine.withdrawCollateral(safeId, amount);
        collateralJoin.exit(msg.sender, amount);
    }

    function borrow(uint256 safeId, uint256 amount) external {
        _updatePrices();
        require(msg.sender == safeEngine.getSafeOwner(safeId), "MGR: not authorized");
        safeEngine.borrow(safeId, amount);
    }

    function repay(uint256 safeId, uint256 amount) external {
        _updatePrices();
        require(msg.sender == safeEngine.getSafeOwner(safeId), "MGR: not authorized");
        safeEngine.repay(safeId, amount);
    }

    /// @notice Open a safe, deposit collateral, and borrow in one transaction
    function openAndBorrow(
        uint256 collateralAmount,
        uint256 borrowAmount
    ) external returns (uint256) {
        _updatePrices();

        uint256 safeId = safeEngine.createSafe(msg.sender);
        uint256 internalAmount = collateralJoin.join(msg.sender, collateralAmount);
        safeEngine.depositCollateral(safeId, internalAmount);
        safeEngine.borrow(safeId, borrowAmount);

        emit SafeOpened(safeId, msg.sender);
        return safeId;
    }

    function getPositionHealth(uint256 safeId) external view returns (GrintaTypes.Health memory) {
        return safeEngine.getSafeHealth(safeId);
    }

    function getMaxBorrow(uint256 safeId) external view returns (uint256) {
        GrintaTypes.Safe memory safe = safeEngine.getSafe(safeId);
        uint256 colPrice = safeEngine.collateralPrice();
        uint256 colValue = safe.collateral.wmul(colPrice);
        uint256 liqRatio = safeEngine.liquidationRatio();
        uint256 maxDebtUsd = colValue.wdiv(liqRatio);

        (, , , , uint256 rPrice) = _getRedemptionPrice();
        uint256 rPriceWad = rPrice / 1e9; // RAY -> WAD
        uint256 maxGrit = rPriceWad > 0 ? maxDebtUsd.wdiv(rPriceWad) : 0;
        return maxGrit > safe.debt ? maxGrit - safe.debt : 0;
    }

    function getSafeOwner(uint256 safeId) external view returns (address) {
        return safeEngine.getSafeOwner(safeId);
    }

    function _getRedemptionPrice() internal view returns (uint256, uint256, uint256, uint64, uint256) {
        // We need to call the engine's getter
        return (0, 0, 0, 0, safeEngine.getRedemptionPrice());
    }

    function setHook(address _hook) external onlyAdmin {
        hook = _hook;
    }
}
