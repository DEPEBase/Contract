const { ethers, network } = require("hardhat");

async function main() {
  console.log("🚀 Starting DEPE Smart Contracts Deployment...\n");

  // Get the deployer account
  const [deployer] = await ethers.getSigners();
  console.log("Deploying contracts with account:", deployer.address);
  console.log("Account balance:", ethers.utils.formatEther(await deployer.getBalance()), "ETH\n");

  // Use existing DEPE Token
  console.log("📝 Using existing DEPE Token...");
  const DEPE_TOKEN_ADDRESS = "0x37e0f2d2340968981ed82d47c0112b1619dc5b07";
  
  // Set platform wallet (using deployer for now)
  const platformWallet = deployer.address;
  
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
  console.log("   Min Pool USD:", ethers.utils.formatEther(await contestFactory.getMinPoolAmount()), "USD\n");

  // Verify contracts (if on testnet/mainnet)
  if (network.name !== "hardhat") {
    console.log("🔍 Verifying contracts...");
    
    // Skip DEPE Token verification since it's an existing external contract
    console.log("⏭️ Skipping DEPE Token verification (external contract)");

    try {
      await hre.run("verify:verify", {
        address: contestFactory.address,
        constructorArguments: [DEPE_TOKEN_ADDRESS, platformWallet],
      });
      console.log("✅ Contest Factory verified");
    } catch (error) {
      console.log("❌ Contest Factory verification failed:", error.message);
    }
  }

  // Save deployment info
  const deploymentInfo = {
    network: network.name,
    chainId: network.config.chainId,
    deployer: deployer.address,
    contracts: {
      DEPEToken: {
        address: DEPE_TOKEN_ADDRESS,
        platformWallet: platformWallet,
        note: "External existing contract",
      },
      ContestFactory: {
        address: contestFactory.address,
        depeToken: DEPE_TOKEN_ADDRESS,
        platformWallet: platformWallet,
        minPoolDEPE: "1000000", // 1M DEPE minimum
      },
    },
    timestamp: new Date().toISOString(),
  };

  console.log("\n📋 Deployment Summary:");
  console.log("====================");
  console.log("Network:", deploymentInfo.network);
  console.log("Chain ID:", deploymentInfo.chainId);
  console.log("Deployer:", deploymentInfo.deployer);
  console.log("\nContracts:");
  console.log("DEPE Token:", deploymentInfo.contracts.DEPEToken.address);
  console.log("Contest Factory:", deploymentInfo.contracts.ContestFactory.address);
  console.log("\n🎉 Deployment completed successfully!");

  // Instructions for next steps
  console.log("\n📝 Next Steps:");
  console.log("1. Update your .env file with the contract addresses");
  console.log("2. Test the contracts with sample contests");
  console.log("3. Integrate with your frontend application");
  console.log("4. Set up monitoring and alerts");

  return deploymentInfo;
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error("❌ Deployment failed:", error);
    process.exit(1);
  });
