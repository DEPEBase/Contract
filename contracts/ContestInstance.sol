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
        uint256 winningSubmissionFid;
        bool memeRewardClaimed;
        bool creatorRewardClaimed;
    }

    struct Submission {
        address submitter;
        uint256 fid;
        string memeUrl;
        string memeType;
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
    
    mapping(uint256 => Submission) private _submissions; // fid => Submission
    mapping(address => bool) private _hasSubmitted; // Track if address has submitted
    mapping(address => uint256) private _userSubmissionFid; // user => their submission FID
    uint256[] private _allSubmissionFids; // Array of all submission FIDs
    
    mapping(uint256 => address[]) private _submissionVoters;
    mapping(uint256 => mapping(address => uint256)) private _submissionVotes;
    mapping(address => bool) private _hasVoted; // Track if address has voted
    
    // Staking: submissionFid => fid => stakeAmount (one stake per FID per submission)
    mapping(uint256 => mapping(uint256 => uint256)) private _submissionStakes;
    mapping(uint256 => mapping(uint256 => bool)) private _stakesClaimed;
    mapping(uint256 => uint256[]) private _submissionStakerFids; // Track FIDs that staked
    mapping(uint256 => mapping(uint256 => address)) private _fidToAddress; // FID to address mapping per submission
    mapping(uint256 => uint256) private _totalStakesByFid;
    
    mapping(bytes32 => bool) public usedSignatures;

    // =============================================================
    //                           EVENTS
    // =============================================================
    
    event ContestCreated(address indexed creator, uint256 memePoolAmount, uint256 minEntriesRequired);
    event SubmissionAdded(uint256 indexed submissionFid, address indexed submitter, uint256 fid);
    event VoteCast(uint256 indexed submissionFid, address indexed voter, uint256 amount);
    event StakePlaced(uint256 indexed submissionFid, uint256 indexed fid, uint256 amount);
    event PhaseChanged(ContestPhase oldPhase, ContestPhase newPhase);
    event WinnerDetermined(uint256 indexed submissionFid, uint256 totalVotes);
    event ContestFailed(string reason);
    event MemeRewardClaimed(uint256 indexed submissionFid, uint256 amount);
    event CreatorRewardClaimed(uint256 amount);
    event StakerRewardClaimed(uint256 indexed fid, uint256 amount);

    // =============================================================
    //                           ERRORS
    // =============================================================
    
    error InvalidAddress();
    error InvalidAmount();
    error InvalidDuration();
    error InvalidString();
    error NotAuthorized();
    error InvalidPhase();
    error DeadlinePassed();
    error SubmissionNotExists();
    error AlreadySubmitted();
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

    modifier validSubmission(uint256 submissionFid) {
        if (!_submissions[submissionFid].exists) revert SubmissionNotExists();
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
            winningSubmissionFid: 0,
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
        uint256 fid,
        bytes calldata platformSignature
    ) external onlyDuringSubmission nonReentrant whenNotPaused {
        if (_hasSubmitted[msg.sender]) revert AlreadySubmitted();
        if (_submissions[fid].exists) revert AlreadySubmitted();

        if (bytes(memeUrl).length == 0) revert InvalidString();
        if (bytes(memeType).length == 0 || bytes(memeType).length > 50) revert InvalidString();
        if (fid == 0) revert InvalidFID();

        bytes32 messageHash = keccak256(abi.encodePacked(
            address(this), memeUrl, memeType, msg.sender, fid
        ));
        _validateSignature(messageHash, platformSignature);

        _submissions[fid] = Submission({
            submitter: msg.sender,
            fid: fid,
            memeUrl: memeUrl,
            memeType: memeType,
            voteCount: 0,
            totalVoteAmount: 0,
            totalStakeAmount: 0,
            createdAt: block.timestamp,
            exists: true
        });

        _hasSubmitted[msg.sender] = true;

        unchecked { ++state.submissionCount; }

        _allSubmissionFids.push(fid);

        emit SubmissionAdded(fid, msg.sender, fid);

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
        uint256 submissionFid,
        uint256 voteAmount,
        uint256 fid,
        bytes calldata platformSignature
    ) external onlyDuringVoting validSubmission(submissionFid) nonReentrant whenNotPaused {
        if (_hasVoted[msg.sender]) revert AlreadyVoted();
        if (_submissionVotes[submissionFid][msg.sender] > 0) revert AlreadyVoted();
        if (fid == 0) revert InvalidFID();
        
        if (voteAmount < config.minVoteAmount || voteAmount > config.maxVoteAmount) {
            revert VoteAmountInvalid();
        }

        bytes32 messageHash = keccak256(abi.encodePacked(
            address(this), submissionFid, voteAmount, msg.sender, fid
        ));
        _validateSignature(messageHash, platformSignature);

        IERC20(config.depeToken).safeTransferFrom(msg.sender, address(this), voteAmount);

        _submissionVotes[submissionFid][msg.sender] = voteAmount;
        _hasVoted[msg.sender] = true;
        state.totalStakingPool += voteAmount;
        _submissionVoters[submissionFid].push(msg.sender);

        unchecked { ++_submissions[submissionFid].voteCount; }
        _submissions[submissionFid].totalVoteAmount += voteAmount;

        emit VoteCast(submissionFid, msg.sender, voteAmount);
    }

    // =============================================================
    //                       STAKING FUNCTIONS
    // =============================================================
    
    function stake(
        uint256 submissionFid,
        uint256 stakeAmount,
        uint256 fid,
        bytes calldata platformSignature
    ) external onlyDuringVoting validSubmission(submissionFid) nonReentrant whenNotPaused {
        if (stakeAmount == 0) revert InvalidAmount();
        if (fid == 0) revert InvalidFID();
        
        // One stake per FID per submission
        if (_submissionStakes[submissionFid][fid] > 0) revert AlreadyStaked();

        uint256 currentTotalStake = _totalStakesByFid[fid];
        uint256 newTotalStake = currentTotalStake + stakeAmount;
        
        uint256 maxTotalStakePerFid = (config.memePoolAmount * MAX_STAKE_PER_USER_PERCENT) / 100;
        if (newTotalStake > maxTotalStakePerFid) {
            revert MaxStakeExceeded();
        }

        bytes32 messageHash = keccak256(abi.encodePacked(
            address(this), submissionFid, stakeAmount, msg.sender, fid
        ));
        _validateSignature(messageHash, platformSignature);

        IERC20(config.depeToken).safeTransferFrom(msg.sender, address(this), stakeAmount);

        _submissionStakes[submissionFid][fid] = stakeAmount;
        _fidToAddress[submissionFid][fid] = msg.sender;
        _submissionStakerFids[submissionFid].push(fid);

        _totalStakesByFid[fid] = newTotalStake;
        
        state.totalStakingPool += stakeAmount;
        _submissions[submissionFid].totalStakeAmount += stakeAmount;

        emit StakePlaced(submissionFid, fid, stakeAmount);
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
        state.memeRewardClaimed = true;

        uint256 winnerIndex = type(uint256).max; // index in _allSubmissionFids
        uint256 winnerFid = 0;                   // actual FID of winning submission
        uint256 highestScore = 0;
        uint256 highestVotes = 0;
        bool found = false;

        uint256 len = _allSubmissionFids.length;
        for (uint256 i = 0; i < len; ) {
            uint256 fid = _allSubmissionFids[i];
            Submission storage s = _submissions[fid];

            // finalScore = votes * ALPHA + voteAmount * BETA
            uint256 scoreVotes = s.voteCount * ALPHA; // scaled
            uint256 scoreVoteAmount = (s.totalVoteAmount * BETA) / 1e18; // scaled

            uint256 finalScore = scoreVotes + scoreVoteAmount;

            // tie-break rules:
            // 1) higher finalScore
            // 2) if equal, higher voteCount
            // 3) if equal, earlier submission (lower i)
            bool takeWinner = false;
            if (finalScore > highestScore) {
                takeWinner = true;
            } else if (finalScore == highestScore) {
                if (s.voteCount > highestVotes) {
                    takeWinner = true;
                } else if (s.voteCount == highestVotes) {
                    // earlier submission wins
                    if (!found || i < winnerIndex) {
                        takeWinner = true;
                    }
                }
            }

            if (takeWinner) {
                highestScore = finalScore;
                highestVotes = s.voteCount;
                winnerIndex = i;
                winnerFid = fid;
                found = true;
            }

            unchecked { ++i; }
        }

        // if no valid votes or no submission found
        if (!found || highestScore == 0) {
            state.memeRewardClaimed = false;
            state.phase = ContestPhase.FAILED;
            emit PhaseChanged(oldPhase, ContestPhase.FAILED);
            emit ContestFailed("No valid votes or stakes received");
            _refundAll();
            return;
        }

        // Save winner as FID (not index)
        state.winningSubmissionFid = winnerFid;
        state.phase = ContestPhase.ENDED;

        emit WinnerDetermined(winnerFid, highestScore);
        emit PhaseChanged(oldPhase, ContestPhase.ENDED);

        // Transfer the meme pool to the winning submitter
        address winnerAddr = _submissions[winnerFid].submitter;
        if (msg.sender != winnerAddr) revert NotAuthorized();

        IERC20(config.depeToken).safeTransfer(winnerAddr, config.memePoolAmount);

        emit MemeRewardClaimed(winnerFid, config.memePoolAmount);
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

    function claimStakerReward(uint256 fid) external onlyAfterVoting nonReentrant {
        if (state.phase != ContestPhase.ENDED) revert InvalidPhase();
        
        uint256 winningSubmissionFid = state.winningSubmissionFid;
        uint256 stakeAmount = _submissionStakes[winningSubmissionFid][fid];
        
        if (stakeAmount == 0) revert NoStakeToClaim();
        if (_fidToAddress[winningSubmissionFid][fid] != msg.sender) revert NotYourStake();
        if (_stakesClaimed[winningSubmissionFid][fid]) revert AlreadyClaimed();
        
        _stakesClaimed[winningSubmissionFid][fid] = true;
        
        uint256 totalStakerReward = (state.totalStakingPool * STAKERS_PERCENT) / BASIS_POINTS;
        uint256 totalStakeAmount = _submissions[winningSubmissionFid].totalStakeAmount;
        uint256 stakerReward = (totalStakerReward * stakeAmount) / totalStakeAmount;
        
        IERC20(config.depeToken).safeTransfer(msg.sender, stakerReward);
        emit StakerRewardClaimed(fid, stakerReward);
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
        uint256 winningSubmissionFid
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
            state.winningSubmissionFid
        );
    }

    function getSubmission(uint256 submissionFid) external view validSubmission(submissionFid) returns (Submission memory) {
        return _submissions[submissionFid];
    }

    function getAllSubmissions() external view returns (Submission[] memory) {
        uint256[] memory allFids = _allSubmissionFids;
        Submission[] memory submissions = new Submission[](allFids.length);
        
        for (uint256 i = 0; i < allFids.length; ) {
            submissions[i] = _submissions[allFids[i]];
            unchecked { ++i; }
        }
        
        return submissions;
    }

    function getUserVoteAmount(address user, uint256 submissionFid) external view returns (uint256) {
        return _submissionVotes[submissionFid][user];
    }

    function getStakeAmount(uint256 submissionFid, uint256 fid) external view returns (uint256) {
        return _submissionStakes[submissionFid][fid];
    }

    function isStakeClaimed(uint256 submissionFid, uint256 fid) external view returns (bool) {
        return _stakesClaimed[submissionFid][fid];
    }

    function getSubmissionStakerFids(uint256 submissionFid) external view returns (uint256[] memory) {
        return _submissionStakerFids[submissionFid];
    }

    function getClaimableStakerReward(uint256 fid) external view returns (uint256) {
        if (state.phase != ContestPhase.ENDED) return 0;
        
        uint256 winningSubmissionFid = state.winningSubmissionFid;
        uint256 stakeAmount = _submissionStakes[winningSubmissionFid][fid];
        
        if (stakeAmount == 0 || _stakesClaimed[winningSubmissionFid][fid]) return 0;
        
        uint256 totalStakerReward = (state.totalStakingPool * STAKERS_PERCENT) / BASIS_POINTS;
        uint256 totalStakeAmount = _submissions[winningSubmissionFid].totalStakeAmount;
        
        return (totalStakerReward * stakeAmount) / totalStakeAmount;
    }

    function getTimeRemaining() external view returns (uint256 timeLeft, bool hasEnded) {
        if (block.timestamp >= config.votingDeadline) {
            return (0, true);
        }
        return (config.votingDeadline - block.timestamp, false);
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
    
    // Iterate over actual submission FIDs
    for (uint256 i = 0; i < _allSubmissionFids.length; i++) {
        uint256 submissionFid = _allSubmissionFids[i];
        uint256[] memory fids = _submissionStakerFids[submissionFid];
        
        // Refund stakes
        for (uint256 j = 0; j < fids.length; j++) {
            uint256 fid = fids[j];
            uint256 stakeAmount = _submissionStakes[submissionFid][fid];
            address staker = _fidToAddress[submissionFid][fid];
            
            if (stakeAmount > 0 && staker != address(0)) {
                IERC20(config.depeToken).safeTransfer(staker, stakeAmount);
            }
        }
        
        // Refund votes
        address[] storage voters = _submissionVoters[submissionFid];
        for (uint256 j = 0; j < voters.length; j++) {
            address voter = voters[j];
            uint256 voteAmount = _submissionVotes[submissionFid][voter];
            
            if (voteAmount > 0) {
                IERC20(config.depeToken).safeTransfer(voter, voteAmount);
            }
        }
    }
}
}