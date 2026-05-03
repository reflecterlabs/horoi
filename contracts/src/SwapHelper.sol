// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

interface IERC20Minimal {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
}

/// @title SwapHelper — Executes swaps via PoolManager unlock callback
contract SwapHelper is IUnlockCallback {
    using BalanceDeltaLibrary for BalanceDelta;

    IPoolManager public immutable poolManager;

    constructor(address _poolManager) {
        poolManager = IPoolManager(_poolManager);
    }

    /// @notice Execute a swap
    /// @dev Caller must approve input token to this contract
    function swap(
        PoolKey memory key,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        address payer
    ) external returns (BalanceDelta delta) {
        bytes memory result = poolManager.unlock(
            abi.encode(key, zeroForOne, amountSpecified, sqrtPriceLimitX96, payer)
        );
        delta = abi.decode(result, (BalanceDelta));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(poolManager), "SH: not pool manager");

        (
            PoolKey memory key,
            bool zeroForOne,
            int256 amountSpecified,
            uint160 sqrtPriceLimitX96,
            address payer
        ) = abi.decode(data, (PoolKey, bool, int256, uint160, address));

        BalanceDelta delta = poolManager.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: sqrtPriceLimitX96
            }),
            ""
        );

        // Settle: negative delta = we owe pool, positive delta = pool owes us
        _settle(key.currency0, delta.amount0(), payer);
        _settle(key.currency1, delta.amount1(), payer);

        return abi.encode(delta);
    }

    function _settle(Currency currency, int128 amount, address payer) internal {
        address token = Currency.unwrap(currency);

        if (amount < 0) {
            // We owe pool — pull from payer and settle
            uint256 amountOwed = uint256(uint128(-amount));
            poolManager.sync(currency);
            IERC20Minimal(token).transferFrom(payer, address(poolManager), amountOwed);
            poolManager.settle();
        } else if (amount > 0) {
            // Pool owes us — take to payer
            uint256 amountOwed = uint256(uint128(amount));
            poolManager.take(currency, payer, amountOwed);
        }
    }
}
