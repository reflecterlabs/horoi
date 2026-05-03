// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

interface IERC20Minimal {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// @title LiquidityHelper — Adds/removes liquidity via PoolManager unlock callback
/// @notice Bypasses PositionManager for direct, script-friendly LP operations
contract LiquidityHelper is IUnlockCallback {
    using BalanceDeltaLibrary for BalanceDelta;

    IPoolManager public immutable poolManager;

    constructor(address _poolManager) {
        poolManager = IPoolManager(_poolManager);
    }

    /// @notice Add liquidity to a V4 pool
    /// @dev Caller must approve both tokens to this contract before calling
    function addLiquidity(
        PoolKey memory key,
        int24 tickLower,
        int24 tickUpper,
        int256 liquidityDelta,
        address payer
    ) external returns (BalanceDelta delta) {
        bytes memory result = poolManager.unlock(
            abi.encode(key, tickLower, tickUpper, liquidityDelta, payer)
        );
        delta = abi.decode(result, (BalanceDelta));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(poolManager), "LH: not pool manager");

        (
            PoolKey memory key,
            int24 tickLower,
            int24 tickUpper,
            int256 liquidityDelta,
            address payer
        ) = abi.decode(data, (PoolKey, int24, int24, int256, address));

        (BalanceDelta delta,) = poolManager.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidityDelta: liquidityDelta,
                salt: bytes32(0)
            }),
            ""
        );

        // Settle tokens owed to the pool (negative delta = caller pays)
        _settleIfNeeded(key.currency0, delta.amount0(), payer);
        _settleIfNeeded(key.currency1, delta.amount1(), payer);

        return abi.encode(delta);
    }

    function _settleIfNeeded(Currency currency, int128 amount, address payer) internal {
        if (amount >= 0) return; // Nothing owed or pool owes us

        uint256 amountOwed = uint256(uint128(-amount));
        address token = Currency.unwrap(currency);

        // Sync balance, transfer tokens, then settle
        poolManager.sync(currency);
        IERC20Minimal(token).transferFrom(payer, address(poolManager), amountOwed);
        poolManager.settle();
    }
}
