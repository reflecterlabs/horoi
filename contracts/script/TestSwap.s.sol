// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";

import {GrintaEngine} from "../src/GrintaEngine.sol";
import {GrintaHook} from "../src/GrintaHook.sol";
import {SwapHelper} from "../src/SwapHelper.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";

/// @title TestSwap — perform a small swap on GRIT/USDC and read system state
contract TestSwap is Script {
    uint160 constant MIN_SQRT_PRICE = 4295128739;
    uint160 constant MAX_SQRT_PRICE = 1461446703485210103287273052203988822378723970341;

    function run() external {
        uint256 deployerKey = vm.envOr(
            "PRIVATE_KEY",
            uint256(0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80)
        );
        address deployer = vm.addr(deployerKey);

        address engineAddr = vm.envAddress("HOROI_ENGINE");
        address hookAddr = vm.envAddress("HOROI_HOOK");
        address swpAddr = vm.envAddress("HOROI_SWAP_HELPER");
        address usdcAddr = vm.envAddress("HOROI_USDC");

        GrintaEngine engine = GrintaEngine(engineAddr);
        GrintaHook hook = GrintaHook(hookAddr);
        SwapHelper swp = SwapHelper(swpAddr);
        MockERC20 usdc = MockERC20(usdcAddr);

        // Reconstruct pool key
        address gritAddr = engineAddr;
        (address c0, address c1) = gritAddr < usdcAddr ? (gritAddr, usdcAddr) : (usdcAddr, gritAddr);
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(c0),
            currency1: Currency.wrap(c1),
            fee: 100,
            tickSpacing: 1,
            hooks: IHooks(hookAddr)
        });

        vm.startBroadcast(deployerKey);

        // Mint + approve USDC
        usdc.mint(deployer, 1_000e6);
        usdc.approve(swpAddr, type(uint256).max);

        // Swap 100 USDC → GRIT
        bool zeroForOne = c0 == usdcAddr; // USDC is the input
        int256 amountSpecified = -100e6; // exact-input
        uint160 sqrtLimit = zeroForOne ? MIN_SQRT_PRICE + 1 : MAX_SQRT_PRICE - 1;

        swp.swap(key, zeroForOne, amountSpecified, sqrtLimit, deployer);

        vm.stopBroadcast();

        console.log("=== Post-swap state ===");
        console.log("Market price (WAD):    ", hook.getMarketPrice());
        console.log("Collateral price (WAD):", engine.collateralPrice());
        console.log("Redemption price (RAY):", engine.getRedemptionPrice());
        console.log("Redemption rate (RAY): ", engine.redemptionRate());
    }
}
