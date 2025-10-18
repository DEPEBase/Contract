// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/**
 * @title ContestValidation
 * @dev Library to extract validation logic from ContestFactory
 * @notice Reduces ContestFactory contract size by ~2-3KB
 */
library ContestValidation {
    // =============================================================
    //                           ERRORS
    // =============================================================
    
    error InvalidAddress();
    error InvalidAmount();
    error InvalidDuration();
    error PoolBelowMinimum();

    // =============================================================
    //                          CONSTANTS
    // =============================================================
    
    uint256 constant MAX_CONTEST_DURATION = 30 days;
    uint256 constant MIN_CONTEST_DURATION = 1 hours;
    uint256 constant MIN_SUBMISSION_DURATION = 1 hours;
    uint256 constant MAX_SUBMISSION_DURATION = 7 days;
    uint256 constant MAX_STRING_LENGTH = 500;
    uint256 constant MAX_TITLE_LENGTH = 100;
    uint256 constant BASIS_POINTS = 10000;
    uint256 constant PLATFORM_FEE_BPS = 1000; // 10%

    // =============================================================
    //                    VALIDATION FUNCTIONS
    // =============================================================

    /**
     * @dev Validate address parameters
     */
    function validateAddresses(
        address depeToken,
        address creator,
        address platformWallet
    ) internal pure {
        if (depeToken == address(0) || creator == address(0) || platformWallet == address(0)) {
            revert InvalidAddress();
        }
    }

    /**
     * @dev Validate and calculate pool amounts
     * @return platformFee The platform fee amount
     * @return netAmount The net pool amount after fee
     */
    function validatePoolAmount(
        uint256 totalPoolAmount,
        uint256 minPoolDEPE
    ) internal pure returns (uint256 platformFee, uint256 netAmount) {
        if (totalPoolAmount < minPoolDEPE) revert PoolBelowMinimum();
        
        platformFee = (totalPoolAmount * PLATFORM_FEE_BPS) / BASIS_POINTS;
        netAmount = totalPoolAmount - platformFee;
        
        // Ensure net amount is still meaningful (at least 90% of minimum)
        if (netAmount < (minPoolDEPE * 90) / 100) revert PoolBelowMinimum();
        
        return (platformFee, netAmount);
    }

    /**
     * @dev Validate duration parameters
     */
    function validateDurations(
        uint256 submissionDuration,
        uint256 contestDuration
    ) internal pure {
        // Submission duration checks
        if (submissionDuration < MIN_SUBMISSION_DURATION) revert InvalidDuration();
        if (submissionDuration > MAX_SUBMISSION_DURATION) revert InvalidDuration();
        
        // Contest duration checks
        if (contestDuration < MIN_CONTEST_DURATION) revert InvalidDuration();
        if (contestDuration > MAX_CONTEST_DURATION) revert InvalidDuration();
        
        // Submission must be shorter than total contest
        if (submissionDuration >= contestDuration) revert InvalidDuration();
        
        // Ensure voting phase is at least 1 hour
        uint256 votingDuration = contestDuration - submissionDuration;
        if (votingDuration < 1 hours) revert InvalidDuration();
    }

    /**
     * @dev Validate vote amounts
     */
    function validateVoteAmounts(
        uint256 maxVoteAmount,
        uint256 minVoteAmount
    ) internal pure {
        if (maxVoteAmount == 0) revert InvalidAmount();
        if (minVoteAmount == 0) revert InvalidAmount();
        if (minVoteAmount > maxVoteAmount) revert InvalidAmount();
    }


    /**
     * @dev Calculate voting duration
     */
    function calculateVotingDuration(
        uint256 submissionDuration,
        uint256 contestDuration
    ) internal pure returns (uint256) {
        return contestDuration - submissionDuration;
    }
}