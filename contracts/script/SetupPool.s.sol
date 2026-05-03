// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";

import {OracleRelayer} from "../src/OracleRelayer.sol";
import {GrintaEngine} from "../src/GrintaEngine.sol";
import {GrintaHook} from "../src/GrintaHook.sol";
import {LiquidityHelper} from "../src/LiquidityHelper.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";

/// @title SetupPool — initialize the GRIT/USDC V4 pool, push prices, seed liquidity
/// @notice Reads contract addresses from env vars set after running Deploy.s.sol
contract SetupPool is Script {
    function run() external {
        uint256 deployerKey = vm.envOr(
            "PRIVATE_KEY",
            uint256(0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80)
        );
        address deployer = vm.addr(deployerKey);

        address poolManagerAddr = vm.envAddress("HOROI_POOL_MANAGER");
        address oracleAddr = vm.envAddress("HOROI_ORACLE");
        address engineAddr = vm.envAddress("HOROI_ENGINE");
        address hookAddr = vm.envAddress("HOROI_HOOK");
        address liqHelperAddr = vm.envAddress("HOROI_LIQUIDITY_HELPER");
        address wbtcAddr = vm.envAddress("HOROI_WBTC");
        address usdcAddr = vm.envAddress("HOROI_USDC");

        OracleRelayer oracle = OracleRelayer(oracleAddr);
        GrintaEngine engine = GrintaEngine(engineAddr);
        GrintaHook hook = GrintaHook(hookAddr);
        IPoolManager poolManager = IPoolManager(poolManagerAddr);
        LiquidityHelper liq = LiquidityHelper(liqHelperAddr);
        MockERC20 wbtc = MockERC20(wbtcAddr);
        MockERC20 usdc = MockERC20(usdcAddr);

        vm.startBroadcast(deployerKey);

        // Push collateral price to oracle: BTC/USDC = $60,000
        oracle.updatePrice(wbtcAddr, usdcAddr, 60_000e18);

        // Bootstrap market price at $1
        hook.setMarketPrice(1e18);

        // Sort currencies for pool key
        address gritAddr = engineAddr; // GRIT lives in GrintaEngine
        (address c0, address c1) = gritAddr < usdcAddr ? (gritAddr, usdcAddr) : (usdcAddr, gritAddr);

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(c0),
            currency1: Currency.wrap(c1),
            fee: 100, // 0.01%
            tickSpacing: 1,
            hooks: IHooks(hookAddr)
        });

        // sqrtPriceX96 derivation:
        //   GRIT (18 dec) is currency0, USDC (6 dec) is currency1 (sorted by addr).
        //   Want 1 human GRIT == 1 human USDC ⇒
        //   1e18 raw GRIT ↔ 1e6 raw USDC ⇒ raw price (token1/token0) = 1e-12
        //   sqrtPrice = 1e-6 ⇒ sqrtPriceX96 = 1e-6 * 2^96 = 79228162514264337593544
        uint160 sqrtPriceX96 = uint160(79228162514264337593544);
        poolManager.initialize(key, sqrtPriceX96);

        // Mint USDC + GRIT (extra cushion vs the ~10K each addLiquidity needs)
        usdc.mint(deployer, 1_000_000e6);
        engine.mintGrit(deployer, 1_000_000e18);

        // Approve helper
        usdc.approve(liqHelperAddr, type(uint256).max);
        engine.approve(liqHelperAddr, type(uint256).max);

        // Tick at price 1e-12 (token1/token0 raw) ≈ -276324. Center ±50 ticks.
        int24 tickLower = -276375;
        int24 tickUpper = -276275;
        int256 liquidityDelta = 2e18;

        liq.addLiquidity(key, tickLower, tickUpper, liquidityDelta, deployer);

        vm.stopBroadcast();

        console.log("=== Pool Setup ===");
        console.log("Pool currency0:", c0);
        console.log("Pool currency1:", c1);
        console.log("BTC oracle (WAD):", oracle.getPriceWad(wbtcAddr, usdcAddr));
        console.log("Market price (WAD):", hook.getMarketPrice());
        console.log("Engine collateralPrice:", engine.collateralPrice());
        console.log("Engine redemptionPrice:", engine.getRedemptionPrice());
        console.log("Engine redemptionRate:", engine.redemptionRate());
    }
}
