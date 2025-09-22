const { ethers } = require("hardhat");

async function main() {
  console.log("🔍 Checking wallet balance on Base Mainnet...\n");

  try {
    // Get the deployer account
    const [deployer] = await ethers.getSigners();
    console.log("Wallet address:", deployer.address);
    
    // Check balance
    const balance = await deployer.getBalance();
    console.log("Balance:", ethers.utils.formatEther(balance), "ETH");
    
    if (balance.eq(0)) {
      console.log("\n❌ No ETH found on Base Mainnet either!");
      console.log("💡 You need to get ETH from:");
      console.log("   - Bridge from Ethereum: https://bridge.base.org/deposit");
      console.log("   - Buy ETH on an exchange and withdraw to Base");
      console.log("\n📝 Make sure you're requesting ETH for:", deployer.address);
    } else {
      console.log("\n✅ You have ETH on Base Mainnet! Ready to deploy.");
      console.log("⚠️  Note: This will deploy to MAINNET (real money!)");
    }
    
  } catch (error) {
    console.log("❌ Error checking balance:", error.message);
  }
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
