# 🚀 DEPE Smart Contracts Deployment Guide

## 📋 Prerequisites

### 1. Install Dependencies
```bash
cd contracts
npm install
```

### 2. Environment Setup
Create `.env` file in the contracts directory:
```env
# Private key for deployment (keep secure!)
PRIVATE_KEY=0x1234567890abcdef...

# BaseScan API key for contract verification
BASESCAN_API_KEY=your_basescan_api_key_here

# Optional: Gas reporting
REPORT_GAS=true
```

### 3. Get Testnet ETH
- **Base Testnet**: https://bridge.base.org/deposit
- **Base Sepolia Faucet**: https://www.coinbase.com/faucets/base-ethereum-sepolia-faucet

## 🧪 Testing Phase

### 1. Run Tests
```bash
npm test
```

### 2. Check Gas Usage
```bash
npm run size
```

### 3. Test Coverage
```bash
npm run coverage
```

## 🌐 Testnet Deployment

### 1. Deploy to Base Testnet
```bash
npx hardhat run scripts/deploy.js --network baseTestnet
```

### 2. Verify Contracts
```bash
npx hardhat verify --network baseTestnet <CONTRACT_ADDRESS> <CONSTRUCTOR_ARGS>
```

### 3. Test Functionality
- Create test contests
- Submit memes
- Vote and stake
- Verify reward distribution

## 🏭 Mainnet Deployment

### 1. Final Checks
- [ ] All tests passing
- [ ] Gas optimization verified
- [ ] Security review completed
- [ ] Testnet testing successful

### 2. Deploy to Base Mainnet
```bash
npx hardhat run scripts/deploy.js --network base
```

### 3. Verify Contracts
```bash
npx hardhat verify --network base <CONTRACT_ADDRESS> <CONSTRUCTOR_ARGS>
```

## 📊 Deployment Output

After successful deployment, you'll get:
```
🚀 Starting DEPE Smart Contracts Deployment...

Deploying contracts with account: 0x1234...
Account balance: 0.5 ETH

📝 Deploying DEPE Token...
✅ DEPE Token deployed to: 0xabcd...
   Platform Wallet: 0x1234...
   Treasury Wallet: 0x1234...
   Initial Supply: 1000000000.0 DEPE

🏭 Deploying Contest Factory...
✅ Contest Factory deployed to: 0xefgh...
   DEPE Token: 0xabcd...
   Platform Wallet: 0x1234...
   Min Pool USD: 50.0 USD

📋 Deployment Summary:
====================
Network: base
Chain ID: 8453
Deployer: 0x1234...

Contracts:
DEPE Token: 0xabcd...
Contest Factory: 0xefgh...

🎉 Deployment completed successfully!
```

## 🔧 Post-Deployment Setup

### 1. Update Environment Variables
Update your backend `.env` file:
```env
# Smart Contract Addresses
DEPE_TOKEN_ADDRESS=0xabcd...
CONTEST_FACTORY_ADDRESS=0xefgh...

# Network Configuration
BASE_RPC_URL=https://mainnet.base.org
BASE_CHAIN_ID=8453
```

### 2. Frontend Integration
Update your frontend configuration:
```javascript
const CONTRACT_ADDRESSES = {
  DEPE_TOKEN: "0xabcd...",
  CONTEST_FACTORY: "0xefgh...",
  NETWORK: "base"
};
```

### 3. Monitor Contracts
- Set up monitoring on Basescan
- Configure alerts for critical functions
- Monitor gas usage and transaction success rates

## 🛡️ Security Checklist

### Pre-Deployment
- [ ] Code review completed
- [ ] Tests passing (100% coverage)
- [ ] Gas optimization verified
- [ ] Security audit completed
- [ ] Testnet testing successful

### Post-Deployment
- [ ] Contracts verified on Basescan
- [ ] Monitoring configured
- [ ] Emergency procedures documented
- [ ] Team access controls set up

## 🚨 Emergency Procedures

### Pause Contracts
```bash
# Pause DEPE Token
npx hardhat run scripts/pause.js --network base

# Pause Contest Factory
npx hardhat run scripts/pause-factory.js --network base
```

### Emergency Withdraw
```bash
# Withdraw funds from contracts
npx hardhat run scripts/emergency-withdraw.js --network base
```

## 📈 Monitoring

### Key Metrics to Monitor
- **Transaction Success Rate**: >99%
- **Gas Usage**: Within expected ranges
- **Contract Interactions**: Normal patterns
- **Error Rates**: <1%

### Alerts to Set Up
- Contract pause events
- Large token transfers
- Failed transactions
- Unusual gas usage

## 🔄 Upgrade Path

### Current Architecture
- **DEPE Token**: Upgradeable (if needed)
- **Contest Factory**: Upgradeable (if needed)
- **Contest Instances**: Immutable (per contest)

### Future Upgrades
- Implement proxy patterns for major upgrades
- Add new features via new contract versions
- Migrate existing contests if needed

## 📞 Support

### Deployment Issues
- Check network connectivity
- Verify private key and balance
- Review gas limits
- Check contract verification

### Post-Deployment Issues
- Monitor contract events
- Check transaction logs
- Verify contract state
- Contact support team

---

**Ready to deploy? Let's make meme contests secure and fun!** 🐸🎩
