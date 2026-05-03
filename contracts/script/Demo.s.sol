// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";

import {OracleRelayer} from "../src/OracleRelayer.sol";
import {GrintaEngine} from "../src/GrintaEngine.sol";
import {GrintaHook} from "../src/GrintaHook.sol";
import {ParameterGuard} from "../src/ParameterGuard.sol";
import {PIDController} from "../src/PIDController.sol";

/// @title Demo — testnet end-to-end without a V4 pool
/// @notice Pushes oracle price + manual market price + triggers PID rate compute
///         + agent governance via ParameterGuard. All on Unichain Sepolia.
contract Demo is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        address oracleAddr = vm.envAddress("HOROI_ORACLE");
        address engineAddr = vm.envAddress("HOROI_ENGINE");
        address hookAddr = vm.envAddress("HOROI_HOOK");
        address pidAddr = vm.envAddress("HOROI_PID");
        address guardAddr = vm.envAddress("HOROI_GUARD");
        address wbtcAddr = vm.envAddress("HOROI_WBTC");
        address usdcAddr = vm.envAddress("HOROI_USDC");

        OracleRelayer oracle = OracleRelayer(oracleAddr);
        GrintaEngine engine = GrintaEngine(engineAddr);
        GrintaHook hook = GrintaHook(hookAddr);
        ParameterGuard guard = ParameterGuard(guardAddr);
        PIDController pid = PIDController(pidAddr);

        console.log("=== Pre-state ===");
        console.log("kp:                    ", uint256(int256(pid.kp())));
        console.log("ki:                    ", uint256(int256(pid.ki())));
        console.log("collateral price (WAD):", engine.collateralPrice());
        console.log("redemption price (RAY):", engine.getRedemptionPrice());
        console.log("redemption rate (RAY): ", engine.redemptionRate());
        console.log("market price (WAD):    ", hook.getMarketPrice());

        vm.startBroadcast(deployerKey);

        // 1. Push BTC oracle price to $60,000
        oracle.updatePrice(wbtcAddr, usdcAddr, 60_000e18);

        // 2. Set market price to $0.99 (1% depeg below)
        hook.setMarketPrice(0.99e18);

        // 3. Manually trigger collateral propagation + PID rate compute
        hook.update();

        // 4. Agent proposes a higher KP (within bounds, within delta cap)
        int128 currentKp = pid.kp();
        int128 newKp = currentKp + int128(int256(uint256(6.67e10)));  // +10% baseline
        guard.proposeParameters(newKp, pid.ki(), false);

        vm.stopBroadcast();

        console.log("");
        console.log("=== Post-state ===");
        console.log("kp:                    ", uint256(int256(pid.kp())));
        console.log("ki:                    ", uint256(int256(pid.ki())));
        console.log("collateral price (WAD):", engine.collateralPrice());
        console.log("redemption price (RAY):", engine.getRedemptionPrice());
        console.log("redemption rate (RAY): ", engine.redemptionRate());
        console.log("market price (WAD):    ", hook.getMarketPrice());
        console.log("guard updateCount:     ", uint256(guard.updateCount()));
        console.log("Deployer:              ", deployer);
    }
}
