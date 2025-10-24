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
 * @dev Contest contract with dual duration and automatic phase transitions
 * @author DEPE Team
 * @notice Refactored with submission and contest deadlines for automatic phase management
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
        uint256 submissionDeadline;  // When submissions end
        uint256 contestDeadline;     // When voting/staking ends
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
    
    mapping(uint256 => Submission) private _submissions;
    mapping(address => bool) private _hasSubmitted;
    mapping(address => uint256) private _userSubmissionFid;
    uint256[] private _allSubmissionFids;
    
    mapping(uint256 => address[]) private _submissionVoters;
    mapping(uint256 => mapping(address => uint256)) private _submissionVotes;
    mapping(address => bool) private _hasVoted;
    
    mapping(uint256 => mapping(uint256 => uint256)) private _submissionStakes;
    mapping(uint256 => mapping(uint256 => bool)) private _stakesClaimed;
    mapping(uint256 => uint256[]) private _submissionStakerFids;
    mapping(uint256 => mapping(uint256 => address)) private _fidToAddress;
    mapping(uint256 => uint256) private _totalStakesByFid;
    
    mapping(bytes32 => bool) public usedSignatures;

    address[] private _allVoters;                    // Track all unique voters
    address[] private _allStakerAddresses;          // Track all unique staker addresses
    uint256[] private _allStakerFids;               // Track all unique staker FIDs
    mapping(address => bool) private _isStaker;      // Quick staker check
    mapping(uint256 => bool) private _fidHasStaked;  // Quick FID stake check
    
    // ✅ NEW: Pull-based refund system
    mapping(address => uint256) private _pendingRefunds;
    bool private _refundMode;

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
    event AllStakesRefunded(uint256 totalRefunded, string reason);
    event RefundClaimed(address indexed user, uint256 amount);
    event RefundModeActivated(string reason);

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
    error NoRefundAvailable();

    // =============================================================
    //                          MODIFIERS
    // =============================================================
    
    modifier onlyDuringSubmission() {
        if (block.timestamp >= config.submissionDeadline) revert InvalidPhase();
        if (state.phase == ContestPhase.FAILED) revert InvalidPhase();
        _;
    }

    modifier onlyDuringVoting() {
        if (block.timestamp < config.submissionDeadline) revert InvalidPhase();
        if (block.timestamp >= config.contestDeadline) revert InvalidPhase();
        if (state.phase == ContestPhase.FAILED || state.phase == ContestPhase.ENDED) revert InvalidPhase();
        _;
    }

    modifier onlyAfterContest() {
        if (block.timestamp < config.contestDeadline) revert InvalidPhase();
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
        uint256 _submissionDuration,
        uint256 _contestDuration,
        string memory _title,
        string memory _description,
        uint256 _maxVoteAmount,
        uint256 _minVoteAmount
    ) Ownable(_creator) {
        if (_depeToken == address(0) || _creator == address(0) || _platformWallet == address(0)) {
            revert InvalidAddress();
        }
        if (_memePoolAmount == 0 || _minEntriesRequired < 2) revert InvalidAmount();
        
        // Validate both durations
        if (_submissionDuration < 1 hours) revert InvalidDuration();
        if (_contestDuration < 1 hours || _contestDuration > 30 days) revert InvalidDuration();
        if (_submissionDuration >= _contestDuration) revert InvalidDuration();
        
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
            submissionDeadline: block.timestamp + _submissionDuration,
            contestDeadline: block.timestamp + _contestDuration
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
    //                   AUTOMATIC PHASE DETECTION
    // =============================================================
    
    /**
     * @dev Get current phase based on timestamps
     * @return current The current computed phase
     */
    function getCurrentPhase() public view returns (ContestPhase current) {
        // Respect manually set FAILED or ENDED states
        if (state.phase == ContestPhase.FAILED || state.phase == ContestPhase.ENDED) {
            return state.phase;
        }
        
        // Automatic determination based on time
        if (block.timestamp < config.submissionDeadline) {
            return ContestPhase.SUBMISSION;
        } else if (block.timestamp < config.contestDeadline) {
            return ContestPhase.VOTING;
        } else {
            return ContestPhase.ENDED;
        }
    }

    /**
     * @dev Check if contest is in submission phase
     */
    function isSubmissionPhase() public view returns (bool) {
        return getCurrentPhase() == ContestPhase.SUBMISSION;
    }

    /**
     * @dev Check if contest is in voting phase
     */
    function isVotingPhase() public view returns (bool) {
        return getCurrentPhase() == ContestPhase.VOTING;
    }

    /**
     * @dev Check if contest has ended
     */
    function isEnded() public view returns (bool) {
        ContestPhase current = getCurrentPhase();
        return current == ContestPhase.ENDED || current == ContestPhase.FAILED;
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
        
        // No auto-transition - handled by timestamps
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
        
        // ✅ OPTIMIZED: Track voter globally on first vote
        if (!_hasVoted[msg.sender]) {
            _hasVoted[msg.sender] = true;
            _allVoters.push(msg.sender);
        }
        
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

        // ✅ OPTIMIZED: Track staker globally on first stake
        if (!_isStaker[msg.sender]) {
            _isStaker[msg.sender] = true;
            _allStakerAddresses.push(msg.sender);
        }
        
        if (!_fidHasStaked[fid]) {
            _fidHasStaked[fid] = true;
            _allStakerFids.push(fid);
        }

        _totalStakesByFid[fid] = newTotalStake;
        
        state.totalStakingPool += stakeAmount;
        _submissions[submissionFid].totalStakeAmount += stakeAmount;

        emit StakePlaced(submissionFid, fid, stakeAmount);
    }

    // =============================================================
    //                     PHASE MANAGEMENT
    // =============================================================
    
    /**
     * @dev Manually fail contest if insufficient entries
     * @notice Can only be called after submission deadline
     */
    function failContestIfInsufficientEntries() external onlyOwner {
        if (block.timestamp < config.submissionDeadline) revert InvalidPhase();
        if (state.phase == ContestPhase.FAILED || state.phase == ContestPhase.ENDED) revert InvalidPhase();

        if (state.submissionCount < config.minEntriesRequired) {
            ContestPhase oldPhase = state.phase;
            state.phase = ContestPhase.FAILED;
            emit PhaseChanged(oldPhase, ContestPhase.FAILED);
            emit ContestFailed("Not enough submissions");
            _refundMemePool();
        }
    }

    // =============================================================
    //                    REWARD DISTRIBUTION
    // =============================================================
    
    function claimMemeWinnerReward() external onlyAfterContest nonReentrant {
        if (state.memeRewardClaimed) revert AlreadyClaimed();
        
        // Check if contest has enough submissions
        if (state.submissionCount < config.minEntriesRequired) {
            state.phase = ContestPhase.FAILED;
            state.memeRewardClaimed = true;
            emit ContestFailed("Not enough submissions");
            _refundMemePool();
            _refundAll();
            return;
        }

        ContestPhase oldPhase = state.phase;
        state.memeRewardClaimed = true;

        uint256 winnerIndex = type(uint256).max;
        uint256 winnerFid = 0;
        uint256 highestScore = 0;
        uint256 highestVotes = 0;
        bool found = false;

        uint256 len = _allSubmissionFids.length;
        
        // ✅ OPTIMIZED: Cache array length
        for (uint256 i = 0; i < len; ) {
            uint256 fid = _allSubmissionFids[i];
            Submission storage s = _submissions[fid];

            uint256 scoreVotes = s.voteCount * ALPHA;
            uint256 scoreVoteAmount = (s.totalVoteAmount * BETA) / 1e18;

            uint256 finalScore = scoreVotes + scoreVoteAmount;

            bool takeWinner = false;
            if (finalScore > highestScore) {
                takeWinner = true;
            } else if (finalScore == highestScore) {
                if (s.voteCount > highestVotes) {
                    takeWinner = true;
                } else if (s.voteCount == highestVotes) {
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

        if (!found || highestScore == 0) {
            state.memeRewardClaimed = false;
            state.phase = ContestPhase.FAILED;
            emit PhaseChanged(oldPhase, ContestPhase.FAILED);
            emit ContestFailed("No valid votes or stakes received");
            _refundAll();
            return;
        }

        // Check if winner has stakers
        uint256 totalStakeAmount = _submissions[winnerFid].totalStakeAmount;
        if (totalStakeAmount == 0 && state.totalStakingPool > 0) {
            _refundAllStakesAndVotes();
        }

        state.winningSubmissionFid = winnerFid;
        state.phase = ContestPhase.ENDED;

        emit WinnerDetermined(winnerFid, highestScore);
        emit PhaseChanged(oldPhase, ContestPhase.ENDED);

        address winnerAddr = _submissions[winnerFid].submitter;
        if (msg.sender != winnerAddr) revert NotAuthorized();

        IERC20(config.depeToken).safeTransfer(winnerAddr, config.memePoolAmount);

        emit MemeRewardClaimed(winnerFid, config.memePoolAmount);
    }


    function claimCreatorReward() external onlyOwner onlyAfterContest nonReentrant {
        if (state.creatorRewardClaimed) revert AlreadyClaimed();
        if (state.phase != ContestPhase.ENDED) revert InvalidPhase();
        
        state.creatorRewardClaimed = true;
        uint256 creatorReward = (state.totalStakingPool * CONTEST_CREATOR_PERCENT) / BASIS_POINTS;
        
        if (creatorReward > 0) {
            IERC20(config.depeToken).safeTransfer(config.creator, creatorReward);
        }
        
        emit CreatorRewardClaimed(creatorReward);
    }

    function claimStakerReward(uint256 fid) external onlyAfterContest nonReentrant {
        if (state.phase != ContestPhase.ENDED) revert InvalidPhase();
        
        uint256 winningSubmissionFid = state.winningSubmissionFid;
        uint256 stakeAmount = _submissionStakes[winningSubmissionFid][fid];
        
        if (stakeAmount == 0) revert NoStakeToClaim();
        if (_fidToAddress[winningSubmissionFid][fid] != msg.sender) revert NotYourStake();
        if (_stakesClaimed[winningSubmissionFid][fid]) revert AlreadyClaimed();
        
        _stakesClaimed[winningSubmissionFid][fid] = true;
        
        uint256 totalStakerReward = (state.totalStakingPool * STAKERS_PERCENT) / BASIS_POINTS;
        uint256 totalStakeAmount = _submissions[winningSubmissionFid].totalStakeAmount;
        
        if (totalStakeAmount == 0) revert NoStakeToClaim();
        
        uint256 stakerReward = (totalStakerReward * stakeAmount) / totalStakeAmount;
        
        IERC20(config.depeToken).safeTransfer(msg.sender, stakerReward);
        emit StakerRewardClaimed(fid, stakerReward);
    }

    /**
     * @dev Users claim their refunds (pull pattern - gas efficient)
     */
    function claimRefund() external nonReentrant {
        if (!_refundMode) revert NoRefundAvailable();
        
        uint256 amount = _pendingRefunds[msg.sender];
        if (amount == 0) revert NoRefundAvailable();
        
        _pendingRefunds[msg.sender] = 0;
        IERC20(config.depeToken).safeTransfer(msg.sender, amount);
        
        emit RefundClaimed(msg.sender, amount);
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
        uint256 submissionDeadline,
        uint256 contestDeadline,
        uint256 winningSubmissionFid
    ) {
        return (
            config.creator,
            config.memePoolAmount,
            state.totalStakingPool,
            config.minEntriesRequired,
            state.submissionCount,
            getCurrentPhase(),
            config.maxVoteAmount,
            config.minVoteAmount,
            config.submissionDeadline,
            config.contestDeadline,
            state.winningSubmissionFid
        );
    }

    function getSubmission(uint256 submissionFid) external view validSubmission(submissionFid) returns (Submission memory) {
        return _submissions[submissionFid];
    }

    function getAllSubmissions() external view returns (Submission[] memory) {
        uint256 length = _allSubmissionFids.length;
        Submission[] memory submissions = new Submission[](length);
        
        for (uint256 i = 0; i < length; ) {
            submissions[i] = _submissions[_allSubmissionFids[i]];
            unchecked { ++i; }
        }
        
        return submissions;
    }

    /**
     * @dev Check pending refund for an address
     */
    function getPendingRefund(address user) external view returns (uint256) {
        return _pendingRefunds[user];
    }

    /**
     * @dev Check if refund mode is active
     */
    function isRefundMode() external view returns (bool) {
        return _refundMode;
    }

    /**
     * @dev Get voter count - O(1)
     */
    function getVoterCount() external view returns (uint256) {
        return _allVoters.length;
    }

    /**
     * @dev Get staker count - O(1)
     */
    function getStakerCount() external view returns (uint256) {
        return _allStakerFids.length;
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

    function getTotalStakesByFid(uint256 fid) external view returns (uint256) {
        return _totalStakesByFid[fid];
    }

    function getClaimableStakerReward(uint256 fid) external view returns (uint256) {
        if (state.phase != ContestPhase.ENDED) return 0;
        
        uint256 winningSubmissionFid = state.winningSubmissionFid;
        uint256 stakeAmount = _submissionStakes[winningSubmissionFid][fid];
        
        if (stakeAmount == 0 || _stakesClaimed[winningSubmissionFid][fid]) return 0;
        
        uint256 totalStakerReward = (state.totalStakingPool * STAKERS_PERCENT) / BASIS_POINTS;
        uint256 totalStakeAmount = _submissions[winningSubmissionFid].totalStakeAmount;
        
        if (totalStakeAmount == 0) return 0;
        
        return (totalStakerReward * stakeAmount) / totalStakeAmount;
    }

    /**
     * @dev Get time remaining for current phase
     */
    function getTimeRemaining() external view returns (
        uint256 timeLeft,
        string memory currentPhaseName
    ) {
        ContestPhase phase = getCurrentPhase();
        
        if (phase == ContestPhase.SUBMISSION) {
            if (block.timestamp >= config.submissionDeadline) {
                return (0, "VOTING");
            }
            return (config.submissionDeadline - block.timestamp, "SUBMISSION");
        } else if (phase == ContestPhase.VOTING) {
            if (block.timestamp >= config.contestDeadline) {
                return (0, "ENDED");
            }
            return (config.contestDeadline - block.timestamp, "VOTING");
        } else if (phase == ContestPhase.ENDED) {
            return (0, "ENDED");
        } else {
            return (0, "FAILED");
        }
    }

    /**
     * @dev Get both deadlines and time remaining
     */
    function getDeadlines() external view returns (
        uint256 submissionDeadline,
        uint256 contestDeadline,
        uint256 submissionTimeLeft,
        uint256 votingTimeLeft
    ) {
        submissionDeadline = config.submissionDeadline;
        contestDeadline = config.contestDeadline;
        
        if (block.timestamp < config.submissionDeadline) {
            submissionTimeLeft = config.submissionDeadline - block.timestamp;
            votingTimeLeft = config.contestDeadline - block.timestamp;
        } else if (block.timestamp < config.contestDeadline) {
            submissionTimeLeft = 0;
            votingTimeLeft = config.contestDeadline - block.timestamp;
        } else {
            submissionTimeLeft = 0;
            votingTimeLeft = 0;
        }
        
        return (submissionDeadline, contestDeadline, submissionTimeLeft, votingTimeLeft);
    }

    /**
     * @dev Get voting duration (time between submission and contest deadlines)
     */
    function getVotingDuration() external view returns (uint256) {
        return config.contestDeadline - config.submissionDeadline;
    }

    /**
     * @dev Get all voters for a specific submission with their vote amounts
     * @param submissionFid The submission FID
     * @return voters Array of voter addresses
     * @return amounts Array of vote amounts corresponding to each voter
     */
    function getSubmissionVoters(uint256 submissionFid) 
        external 
        view 
        validSubmission(submissionFid) 
        returns (address[] memory voters, uint256[] memory amounts) 
    {
        address[] memory voterAddresses = _submissionVoters[submissionFid];
        uint256 length = voterAddresses.length;
        uint256[] memory voteAmounts = new uint256[](length);
        
        for (uint256 i = 0; i < length; ) {
            voteAmounts[i] = _submissionVotes[submissionFid][voterAddresses[i]];
            unchecked { ++i; }
        }
        
        return (voterAddresses, voteAmounts);
    }

    /**
     * @dev Get all stakers for a specific submission with their stake amounts
     * @param submissionFid The submission FID
     * @return fids Array of staker FIDs
     * @return addresses Array of staker addresses
     * @return amounts Array of stake amounts corresponding to each staker
     */
    function getSubmissionStakers(uint256 submissionFid) 
        external 
        view 
        validSubmission(submissionFid) 
        returns (
            uint256[] memory fids, 
            address[] memory addresses, 
            uint256[] memory amounts
        ) 
    {
        uint256[] memory stakerFids = _submissionStakerFids[submissionFid];
        uint256 length = stakerFids.length;
        address[] memory stakerAddresses = new address[](length);
        uint256[] memory stakeAmounts = new uint256[](length);
        
        for (uint256 i = 0; i < length; ) {
            uint256 fid = stakerFids[i];
            stakerAddresses[i] = _fidToAddress[submissionFid][fid];
            stakeAmounts[i] = _submissionStakes[submissionFid][fid];
            unchecked { ++i; }
        }
        
        return (stakerFids, stakerAddresses, stakeAmounts);
    }

    /**
     * @dev Get all voters across all submissions in the contest
     * @return allVoters Array of unique voter addresses
     * @return totalVoted Total amount voted by each voter across all submissions
     */
    function getAllVoters() external view returns (
        address[] memory allVoters,
        uint256[] memory totalVoted
    ) {
        uint256 count = _allVoters.length;
        allVoters = new address[](count);
        totalVoted = new uint256[](count);
        
        uint256 submissionCount = _allSubmissionFids.length;
        
        for (uint256 i = 0; i < count; ) {
            address voter = _allVoters[i];
            allVoters[i] = voter;
            
            // Calculate total voted by this voter
            for (uint256 j = 0; j < submissionCount; ) {
                totalVoted[i] += _submissionVotes[_allSubmissionFids[j]][voter];
                unchecked { ++j; }
            }
            unchecked { ++i; }
        }
        
        return (allVoters, totalVoted);
    }

    /**
     * @dev Get all stakers across all submissions in the contest
     * @return allFids Array of unique staker FIDs
     * @return allAddresses Array of staker addresses corresponding to FIDs
     * @return totalStaked Total amount staked by each FID across all submissions
     */
    function getAllStakers() external view returns (
        uint256[] memory allFids,
        address[] memory allAddresses,
        uint256[] memory totalStaked
    ) {
        uint256 count = _allStakerFids.length;
        allFids = new uint256[](count);
        allAddresses = new address[](count);
        totalStaked = new uint256[](count);
        
        for (uint256 i = 0; i < count; ) {
            uint256 fid = _allStakerFids[i];
            allFids[i] = fid;
            totalStaked[i] = _totalStakesByFid[fid];
            
            // Get address from first submission where this FID staked
            uint256 submissionCount = _allSubmissionFids.length;
            for (uint256 j = 0; j < submissionCount; ) {
                uint256 submissionFid = _allSubmissionFids[j];
                if (_submissionStakes[submissionFid][fid] > 0) {
                    allAddresses[i] = _fidToAddress[submissionFid][fid];
                    break;
                }
                unchecked { ++j; }
            }
            
            unchecked { ++i; }
        }
        
        return (allFids, allAddresses, totalStaked);
    }

    /**
     * @dev Get voter info for a specific address across all submissions
     * @param voter The voter address
     * @return submissionFids Array of submission FIDs voted on
     * @return amounts Array of amounts voted on each submission
     * @return totalAmount Total amount voted across all submissions
     */
    function getVoterInfo(address voter) external view returns (
        uint256[] memory submissionFids,
        uint256[] memory amounts,
        uint256 totalAmount
    ) {
        // Count how many submissions this voter voted on
        uint256 voteCount = 0;
        uint256 submissionCount = _allSubmissionFids.length;
        
        for (uint256 i = 0; i < submissionCount; ) {
            uint256 fid = _allSubmissionFids[i];
            if (_submissionVotes[fid][voter] > 0) {
                unchecked { ++voteCount; }
            }
            unchecked { ++i; }
        }
        
        // Create arrays
        submissionFids = new uint256[](voteCount);
        amounts = new uint256[](voteCount);
        uint256 index = 0;
        
        for (uint256 i = 0; i < submissionCount; ) {
            uint256 fid = _allSubmissionFids[i];
            uint256 amount = _submissionVotes[fid][voter];
            
            if (amount > 0) {
                submissionFids[index] = fid;
                amounts[index] = amount;
                totalAmount += amount;
                unchecked { ++index; }
            }
            unchecked { ++i; }
        }
        
        return (submissionFids, amounts, totalAmount);
    }

    /**
     * @dev Get staker info for a specific FID across all submissions
     * @param fid The staker FID
     * @return submissionFids Array of submission FIDs staked on
     * @return amounts Array of amounts staked on each submission
     * @return totalAmount Total amount staked across all submissions
     * @return stakerAddress Address associated with this FID
     */
    function getStakerInfo(uint256 fid) external view returns (
        uint256[] memory submissionFids,
        uint256[] memory amounts,
        uint256 totalAmount,
        address stakerAddress
    ) {
        // Count how many submissions this FID staked on
        uint256 stakeCount = 0;
        uint256 submissionCount = _allSubmissionFids.length;
        
        for (uint256 i = 0; i < submissionCount; ) {
            uint256 submissionFid = _allSubmissionFids[i];
            if (_submissionStakes[submissionFid][fid] > 0) {
                unchecked { ++stakeCount; }
            }
            unchecked { ++i; }
        }
        
        // Create arrays
        submissionFids = new uint256[](stakeCount);
        amounts = new uint256[](stakeCount);
        uint256 index = 0;
        
        for (uint256 i = 0; i < submissionCount; ) {
            uint256 submissionFid = _allSubmissionFids[i];
            uint256 amount = _submissionStakes[submissionFid][fid];
            
            if (amount > 0) {
                submissionFids[index] = submissionFid;
                amounts[index] = amount;
                totalAmount += amount;
                
                if (stakerAddress == address(0)) {
                    stakerAddress = _fidToAddress[submissionFid][fid];
                }
                
                unchecked { ++index; }
            }
            unchecked { ++i; }
        }
        
        return (submissionFids, amounts, totalAmount, stakerAddress);
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

    // =============================================================
    //               PULL-BASED REFUND SYSTEM
    // =============================================================

    /**
     * @dev Calculate and store refunds instead of sending (gas-efficient)
     */
    function _refundAllStakesAndVotes() private {
        _refundMode = true;
        emit RefundModeActivated("Winner has no stakers");
        
        uint256 submissionCount = _allSubmissionFids.length;
        
        for (uint256 i = 0; i < submissionCount; ) {
            uint256 submissionFid = _allSubmissionFids[i];
            
            // Calculate stake refunds
            uint256[] memory fids = _submissionStakerFids[submissionFid];
            uint256 fidsLength = fids.length;
            
            for (uint256 j = 0; j < fidsLength; ) {
                uint256 fid = fids[j];
                uint256 stakeAmount = _submissionStakes[submissionFid][fid];
                address staker = _fidToAddress[submissionFid][fid];
                
                if (stakeAmount > 0 && staker != address(0)) {
                    _pendingRefunds[staker] += stakeAmount;
                }
                unchecked { ++j; }
            }
            
            // Calculate vote refunds
            address[] storage voters = _submissionVoters[submissionFid];
            uint256 votersLength = voters.length;
            
            for (uint256 j = 0; j < votersLength; ) {
                address voter = voters[j];
                uint256 voteAmount = _submissionVotes[submissionFid][voter];
                
                if (voteAmount > 0) {
                    _pendingRefunds[voter] += voteAmount;
                }
                unchecked { ++j; }
            }
            
            unchecked { ++i; }
        }
    }

    /**
     * @dev Refund all - OPTIMIZED with pull pattern
     */
    function _refundAll() private {
        _refundMemePool();
        _refundMode = true;
        emit RefundModeActivated("Contest failed");
        
        uint256 submissionCount = _allSubmissionFids.length;
        
        for (uint256 i = 0; i < submissionCount; ) {
            uint256 submissionFid = _allSubmissionFids[i];
            
            // Calculate stake refunds
            uint256[] memory fids = _submissionStakerFids[submissionFid];
            uint256 fidsLength = fids.length;
            
            for (uint256 j = 0; j < fidsLength; ) {
                uint256 fid = fids[j];
                uint256 stakeAmount = _submissionStakes[submissionFid][fid];
                address staker = _fidToAddress[submissionFid][fid];
                
                if (stakeAmount > 0 && staker != address(0)) {
                    _pendingRefunds[staker] += stakeAmount;
                }
                unchecked { ++j; }
            }
            
            // Calculate vote refunds
            address[] storage voters = _submissionVoters[submissionFid];
            uint256 votersLength = voters.length;
            
            for (uint256 j = 0; j < votersLength; ) {
                address voter = voters[j];
                uint256 voteAmount = _submissionVotes[submissionFid][voter];
                
                if (voteAmount > 0) {
                    _pendingRefunds[voter] += voteAmount;
                }
                unchecked { ++j; }
                }
            
                unchecked { ++i; }
        }
    }
}