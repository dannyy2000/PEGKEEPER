// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";

import {PegKeeper} from "../src/PegKeeper.sol";
import {MockPriceFeed} from "../src/MockPriceFeed.sol";
import {MockERC20} from "../src/MockERC20.sol";
import {ReactiveMonitor} from "../src/ReactiveMonitor.sol";
import {HookMiner} from "./HookMiner.sol";

/// @title Deploy
/// @notice Deploys the full PegKeeper system in one broadcast:
///         MockUSDT → MockPriceFeed → PegKeeper (CREATE2) → ReactiveMonitor → pool init.
///
/// Pool pair: real USDC (Unichain Sepolia) / MockUSDT (deployed here).
/// Token ordering is resolved automatically — no manual sorting needed.
///
/// Usage:
///   cp .env.example .env  # fill in vars
///   forge script script/Deploy.s.sol \
///     --rpc-url unichain_sepolia \
///     --broadcast \
///     --verify \
///     -vvvv
///
/// Required env vars (see .env.example):
///   PRIVATE_KEY           deployer private key (no 0x prefix)
///   POOL_MANAGER_ADDRESS  Unichain Sepolia PoolManager
///   USDC_ADDRESS          real USDC on Unichain Sepolia
contract Deploy is Script {
    using PoolIdLibrary for PoolKey;

    struct Config {
        uint256 deployerKey;
        address poolManagerAddr;
        address usdcAddr;
        address deployer;
    }

    struct Precomputed {
        address monitor;
        address usdt;
        address token0;
        address token1;
        address expectedHook;
        bytes32 salt;
    }

    struct DeploymentResult {
        MockERC20 usdt;
        MockPriceFeed priceFeed;
        PegKeeper hook;
        ReactiveMonitor monitor;
    }

    // afterInitialize (12) | beforeAddLiquidity (11) | afterAddLiquidity (10) | beforeSwap (7)
    uint160 constant HOOK_FLAGS     = 0x1C80;
    uint160 constant HOOK_FLAG_MASK = 0x3FFF; // lowest 14 bits

    // Forge routes all CREATE2 deployments in broadcast through this deterministic proxy
    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    // sqrtPriceX96 for 1:1 price = sqrt(1) * 2^96
    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336;

    // 1 million tokens minted to deployer for liquidity provision
    uint256 constant MINT_AMOUNT = 1_000_000 * 1e6; // 6 decimals

    function run() external {
        Config memory config = _loadConfig();
        Precomputed memory precomputed = _precompute(config);
        DeploymentResult memory deployed = _deploy(config, precomputed);
        bytes32 poolId = _initializePool(config, precomputed, deployed);

        _logSummary(config, precomputed, deployed, poolId);
    }

    function _loadConfig() internal returns (Config memory config) {
        config.deployerKey = vm.envUint("PRIVATE_KEY");
        config.poolManagerAddr = vm.envAddress("POOL_MANAGER_ADDRESS");
        config.usdcAddr = vm.envAddress("USDC_ADDRESS");
        config.deployer = vm.addr(config.deployerKey);
    }

    function _precompute(Config memory config) internal returns (Precomputed memory precomputed) {
        // Nonce progression during broadcast:
        //   nonce+0  → MockUSDT
        //   nonce+1  → MockPriceFeed
        //   nonce+2  → PegKeeper
        //   nonce+3  → ReactiveMonitor
        uint64 startNonce = vm.getNonce(config.deployer);

        precomputed.monitor = vm.computeCreateAddress(config.deployer, startNonce + 3);
        console2.log("Pre-computed ReactiveMonitor:", precomputed.monitor);

        // Pre-compute MockUSDT address so we can sort the pair before mining
        precomputed.usdt = vm.computeCreateAddress(config.deployer, startNonce);

        // Sort tokens — PoolManager requires currency0 < currency1
        (precomputed.token0, precomputed.token1) = config.usdcAddr < precomputed.usdt
            ? (config.usdcAddr, precomputed.usdt)
            : (precomputed.usdt, config.usdcAddr);

        console2.log("token0:", precomputed.token0);
        console2.log("token1:", precomputed.token1);

        // Mine CREATE2 salt for PegKeeper
        bytes memory initCode = abi.encodePacked(
            type(PegKeeper).creationCode,
            abi.encode(config.poolManagerAddr, precomputed.monitor)
        );

        (precomputed.expectedHook, precomputed.salt) = HookMiner.find(
            CREATE2_DEPLOYER,
            HOOK_FLAGS,
            HOOK_FLAG_MASK,
            initCode
        );
        console2.log("Mined PegKeeper address:", precomputed.expectedHook);
        console2.log("Salt (uint256)          :", uint256(precomputed.salt));
    }

    function _deploy(Config memory config, Precomputed memory precomputed)
        internal
        returns (DeploymentResult memory deployed)
    {
        vm.startBroadcast(config.deployerKey);

        // 1. MockUSDT  (nonce+0 → lands at precomputedUSDT)
        // Initial supply minted in constructor — no separate tx, keeps nonce count exact.
        deployed.usdt = new MockERC20("Mock USDT", "USDT", 6, MINT_AMOUNT);
        require(address(deployed.usdt) == precomputed.usdt, "Deploy: USDT address mismatch");
        console2.log("MockUSDT deployed       :", address(deployed.usdt));

        // 2. MockPriceFeed  (nonce+1)
        deployed.priceFeed = new MockPriceFeed();
        console2.log("MockPriceFeed deployed  :", address(deployed.priceFeed));

        // 3. PegKeeper via CREATE2  (nonce+2)
        // Using Solidity's new{salt:} syntax so the EOA is the direct CREATE2 deployer,
        // matching the address mined by HookMiner.find(deployer, ...).
        deployed.hook = new PegKeeper{salt: precomputed.salt}(
            IPoolManager(config.poolManagerAddr),
            precomputed.monitor
        );
        require(address(deployed.hook) == precomputed.expectedHook, "Deploy: hook address mismatch");
        console2.log("PegKeeper deployed      :", address(deployed.hook));

        // 4. ReactiveMonitor  (nonce+3 → lands at precomputedMonitor)
        deployed.monitor = new ReactiveMonitor(
            address(deployed.hook),
            address(deployed.priceFeed)
        );
        require(address(deployed.monitor) == precomputed.monitor, "Deploy: monitor address mismatch");
        console2.log("ReactiveMonitor deployed:", address(deployed.monitor));

        vm.stopBroadcast();
    }

    function _initializePool(
        Config memory config,
        Precomputed memory precomputed,
        DeploymentResult memory deployed
    ) internal returns (bytes32 poolId) {
        // 5. Initialise USDC/USDT pool
        PoolKey memory key = PoolKey({
            currency0:   Currency.wrap(precomputed.token0),
            currency1:   Currency.wrap(precomputed.token1),
            fee:         LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 1,
            hooks:       IHooks(address(deployed.hook))
        });

        vm.startBroadcast(config.deployerKey);
        IPoolManager(config.poolManagerAddr).initialize(key, SQRT_PRICE_1_1);
        vm.stopBroadcast();

        console2.log("Pool initialised. PoolId:");
        poolId = PoolId.unwrap(key.toId());
        console2.logBytes32(poolId);
    }

    function _logSummary(
        Config memory config,
        Precomputed memory precomputed,
        DeploymentResult memory deployed,
        bytes32
    ) internal view {
        console2.log("\n========== Deployment Summary ==========");
        console2.log("MockUSDT        :", address(deployed.usdt));
        console2.log("MockPriceFeed   :", address(deployed.priceFeed));
        console2.log("PegKeeper       :", address(deployed.hook));
        console2.log("ReactiveMonitor :", address(deployed.monitor));
        console2.log("PoolManager     :", config.poolManagerAddr);
        console2.log("Pool token0     :", precomputed.token0);
        console2.log("Pool token1     :", precomputed.token1);
        console2.log("========================================");
    }
}
