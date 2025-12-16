// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/AuctionSaveFactory.sol";
import "../src/AuctionSaveGroup.sol";
import "../src/MockUSDT.sol";

/// @title DeployAuctionSave - Deployment script for AuctionSave protocol
/// @notice Deploys AuctionSaveFactory and optionally creates a demo pool
contract DeployAuctionSave is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address developer = vm.envAddress("DEVELOPER_ADDRESS");

        vm.startBroadcast(deployerPrivateKey);

        // Deploy Factory
        AuctionSaveFactory factory = new AuctionSaveFactory(developer);
        console.log("AuctionSaveFactory deployed at:", address(factory));

        vm.stopBroadcast();
    }

    /// @notice Deploy factory and create a demo group (per boss's design)
    function runWithDemoGroup() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address developer = vm.envAddress("DEVELOPER_ADDRESS");
        address token = vm.envAddress("TOKEN_ADDRESS");

        vm.startBroadcast(deployerPrivateKey);

        // Deploy Factory
        AuctionSaveFactory factory = new AuctionSaveFactory(developer);
        console.log("AuctionSaveFactory deployed at:", address(factory));

        // Create demo group (per boss's design)
        address group = factory.createGroup(
            token,
            block.timestamp,
            7 days,
            false // demoMode
        );
        console.log("Demo AuctionSavePool deployed at:", group);

        vm.stopBroadcast();
    }

    /// @notice Deploy for demo mode (per boss's design with speedUpCycle)
    function runDemoMode() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address developer = vm.envAddress("DEVELOPER_ADDRESS");
        address token = vm.envAddress("TOKEN_ADDRESS");

        vm.startBroadcast(deployerPrivateKey);

        // Deploy Factory
        AuctionSaveFactory factory = new AuctionSaveFactory(developer);
        console.log("AuctionSaveFactory deployed at:", address(factory));

        // Create demo group with demoMode=true (per boss's design)
        address group = factory.createGroup(
            token,
            block.timestamp,
            10 minutes, // short for demo
            true // demoMode - enables speedUpCycle()
        );
        console.log("Demo AuctionSavePool (fast mode) deployed at:", group);

        vm.stopBroadcast();
    }

    /// @notice Deploy everything: MockUSDT + Factory + Demo Group (RECOMMENDED for testnet)
    function runFullDemo() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address developer = vm.envAddress("DEVELOPER_ADDRESS");

        vm.startBroadcast(deployerPrivateKey);

        // 1. Deploy MockUSDT with faucet
        MockUSDT mockToken = new MockUSDT();
        console.log("MockUSDT deployed at:", address(mockToken));
        console.log("  - Faucet: call faucet() to get 10,000 mUSDT");
        console.log("  - Cooldown: 1 hour between faucet calls");

        // 2. Deploy Factory
        AuctionSaveFactory factory = new AuctionSaveFactory(developer);
        console.log("AuctionSaveFactory deployed at:", address(factory));

        // 3. Create demo group (per boss's design)
        address group = factory.createGroup(
            address(mockToken),
            block.timestamp,
            10 minutes, // short for demo
            true // demoMode - enables speedUpCycle()
        );
        console.log("Demo AuctionSavePool deployed at:", group);

        console.log("");
        console.log("=== DEPLOYMENT SUMMARY ===");
        console.log("MockUSDT:           ", address(mockToken));
        console.log("AuctionSaveFactory: ", address(factory));
        console.log("Demo Pool:          ", group);
        console.log("");
        console.log("Next steps:");
        console.log("1. Call mockToken.faucet() to get test tokens");
        console.log("2. Approve pool to spend your tokens (100 ether per join)");
        console.log("3. Join the pool with 5 accounts");

        vm.stopBroadcast();
    }

    /// @notice Deploy only MockUSDT token
    function runDeployToken() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(deployerPrivateKey);

        MockUSDT mockToken = new MockUSDT();
        console.log("MockUSDT deployed at:", address(mockToken));

        vm.stopBroadcast();
    }
}
