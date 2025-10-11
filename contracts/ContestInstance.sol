// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

/**
 * @title ContestInstance
 * @dev Contest contract with platform validation and optimized claiming
 * @author DEPE Team
 */
contract ContestInstance is ReentrancyGuard, Ownable, Pausable {
    using ECDSA for bytes32;
    using MessageHashUtils for bytes32;
    using SafeERC20 for IERC20;

    // =============================================================
    //                           CONSTANTS
    // =============================================================
    
    uint256 private constant MAX_STRING_LENGTH = 500;
    uint256 private constant MAX_STAKE_PER_USER_PERCENT = 25;
    uint256 private constant BASIS_POINTS = 10000;
    
    uint256 private constant MEME_WINNER_PERCENT = 10000; // 100%
    uint256 private constant CONTEST_CREATOR_PERCENT = 2000; // 20%
    uint256 private constant STAKERS_PERCENT = 8000; // 80%

    // Constants for scoring weights (scaled by 1e18)
    uint256 constant ALPHA = 1e18;      // each vote = 1 point
    uint256 constant BETA = 5e14;       // 0.0005 in 18-decimal precision

    // =============================================================
    //                            ENUMS
    // =============================================================
    
    enum ContestPhase {
        SUBMISSION,
        VOTING,
        ENDED,
        FAILED
    }

    // =============================================================
    //                           STRUCTS
    // =============================================================
    
    struct ContestConfig {
        address depeToken;
        address creator;
        address platformWallet;
        uint256 memePoolAmount;
        uint256 maxVoteAmount;
        uint256 minVoteAmount;
        uint256 minEntriesRequired;
        uint256 votingDeadline;
    }

    struct ContestState {
        string title;
        string description;
        ContestPhase phase;
        uint256 submissionCount;
        uint256 totalStakingPool;
        uint256 winningSubmissionId;
        bool memeRewardClaimed;
        bool creatorRewardClaimed;
    }

    struct Submission {
        address submitter;
        uint256 fid;
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

    // =============================================================
    //                       STATE VARIABLES
    // =============================================================
    
    ContestConfig public config;
    ContestState public state;
    
    mapping(uint256 => Submission) private _submissions;
    mapping(address => uint256[]) private _userSubmissions;
    
    mapping(uint256 => address[]) private _submissionVoters;
    mapping(uint256 => mapping(address => uint256)) private _submissionVotes;
    
    // Staking: submissionId => address => stakeAmount (one stake per address per submission)
    mapping(uint256 => mapping(address => uint256)) private _submissionStakes;
    mapping(uint256 => mapping(address => bool)) private _stakesClaimed;
    mapping(uint256 => address[]) private _submissionStakers; // Track stakers that staked
    
    mapping(bytes32 => bool) public usedSignatures;

    // =============================================================
    //                           EVENTS
    // =============================================================
    
    event ContestCreated(address indexed creator, uint256 memePoolAmount, uint256 minEntriesRequired);
    event SubmissionAdded(uint256 indexed submissionId, address indexed submitter, uint256 fid);
    event VoteCast(uint256 indexed submissionId, address indexed voter, uint256 amount);
    event StakePlaced(uint256 indexed submissionId, address indexed staker, uint256 amount);
    event PhaseChanged(ContestPhase oldPhase, ContestPhase newPhase);
    event WinnerDetermined(uint256 indexed submissionId, uint256 totalVotes);
    event ContestFailed(string reason);
    event MemeRewardClaimed(uint256 indexed submissionId, uint256 amount);
    event CreatorRewardClaimed(uint256 amount);
    event StakerRewardClaimed(address indexed staker, uint256 amount);

    // =============================================================
    //                           ERRORS
    // =============================================================
    
    error InvalidAddress();
    error InvalidAmount();
    error InvalidDuration();
    error InvalidString();
    error InvalidPhase();
    error DeadlinePassed();
    error SubmissionNotExists();
    error AlreadyVoted();
    error VoteAmountInvalid();
    error MaxStakeExceeded();
    error InvalidFID();
    error InvalidPlatformSignature();
    error SignatureAlreadyUsed();
    error AlreadyStaked();
    error AlreadyClaimed();
    error NotYourStake();
    error NoStakeToClaim();

    // =============================================================
    //                          MODIFIERS
    // =============================================================
    
    modifier onlyDuringSubmission() {
        if (state.phase != ContestPhase.SUBMISSION) revert InvalidPhase();
        _;
    }

    modifier onlyDuringVoting() {
        if (state.phase != ContestPhase.VOTING) revert InvalidPhase();
        if (block.timestamp > config.votingDeadline) revert DeadlinePassed();
        _;
    }

    modifier onlyAfterVoting() {
        if (block.timestamp < config.votingDeadline) revert InvalidPhase();
        _;
    }

    modifier validSubmission(uint256 submissionId) {
        if (!_submissions[submissionId].exists) revert SubmissionNotExists();
        _;
    }

    // =============================================================
    //                        CONSTRUCTOR
    // =============================================================
    
    constructor(
        address _depeToken,
        address _creator,
        address _platformWallet,
        uint256 _memePoolAmount,
        uint256 _minEntriesRequired,
        uint256 _duration,
        string memory _title,
        string memory _description,
        uint256 _maxVoteAmount,
        uint256 _minVoteAmount
    ) Ownable(_creator) {
        if (_depeToken == address(0) || _creator == address(0) || _platformWallet == address(0)) {
            revert InvalidAddress();
        }
        if (_memePoolAmount == 0 || _minEntriesRequired < 2) revert InvalidAmount();
        if (_duration < 1 hours || _duration > 7 days) revert InvalidDuration();
        if (bytes(_title).length == 0 || bytes(_title).length > MAX_STRING_LENGTH) revert InvalidString();
        if (_maxVoteAmount == 0 || _minVoteAmount == 0 || _minVoteAmount > _maxVoteAmount) revert InvalidAmount();

        config = ContestConfig({
            depeToken: _depeToken,
            creator: _creator,
            platformWallet: _platformWallet,
            memePoolAmount: _memePoolAmount,
            maxVoteAmount: _maxVoteAmount,
            minVoteAmount: _minVoteAmount,
            minEntriesRequired: _minEntriesRequired,
            votingDeadline: block.timestamp + _duration
        });

        state = ContestState({
            title: _title,
            description: _description,
            phase: ContestPhase.SUBMISSION,
            submissionCount: 0,
            totalStakingPool: 0,
            winningSubmissionId: 0,
            memeRewardClaimed: false,
            creatorRewardClaimed: false
        });

        emit ContestCreated(_creator, _memePoolAmount, _minEntriesRequired);
    }

    // =============================================================
    //                      SUBMISSION FUNCTIONS
    // =============================================================
    
    function addSubmission(
        string calldata memeUrl,
        string calldata memeType,
        string calldata submissionTitle,
        string calldata submissionDescription,
        uint256 fid,
        bytes calldata platformSignature
    ) external onlyDuringSubmission nonReentrant whenNotPaused {
        if (bytes(memeUrl).length == 0) revert InvalidString();
        if (bytes(memeType).length == 0 || bytes(memeType).length > 50) revert InvalidString();
        if (bytes(submissionTitle).length > MAX_STRING_LENGTH) revert InvalidString();
        if (fid == 0) revert InvalidFID();

        bytes32 messageHash = keccak256(abi.encodePacked(
            address(this), memeUrl, memeType, submissionTitle, msg.sender, fid, block.timestamp
        ));
        _validateSignature(messageHash, platformSignature);

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

        emit SubmissionAdded(submissionId, msg.sender, fid);

        // Auto-transition to voting
        if (state.submissionCount >= config.minEntriesRequired) {
            ContestPhase oldPhase = state.phase;
            state.phase = ContestPhase.VOTING;
            emit PhaseChanged(oldPhase, ContestPhase.VOTING);
        }
    }

    // =============================================================
    //                       VOTING FUNCTIONS
    // =============================================================
    
    function vote(
        uint256 submissionId,
        uint256 voteAmount,
        uint256 fid,
        bytes calldata platformSignature
    ) external onlyDuringVoting validSubmission(submissionId) nonReentrant whenNotPaused {
        if (_submissionVotes[submissionId][msg.sender] > 0) revert AlreadyVoted();
        if (fid == 0) revert InvalidFID();
        
        if (voteAmount < config.minVoteAmount || voteAmount > config.maxVoteAmount) {
            revert VoteAmountInvalid();
        }

        bytes32 messageHash = keccak256(abi.encodePacked(
            address(this), submissionId, voteAmount, msg.sender, fid, block.timestamp
        ));
        _validateSignature(messageHash, platformSignature);

        IERC20(config.depeToken).safeTransferFrom(msg.sender, address(this), voteAmount);

        _submissionVotes[submissionId][msg.sender] = voteAmount;
        state.totalStakingPool += voteAmount;
        _submissionVoters[submissionId].push(msg.sender);

        unchecked { ++_submissions[submissionId].voteCount; }
        _submissions[submissionId].totalVoteAmount += voteAmount;

        emit VoteCast(submissionId, msg.sender, voteAmount);
    }

    // =============================================================
    //                       STAKING FUNCTIONS
    // =============================================================
    
    function stake(
        uint256 submissionId,
        uint256 stakeAmount,
        uint256 fid,
        bytes calldata platformSignature
    ) external onlyDuringVoting validSubmission(submissionId) nonReentrant whenNotPaused {
        if (stakeAmount == 0) revert InvalidAmount();
        

        uint256 maxStakePerUser = (config.memePoolAmount * MAX_STAKE_PER_USER_PERCENT) / 100;
        

        bytes32 messageHash = keccak256(abi.encodePacked(
            address(this), submissionId, stakeAmount, msg.sender, fid, block.timestamp
        ));
        _validateSignature(messageHash, platformSignature);

        
        uint256 currentAmount = _submissionStakes[submissionId][msg.sender];
        if (currentAmount + stakeAmount > maxStakePerUser) {
            revert MaxStakeExceeded();
        }

        _submissionStakes[submissionId][msg.sender] += stakeAmount;
        _submissionStakers[submissionId].push(msg.sender);

        IERC20(config.depeToken).safeTransferFrom(msg.sender, address(this), stakeAmount);
        
        state.totalStakingPool += stakeAmount;
        _submissions[submissionId].totalStakeAmount += stakeAmount;

        emit StakePlaced(submissionId, msg.sender, stakeAmount);
    }

    // =============================================================
    //                     PHASE MANAGEMENT
    // =============================================================
    
    function endSubmissionPhase() external onlyOwner {
        if (state.phase != ContestPhase.SUBMISSION) revert InvalidPhase();

        ContestPhase oldPhase = state.phase;

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

    // =============================================================
    //                    REWARD DISTRIBUTION
    // =============================================================
    
    function claimMemeWinnerReward() external onlyAfterVoting nonReentrant {
        if (state.memeRewardClaimed) revert AlreadyClaimed();

        ContestPhase oldPhase = state.phase;

        uint256 winnerId;
        uint256 highestScore;
        uint256 highestVotes;
        bool foundWinner;

        for (uint256 i = 0; i < state.submissionCount; ) {
            Submission storage s = _submissions[i];

            // Weighted scoring formula
            uint256 finalScore = 
                (s.voteCount * ALPHA) + 
                ((s.totalVoteAmount * BETA) / 1e18);

            // Determine winner using 3-tier tie-breaking:
            // 1️⃣ Highest final score wins
            // 2️⃣ If tied, higher voteCount wins
            // 3️⃣ If still tied, earlier submission (lower i) wins
            if (
                finalScore > highestScore ||
                (finalScore == highestScore && s.voteCount > highestVotes) ||
                (finalScore == highestScore && s.voteCount == highestVotes && !foundWinner)
            ) {
                highestScore = finalScore;
                highestVotes = s.voteCount;
                winnerId = i;
                foundWinner = true;
            }

            unchecked { ++i; }
        }

        if (!foundWinner || highestScore == 0) {
            state.phase = ContestPhase.FAILED;
            emit PhaseChanged(oldPhase, ContestPhase.FAILED);
            emit ContestFailed("No valid votes received");
            _refundAll();
            return;
        }

        state.winningSubmissionId = winnerId;
        state.phase = ContestPhase.ENDED;
        state.memeRewardClaimed = true;

        emit WinnerDetermined(winnerId, highestScore);
        emit PhaseChanged(oldPhase, ContestPhase.ENDED);

        IERC20(config.depeToken).safeTransfer(
            _submissions[winnerId].submitter,
            config.memePoolAmount
        );

        emit MemeRewardClaimed(winnerId, config.memePoolAmount);
    }



    function claimCreatorReward() external onlyOwner onlyAfterVoting nonReentrant {
        if (state.creatorRewardClaimed) revert AlreadyClaimed();
        if (state.phase != ContestPhase.ENDED) revert InvalidPhase();
        
        state.creatorRewardClaimed = true;
        uint256 creatorReward = (state.totalStakingPool * CONTEST_CREATOR_PERCENT) / BASIS_POINTS;
        
        if (creatorReward > 0) {
            IERC20(config.depeToken).safeTransfer(config.creator, creatorReward);
        }
        
        emit CreatorRewardClaimed(creatorReward);
    }

    function claimStakerReward() external onlyAfterVoting nonReentrant {
        if (state.phase != ContestPhase.ENDED) revert InvalidPhase();
        
        uint256 winningSubmissionId = state.winningSubmissionId;
        uint256 stakeAmount = _submissionStakes[winningSubmissionId][msg.sender];
        
        if (stakeAmount == 0) revert NoStakeToClaim();
        if (_stakesClaimed[winningSubmissionId][msg.sender]) revert AlreadyClaimed();
        
        _stakesClaimed[winningSubmissionId][msg.sender] = true;
        
        uint256 totalStakerReward = (state.totalStakingPool * STAKERS_PERCENT) / BASIS_POINTS;
        uint256 totalStakeAmount = _submissions[winningSubmissionId].totalStakeAmount;
        uint256 stakerReward = (totalStakerReward * stakeAmount) / totalStakeAmount;
        
        IERC20(config.depeToken).safeTransfer(msg.sender, stakerReward);
        emit StakerRewardClaimed(msg.sender, stakerReward);
    }

    // =============================================================
    //                       VIEW FUNCTIONS
    // =============================================================
    
    function getContestInfo() external view returns (
        address creator,
        uint256 memePoolAmount,
        uint256 totalStakingPool,
        uint256 minEntriesRequired,
        uint256 submissionCount,
        ContestPhase phase,
        uint256 maxVoteAmount,
        uint256 minVoteAmount,
        uint256 votingDeadline,
        uint256 winningSubmissionId
    ) {
        return (
            config.creator,
            config.memePoolAmount,
            state.totalStakingPool,
            config.minEntriesRequired,
            state.submissionCount,
            state.phase,
            config.maxVoteAmount,
            config.minVoteAmount,
            config.votingDeadline,
            state.winningSubmissionId
        );
    }

    function getSubmission(uint256 submissionId) external view validSubmission(submissionId) returns (Submission memory) {
        return _submissions[submissionId];
    }

    function getUserSubmissions(address user) external view returns (uint256[] memory) {
        return _userSubmissions[user];
    }

    function getUserVoteAmount(address user, uint256 submissionId) external view returns (uint256) {
        return _submissionVotes[submissionId][user];
    }

    function getStakeAmount(uint256 submissionId, address staker) external view returns (uint256) {
        return _submissionStakes[submissionId][staker];
    }

    function isStakeClaimed(uint256 submissionId, address staker) external view returns (bool) {
        return _stakesClaimed[submissionId][staker];
    }

    function getSubmissionStakers(uint256 submissionId) external view returns (address[] memory) {
        return _submissionStakers[submissionId];
    }

    function getClaimableStakerReward(address staker) external view returns (uint256) {
        if (state.phase != ContestPhase.ENDED) return 0;
        
        uint256 winningSubmissionId = state.winningSubmissionId;
        uint256 stakeAmount = _submissionStakes[winningSubmissionId][staker];
        
        if (stakeAmount == 0 || _stakesClaimed[winningSubmissionId][staker]) return 0;
        
        uint256 totalStakerReward = (state.totalStakingPool * STAKERS_PERCENT) / BASIS_POINTS;
        uint256 totalStakeAmount = _submissions[winningSubmissionId].totalStakeAmount;
        
        return (totalStakerReward * stakeAmount) / totalStakeAmount;
    }

    // =============================================================
    //                      PRIVATE FUNCTIONS
    // =============================================================
    
    function _validateSignature(bytes32 messageHash, bytes calldata signature) private {
        bytes32 sigHash = keccak256(signature);
        if (usedSignatures[sigHash]) revert SignatureAlreadyUsed();
        
        bytes32 ethSignedMessageHash = messageHash.toEthSignedMessageHash();
        address recoveredAddress = ethSignedMessageHash.recover(signature);
        
        if (recoveredAddress != config.platformWallet) revert InvalidPlatformSignature();
        usedSignatures[sigHash] = true;
    }

    function _refundMemePool() private {
        if (config.memePoolAmount > 0) {
            IERC20(config.depeToken).safeTransfer(config.creator, config.memePoolAmount);
        }
    }

    function _refundAll() private {
        _refundMemePool();
        
        // Refund all stakes
        for (uint256 submissionId = 0; submissionId < state.submissionCount; ) {
            address[] memory stakers = _submissionStakers[submissionId];
            
            for (uint256 i = 0; i < stakers.length; ) {
                address stakerAddress = stakers[i];
                uint256 stakeAmount = _submissionStakes[submissionId][stakerAddress];
                address staker = stakerAddress;
                
                if (stakeAmount > 0 && staker != address(0)) {
                    IERC20(config.depeToken).safeTransfer(staker, stakeAmount);
                }
                unchecked { ++i; }
            }
            
            // Refund all votes
            address[] storage voters = _submissionVoters[submissionId];
            for (uint256 i = 0; i < voters.length; ) {
                address voter = voters[i];
                uint256 voteAmount = _submissionVotes[submissionId][voter];
                
                if (voteAmount > 0) {
                    IERC20(config.depeToken).safeTransfer(voter, voteAmount);
                }
                unchecked { ++i; }
            }
            unchecked { ++submissionId; }
        }
    }
}