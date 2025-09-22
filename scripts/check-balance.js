const { ethers } = require("hardhat");

async function main() {
  console.log("🔍 Checking wallet balance on Base Testnet...\n");

  try {
    // Get the deployer account
    const [deployer] = await ethers.getSigners();
    console.log("Wallet address:", deployer.address);
    
    // Check balance
    const balance = await deployer.getBalance();
    console.log("Balance:", ethers.utils.formatEther(balance), "ETH");
    
    if (balance.eq(0)) {
      console.log("\n❌ No ETH found!");
      console.log("💡 You need to get Base Sepolia testnet ETH from:");
      console.log("   https://www.coinbase.com/faucets/base-ethereum-sepolia-faucet");
      console.log("   or");
      console.log("   https://bridge.base.org/deposit");
      console.log("\n📝 Make sure you're requesting ETH for:", deployer.address);
    } else {
      console.log("\n✅ You have ETH! Ready to deploy.");
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
