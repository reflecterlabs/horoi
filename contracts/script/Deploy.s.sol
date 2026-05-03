// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {GrintaEngine} from "../src/GrintaEngine.sol";
import {PIDController} from "../src/PIDController.sol";
import {OracleRelayer} from "../src/OracleRelayer.sol";
import {CollateralJoin} from "../src/CollateralJoin.sol";
import {SafeManager} from "../src/SafeManager.sol";
import {GrintaHook} from "../src/GrintaHook.sol";
import {ParameterGuard} from "../src/ParameterGuard.sol";
import {LiquidityHelper} from "../src/LiquidityHelper.sol";
import {SwapHelper} from "../src/SwapHelper.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";
import {HookMiner} from "./HookMiner.sol";

/// @title Deploy — full Horoi Protocol deployment for Anvil / Unichain Sepolia
/// @notice Detects chainId and either deploys a PoolManager (Anvil) or uses
///         the canonical Unichain Sepolia PoolManager.
contract Deploy is Script {
    // ====================================================================
    // Constants
    // ====================================================================

    uint256 constant WAD = 1e18;
    uint256 constant RAY = 1e27;

    // PID baseline (post-RAY-fix scales)
    int128 constant KP = 6.67e11; // ~6.67e-7 WAD
    int128 constant KI = 6.67e5;  // ~6.67e-13 WAD
    uint256 constant NOISE_BARRIER = 1e18; // == WAD → filter disabled (every dev acts)
    uint64 constant INTEGRAL_PERIOD = 5; // demo cooldown
    uint256 constant LEAK = 1e27; // RAY = no decay (demo)

    // ParameterGuard policy (±50% of baseline; 10% delta cap)
    int128 constant KP_MIN = 3.33e11;
    int128 constant KP_MAX = 1e12;
    int128 constant KI_MIN = 3.33e5;
    int128 constant KI_MAX = 1e6;
    uint256 constant MAX_KP_DELTA = 6.67e10;
    uint256 constant MAX_KI_DELTA = 6.67e4;
    uint64 constant COOLDOWN = 5;
    uint64 constant EMERGENCY_COOLDOWN = 3;
    uint32 constant MAX_UPDATES = 1000;

    // System parameters
    uint256 constant DEBT_CEILING = 1_000_000e18;
    uint256 constant LIQUIDATION_RATIO = 1.5e18;

    // Canonical deployers / addresses
    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    address constant UNICHAIN_SEPOLIA_POOL_MANAGER = 0x00B036B58a818B1BC34d502D3fE730Db729e62AC;

    function run() external {
        uint256 deployerKey = vm.envOr(
            "PRIVATE_KEY",
            uint256(0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80)
        );
        address deployer = vm.addr(deployerKey);
        address agent = vm.envOr("AGENT_ADDRESS", deployer);

        vm.startBroadcast(deployerKey);

        // ----------------------------------------------------------------
        // PoolManager: deploy locally on Anvil; use canonical on Unichain.
        // ----------------------------------------------------------------
        IPoolManager poolManager;
        if (block.chainid == 31337) {
            poolManager = IPoolManager(address(new PoolManager(deployer)));
        } else if (block.chainid == 1301) {
            poolManager = IPoolManager(UNICHAIN_SEPOLIA_POOL_MANAGER);
        } else {
            revert("Deploy: unsupported chainId");
        }

        // ----------------------------------------------------------------
        // Mock tokens (always — even on testnets we deploy our own pair).
        // ----------------------------------------------------------------
        MockERC20 wbtc = new MockERC20("Wrapped BTC", "WBTC", 8);
        MockERC20 usdc = new MockERC20("USD Coin", "USDC", 6);

        // ----------------------------------------------------------------
        // OracleRelayer
        // ----------------------------------------------------------------
        OracleRelayer oracle = new OracleRelayer();

        // ----------------------------------------------------------------
        // GrintaEngine (admin = deployer; debt ceiling 1M; LR 150%)
        // ----------------------------------------------------------------
        GrintaEngine engine = new GrintaEngine(deployer, DEBT_CEILING, LIQUIDATION_RATIO);

        // ----------------------------------------------------------------
        // PIDController — seedProposer set to address(0) initially; will
        //                 be set to the hook address AFTER salt mining.
        // ----------------------------------------------------------------
        PIDController pid = new PIDController(
            deployer,
            address(0),       // guardian — set after Guard deployed
            address(0),       // seedProposer — set after hook deployed
            KP,
            KI,
            NOISE_BARRIER,
            INTEGRAL_PERIOD,
            RAY,              // upper bound (RAY)
            -int128(int256(RAY)), // lower bound (-RAY)
            LEAK
        );

        // ----------------------------------------------------------------
        // CollateralJoin — WBTC, 8 decimals
        // ----------------------------------------------------------------
        CollateralJoin join = new CollateralJoin(deployer, address(wbtc), 8, address(engine));

        // ----------------------------------------------------------------
        // Mine hook salt for afterSwap-only flag (bit 6).
        // ----------------------------------------------------------------
        uint160 flags = Hooks.AFTER_SWAP_FLAG;
        bytes memory hookArgs = abi.encode(
            deployer,
            address(engine),
            address(pid),
            address(oracle),
            Currency.wrap(address(0)),  // GRIT — re-encoded with engine address below for hook constructor
            Currency.wrap(address(wbtc)),
            Currency.wrap(address(usdc))
        );
        // GRIT token is GrintaEngine itself (embedded ERC20)
        hookArgs = abi.encode(
            deployer,
            address(engine),
            address(pid),
            address(oracle),
            Currency.wrap(address(engine)),
            Currency.wrap(address(wbtc)),
            Currency.wrap(address(usdc))
        );
        (address predictedHook, bytes32 salt) = HookMiner.find(
            CREATE2_DEPLOYER,
            flags,
            type(GrintaHook).creationCode,
            hookArgs
        );

        // Deploy hook via canonical CREATE2 deployer to match predicted address.
        bytes memory hookInitcode = abi.encodePacked(type(GrintaHook).creationCode, hookArgs);
        (bool ok, ) = CREATE2_DEPLOYER.call(abi.encodePacked(salt, hookInitcode));
        require(ok, "Deploy: hook CREATE2 failed");
        require(predictedHook.code.length > 0, "Deploy: hook not deployed at predicted addr");
        GrintaHook hook = GrintaHook(predictedHook);

        // ----------------------------------------------------------------
        // SafeManager
        // ----------------------------------------------------------------
        SafeManager mgr = new SafeManager(
            deployer,
            address(engine),
            address(join),
            address(hook)
        );

        // ----------------------------------------------------------------
        // ParameterGuard
        // ----------------------------------------------------------------
        ParameterGuard guard = new ParameterGuard(
            deployer,
            address(pid),
            agent,
            KP_MIN,
            KP_MAX,
            KI_MIN,
            KI_MAX,
            MAX_KP_DELTA,
            MAX_KI_DELTA,
            COOLDOWN,
            EMERGENCY_COOLDOWN,
            MAX_UPDATES
        );

        // ----------------------------------------------------------------
        // Helpers (LiquidityHelper, SwapHelper)
        // ----------------------------------------------------------------
        LiquidityHelper liq = new LiquidityHelper(address(poolManager));
        SwapHelper swp = new SwapHelper(address(poolManager));

        // ----------------------------------------------------------------
        // Permission wiring
        // ----------------------------------------------------------------
        engine.setHook(address(hook));
        engine.setSafeManager(address(mgr));
        engine.setCollateralJoin(address(join));
        join.setSafeManager(address(mgr));
        pid.setSeedProposer(address(hook));
        pid.setGuardian(address(guard));

        vm.stopBroadcast();

        // ----------------------------------------------------------------
        // Print deployed addresses
        // ----------------------------------------------------------------
        console.log("=== Horoi Deployment ===");
        console.log("ChainId:        ", block.chainid);
        console.log("Deployer:       ", deployer);
        console.log("Agent:          ", agent);
        console.log("PoolManager:    ", address(poolManager));
        console.log("WBTC:           ", address(wbtc));
        console.log("USDC:           ", address(usdc));
        console.log("OracleRelayer:  ", address(oracle));
        console.log("GrintaEngine:   ", address(engine));
        console.log("PIDController:  ", address(pid));
        console.log("CollateralJoin: ", address(join));
        console.log("GrintaHook:     ", address(hook));
        console.log("SafeManager:    ", address(mgr));
        console.log("ParameterGuard: ", address(guard));
        console.log("LiquidityHelper:", address(liq));
        console.log("SwapHelper:     ", address(swp));
        console.log("HookSalt:       ");
        console.logBytes32(salt);
    }
}
