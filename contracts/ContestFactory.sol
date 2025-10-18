// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./ContestInstance.sol";
import "./ValidationLibrary.sol";

/**
 * @title ContestFactory
 * @dev Factory contract with platform validation and DEPE token integration
 * @notice Updated factory with platform wallet parameter while preserving all existing functionality
 * @author DEPE Team
 */
contract ContestFactory is ReentrancyGuard, Ownable, Pausable {
       using SafeERC20 for IERC20;

    // ===== CONSTANTS =====
    uint256 private constant PLATFORM_FEE_BPS = 1000; // 10%
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
    
    mapping(uint256 => ContestInfo) private _contests;
    mapping(address => uint256[]) private _userContests;

    // ===== EVENTS =====
    event ContestCreated(
        uint256 indexed contestId,
        address indexed contestAddress,
        address indexed creator,
        uint256 netPoolAmount,
        uint256 platformFee
    );
    
    event DEPEVoteAmountUpdated(uint256 min, uint256 max);
    event MinPoolUpdated(uint256 oldMin, uint256 newMin);
    event ContestDeactivated(uint256 indexed contestId, address indexed creator);
    event PlatformWalletUpdated(address indexed oldWallet, address indexed newWallet);
    event PlatformFeeCollected(uint256 indexed contestId, uint256 amount, address indexed creator);

    // ===== ERRORS =====
    error ContestNotExists();
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
        ContestValidation.validateAddresses(_depeToken, _platformWallet, msg.sender);
        ContestValidation.validateVoteAmounts(maxVoteAmount, minVoteAmount);
        
        config = FactoryConfig({
            depeToken: _depeToken,
            platformWallet: _platformWallet,
            minPoolDEPE: 1_000_000 * 1e18,
            maxVoteAmount: maxVoteAmount,
            minVoteAmount: minVoteAmount,
            totalContests: 0,
            totalFeesCollected: 0
        });
    }

    // ===== CONTEST CREATION =====
    
    /**
     * @dev Create a new contest - SIMPLIFIED with library
     */
    function createContest(
        uint256 totalPoolAmount,
        uint256 minEntriesRequired,
        uint256 submissionDuration,
        uint256 contestDuration,
        string calldata title,
        string calldata description
    ) 
        external 
        nonReentrant 
        whenNotPaused
        returns (address contestAddress) 
    {
        (uint256 platformFee, uint256 netPoolAmount) = ContestValidation.validatePoolAmount(
            totalPoolAmount,
            config.minPoolDEPE
        );

        
        // Process fees
        IERC20(config.depeToken).safeTransferFrom(msg.sender, address(this), totalPoolAmount);
        
        if (platformFee > 0) {
            IERC20(config.depeToken).safeTransfer(config.platformWallet, platformFee);
            config.totalFeesCollected += platformFee;
        }
        
        // Deploy contest
        contestAddress = _deployContest(
            netPoolAmount,
            minEntriesRequired,
            submissionDuration,
            contestDuration,
            title,
            description
        );
        
        // Store and finalize
        _finalizeContestCreation(contestAddress, netPoolAmount, platformFee, title);
        
        return contestAddress;
    }

    // ===== CONTEST MANAGEMENT =====
    
    function deactivateContest(uint256 contestId) 
        external 
        validContestId(contestId) 
        nonReentrant 
    {
        ContestInfo storage contestInfo = _contests[contestId];
        
        if (contestInfo.creator != msg.sender) revert UnauthorizedDeactivation();
        if (!contestInfo.active) return;
        
        contestInfo.active = false;
        emit ContestDeactivated(contestId, msg.sender);
    }

    // ===== VIEW FUNCTIONS =====
    
    function getContest(uint256 contestId) 
        external 
        view 
        validContestId(contestId) 
        returns (ContestInfo memory) 
    {
        return _contests[contestId];
    }

    function getContestAddress(uint256 contestId) 
        external 
        view 
        validContestId(contestId) 
        returns (address) 
    {
        return _contests[contestId].contestAddress;
    }

    function getUserContests(address user) external view returns (uint256[] memory) {
        return _userContests[user];
    }

    function getUserContestCount(address user) external view returns (uint256) {
        return _userContests[user].length;  // ✅ Calculate instead of storing
    }

    function getActiveContests(uint256 startId, uint256 endId) 
        external 
        view 
        returns (ContestInfo[] memory) 
    {
        if (endId > config.totalContests) {
            endId = config.totalContests;
        }
        
        uint256 activeCount = 0;
        for (uint256 i = startId; i < endId; ) {
            if (_contests[i].active) {
                unchecked { ++activeCount; }
            }
            unchecked { ++i; }
        }
        
        ContestInfo[] memory activeContests = new ContestInfo[](activeCount);
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

    function getFactoryConfig() external view returns (FactoryConfig memory) {
        return config;
    }

    function getTotalFeesCollected() external view returns (uint256) {
        return config.totalFeesCollected;
    }

    // ===== ADMIN FUNCTIONS =====
    
    function updatePlatformWallet(address newPlatformWallet) external onlyOwner {
        ContestValidation.validateAddresses(config.depeToken, msg.sender, newPlatformWallet);
        address oldWallet = config.platformWallet;
        config.platformWallet = newPlatformWallet;
        emit PlatformWalletUpdated(oldWallet, newPlatformWallet);
    }

    function updateVoteAmout(uint256 _maxVote, uint256 _minVote) external onlyOwner {
        ContestValidation.validateVoteAmounts(_maxVote, _minVote);
        config.maxVoteAmount = _maxVote;
        config.minVoteAmount = _minVote;
        emit DEPEVoteAmountUpdated(_minVote, _maxVote);
    }

    function updateMinPoolDEPE(uint256 newMinPool) external onlyOwner {
        if (newMinPool == 0) revert ContestValidation.InvalidAmount();
        uint256 oldMin = config.minPoolDEPE;
        config.minPoolDEPE = newMinPool;
        emit MinPoolUpdated(oldMin, newMinPool);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    // ===== INTERNAL FUNCTIONS =====
    
    function _deployContest(
        uint256 netPoolAmount,
        uint256 minEntriesRequired,
        uint256 submissionDuration,
        uint256 contestDuration,
        string calldata title,
        string calldata description
    ) private returns (address) {
        ContestInstance contestInstance = new ContestInstance(
            config.depeToken,
            msg.sender,
            config.platformWallet,
            netPoolAmount,
            minEntriesRequired,
            submissionDuration,
            contestDuration,
            title,
            description,
            config.maxVoteAmount,
            config.minVoteAmount
        );
        
        address contestAddress = address(contestInstance);
        IERC20(config.depeToken).safeTransfer(contestAddress, netPoolAmount);
        
        return contestAddress;
    }

    function _finalizeContestCreation(
        address contestAddress,
        uint256 netPoolAmount,
        uint256 platformFee,
        string calldata title
    ) private {
        uint256 contestId = config.totalContests;
        
        _contests[contestId] = ContestInfo({
            contestAddress: contestAddress,
            creator: msg.sender,
            memePoolAmount: netPoolAmount,
            createdAt: block.timestamp,
            title: title,
            active: true
        });
        
        _userContests[msg.sender].push(contestId);
        unchecked { ++config.totalContests; }

        emit ContestCreated(
            contestId,
            contestAddress,
            msg.sender,
            netPoolAmount,
            platformFee
        );
        
        emit PlatformFeeCollected(contestId, platformFee, msg.sender);
    }
}