// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {GrintaEngine} from "../src/GrintaEngine.sol";
import {PIDController} from "../src/PIDController.sol";
import {OracleRelayer} from "../src/OracleRelayer.sol";
import {CollateralJoin} from "../src/CollateralJoin.sol";
import {SafeManager} from "../src/SafeManager.sol";
import {GrintaHook} from "../src/GrintaHook.sol";
import {ParameterGuard} from "../src/ParameterGuard.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";
import {HookMiner} from "../script/HookMiner.sol";

/// @title IntegrationTest — end-to-end: depeg → hook update → PID → engine rate moves
contract IntegrationTest is Test {
    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    uint256 constant WAD = 1e18;
    uint256 constant RAY = 1e27;

    int128 constant KP = 6.67e11;
    int128 constant KI = 6.67e5;
    int128 constant KP_MIN = 3.33e11;
    int128 constant KP_MAX = 1e12;
    int128 constant KI_MIN = 3.33e5;
    int128 constant KI_MAX = 1e6;
    uint256 constant MAX_KP_DELTA = 6.67e10;
    uint256 constant MAX_KI_DELTA = 6.67e4;

    address internal admin = address(this);
    address internal agent = address(0xA9E47);

    MockERC20 wbtc;
    MockERC20 usdc;
    OracleRelayer oracle;
    GrintaEngine engine;
    PIDController pid;
    CollateralJoin join;
    GrintaHook hook;
    SafeManager mgr;
    ParameterGuard guard;

    function setUp() public {
        wbtc = new MockERC20("Wrapped BTC", "WBTC", 8);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        oracle = new OracleRelayer();
        engine = new GrintaEngine(admin, 1_000_000e18, 1.5e18);

        pid = new PIDController(
            admin,
            address(0),
            address(0),
            KP,
            KI,
            1e18, // noise barrier — disabled (== WAD)
            5,    // integral period
            RAY,
            -int128(int256(RAY)),
            RAY
        );

        join = new CollateralJoin(admin, address(wbtc), 8, address(engine));

        // Mine salt + deploy hook with new{salt:} (deployer = this test contract)
        bytes memory hookArgs = abi.encode(
            admin,
            address(engine),
            address(pid),
            address(oracle),
            Currency.wrap(address(engine)), // GRIT (engine self)
            Currency.wrap(address(wbtc)),
            Currency.wrap(address(usdc))
        );
        (address predicted, bytes32 salt) = HookMiner.find(
            address(this),
            Hooks.AFTER_SWAP_FLAG,
            type(GrintaHook).creationCode,
            hookArgs
        );
        hook = new GrintaHook{salt: salt}(
            admin,
            address(engine),
            address(pid),
            address(oracle),
            Currency.wrap(address(engine)),
            Currency.wrap(address(wbtc)),
            Currency.wrap(address(usdc))
        );
        require(address(hook) == predicted, "Hook addr mismatch");

        mgr = new SafeManager(admin, address(engine), address(join), address(hook));

        guard = new ParameterGuard(
            admin,
            address(pid),
            agent,
            KP_MIN,
            KP_MAX,
            KI_MIN,
            KI_MAX,
            MAX_KP_DELTA,
            MAX_KI_DELTA,
            5,    // cooldown
            3,    // emergency cooldown
            1000  // max updates
        );

        // Wire perms
        engine.setHook(address(hook));
        engine.setSafeManager(address(mgr));
        engine.setCollateralJoin(address(join));
        join.setSafeManager(address(mgr));
        pid.setSeedProposer(address(hook));
        pid.setGuardian(address(guard));
    }

    // ====================================================================
    // E2E: market depeg → agent proposes → hook triggers PID → rate moves
    // ====================================================================

    function test_e2e_rateMovesOnDepeg() public {
        // Push BTC oracle price
        oracle.updatePrice(address(wbtc), address(usdc), 60_000e18);

        // Bootstrap market price slightly below peg (1% below)
        hook.setMarketPrice(0.99e18);

        // Move time forward so price update interval is satisfied.
        // Hook's PRICE_UPDATE_INTERVAL=60s, RATE_UPDATE_INTERVAL=3600s.
        vm.warp(block.timestamp + 3601);

        // First update propagates collateral price to engine and (after rate
        // throttle) triggers PID rate computation
        hook.update();

        // Engine should now have collateral price set
        assertEq(engine.collateralPrice(), 60_000e18, "collateral price propagated");

        // And redemption rate moved away from RAY (above, since market < redemption)
        uint256 rate = engine.redemptionRate();
        assertGt(rate, RAY, "redemption rate must increase under depeg-below");
    }

    // ====================================================================
    // E2E: agent rotation — guard rotates KP within bounds
    // ====================================================================

    function test_e2e_agentRotatesKpThroughGuard() public {
        int128 newKp = KP + int128(int256(MAX_KP_DELTA / 2));

        vm.prank(agent);
        guard.proposeParameters(newKp, KI, false);

        assertEq(int256(pid.kp()), int256(newKp), "guard updated PID kp");
        assertEq(uint256(guard.updateCount()), 1, "guard update count incremented");
    }
}
