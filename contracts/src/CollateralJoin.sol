// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title CollateralJoin — WBTC custody contract
/// @notice Holds WBTC tokens and converts between asset amounts and internal WAD units
contract CollateralJoin {
    address public admin;
    address public safeManager;
    address public safeEngine;
    IERC20 public collateralToken;
    uint8 public tokenDecimals;
    uint256 public totalAssets;

    event Joined(address indexed user, uint256 assetAmount, uint256 internalAmount);
    event Exited(address indexed user, uint256 assetAmount, uint256 internalAmount);

    constructor(
        address _admin,
        address _collateralToken,
        uint8 _tokenDecimals,
        address _safeEngine
    ) {
        admin = _admin;
        collateralToken = IERC20(_collateralToken);
        tokenDecimals = _tokenDecimals;
        safeEngine = _safeEngine;
    }

    modifier onlySafeManager() {
        require(msg.sender == safeManager, "JOIN: not manager");
        _;
    }

    modifier onlyAdmin() {
        require(msg.sender == admin, "JOIN: not admin");
        _;
    }

    /// @notice Transfer WBTC from user into this contract, return internal (WAD) amount
    function join(address user, uint256 amount) external onlySafeManager returns (uint256) {
        uint256 internalAmount = _toInternal(amount);
        require(internalAmount > 0, "JOIN: zero amount");

        bool success = collateralToken.transferFrom(user, address(this), amount);
        require(success, "JOIN: transfer failed");

        totalAssets += amount;

        emit Joined(user, amount, internalAmount);
        return internalAmount;
    }

    /// @notice Transfer WBTC from this contract back to user, given internal (WAD) amount
    function exit(address user, uint256 amount) external onlySafeManager returns (uint256) {
        uint256 assetAmount = _toAssets(amount);
        require(assetAmount > 0, "JOIN: zero amount");

        require(totalAssets >= assetAmount, "JOIN: insufficient assets");
        totalAssets -= assetAmount;

        bool success = collateralToken.transfer(user, assetAmount);
        require(success, "JOIN: transfer failed");

        emit Exited(user, assetAmount, amount);
        return assetAmount;
    }

    /// @notice Convert asset amount (e.g. 8 decimals for WBTC) to internal WAD (18 decimals)
    function _toInternal(uint256 assetAmount) internal view returns (uint256) {
        if (tokenDecimals < 18) {
            uint256 scale = 10 ** (18 - tokenDecimals);
            return assetAmount * scale;
        } else if (tokenDecimals > 18) {
            uint256 scale = 10 ** (tokenDecimals - 18);
            return assetAmount / scale;
        }
        return assetAmount;
    }

    /// @notice Convert internal WAD (18 decimals) back to asset amount
    function _toAssets(uint256 internalAmount) internal view returns (uint256) {
        if (tokenDecimals < 18) {
            uint256 scale = 10 ** (18 - tokenDecimals);
            return internalAmount / scale;
        } else if (tokenDecimals > 18) {
            uint256 scale = 10 ** (tokenDecimals - 18);
            return internalAmount * scale;
        }
        return internalAmount;
    }

    function convertToInternal(uint256 assetAmount) external view returns (uint256) {
        return _toInternal(assetAmount);
    }

    function convertToAssets(uint256 internalAmount) external view returns (uint256) {
        return _toAssets(internalAmount);
    }

    function setSafeManager(address _safeManager) external onlyAdmin {
        safeManager = _safeManager;
    }
}
