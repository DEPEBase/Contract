const { ethers, network } = require("hardhat");

async function main() {
  console.log("🚀 Starting DEPE Smart Contracts Deployment to Base Mainnet...\n");

  // Check if we have a private key
  if (!process.env.PRIVATE_KEY) {
    console.log("❌ No private key found in environment variables");
    console.log("📝 Please create a .env file with your private key:");
    console.log("   PRIVATE_KEY=0x1234567890abcdef...");
    console.log("   PLATFORM_WALLET=0x1234567890abcdef...");
    console.log("   BASESCAN_API_KEY=your_api_key_here");
    console.log("\n💡 You can get your private key from MetaMask:");
    console.log("   1. Open MetaMask");
    console.log("   2. Click account menu (three dots)");
    console.log("   3. Account Details > Export Private Key");
    console.log("   4. Copy the private key (starts with 0x)");
    console.log("\n⚠️  Keep your private key secure and never share it!");
    return;
  }

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
  console.log("🏭 Deploying Contest Factory to Base Mainnet...");
  const ContestFactory = await ethers.getContractFactory("ContestFactory");
  
  const contestFactory = await ContestFactory.deploy(DEPE_TOKEN_ADDRESS, platformWallet);
  await contestFactory.deployed();
  
  console.log("✅ Contest Factory deployed to:", contestFactory.address);
  console.log("   DEPE Token:", DEPE_TOKEN_ADDRESS);
  console.log("   Platform Wallet:", platformWallet);
  console.log("   Min Pool DEPE:", await contestFactory.getMinPoolAmount(), "DEPE\n");

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
  console.log("1. Update your frontend with the new contract address:", contestFactory.address);
  console.log("2. Update your backend .env with the new contract address");
  console.log("3. Test the contracts with sample contests");
  console.log("4. Verify the contract on BaseScan (optional)");

  return deploymentInfo;
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error("❌ Deployment failed:", error);
    process.exit(1);
  });
