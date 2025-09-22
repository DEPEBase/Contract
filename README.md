# 🐸🎩 DEPE Smart Contracts

**Secure, Battle-Tested Smart Contracts for the DEPE Meme Contest Platform**

## 📋 Overview

This repository contains the smart contracts for the DEPE meme contest platform, built on the Base network. The contracts implement a complete meme contest system with voting, staking, and automatic reward distribution.

## 🏗️ Architecture

### Core Contracts

1. **Existing DEPE Token** - Using DEPE token at `0x37e0f2d2340968981ed82d47c0112b1619dc5b07`
2. **ContestFactory.sol** - Factory contract for creating new contests
3. **ContestInstance.sol** - Individual contest contract with full functionality

### Contract Relationships

```
Existing DEPE Token (0x37e0f2d2340968981ed82d47c0112b1619dc5b07)
    ↓
ContestFactory
    ↓
ContestInstance (per contest)
```

## 🔒 Security Features

### Multi-Layer Security
- **ReentrancyGuard** - Prevents reentrancy attacks
- **Pausable** - Emergency stop functionality
- **Ownable** - Access control and admin functions
- **SafeMath** - Overflow/underflow protection

### Access Controls
- **Owner** - Full administrative control
- **Platform Wallet** - Fee collection and platform operations
- **Contest Creator** - Controls contest lifecycle
- **Users** - Submit memes, vote, and stake

## 💰 Reward Distribution

### Meme Pool (90% to winner, 10% to platform)
- **90%** - Goes to the winning meme submitter
- **10%** - Platform fee

### Staking Pool (20% to creator, 80% to stakers)
- **20%** - Goes to contest creator
- **80%** - Distributed pro-rata to winning stakers only

### Voting Pool
- **100%** - Goes to staking pool (voting funds staking pool)

## 🎯 Contest Lifecycle

### Phase 1: Submission (60% of duration)
- Users submit memes
- Users can stake on submissions
- Creator can end phase early

### Phase 2: Voting (40% of duration)
- Users vote with DEPE tokens
- Minimum $1 USD per vote (in DEPE tokens)
- Maximum $10 USD per vote
- Creator can end phase early

### Phase 3: Ended
- Winner determined by highest vote count
- Rewards automatically distributed
- Stakers can claim winnings

## 📊 Key Parameters

### Contest Requirements
- **Minimum Pool**: $50 USD in DEPE
- **Minimum Entries**: User-settable (1-1000)
- **Duration**: 1-7 days
- **Platform Fee**: 10% of meme pool

### Voting Requirements
- **Minimum Vote**: $1 USD worth of DEPE
- **Maximum Vote**: $10 USD worth of DEPE
- **Vote Lock**: During voting phase only

### Staking
- **No Minimum**: Any amount can be staked
- **Lock Period**: Until contest ends
- **Rewards**: Pro-rata to winning submission stakers only

## 🚀 Deployment

### Prerequisites
```bash
npm install
```

### Environment Setup
Create `.env` file:
```env
PRIVATE_KEY=your_private_key_here
BASESCAN_API_KEY=your_basescan_api_key_here
```

### Deploy to Base Testnet
```bash
npx hardhat run scripts/deploy.js --network baseTestnet
```

### Deploy to Base Mainnet
```bash
npx hardhat run scripts/deploy.js --network base
```

## 🧪 Testing

### Run Tests
```bash
npm test
```

### Test Coverage
```bash
npm run coverage
```

### Gas Usage
```bash
npm run size
```

## 📝 Contract Functions

### DEPEToken
- `transfer()` - Transfer tokens with fee logic
- `mint()` - Mint new tokens (owner only)
- `pause()` / `unpause()` - Emergency controls
- `updateTransferFee()` - Update transfer fee

### ContestFactory
- `createContest()` - Create new contest
- `getContest()` - Get contest address by ID
- `getUserContests()` - Get user's contests
- `updateDEPEPrice()` - Update DEPE price for USD conversion

### ContestInstance
- `addSubmission()` - Submit meme
- `vote()` - Vote for submission
- `stake()` - Stake on submission
- `endSubmissionPhase()` - End submission phase
- `endVotingPhase()` - End voting phase
- `distributeRewards()` - Distribute rewards

## 🔍 Verification

### Verify Contracts
```bash
npx hardhat verify --network base <CONTRACT_ADDRESS> <CONSTRUCTOR_ARGS>
```

## 📈 Gas Optimization

### Optimizations Implemented
- **Solidity 0.8.19** - Latest stable version
- **Optimizer Enabled** - 200 runs for gas efficiency
- **Packed Structs** - Efficient storage layout
- **Batch Operations** - Reduce transaction costs

### Gas Usage Estimates
- **DEPEToken Deployment**: ~2.5M gas
- **ContestFactory Deployment**: ~3M gas
- **Contest Creation**: ~800K gas
- **Meme Submission**: ~150K gas
- **Voting**: ~200K gas
- **Staking**: ~150K gas

## 🛡️ Security Considerations

### Auditing Checklist
- [ ] Reentrancy protection
- [ ] Access control validation
- [ ] Input validation
- [ ] Overflow/underflow protection
- [ ] Emergency pause functionality
- [ ] Fee calculation accuracy
- [ ] Reward distribution logic
- [ ] State transition validation

### Known Limitations
- **Price Oracle**: Currently uses fixed price, should integrate Chainlink
- **Gas Limits**: Large contests may hit block gas limits
- **Front-running**: Vote timing can be front-run

## 🔧 Development

### Local Development
```bash
npx hardhat node
npx hardhat run scripts/deploy.js --network localhost
```

### Testing on Testnet
1. Get testnet ETH from Base faucet
2. Deploy contracts to Base testnet
3. Test all functionality
4. Verify contracts on Basescan

## 📞 Support

For questions or issues:
- **GitHub Issues**: Create an issue
- **Discord**: Join our community
- **Email**: support@depe.com

## 📄 License

MIT License - see LICENSE file for details.

---

**Built with ❤️ by the DEPE Team**

*Making meme contests secure, fair, and fun!* 🐸🎩
