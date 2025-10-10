// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./ContestInstance.sol";

/**
 * @title ContestFactory
 * @dev Factory contract with platform validation and DEPE token integration
 * @notice Updated factory with platform wallet parameter while preserving all existing functionality
 * @author DEPE Team
 */
contract ContestFactory is ReentrancyGuard, Ownable, Pausable {
    using SafeERC20 for IERC20;

    // ===== CONSTANTS =====
    uint256 private constant MAX_CONTEST_DURATION = 30 days;
    uint256 private constant MIN_CONTEST_DURATION = 1 minutes;
    uint256 private constant MAX_STRING_LENGTH = 500;
    uint256 private constant MAX_TITLE_LENGTH = 100;
    uint256 private constant PLATFORM_FEE_BPS = 1000; // 10% platform fee
    uint256 private constant BASIS_POINTS = 10000;

    // ===== STRUCTS =====
    struct ContestInfo {
        address contestAddress;
        address creator;
        uint256 memePoolAmount;
        uint256 createdAt;
        string title;
        bool active;
    }

    struct FactoryConfig {
        address depeToken;
        address platformWallet;
        uint256 minPoolDEPE;
        uint256 maxVoteAmount;
        uint256 minVoteAmount;
        uint256 totalContests;
        uint256 totalFeesCollected;
    }

    // ===== STATE VARIABLES =====
    FactoryConfig public config;
    
    // Contest tracking - optimized storage
    mapping(uint256 => ContestInfo) private _contests;
    mapping(address => uint256[]) private _userContests;
    mapping(address => uint256) private _userContestCount;
    
    // Rate limiting
    mapping(address => uint256) private _lastContestTime;
    mapping(address => uint256) private _dailyContestCount;
    mapping(address => uint256) private _dailyResetTime;
    
    // Contest validation
    uint256 public minPoolDEPE = 1_000_000 * 1e18; // 1M DEPE minimum

    // ===== EVENTS =====
    event ContestCreated(
        uint256 indexed contestId,
        address indexed contestAddress,
        address indexed creator,
        uint256 totalPoolAmount,
        uint256 netPoolAmount,
        uint256 platformFee,
        uint256 minEntriesRequired,
        uint256 duration,
        string title
    );
    
    event DEPEVoteAmoutUpdated(uint256 min, uint256 newPrice);
    event MinPoolUpdated(uint256 oldMin, uint256 newMin);
    event ContestDeactivated(uint256 indexed contestId, address indexed creator);
    event PlatformWalletUpdated(address indexed oldWallet, address indexed newWallet);
    event PlatformFeeCollected(uint256 indexed contestId, uint256 amount, address indexed creator);
    event durationLog(uint256 duration, uint256 minDuration,  uint256 maxDuration);

    // ===== ERRORS =====
    error InvalidAddress();
    error InvalidAmount();
    error InvalidDuration();
    error InvalidString();
    error InvalidMinEntries();
    error PoolBelowMinimum();
    error RateLimitExceeded();
    error CooldownNotMet();
    error ContestNotExists();
    error SaltAlreadyUsed();
    error TransferFailed();
    error UnauthorizedDeactivation();

    // ===== MODIFIERS =====
    modifier validContestId(uint256 contestId) {
        if (contestId >= config.totalContests) revert ContestNotExists();
        _;
    }

    // ===== CONSTRUCTOR =====
    constructor(
        address _depeToken,
        address _platformWallet,
        uint256 maxVoteAmount,
        uint256 minVoteAmount
    ) Ownable(msg.sender) {
        if (_depeToken == address(0) || _platformWallet == address(0)) revert InvalidAddress();
        
        config = FactoryConfig({
            depeToken: _depeToken,
            platformWallet: _platformWallet,
            minPoolDEPE: minPoolDEPE,
            maxVoteAmount: maxVoteAmount,
            minVoteAmount: minVoteAmount,
            totalContests: 0,
            totalFeesCollected: 0
        });
    }

    // ===== CONTEST CREATION =====
    
    /**
     * @dev Create a new contest with deterministic address
     * @param totalPoolAmount Total amount of DEPE (platform fee will be deducted)
     * @param minEntriesRequired Minimum entries required for contest to be valid
     * @param duration Contest duration in seconds
     * @param title Contest title
     * @param description Contest description
     * @return contestAddress Address of the created contest
     */
    function createContest(
        uint256 totalPoolAmount,
        uint256 minEntriesRequired,
        uint256 duration,
        string calldata title,
        string calldata description
    ) 
        external 
        nonReentrant 
        whenNotPaused
        returns (address contestAddress) 
    {
        // Comprehensive parameter validation
        _validateContestParameters(totalPoolAmount, duration, title, description);
        
        // Process fees and transfers
        uint256 netPoolAmount = _processFees(totalPoolAmount);
        
        // Deploy contest
        contestAddress = _deployContest(
            netPoolAmount,
            minEntriesRequired,
            duration,
            title,
            description
        );
        
        // Store contest and emit events
        _finalizeContestCreation(
            contestAddress,
            totalPoolAmount,
            netPoolAmount,
            minEntriesRequired,
            duration,
            title
        );
        
        return contestAddress;
    }

    // ===== CONTEST MANAGEMENT =====
    
    /**
     * @dev Deactivate a contest (creator only)
     * @param contestId Contest ID to deactivate
     */
    function deactivateContest(uint256 contestId) 
        external 
        validContestId(contestId) 
        nonReentrant 
    {
        ContestInfo storage contestInfo = _contests[contestId];
        
        if (contestInfo.creator != msg.sender) revert UnauthorizedDeactivation();
        if (!contestInfo.active) return; // Already deactivated
        
        contestInfo.active = false;
        emit ContestDeactivated(contestId, msg.sender);
    }

    // ===== VIEW FUNCTIONS =====
    
    /**
     * @dev Get contest information by ID
     * @param contestId Contest ID
     * @return contestInfo Contest information struct
     */
    function getContest(uint256 contestId) 
        external 
        view 
        validContestId(contestId) 
        returns (ContestInfo memory contestInfo) 
    {
        return _contests[contestId];
    }

    /**
     * @dev Get contest address by ID
     * @param contestId Contest ID
     * @return contestAddress Contest contract address
     */
    function getContestAddress(uint256 contestId) 
        external 
        view 
        validContestId(contestId) 
        returns (address contestAddress) 
    {
        return _contests[contestId].contestAddress;
    }

    /**
     * @dev Get user's contest IDs
     * @param user User address
     * @return contestIds Array of contest IDs created by user
     */
    function getUserContests(address user) external view returns (uint256[] memory contestIds) {
        return _userContests[user];
    }

    /**
     * @dev Get user's contest count
     * @param user User address
     * @return count Number of contests created by user
     */
    function getUserContestCount(address user) external view returns (uint256 count) {
        return _userContestCount[user];
    }

    /**
     * @dev Get active contests in a range
     * @param startId Starting contest ID
     * @param endId Ending contest ID (exclusive)
     * @return activeContests Array of active contest information
     */
    function getActiveContests(uint256 startId, uint256 endId) 
        external 
        view 
        returns (ContestInfo[] memory activeContests) 
    {
        if (endId > config.totalContests) {
            endId = config.totalContests;
        }
        
        // Count active contests first
        uint256 activeCount = 0;
        for (uint256 i = startId; i < endId; ) {
            if (_contests[i].active) {
                unchecked { ++activeCount; }
            }
            unchecked { ++i; }
        }
        
        // Populate array
        activeContests = new ContestInfo[](activeCount);
        uint256 index = 0;
        
        for (uint256 i = startId; i < endId && index < activeCount; ) {
            if (_contests[i].active) {
                activeContests[index] = _contests[i];
                unchecked { ++index; }
            }
            unchecked { ++i; }
        }
        
        return activeContests;
    }

    /**
     * @dev Get factory configuration
     * @return factoryConfig Current factory configuration
     */
    function getFactoryConfig() external view returns (FactoryConfig memory factoryConfig) {
        return config;
    }

    // ===== ADMIN FUNCTIONS =====
    
    /**
     * @dev Update platform wallet (only owner)
     * @param newPlatformWallet New platform wallet address
     */
    function updatePlatformWallet(address newPlatformWallet) external onlyOwner {
        if (newPlatformWallet == address(0)) revert InvalidAddress();
        address oldWallet = config.platformWallet;
        config.platformWallet = newPlatformWallet;
        emit PlatformWalletUpdated(oldWallet, newPlatformWallet);
    }

    /**
     * @dev Update DEPE vote amount (only owner)
     * @param _maxVote & _minVote DEPE amount in (18 decimals)
     */
    function updateDEPEPrice(uint256 _maxVote, uint256 _minVote) external onlyOwner {
        if (_maxVote == 0) revert InvalidAmount();
        if (_minVote == 0) revert InvalidAmount();
        if (_maxVote < _minVote) revert InvalidAmount();
        
        config.maxVoteAmount = _maxVote;
        config.minVoteAmount = _minVote;
        emit DEPEVoteAmoutUpdated(_minVote, _maxVote);
    }

    /**
     * @dev Update minimum pool amount in DEPE (only owner)
     * @param newMinPool New minimum pool amount in DEPE tokens
     */
    function updateMinPoolDEPE(uint256 newMinPool) external onlyOwner {
        if (newMinPool == 0) revert InvalidAmount();
        uint256 oldMin = config.minPoolDEPE;
        config.minPoolDEPE = newMinPool;
        emit MinPoolUpdated(oldMin, newMinPool);
    }

    /**
     * @dev Pause factory (only owner)
     */
    function pause() external onlyOwner {
        _pause();
    }

    /**
     * @dev Unpause factory (only owner)
     */
    function unpause() external onlyOwner {
        _unpause();
    }

    /**
     * @dev Calculate platform fee for a given pool amount
     * @param totalAmount Total pool amount in DEPE
     * @return platformFee Platform fee in DEPE
     * @return netAmount Net amount after fee deduction
     */
    function calculateFees(uint256 totalAmount) 
        external 
        pure 
        returns (uint256 platformFee, uint256 netAmount) 
    {
        platformFee = (totalAmount * PLATFORM_FEE_BPS) / BASIS_POINTS;
        netAmount = totalAmount - platformFee;
        return (platformFee, netAmount);
    }

    /**
     * @dev Get total fees collected by the platform
     * @return totalFees Total platform fees collected
     */
    function getTotalFeesCollected() external view returns (uint256 totalFees) {
        return config.totalFeesCollected;
    }

    // ===== INTERNAL FUNCTIONS =====
    
    function _validateContestParameters(
        uint256 totalPoolAmount,
        uint256 duration,
        string calldata title,
        string calldata description
    ) private  {
        // Amount validation (validate total amount, not net amount)
        if (totalPoolAmount < config.minPoolDEPE) revert PoolBelowMinimum();
        
        // Ensure net amount after fee is still meaningful
        uint256 platformFee = (totalPoolAmount * PLATFORM_FEE_BPS) / BASIS_POINTS;
        uint256 netAmount = totalPoolAmount - platformFee;
        if (netAmount < (config.minPoolDEPE * 90) / 100) revert PoolBelowMinimum(); // Net should be at least 90% of minimum
        emit durationLog(duration, MIN_CONTEST_DURATION, MAX_CONTEST_DURATION);
        // Duration validation
        if (duration < MIN_CONTEST_DURATION || duration > MAX_CONTEST_DURATION) {
            revert InvalidDuration();
        }
        
        // String validation
        if (bytes(title).length == 0 || bytes(title).length > MAX_TITLE_LENGTH) {
            revert InvalidString();
        }
        if (bytes(description).length > MAX_STRING_LENGTH) {
            revert InvalidString();
        }
    }

    function _processFees(uint256 totalPoolAmount) private returns (uint256 netPoolAmount) {
        // Calculate platform fee and net pool amount
        uint256 platformFee = (totalPoolAmount * PLATFORM_FEE_BPS) / BASIS_POINTS;
        netPoolAmount = totalPoolAmount - platformFee;
        
        // Transfer total amount from user first
        IERC20(config.depeToken).safeTransferFrom(msg.sender, address(this), totalPoolAmount);
        
        // Send platform fee to platform wallet
        if (platformFee > 0) {
            IERC20(config.depeToken).safeTransfer(config.platformWallet, platformFee);
            config.totalFeesCollected += platformFee;
        }
        
        return netPoolAmount;
    }

    function _deployContest(
        uint256 netPoolAmount,
        uint256 minEntriesRequired,
        uint256 duration,
        string calldata title,
        string calldata description
    ) private returns (address) {
        ContestInstance contestInstance = new ContestInstance(
            config.depeToken,
            msg.sender,
            config.platformWallet,
            netPoolAmount,
            minEntriesRequired,
            duration,
            title,
            description,
            config.maxVoteAmount,
            config.minVoteAmount
        );
        address contestAddress = address(contestInstance);
        
        // Transfer net pool amount to the contest contract
        IERC20(config.depeToken).safeTransfer(contestAddress, netPoolAmount);
        
        return contestAddress;
    }

    function _finalizeContestCreation(
        address contestAddress,
        uint256 totalPoolAmount,
        uint256 netPoolAmount,
        uint256 minEntriesRequired,
        uint256 duration,
        string calldata title
    ) private {
        uint256 platformFee = totalPoolAmount - netPoolAmount;
        
        // Store contest information
        uint256 contestId = config.totalContests;
        _contests[contestId] = ContestInfo({
            contestAddress: contestAddress,
            creator: msg.sender,
            memePoolAmount: netPoolAmount,
            createdAt: block.timestamp,
            title: title,
            active: true
        });
        
        // Update mappings
        _userContests[msg.sender].push(contestId);
        unchecked { 
            ++_userContestCount[msg.sender];
            ++config.totalContests;
        }

        emit ContestCreated(
            contestId,
            contestAddress,
            msg.sender,
            totalPoolAmount,
            netPoolAmount,
            platformFee,
            minEntriesRequired,
            duration,
            title
        );
        
        emit PlatformFeeCollected(contestId, platformFee, msg.sender);
    }
}