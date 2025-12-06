// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

interface IERC20 {
    function transfer(address recipient, uint256 amount) external returns (bool);
}

/// @title PMAirdrop - Airdrop with tasks completion before claim, fees charged once at final claim
/// @notice Users visit tasks (no tokens given per task), then claim all tokens once after finishing all tasks.
/// @dev Uses ReentrancyGuard to protect ETH transfer functions. Fees paid once on final claim.
contract PMAirdrop is Ownable, ReentrancyGuard {
    IERC20 public immutable pmToken;

    uint256 public constant TOTAL_TASKS = 9;  // fixed total tasks

    uint256 public maxClaimable;
    uint256 public totalClaimed;

    uint256 public claimFeeBNB = 0.0005 ether;  
    uint256 public networkFeeBNB = 0.0005 ether;

    uint256 public totalReward; // total reward after completing all tasks

    address public feeCollector;

    // User => taskId => visited flag
    mapping(address => mapping(uint256 => bool)) private _taskVisited;

    // User => claimed flag
    mapping(address => bool) private _hasClaimed;

    // EVENTS
    event TaskVisited(address indexed user, uint256 indexed taskId);
    event RewardClaimed(address indexed user, uint256 amount);
    event FeesPaid(address indexed user, uint256 amount);
    event FeesUpdated(uint256 claimFeeBNB, uint256 networkFeeBNB);
    event MaxClaimableUpdated(uint256 maxClaimable);
    event TotalRewardUpdated(uint256 totalReward);
    event FeeCollectorUpdated(address indexed feeCollector);

    // ERRORS for gas optimization & clarity
    error InvalidTaskId(uint256 taskId);
    error TaskAlreadyVisited(uint256 taskId);
    error AlreadyClaimed();
    error NotAllTasksCompleted();
    error InsufficientFee(uint256 required, uint256 sent);
    error MaxClaimableExceeded(uint256 totalClaimed, uint256 maxClaimable);
    error TransferFailed();

    constructor(address _pmToken, uint256 _totalReward) Ownable(msg.sender) {
    require(_pmToken != address(0), "Zero token address");
    require(_totalReward > 0, "Total reward must be > 0");

    pmToken = IERC20(_pmToken);
    totalReward = _totalReward;
    feeCollector = msg.sender;
}


    /// @notice Mark a specific task as visited/completed (no tokens transferred)
    /// @param _taskId Task ID between 0 and TOTAL_TASKS-1
    function visitTask(uint256 _taskId) external {
        if (_taskId >= TOTAL_TASKS) revert InvalidTaskId(_taskId);
        if (_hasClaimed[msg.sender]) revert AlreadyClaimed();
        if (_taskVisited[msg.sender][_taskId]) revert TaskAlreadyVisited(_taskId);

        _taskVisited[msg.sender][_taskId] = true;
        emit TaskVisited(msg.sender, _taskId);
    }

    /// @notice Claim total reward after all tasks visited, paying fees once
    /// @dev Uses nonReentrant modifier for safety
    function claimReward() external payable nonReentrant {
        if (_hasClaimed[msg.sender]) revert AlreadyClaimed();
        if (totalClaimed + totalReward > maxClaimable) revert MaxClaimableExceeded(totalClaimed, maxClaimable);

        // Check all tasks visited
        for (uint256 i = 0; i < TOTAL_TASKS; i++) {
            if (!_taskVisited[msg.sender][i]) revert NotAllTasksCompleted();
        }

        uint256 totalFee = claimFeeBNB + networkFeeBNB;
        if (msg.value < totalFee) revert InsufficientFee(totalFee, msg.value);

        // Mark claimed BEFORE external calls (checks-effects-interactions pattern)
        _hasClaimed[msg.sender] = true;
        totalClaimed += totalReward;

        // Transfer tokens to user
        bool sent = pmToken.transfer(msg.sender, totalReward);
        if (!sent) revert TransferFailed();

        // Transfer fees to feeCollector
        (bool feeSent, ) = payable(feeCollector).call{value: totalFee}("");
        require(feeSent, "Fee transfer failed");

        // Refund extra BNB
        if (msg.value > totalFee) {
            (bool refundSent, ) = payable(msg.sender).call{value: msg.value - totalFee}("");
            require(refundSent, "Refund failed");
        }

        emit RewardClaimed(msg.sender, totalReward);
        emit FeesPaid(msg.sender, totalFee);
    }

    /// @notice Returns whether the user has visited a specific task
    /// @param user User address to query
    /// @param taskId Task ID between 0 and TOTAL_TASKS-1
    function hasVisitedTask(address user, uint256 taskId) external view returns (bool) {
        if (taskId >= TOTAL_TASKS) return false;
        return _taskVisited[user][taskId];
    }

    /// @notice Returns whether the user has claimed the reward
    /// @param user User address
    function hasClaimedReward(address user) external view returns (bool) {
        return _hasClaimed[user];
    }

    // ADMIN FUNCTIONS

    /// @notice Set flat claim fee (in wei)
    function setClaimFeeBNB(uint256 _fee) external onlyOwner {
        claimFeeBNB = _fee;
        emit FeesUpdated(claimFeeBNB, networkFeeBNB);
    }

    /// @notice Set flat network fee (in wei)
    function setNetworkFeeBNB(uint256 _fee) external onlyOwner {
        networkFeeBNB = _fee;
        emit FeesUpdated(claimFeeBNB, networkFeeBNB);
    }

    /// @notice Set max claimable tokens in total
    function setMaxClaimable(uint256 _max) external onlyOwner {
        maxClaimable = _max;
        emit MaxClaimableUpdated(_max);
    }

    /// @notice Set total reward amount for completing all tasks
    function setTotalReward(uint256 _totalReward) external onlyOwner {
        totalReward = _totalReward;
        emit TotalRewardUpdated(_totalReward);
    }

    /// @notice Set fee collector address
    function setFeeCollector(address _collector) external onlyOwner {
        require(_collector != address(0), "Zero fee collector");
        feeCollector = _collector;
        emit FeeCollectorUpdated(_collector);
    }

    /// @notice Withdraw leftover tokens (emergency use)
    /// @param amount Amount to withdraw
    function withdrawTokens(uint256 amount) external onlyOwner {
        bool sent = pmToken.transfer(msg.sender, amount);
        require(sent, "Token withdraw failed");
    }

    /// @notice Receive function to accept BNB fees
    receive() external payable {}

    /// @notice Fallback function
    fallback() external payable {}
}
