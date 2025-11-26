# DEPE Smart Contracts

**Decentralized Meme Contest Platform on Base Network**

## Overview

The DEPE smart contract system implements a complete decentralized meme contest platform built on Base. The platform enables users to create contests, submit memes, vote with DEPE tokens, and stake on submissions with automatic reward distribution. The contracts are designed for security, gas efficiency, and fair reward distribution.

## Live Application

**Experience DEPE Contest Arena:**

- **Farcaster Mini App**: [https://farcaster.xyz/miniapps/3UkXwOASV_BU/depe](https://farcaster.xyz/miniapps/3UkXwOASV_BU/depe)
- **Base App**: Search "DEPE" in the Base app
- **Live on Base Mainnet**: Fully functional with real $DEPE token integration
- **Alpha Test Version**: Create, participate, and win in live meme contests

## Architecture

### Core Contracts

- **DEPE Token** - Existing ERC-20 token at `0x37e0f2d2340968981ed82d47c0112b1619dc5b07`
- **ContestFactory** - Factory contract for creating contests with platform validation
- **ContestInstance** - Individual contest contract with dual-phase system
- **ValidationLibrary** - Gas-optimized validation library for contract parameters

### Contract Relationships

```
DEPE Token (0x37e0f2d2340968981ed82d47c0112b1619dc5b07)
    ↓
ContestFactory (uses ValidationLibrary)
    ↓
ContestInstance (per contest)
```

### Deployed Contract Addresses

**Base Mainnet:**
- **DEPE Token**: `0x37e0f2d2340968981ed82d47c0112b1619dc5b07`
- **ContestFactory**: `0xd0A86cb10EaEbF19Eb2b93fC123eDe7457B96e90`


## Security Features

### Multi-Layer Security Implementation
- **ReentrancyGuard** - Comprehensive protection against reentrancy attacks
- **Pausable** - Emergency stop functionality for critical situations
- **Ownable** - Role-based access control with administrative functions
- **SafeMath** - Built-in overflow and underflow protection

### Access Control System
- **Owner** - Full administrative control over platform parameters
- **Platform Wallet** - Dedicated fee collection and platform operations
- **Contest Creator** - Controls individual contest lifecycle and parameters
- **Users** - Submit memes, vote, stake, and claim rewards

## Economic Model

### Reward Distribution Structure

**Meme Pool Distribution (90/10 Split)**
- 90% to winning meme submitter
- 10% platform fee for sustainability

**Staking Pool Distribution (20/80 Split)**
- 20% to contest creator as incentive
- 80% distributed pro-rata to winning stakers only

**Voting Pool Integration**
- 100% of voting funds contribute to staking pool
- Creates additional incentive for participation

### Fee Structure
- Contest creation: Minimum 10 and maximum 10000000 $DEPE
- Platform fee: 10% of meme pool
- Transfer fees: Configurable on DEPE token transfers

## Contest Lifecycle

### Phase 1: Submission Phase
- Users submit meme entries with platform signature verification
- Users can stake on submissions during this phase
- Duration: Independent submission duration (1 hour to 7 days)
- Submission phase ends early if sufficient entries

### Phase 2: Voting Phase  
- Users vote with $DEPE tokens (minimum 10 $DEPE)
- Maximum vote limit of 10,000,000 per vote
- Vote amounts contribute to staking pool
- Duration: Remaining time until contest deadline (minimum 1 hour)

### Phase 3: Resolution Phase
- Winner determined by vote points calculation: `(vote_count × 1e18) + (vote_amount × 0.0005)`
- Tie-breaker logic: Highest vote points → Most vote count → Earliest submission
- Automatic reward distribution to winners
- Stakers can claim proportional rewards
- Contest creator receives creator rewards

## Technical Specifications

### Contest Parameters
- **Minimum Pool**: 1,000,000 $DEPE (~$1 USD equivalent)
- **Minimum Entries**: User-configurable (1-1000 entries)
- **Duration**: 1 hour to 30 days total contest length
- **Submission Duration**: 1 hour to 7 days
- **Voting Duration**: Minimum 1 hour
- **Platform Fee**: 10% of total pool amount

### Staking Mechanics
- **No Minimum Stake**: Any amount can be staked
- **Lock Period**: Until contest resolution
- **Reward Calculation**: Pro-rata distribution to winning submission stakers only
- **Refund Mechanism**: Automatic refunds for single-stake contests
- **Maximum Stake**: 25% of total pool per user

### Gas Optimization
- **Solidity Version**: 0.8.26 with optimizer enabled
- **Optimization Runs**: 200 runs for maximum efficiency
- **Storage Layout**: Packed structs for gas efficiency
- **Library Usage**: ValidationLibrary reduces contract size by 2-3KB
- **Batch Operations**: Reduced transaction costs for multiple operations

## Deployment

### Option 1: Hardhat CLI Deployment

#### Prerequisites
```bash
npm install
```

#### Environment Configuration
Create `.env` file with required variables:
```env
PRIVATE_KEY=your_deployment_private_key
BASESCAN_API_KEY=your_basescan_api_key
```

#### Network Deployment

**Base Testnet Deployment:**
```bash
npx hardhat run scripts/deploy.js --network baseTestnet
```

**Base Mainnet Deployment:**
```bash
npx hardhat run scripts/deploy.js --network base
```

### Option 2: Remix IDE Deployment

#### Prerequisites
1. Visit [Remix IDE](https://remix.ethereum.org/)
2. Connect your wallet (MetaMask recommended)
3. Switch to Base network in your wallet

#### Deployment Steps

1. **Create New Workspace**
   - Click "Create New Workspace"
   - Choose "Blank" template
   - Name: "DEPE-Contracts"

2. **Upload Contract Files**
   - Create `contracts` folder
   - Upload `ContestFactory.sol`, `ContestInstance.sol`, and `ValidationLibrary.sol`
   - Ensure OpenZeppelin contracts are available (Remix will auto-install)

3. **Compile Contracts**
   - Go to "Solidity Compiler" tab
   - Select compiler version `0.8.26`
   - Click "Compile ContestFactory.sol"

4. **Deploy ContestFactory**
   - Go to "Deploy & Run Transactions" tab
   - Select "ContestFactory" contract
   - Set constructor parameters:
     - `_depeToken`: `0x37e0f2d2340968981ed82d47c0112b1619dc5b07`
     - `_platformWallet`: `your_platform_wallet_address`
     - `maxVoteAmount`: `10000000000000000000000000` (10M $DEPE)
     - `minVoteAmount`: `10000000000000000000` (10 $DEPE)
   - Click "Deploy"
   - Copy the deployed contract address

5. **Verify Contracts**
   - Use BaseScan to verify your deployed contracts
   - Contract source code will be available for public verification
   


## Testing and Verification

### Test Suite Execution
```bash
npm test
```

### Coverage Analysis
```bash
npm run coverage
```

### Contract Verification

#### Option 1: Hardhat CLI Verification
```bash
npx hardhat verify --network base <CONTRACT_ADDRESS> <CONSTRUCTOR_ARGS>
```

#### Option 2: Remix IDE Verification

1. **Visit Remix**
   - Go to [Remix](https://remix.ethereum.org/)
   - Uplaod your contract files in the files explorer `ContestFactory.sol`, `ContestInstance.sol`, and `ValidationLibrary.sol`

2. **Access Verification Contract Tab**
   - Click on the "Contract Verification icon" tab - bottom-left sidebar
   - Fill in the required details

3. **Select Verification Method**
   - Choose "Ethscan and Blockscout" and 
   - Make sure you have your Ethscan API
   - Ensure OpenZeppelin contracts are available

4. **Set Compiler Settings**
   - Compiler Version: `0.8.26`
   - Optimization: Enabled (200 runs)
   - EVM Version: Default

5. **Enter Constructor Arguments**
   - ContestFactory: `["0x37e0f2d2340968981ed82d47c0112b1619dc5b07", "your_platform_wallet_address", "10000000000000000000000000", "10000000000000000000"]`
   - ContestInstance: Constructor arguments from deployment

7. **Submit for Verification**
   - Click "Verify and Publish"
   - Wait for verification to complete

## Contract Interface

### ContestFactory Functions
- `createContest(uint256 totalPoolAmount, uint256 minEntriesRequired, uint256 submissionDuration, uint256 contestDuration, string calldata title, string calldata description)` - Create new contest
- `getContest(uint256 contestId)` - Retrieve contest information
- `getContestAddress(uint256 contestId)` - Get contest contract address
- `getUserContests(address user)` - Get user's created contests
- `getActiveContests(uint256 startId, uint256 endId)` - Get active contests in range
- `deactivateContest(uint256 contestId)` - Deactivate contest (creator only)
- `updateVoteAmout(uint256 maxVote, uint256 minVote)` - Update vote limits (owner only)
- `updateMinPoolDEPE(uint256 newMinPool)` - Update minimum pool requirement (owner only)

### ContestInstance Functions
- `addSubmission(string calldata memeUrl, string calldata memeType, uint256 fid, bytes calldata platformSignature)` - Submit meme entry with platform verification
- `vote(uint256 submissionFid, uint256 amount, uint256 fid, bytes calldata platformSignature)` - Vote for submission with $DEPE tokens and platform verification
- `stake(uint256 submissionFid, uint256 amount, uint256 fid, bytes calldata platformSignature)` - Stake on submission with platform verification
- `determineWinner()` - Determine contest winner based on vote points
- `finalizeContest()` - Finalize contest by determining winner and setting phase to ENDED (can be called by anyone after deadline)
- `claimMemeWinnerReward()` - Claim meme winner reward
- `claimCreatorReward()` - Claim creator reward (20% of staking pool)
- `claimStakerReward(uint256 fid)` - Claim staker reward for specific FID
- `failContestIfInsufficientEntries()` - Contest creator triggers refund for failed contests (no parameters)
- `claimRefund()` - Users claim refunds for failed contests (no parameters)
- `getContestState()` - Get current contest state and phase
- `getSubmission(uint256 submissionFid)` - Get submission details

## Gas Usage Estimates

- **ContestFactory Deployment**: ~3M gas
- **ContestInstance Deployment**: ~4M gas
- **Contest Creation**: ~800K gas
- **Meme Submission**: ~150K gas
- **Voting Transaction**: ~200K gas
- **Staking Transaction**: ~150K gas
- **Winner Determination**: ~300K gas
- **Reward Claims**: ~100K gas each

## Security Considerations

### Implemented Security Measures
- Reentrancy protection on all external functions
- Access control validation for administrative functions
- Input validation and bounds checking
- Overflow/underflow protection with SafeMath
- Emergency pause functionality for critical situations
- Accurate fee calculation and reward distribution
- State transition validation for contest phases
- **Platform signature verification for all user actions**
- **Signature replay protection to prevent double-spending**

### Known Limitations and Future Improvements
- **Price Oracle Integration**: Currently uses fixed price mechanism, Chainlink integration recommended
- **Gas Limit Considerations**: Large contests may approach block gas limits
- **Front-running Mitigation**: Vote timing can be optimized with commit-reveal schemes
- **Platform Signature System**: All user actions require platform signature verification for security

## Development Workflow

### Local Development Environment
```bash
npx hardhat node
npx hardhat run scripts/deploy.js --network localhost
```

### Testnet Testing Process
1. Acquire testnet Base ETH from [Base faucet](https://docs.base.org/base-chain/tools/network-faucets/)
2. Deploy contracts to Base testnet
3. Execute comprehensive functionality tests
4. Verify contracts on Basescan explorer

## Integration Guide

### Frontend Integration
The contracts are designed for seamless frontend integration with standard Web3 libraries. Key integration points include:

- Contest creation and management
- Meme submission with metadata storage
- Voting and staking functionality
- Reward claiming mechanisms
- Real-time contest state monitoring

### API Integration
Backend systems can monitor contract events for:
- Contest state changes
- Submission additions
- Vote and stake transactions
- Reward distributions
- User activity tracking

## License

This project is licensed under the MIT License. See the LICENSE file for complete details.

## Contributing

We welcome contributions to improve the DEPE platform. Please get in touch.

## Support and Community

For technical support, feature requests, or community discussions:
- Create issues on our GitHub repository
- Join our [Telgram community](https://t.me/DegenDEPE)
- Contact: @dracklyn on Farcaster, BaseApp, Telegram, and X

---

**Built by the DEPE Team**

*Make every meme liquid.*