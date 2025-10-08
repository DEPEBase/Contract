// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

/**
 * @title ContestInstance
 * @dev Contest contract with platform validation and automatic phase management
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
    uint256 private constant MIN_VOTE_USD = 1e18; // $1 USD
    uint256 private constant MAX_VOTE_USD = 10e18; // $10 USD
    uint256 private constant MAX_STAKE_PER_USER_PERCENT = 25;
    uint256 private constant BASIS_POINTS = 10000;
    
    uint256 private constant MEME_WINNER_PERCENT = 10000; // 100%
    uint256 private constant CONTEST_CREATOR_PERCENT = 2000; // 20%
    uint256 private constant STAKERS_PERCENT = 7000; // 70%

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
        uint256 minEntriesRequired;
        uint256 submissionDeadline;
        uint256 votingDeadline;
        uint256 depePriceUSD;
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

    struct Stake {
        address staker;
        uint256 fid;
        uint256 amount;
        uint256 timestamp;
        bool claimed;
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
    mapping(address => uint256) private _userTotalVotes;
    
    mapping(uint256 => Stake[]) private _submissionStakes;
    mapping(address => mapping(uint256 => uint256)) private _userStakeAmount;
    mapping(address => uint256[]) private _userStakes;
    mapping(address => uint256) private _userTotalStakes;
    
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
    event RewardsDistributed(uint256 indexed submissionId, uint256 memeWinnerReward, uint256 contestCreatorReward, uint256 stakersReward);
    event ContestFailed(string reason);
    event DEPEPriceUpdated(uint256 oldPrice, uint256 newPrice);

    // =============================================================
    //                           ERRORS
    // =============================================================
    
    error InvalidAddress();
    error InvalidAmount();
    error InvalidDuration();
    error InvalidString();
    error InvalidPhase();
    error DeadlinePassed();
    error ContestNotEnded();
    error SubmissionNotExists();
    error AlreadyVoted();
    error VoteAmountInvalid();
    error RewardsAlreadyDistributed();
    error MaxStakeExceeded();
    error InvalidFID();
    error InvalidPlatformSignature();
    error SignatureAlreadyUsed();

    // =============================================================
    //                          MODIFIERS
    // =============================================================
    
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
        uint256 _depePriceUSD
    ) Ownable(_creator) {
        if (_depeToken == address(0) || _creator == address(0) || _platformWallet == address(0)) {
            revert InvalidAddress();
        }
        if (_memePoolAmount == 0 || _minEntriesRequired < 2) revert InvalidAmount();
        if (_duration < 1 hours || _duration > 7 days) revert InvalidDuration();
        if (bytes(_title).length == 0 || bytes(_title).length > MAX_STRING_LENGTH) revert InvalidString();
        if (_depePriceUSD == 0) revert InvalidAmount();

        config = ContestConfig({
            depeToken: _depeToken,
            creator: _creator,
            platformWallet: _platformWallet,
            memePoolAmount: _memePoolAmount,
            minEntriesRequired: _minEntriesRequired,
            submissionDeadline: block.timestamp + (_duration * 60 / 100),
            votingDeadline: block.timestamp + _duration,
            depePriceUSD: _depePriceUSD
        });

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

        // Verify signature
        bytes32 messageHash = keccak256(abi.encodePacked(
            address(this), memeUrl, memeType, submissionTitle, msg.sender, fid, block.timestamp
        ));
        _validateSignature(messageHash, platformSignature);

        // Create submission
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

        uint256 minVoteDEPE = (MIN_VOTE_USD * 1e18) / config.depePriceUSD;
        uint256 maxVoteDEPE = (MAX_VOTE_USD * 1e18) / config.depePriceUSD;
        
        if (voteAmount < minVoteDEPE || voteAmount > maxVoteDEPE) {
            revert VoteAmountInvalid();
        }

        // Verify signature
        bytes32 messageHash = keccak256(abi.encodePacked(
            address(this), submissionId, voteAmount, msg.sender, fid, block.timestamp
        ));
        _validateSignature(messageHash, platformSignature);

        IERC20(config.depeToken).safeTransferFrom(msg.sender, address(this), voteAmount);

        _submissionVotes[submissionId][msg.sender] = voteAmount;
        _userTotalVotes[msg.sender] += voteAmount;
        state.totalVotingPool += voteAmount;
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
    ) external onlyDuringSubmission validSubmission(submissionId) nonReentrant whenNotPaused {
        if (stakeAmount == 0) revert InvalidAmount();
        if (fid == 0) revert InvalidFID();

        uint256 maxStakePerUser = (config.memePoolAmount * MAX_STAKE_PER_USER_PERCENT) / 100;
        if (_userTotalStakes[msg.sender] + stakeAmount > maxStakePerUser) {
            revert MaxStakeExceeded();
        }

        // Verify signature
        bytes32 messageHash = keccak256(abi.encodePacked(
            address(this), submissionId, stakeAmount, msg.sender, fid, block.timestamp
        ));
        _validateSignature(messageHash, platformSignature);

        IERC20(config.depeToken).safeTransferFrom(msg.sender, address(this), stakeAmount);

        _submissionStakes[submissionId].push(Stake({
            staker: msg.sender,
            fid: fid,
            amount: stakeAmount,
            timestamp: block.timestamp,
            claimed: false
        }));

        _userStakeAmount[msg.sender][submissionId] += stakeAmount;
        _userStakes[msg.sender].push(submissionId);
        _userTotalStakes[msg.sender] += stakeAmount;
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

        // Find winner
        uint256 maxVoteAmount;
        uint256 maxVoteCount;
        uint256 winnerId;
        bool foundWinner;

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

    // =============================================================
    //                    REWARD DISTRIBUTION
    // =============================================================
    
    function distributeRewards() external onlyAfterVoting nonReentrant {
        if (state.rewardsDistributed) revert RewardsAlreadyDistributed();

        state.rewardsDistributed = true;

        uint256 memeWinnerReward = config.memePoolAmount;
        uint256 contestCreatorReward = (state.totalVotingPool * CONTEST_CREATOR_PERCENT) / BASIS_POINTS;
        uint256 stakersReward = state.totalVotingPool - contestCreatorReward;

        if (memeWinnerReward > 0) {
            IERC20(config.depeToken).safeTransfer(
                _submissions[state.winningSubmissionId].submitter,
                memeWinnerReward
            );
        }

        if (contestCreatorReward > 0) {
            IERC20(config.depeToken).safeTransfer(config.creator, contestCreatorReward);
        }

        if (stakersReward > 0 && state.totalStakingPool > 0) {
            _distributeStakingRewards(stakersReward);
        }

        emit RewardsDistributed(state.winningSubmissionId, memeWinnerReward, contestCreatorReward, stakersReward);
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

    // =============================================================
    //                      ADMIN FUNCTIONS
    // =============================================================
    
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

    function getSubmission(uint256 submissionId) external view validSubmission(submissionId) returns (Submission memory) {
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
            
            address[] storage voters = _submissionVoters[submissionId];
            for (uint256 i = 0; i < voters.length; ) {
                address voter = voters[i];
                uint256 voteAmount = _submissionVotes[submissionId][voter];
                
                if (voteAmount > 0) {
                    IERC20(config.depeToken).safeTransfer(voter, voteAmount);
                    _submissionVotes[submissionId][voter] = 0;
                }
                unchecked { ++i; }
            }
            unchecked { ++submissionId; }
        }
    }
}