// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

/**
 * @title ContestInstance
 * @dev Contest contract with platform validation and automatic phase management
 * @notice Updated contract with 3 security improvements while preserving all existing functionality
 * @author DEPE Team
 */
contract ContestInstance is ReentrancyGuard, Ownable, Pausable {
    using SafeERC20 for IERC20;
    using Math for uint256;
    
    // ===== CONSTANTS =====
    uint256 private constant MAX_STRING_LENGTH = 500;
    uint256 private constant MIN_VOTE_USD = 1e18; // $1 USD
    uint256 private constant MAX_VOTE_USD = 10e18; // $10 USD
    uint256 private constant MAX_STAKE_PER_USER_PERCENT = 25; // 25% max stake per user
    uint256 private constant BASIS_POINTS = 10000;
    
    // Reward percentages in basis points (no platform fee)
    uint256 private constant MEME_WINNER_PERCENT = 10000; // 100% of meme pool
    uint256 private constant CONTEST_CREATOR_PERCENT = 2500; // 25% of voting pool
    uint256 private constant STAKERS_PERCENT = 7500; // 75% of voting pool
    
    // ===== ENUMS =====
    enum ContestPhase {
        SUBMISSION,
        VOTING,
        ENDED,
        FAILED
    }
    
    // ===== STRUCTS =====
    struct ContestConfig {
        address depeToken; // DEPE token address
        address creator;
        address platformWallet; // NEW: Platform wallet for signature verification
        uint256 memePoolAmount;
        uint256 minEntriesRequired;
        uint256 contestDuration;
        uint256 submissionDeadline;
        uint256 votingDeadline;
        uint256 depePriceUSD; // DEPE price in USD
    }
    
    struct ContestState {
        string title;
        string description;
        ContestPhase phase;
        uint256 submissionCount;
        uint256 totalStakingPool;
        uint256 totalVotingPool;
        uint256 winningSubmissionId;
        bool rewardsDistributed;
    }
    
    struct Submission {
        address submitter;
        uint256 fid; // NEW: Farcaster FID
        string memeUrl;
        string memeType;
        string title;
        string description;
        uint256 voteCount;
        uint256 totalVoteAmount;
        uint256 totalStakeAmount;
        uint256 createdAt;
        bool exists;
    }
    
    struct Vote {
        address voter;
        uint256 fid; // NEW: Farcaster FID
        uint256 amount;
        uint256 timestamp;
    }
    
    struct Stake {
        address staker;
        uint256 fid; // NEW: Farcaster FID
        uint256 amount;
        uint256 timestamp;
        bool claimed;
    }
    
    // ===== STATE VARIABLES =====
    ContestConfig public config;
    ContestState public state;
    
    // Mappings for submissions
    mapping(uint256 => Submission) private _submissions;
    mapping(address => uint256[]) private _userSubmissions;
    
    // Mappings for voting
    mapping(uint256 => address[]) private _submissionVoters;
    mapping(uint256 => mapping(address => uint256)) private _submissionVotes; // submissionId => voter => amount
    mapping(address => uint256) private _userTotalVotes;
    mapping(uint256 => uint256) private _submissionTotalVotes;
    
    // Mappings for staking
    mapping(uint256 => Stake[]) private _submissionStakes;
    mapping(address => mapping(uint256 => uint256)) private _userStakeAmount;
    mapping(address => uint256[]) private _userStakes;
    mapping(address => uint256) private _userTotalStakes;
    
    // NEW: Platform signature tracking
    mapping(bytes32 => bool) public usedSignatures;
    
    // Security mappings
    mapping(address => uint256) private _lastActionTimestamp;
    mapping(address => uint256) private _dailyActionCount;
    mapping(address => uint256) private _dailyResetTimestamp;
    
    // ===== EVENTS =====
    event ContestCreated(
        address indexed creator,
        uint256 memePoolAmount,
        uint256 minEntriesRequired,
        uint256 duration
    );
    
    event SubmissionAdded(
        uint256 indexed submissionId,
        address indexed submitter,
        uint256 fid,
        string memeUrl,
        string title
    );
    
    event VoteCast(
        uint256 indexed submissionId,
        address indexed voter,
        uint256 fid,
        uint256 amount
    );
    
    event StakePlaced(
        uint256 indexed submissionId,
        address indexed staker,
        uint256 fid,
        uint256 amount
    );
    
    event PhaseChanged(ContestPhase oldPhase, ContestPhase newPhase);
    event WinnerDetermined(uint256 indexed submissionId, uint256 totalVotes);
    
    event RewardsDistributed(
        uint256 indexed submissionId,
        uint256 memeWinnerReward,
        uint256 contestCreatorReward,
        uint256 stakersReward
    );
    
    event ContestFailed(string reason);
    event DEPEPriceUpdated(uint256 oldPrice, uint256 newPrice);
    
    // ===== ERRORS =====
    error InvalidAddress();
    error InvalidAmount();
    error InvalidDuration();
    error InvalidString();
    error UnauthorizedCreator();
    error InvalidPhase();
    error DeadlinePassed();
    error ContestNotEnded();
    error SubmissionNotExists();
    error AlreadyVoted();
    error VoteAmountInvalid();
    error RewardsAlreadyDistributed();
    error NoSubmissions();
    error TransferFailed();
    error MaxStakeExceeded();
    error InvalidFID();
    error InvalidPlatformSignature();
    error SignatureAlreadyUsed();
    
    // ===== MODIFIERS =====
    modifier onlyDuringSubmission() {
        if (state.phase != ContestPhase.SUBMISSION) revert InvalidPhase();
        if (block.timestamp > config.submissionDeadline) revert DeadlinePassed();
        _;
    }

    modifier onlyDuringVoting() {
        if (state.phase != ContestPhase.VOTING) revert InvalidPhase();
        if (block.timestamp > config.votingDeadline) revert DeadlinePassed();
        _;
    }

    modifier onlyAfterVoting() {
        if (state.phase != ContestPhase.ENDED) revert ContestNotEnded();
        _;
    }

    modifier validSubmission(uint256 submissionId) {
        if (!_submissions[submissionId].exists) revert SubmissionNotExists();
        _;
    }
    
    // ===== CONSTRUCTOR =====
    constructor(
        address _depeToken,
        address _creator,
        uint256 _memePoolAmount,
        uint256 _minEntriesRequired,
        uint256 _duration,
        string memory _title,
        string memory _description,
        uint256 _depePriceUSD,
        address _platformWallet
    ) Ownable(_creator) {
        // Input validation
        if (_depeToken == address(0) || _creator == address(0) || _platformWallet == address(0)) {
            revert InvalidAddress();
        }
        if (_memePoolAmount == 0) revert InvalidAmount();
        if (_duration < 1 hours || _duration > 7 days) revert InvalidDuration();
        if (bytes(_title).length == 0 || bytes(_title).length > MAX_STRING_LENGTH) revert InvalidString();
        if (_depePriceUSD == 0) revert InvalidAmount();
        require(_minEntriesRequired >= 2, "Minimum entries must be at least 2"); // NEW: Default min 2

        // Initialize config
        config = ContestConfig({
            depeToken: _depeToken,
            creator: _creator,
            platformWallet: _platformWallet,
            memePoolAmount: _memePoolAmount,
            minEntriesRequired: _minEntriesRequired,
            contestDuration: _duration,
            submissionDeadline: block.timestamp + (_duration * 60 / 100), // 60% for submissions
            votingDeadline: block.timestamp + _duration,
            depePriceUSD: _depePriceUSD
        });

        // Initialize state
        state = ContestState({
            title: _title,
            description: _description,
            phase: ContestPhase.SUBMISSION,
            submissionCount: 0,
            totalStakingPool: 0,
            totalVotingPool: 0,
            winningSubmissionId: 0,
            rewardsDistributed: false
        });

        emit ContestCreated(_creator, _memePoolAmount, _minEntriesRequired, _duration);
    }
    
    // ===== SUBMISSION FUNCTIONS =====
    
    /**
     * @dev Add a submission with platform validation
     * @notice NEW: Includes platform signature verification and auto-phase management
     */
    function addSubmission(
        string calldata memeUrl,
        string calldata memeType,
        string calldata submissionTitle,
        string calldata submissionDescription,
        uint256 fid, // NEW: Farcaster FID
        bytes32 platformSignature // NEW: Platform signature
    ) external onlyDuringSubmission nonReentrant whenNotPaused {
        // Validate inputs
        if (bytes(memeUrl).length == 0) revert InvalidString();
        if (bytes(memeType).length == 0 || bytes(memeType).length > 50) revert InvalidString();
        if (bytes(submissionTitle).length > MAX_STRING_LENGTH) revert InvalidString();
        if (fid == 0) revert InvalidFID();
        
        // NEW: Platform signature verification
        bytes32 messageHash = keccak256(abi.encodePacked(
            address(this),
            memeUrl,
            memeType,
            submissionTitle,
            msg.sender,
            fid,
            block.timestamp
        ));
        require(verifyPlatformSignature(messageHash, platformSignature), "Invalid platform signature");
        require(!usedSignatures[platformSignature], "Signature already used");
        usedSignatures[platformSignature] = true;

        uint256 submissionId = state.submissionCount;
        
        _submissions[submissionId] = Submission({
            submitter: msg.sender,
            fid: fid,
            memeUrl: memeUrl,
            memeType: memeType,
            title: submissionTitle,
            description: submissionDescription,
            voteCount: 0,
            totalVoteAmount: 0,
            totalStakeAmount: 0,
            createdAt: block.timestamp,
            exists: true
        });

        _userSubmissions[msg.sender].push(submissionId);
        unchecked { ++state.submissionCount; }

        emit SubmissionAdded(submissionId, msg.sender, fid, memeUrl, submissionTitle);
        
        // NEW: Auto-end submission phase when entries met
        if (state.submissionCount >= config.minEntriesRequired) {
            ContestPhase oldPhase = state.phase;
            state.phase = ContestPhase.VOTING;
            emit PhaseChanged(oldPhase, ContestPhase.VOTING);
        }
    }
    
    // ===== VOTING FUNCTIONS =====
    
    /**
     * @dev Cast a vote with platform validation
     * @notice NEW: Includes platform signature verification
     */
    function vote(
        uint256 submissionId, 
        uint256 voteAmount,
        uint256 fid, // NEW: Farcaster FID
        bytes32 platformSignature // NEW: Platform signature
    ) external onlyDuringVoting validSubmission(submissionId) nonReentrant whenNotPaused {
        // Check if already voted for this submission
        if (_submissionVotes[submissionId][msg.sender] > 0) revert AlreadyVoted();

        // Validate vote amount in USD terms
        uint256 minVoteDEPE = (MIN_VOTE_USD * 1e18) / config.depePriceUSD;
        uint256 maxVoteDEPE = (MAX_VOTE_USD * 1e18) / config.depePriceUSD;
        
        if (voteAmount < minVoteDEPE || voteAmount > maxVoteDEPE) {
            revert VoteAmountInvalid();
        }
        
        if (fid == 0) revert InvalidFID();
        
        // NEW: Platform signature verification
        bytes32 messageHash = keccak256(abi.encodePacked(
            address(this),
            submissionId,
            voteAmount,
            msg.sender,
            fid,
            block.timestamp
        ));
        require(verifyPlatformSignature(messageHash, platformSignature), "Invalid platform signature");
        require(!usedSignatures[platformSignature], "Signature already used");
        usedSignatures[platformSignature] = true;

        // Transfer tokens
        IERC20(config.depeToken).safeTransferFrom(msg.sender, address(this), voteAmount);

        // Update vote mappings
        _submissionVotes[submissionId][msg.sender] = voteAmount;
        _userTotalVotes[msg.sender] += voteAmount;
        _submissionTotalVotes[submissionId] += voteAmount;
        state.totalVotingPool += voteAmount;

        // Track voter for potential refunds
        _submissionVoters[submissionId].push(msg.sender);

        // Update submission
        unchecked {
            ++_submissions[submissionId].voteCount;
        }
        _submissions[submissionId].totalVoteAmount += voteAmount;

        emit VoteCast(submissionId, msg.sender, fid, voteAmount);
    }
    
    // ===== STAKING FUNCTIONS =====
    
    /**
     * @dev Place a stake with platform validation
     * @notice NEW: Includes platform signature verification
     */
    function stake(
        uint256 submissionId, 
        uint256 stakeAmount,
        uint256 fid, // NEW: Farcaster FID
        bytes32 platformSignature // NEW: Platform signature
    ) external onlyDuringSubmission validSubmission(submissionId) nonReentrant whenNotPaused {
        if (stakeAmount == 0) revert InvalidAmount();
        if (fid == 0) revert InvalidFID();

        // Prevent excessive concentration of stakes
        uint256 maxStakePerUser = (config.memePoolAmount * MAX_STAKE_PER_USER_PERCENT) / 100;
        if (_userTotalStakes[msg.sender] + stakeAmount > maxStakePerUser) {
            revert MaxStakeExceeded();
        }
        
        // NEW: Platform signature verification
        bytes32 messageHash = keccak256(abi.encodePacked(
            address(this),
            submissionId,
            stakeAmount,
            msg.sender,
            fid,
            block.timestamp
        ));
        require(verifyPlatformSignature(messageHash, platformSignature), "Invalid platform signature");
        require(!usedSignatures[platformSignature], "Signature already used");
        usedSignatures[platformSignature] = true;

        // Transfer tokens
        IERC20(config.depeToken).safeTransferFrom(msg.sender, address(this), stakeAmount);

        // Add stake
        _submissionStakes[submissionId].push(Stake({
            staker: msg.sender,
            fid: fid,
            amount: stakeAmount,
            timestamp: block.timestamp,
            claimed: false
        }));

        // Update mappings
        _userStakeAmount[msg.sender][submissionId] += stakeAmount;
        _userStakes[msg.sender].push(submissionId);
        _userTotalStakes[msg.sender] += stakeAmount;
        state.totalStakingPool += stakeAmount;

        // Update submission
        _submissions[submissionId].totalStakeAmount += stakeAmount;

        emit StakePlaced(submissionId, msg.sender, fid, stakeAmount);
    }
    
    // ===== PHASE MANAGEMENT =====
    
    /**
     * @dev End submission phase manually (only if auto-end didn't trigger)
     * @notice Only owner can call this
     */
    function endSubmissionPhase() external onlyOwner {
        if (state.phase != ContestPhase.SUBMISSION) revert InvalidPhase();
        
        ContestPhase oldPhase = state.phase;
        
        // NEW: Auto-fail if entries not met
        if (state.submissionCount < config.minEntriesRequired) {
            state.phase = ContestPhase.FAILED;
            emit PhaseChanged(oldPhase, ContestPhase.FAILED);
            emit ContestFailed("Not enough submissions");
            _refundMemePool();
        } else {
            state.phase = ContestPhase.VOTING;
            emit PhaseChanged(oldPhase, ContestPhase.VOTING);
        }
    }

    function endVotingPhase() external onlyOwner {
        if (state.phase != ContestPhase.VOTING) revert InvalidPhase();
        if (block.timestamp < config.votingDeadline) revert DeadlinePassed();

        ContestPhase oldPhase = state.phase;

        if (state.submissionCount == 0) {
            state.phase = ContestPhase.FAILED;
            emit PhaseChanged(oldPhase, ContestPhase.FAILED);
            emit ContestFailed("No submissions");
            _refundMemePool();
            return;
        }

        // Find winner (highest vote amount, then highest vote count as tiebreaker)
        uint256 maxVoteAmount = 0;
        uint256 maxVoteCount = 0;
        uint256 winnerId = 0;
        bool foundWinner = false;

        for (uint256 i = 0; i < state.submissionCount; ) {
            uint256 currentVoteAmount = _submissions[i].totalVoteAmount;
            uint256 currentVoteCount = _submissions[i].voteCount;
            
            if (currentVoteAmount > maxVoteAmount || 
                (currentVoteAmount == maxVoteAmount && currentVoteCount > maxVoteCount)) {
                maxVoteAmount = currentVoteAmount;
                maxVoteCount = currentVoteCount;
                winnerId = i;
                foundWinner = true;
            }
            
            unchecked { ++i; }
        }

        if (!foundWinner || maxVoteAmount == 0) {
            state.phase = ContestPhase.FAILED;
            emit PhaseChanged(oldPhase, ContestPhase.FAILED);
            emit ContestFailed("No votes received");
            _refundAll();
            return;
        }

        state.winningSubmissionId = winnerId;
        state.phase = ContestPhase.ENDED;

        emit WinnerDetermined(winnerId, maxVoteAmount);
        emit PhaseChanged(oldPhase, ContestPhase.ENDED);
    }
    
    // ===== REWARD DISTRIBUTION =====
    
    function distributeRewards() external onlyAfterVoting nonReentrant {
        if (state.rewardsDistributed) revert RewardsAlreadyDistributed();

        state.rewardsDistributed = true;

        // Calculate rewards (no platform fee)
        uint256 memeWinnerReward = config.memePoolAmount; // 100% of meme pool
        uint256 contestCreatorReward = (state.totalVotingPool * CONTEST_CREATOR_PERCENT) / BASIS_POINTS; // 25%
        uint256 stakersReward = state.totalVotingPool - contestCreatorReward; // 75%

        // Distribute meme pool to winner (full amount)
        if (memeWinnerReward > 0) {
            IERC20(config.depeToken).safeTransfer(
                _submissions[state.winningSubmissionId].submitter,
                memeWinnerReward
            );
        }

        // Send creator reward (25% of voting pool)
        if (contestCreatorReward > 0) {
            IERC20(config.depeToken).safeTransfer(config.creator, contestCreatorReward);
        }

        // Distribute staking rewards (75% of voting pool)
        if (stakersReward > 0 && state.totalStakingPool > 0) {
            _distributeStakingRewards(stakersReward);
        }

        emit RewardsDistributed(
            state.winningSubmissionId,
            memeWinnerReward,
            contestCreatorReward,
            stakersReward
        );
    }

    function _distributeStakingRewards(uint256 totalReward) private {
        Stake[] storage winningStakes = _submissionStakes[state.winningSubmissionId];
        uint256 winningStakeTotal = _submissions[state.winningSubmissionId].totalStakeAmount;
        
        if (winningStakeTotal == 0) return;

        for (uint256 i = 0; i < winningStakes.length; ) {
            Stake storage currentStake = winningStakes[i];
            if (!currentStake.claimed) {
                uint256 stakerReward = (totalReward * currentStake.amount) / winningStakeTotal;
                
                if (stakerReward > 0) {
                    IERC20(config.depeToken).safeTransfer(currentStake.staker, stakerReward);
                    currentStake.claimed = true;
                }
            }
            unchecked { ++i; }
        }
    }
    
    // ===== PLATFORM VALIDATION =====
    
    /**
     * @dev Verify platform signature
     * @notice NEW: Core security feature for platform validation
     */
    function verifyPlatformSignature(bytes32 messageHash, bytes32 signature) internal view returns (bool) {
        bytes32 ethSignedMessageHash = keccak256(abi.encodePacked(
            "\x19Ethereum Signed Message:\n32",
            messageHash
        ));
        
        address recoveredAddress = ecrecover(ethSignedMessageHash, signature);
        return recoveredAddress == config.platformWallet;
    }
    
    // ===== ADMIN FUNCTIONS =====
    
    function updateDEPEPrice(uint256 newPrice) external onlyOwner {
        if (newPrice == 0) revert InvalidAmount();
        uint256 oldPrice = config.depePriceUSD;
        config.depePriceUSD = newPrice;
        emit DEPEPriceUpdated(oldPrice, newPrice);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }
    
    // ===== VIEW FUNCTIONS =====
    
    function getContestInfo() external view returns (
        address creator,
        uint256 memePoolAmount,
        uint256 totalStakingPool,
        uint256 minEntriesRequired,
        uint256 submissionCount,
        ContestPhase phase,
        uint256 submissionDeadline,
        uint256 votingDeadline,
        uint256 winningSubmissionId,
        bool rewardsDistributed
    ) {
        return (
            config.creator,
            config.memePoolAmount,
            state.totalStakingPool,
            config.minEntriesRequired,
            state.submissionCount,
            state.phase,
            config.submissionDeadline,
            config.votingDeadline,
            state.winningSubmissionId,
            state.rewardsDistributed
        );
    }

    function getSubmission(uint256 submissionId) 
        external 
        view 
        validSubmission(submissionId) 
        returns (Submission memory) 
    {
        return _submissions[submissionId];
    }

    function getUserSubmissions(address user) external view returns (uint256[] memory) {
        return _userSubmissions[user];
    }

    function getUserStakes(address user) external view returns (uint256[] memory) {
        return _userStakes[user];
    }

    function getUserVoteAmount(address user, uint256 submissionId) external view returns (uint256) {
        return _submissionVotes[submissionId][user];
    }

    function getUserStakeAmount(address user, uint256 submissionId) external view returns (uint256) {
        return _userStakeAmount[user][submissionId];
    }

    function getSubmissionStakes(uint256 submissionId) external view returns (Stake[] memory) {
        return _submissionStakes[submissionId];
    }
    
    // ===== PRIVATE FUNCTIONS =====
    
    function _refundMemePool() private {
        if (config.memePoolAmount > 0) {
            IERC20(config.depeToken).safeTransfer(config.creator, config.memePoolAmount);
        }
    }

    function _refundAll() private {
        // Refund meme pool to creator
        _refundMemePool();
        
        // Refund all stakes to stakers
        _refundAllStakes();
        
        // Refund all votes to voters
        _refundAllVotes();
    }

    function _refundAllStakes() private {
        // Refund stakes from all submissions
        for (uint256 submissionId = 0; submissionId < state.submissionCount; ) {
            Stake[] storage stakes = _submissionStakes[submissionId];
            
            for (uint256 i = 0; i < stakes.length; ) {
                Stake storage currentStake = stakes[i];
                if (!currentStake.claimed && currentStake.amount > 0) {
                    IERC20(config.depeToken).safeTransfer(currentStake.staker, currentStake.amount);
                    currentStake.claimed = true;
                }
                unchecked { ++i; }
            }
            unchecked { ++submissionId; }
        }
    }

    function _refundAllVotes() private {
        // Refund votes from all submissions
        for (uint256 submissionId = 0; submissionId < state.submissionCount; ) {
            address[] storage voters = _submissionVoters[submissionId];
            
            for (uint256 i = 0; i < voters.length; ) {
                address voter = voters[i];
                uint256 voteAmount = _submissionVotes[submissionId][voter];
                
                if (voteAmount > 0) {
                    IERC20(config.depeToken).safeTransfer(voter, voteAmount);
                    _submissionVotes[submissionId][voter] = 0; // Mark as refunded
                }
                unchecked { ++i; }
            }
            unchecked { ++submissionId; }
        }
    }
}