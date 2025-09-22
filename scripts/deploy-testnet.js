const { ethers } = require("hardhat");

async function main() {
  console.log("🚀 Starting DEPE Smart Contracts Deployment to Base Testnet...\n");

  try {
    // Check if we have a private key
    if (!process.env.PRIVATE_KEY) {
      console.log("❌ PRIVATE_KEY not found in environment variables");
      console.log("   Please add your private key to the .env file");
      console.log("   Example: PRIVATE_KEY=0x1234567890abcdef...");
      process.exit(1);
    }

    // Get the deployer account
    const [deployer] = await ethers.getSigners();
    console.log("Deploying contracts with account:", deployer.address);
    
    // Check balance
    const balance = await deployer.getBalance();
    console.log("Account balance:", ethers.utils.formatEther(balance), "ETH");
    
    if (balance.lt(ethers.utils.parseEther("0.01"))) {
      console.log("⚠️  Warning: Low ETH balance. You may need more ETH for gas fees.");
    }

    // Use existing DEPE Token
    const DEPE_TOKEN_ADDRESS = "0x37e0f2d2340968981ed82d47c0112b1619dc5b07";
    const platformWallet = process.env.PLATFORM_WALLET || deployer.address;
    
    console.log("✅ Using existing DEPE Token at:", DEPE_TOKEN_ADDRESS);
    console.log("   Platform Wallet:", platformWallet);
    console.log("   Note: Using existing DEPE token contract\n");

    // Deploy Contest Factory
    console.log("🏭 Deploying Contest Factory...");
    const ContestFactory = await ethers.getContractFactory("ContestFactory");
    
    const contestFactory = await ContestFactory.deploy(DEPE_TOKEN_ADDRESS, platformWallet);
    await contestFactory.deployed();
    
    console.log("✅ Contest Factory deployed to:", contestFactory.address);
    console.log("   DEPE Token:", DEPE_TOKEN_ADDRESS);
    console.log("   Platform Wallet:", platformWallet);

    // Test basic functionality
    console.log("\n🧪 Testing basic functionality...");
    
    try {
      const factoryInfo = await contestFactory.getFactoryInfo();
      console.log("✅ Factory info retrieved successfully");
      console.log("   Total contests:", factoryInfo[0].toString());
      console.log("   Min pool USD:", ethers.utils.formatEther(factoryInfo[1]), "USD");
    } catch (error) {
      console.log("❌ Error testing factory:", error.message);
    }

    console.log("\n🎉 Deployment completed successfully!");
    console.log("\n📋 Deployment Summary:");
    console.log("   Contest Factory:", contestFactory.address);
    console.log("   DEPE Token:", DEPE_TOKEN_ADDRESS);
    console.log("   Platform Wallet:", platformWallet);
    console.log("   Network: Base Testnet");
    
    console.log("\n🔗 View on BaseScan:");
    console.log("   https://sepolia.basescan.org/address/" + contestFactory.address);
    
  } catch (error) {
    console.log("❌ Deployment failed:", error.message);
    if (error.message.includes("insufficient funds")) {
      console.log("   💡 You need more ETH for gas fees");
    } else if (error.message.includes("nonce")) {
      console.log("   💡 Try again in a few seconds");
    }
    process.exit(1);
  }
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
