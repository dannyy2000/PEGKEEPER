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
        uint256 deployerKey     = vm.envUint("PRIVATE_KEY");
        address poolManagerAddr = vm.envAddress("POOL_MANAGER_ADDRESS");
        address usdcAddr        = vm.envAddress("USDC_ADDRESS");

        address deployer = vm.addr(deployerKey);

        // ── Pre-compute addresses BEFORE broadcast ────────────────────────────
        //
        // Nonce progression during broadcast:
        //   nonce+0  → MockUSDT        (regular CREATE)
        //   nonce+1  → MockPriceFeed   (regular CREATE)
        //   nonce+2  → PegKeeper       (CREATE2, still increments nonce)
        //   nonce+3  → ReactiveMonitor (regular CREATE)
        //
        uint64 startNonce = vm.getNonce(deployer);

        address precomputedMonitor = vm.computeCreateAddress(deployer, startNonce + 3);
        console2.log("Pre-computed ReactiveMonitor:", precomputedMonitor);

        // Pre-compute MockUSDT address so we can sort the pair before mining
        address precomputedUSDT = vm.computeCreateAddress(deployer, startNonce);

        // Sort tokens — PoolManager requires currency0 < currency1
        (address token0, address token1) = usdcAddr < precomputedUSDT
            ? (usdcAddr, precomputedUSDT)
            : (precomputedUSDT, usdcAddr);

        console2.log("token0:", token0);
        console2.log("token1:", token1);

        // Mine CREATE2 salt for PegKeeper
        bytes memory initCode = abi.encodePacked(
            type(PegKeeper).creationCode,
            abi.encode(poolManagerAddr, precomputedMonitor)
        );

        (address expectedHookAddr, bytes32 salt) = HookMiner.find(
            CREATE2_DEPLOYER,
            HOOK_FLAGS,
            HOOK_FLAG_MASK,
            initCode
        );
        console2.log("Mined PegKeeper address:", expectedHookAddr);
        console2.log("Salt (uint256)          :", uint256(salt));

        // ── Broadcast ────────────────────────────────────────────────────────
        vm.startBroadcast(deployerKey);

        // 1. MockUSDT  (nonce+0 → lands at precomputedUSDT)
        // Initial supply minted in constructor — no separate tx, keeps nonce count exact.
        MockERC20 usdt = new MockERC20("Mock USDT", "USDT", 6, MINT_AMOUNT);
        require(address(usdt) == precomputedUSDT, "Deploy: USDT address mismatch");
        console2.log("MockUSDT deployed       :", address(usdt));

        // 2. MockPriceFeed  (nonce+1)
        MockPriceFeed priceFeed = new MockPriceFeed();
        console2.log("MockPriceFeed deployed  :", address(priceFeed));

        // 3. PegKeeper via CREATE2  (nonce+2)
        // Using Solidity's new{salt:} syntax so the EOA is the direct CREATE2 deployer,
        // matching the address mined by HookMiner.find(deployer, ...).
        PegKeeper hook = new PegKeeper{salt: salt}(
            IPoolManager(poolManagerAddr),
            precomputedMonitor
        );
        require(address(hook) == expectedHookAddr, "Deploy: hook address mismatch");
        console2.log("PegKeeper deployed      :", address(hook));

        // 4. ReactiveMonitor  (nonce+3 → lands at precomputedMonitor)
        ReactiveMonitor monitor = new ReactiveMonitor(
            address(hook),
            address(priceFeed)
        );
        require(address(monitor) == precomputedMonitor, "Deploy: monitor address mismatch");
        console2.log("ReactiveMonitor deployed:", address(monitor));

        // 5. Initialise USDC/USDT pool
        PoolKey memory key = PoolKey({
            currency0:   Currency.wrap(token0),
            currency1:   Currency.wrap(token1),
            fee:         LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 1,
            hooks:       IHooks(address(hook))
        });

        IPoolManager(poolManagerAddr).initialize(key, SQRT_PRICE_1_1);
        console2.log("Pool initialised. PoolId:");
        console2.logBytes32(PoolId.unwrap(key.toId()));

        vm.stopBroadcast();

        // ── Summary ───────────────────────────────────────────────────────────
        console2.log("\n========== Deployment Summary ==========");
        console2.log("MockUSDT        :", address(usdt));
        console2.log("MockPriceFeed   :", address(priceFeed));
        console2.log("PegKeeper       :", address(hook));
        console2.log("ReactiveMonitor :", address(monitor));
        console2.log("PoolManager     :", poolManagerAddr);
        console2.log("Pool token0     :", token0);
        console2.log("Pool token1     :", token1);
        console2.log("========================================");
    }
}
