// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function decimals() external view returns (uint8);
}

abstract contract Ownable {
    address private _owner;
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    
    constructor() { _owner = msg.sender; emit OwnershipTransferred(address(0), msg.sender); }
    function owner() public view returns (address) { return _owner; }
    modifier onlyOwner() { require(_owner == msg.sender, "Not owner"); _; }
    function transferOwnership(address newOwner) public onlyOwner {
        require(newOwner != address(0), "Zero address");
        emit OwnershipTransferred(_owner, newOwner);
        _owner = newOwner;
    }
}

abstract contract ReentrancyGuard {
    uint256 private _status = 1;
    modifier nonReentrant() {
        require(_status != 2, "Reentrant call");
        _status = 2;
        _;
        _status = 1;
    }
}

abstract contract Pausable is Ownable {
    bool private _paused;
    event Paused(address account);
    event Unpaused(address account);
    
    function paused() public view returns (bool) { return _paused; }
    modifier whenNotPaused() { require(!_paused, "Paused"); _; }
    modifier whenPaused() { require(_paused, "Not paused"); _; }
    function pause() public onlyOwner whenNotPaused { _paused = true; emit Paused(msg.sender); }
    function unpause() public onlyOwner whenPaused { _paused = false; emit Unpaused(msg.sender); }
}

contract PMVault is Ownable, ReentrancyGuard, Pausable {
    IERC20 public immutable pmToken;
    IERC20 public immutable usdtToken;
    IERC20 public immutable usdcToken;
    
    uint256 public constant LOCK_PERIOD = 90 days;
    uint256 public constant MIN_CLAIM = 10 * 1e18; // 10 USDT/USDC (18 decimals)
    uint256 public constant WITHDRAWAL_TAX = 5; // 5%
    
    struct Plan {
        uint256 minStake;
        uint256 maxStake;
        uint256 dailyRate; // in basis points (40 = 0.4%)
        uint256 minPmHold;
        uint256 maxPoolSize;
        uint256 currentPoolSize;
        bool isActive;
    }
    
    struct Stake {
        uint256 planId;
        uint256 amount;
        address token; // USDT or USDC address
        uint256 startTime;
        uint256 endTime;
        uint256 claimedRewards;
        uint256 lastClaimTime;
        uint256 totalCompounded;
        bool autoCompound;
        bool isActive;
    }
    
    struct UserStats {
        uint256 totalCompounded;
        uint256 compoundCount;
    }
    
    struct CompoundEntry {
        uint256 stakeIndex;
        uint256 amount;
        uint256 timestamp;
        bool isAutoCompound;
    }
    
    mapping(uint256 => Plan) public plans;
    mapping(address => Stake[]) public userStakes;
    mapping(address => uint256) public totalStaked;
    mapping(address => UserStats) public userStats;
    mapping(address => CompoundEntry[]) public compoundHistory;
    
    uint256 public planCount;
    uint256 public totalStakedGlobal;
    uint256 public totalRewardsDistributed;
    uint256 public totalCompoundedGlobal;
    address public feeCollector;
    
    uint256 public constant AUTO_COMPOUND_THRESHOLD = 10 * 1e18; // $10 minimum
    
    event Staked(address indexed user, uint256 planId, uint256 amount, address token, uint256 stakeIndex);
    event RewardsClaimed(address indexed user, uint256 stakeIndex, uint256 amount, uint256 tax);
    event RewardsCompounded(address indexed user, uint256 stakeIndex, uint256 amount);
    event AutoCompoundToggled(address indexed user, uint256 stakeIndex, bool enabled);
    event AutoCompoundExecuted(address indexed user, uint256 stakeIndex, uint256 amount);
    event CapitalWithdrawn(address indexed user, uint256 stakeIndex, uint256 amount);
    event PlanCreated(uint256 planId, uint256 minStake, uint256 maxStake, uint256 dailyRate, uint256 minPmHold, uint256 maxPoolSize);
    event PlanUpdated(uint256 planId);
    
    constructor(address _pmToken, address _usdtToken, address _usdcToken) {
        pmToken = IERC20(_pmToken);
        usdtToken = IERC20(_usdtToken);
        usdcToken = IERC20(_usdcToken);
        feeCollector = msg.sender;
        
        // Bronze: 10-1000 USDT, 0.4% daily, 100k PM required, 300k max pool
        _createPlan(10 * 1e18, 1000 * 1e18, 40, 100000 * 1e18, 300000 * 1e18);
        
        // Silver: 1001-10000 USDT, 0.5% daily, 300k PM required, 500k max pool
        _createPlan(1001 * 1e18, 10000 * 1e18, 50, 300000 * 1e18, 500000 * 1e18);
        
        // Gold: 10001-25000 USDT, 0.6% daily, 500k PM required, 1M max pool
        _createPlan(10001 * 1e18, 25000 * 1e18, 60, 500000 * 1e18, 1000000 * 1e18);
    }
    
    function _createPlan(
        uint256 minStake,
        uint256 maxStake,
        uint256 dailyRate,
        uint256 minPmHold,
        uint256 maxPoolSize
    ) internal {
        plans[planCount] = Plan({
            minStake: minStake,
            maxStake: maxStake,
            dailyRate: dailyRate,
            minPmHold: minPmHold,
            maxPoolSize: maxPoolSize,
            currentPoolSize: 0,
            isActive: true
        });
        emit PlanCreated(planCount, minStake, maxStake, dailyRate, minPmHold, maxPoolSize);
        planCount++;
    }
    
    function stake(uint256 planId, uint256 amount, bool useUSDT) external nonReentrant whenNotPaused {
        require(planId < planCount, "Invalid plan");
        Plan storage plan = plans[planId];
        require(plan.isActive, "Plan inactive");
        require(amount >= plan.minStake && amount <= plan.maxStake, "Invalid amount");
        require(plan.currentPoolSize + amount <= plan.maxPoolSize, "Pool full");
        require(pmToken.balanceOf(msg.sender) >= plan.minPmHold, "Insufficient PM balance");
        
        IERC20 stakeToken = useUSDT ? usdtToken : usdcToken;
        require(stakeToken.transferFrom(msg.sender, address(this), amount), "Transfer failed");
        
        userStakes[msg.sender].push(Stake({
            planId: planId,
            amount: amount,
            token: address(stakeToken),
            startTime: block.timestamp,
            endTime: block.timestamp + LOCK_PERIOD,
            claimedRewards: 0,
            lastClaimTime: block.timestamp,
            totalCompounded: 0,
            autoCompound: false,
            isActive: true
        }));
        
        plan.currentPoolSize += amount;
        totalStaked[msg.sender] += amount;
        totalStakedGlobal += amount;
        
        emit Staked(msg.sender, planId, amount, address(stakeToken), userStakes[msg.sender].length - 1);
    }
    
    function calculatePendingRewards(address user, uint256 stakeIndex) public view returns (uint256) {
        require(stakeIndex < userStakes[user].length, "Invalid stake");
        Stake storage s = userStakes[user][stakeIndex];
        if (!s.isActive) return 0;
        
        Plan storage plan = plans[s.planId];
        uint256 elapsed = block.timestamp - s.lastClaimTime;
        
        // Daily rate in basis points (40 = 0.4%)
        // Rewards = amount * (dailyRate/10000) * (elapsed/1 day)
        uint256 daysElapsed = elapsed * 1e18 / 1 days;
        
        return (s.amount * plan.dailyRate * daysElapsed) / 10000 / 1e18;
    }
    
    function claimRewards(uint256 stakeIndex) external nonReentrant whenNotPaused {
        require(stakeIndex < userStakes[msg.sender].length, "Invalid stake");
        Stake storage s = userStakes[msg.sender][stakeIndex];
        require(s.isActive, "Stake inactive");
        
        uint256 pending = calculatePendingRewards(msg.sender, stakeIndex);
        require(pending >= MIN_CLAIM, "Below minimum claim");
        
        uint256 tax = (pending * WITHDRAWAL_TAX) / 100;
        uint256 netAmount = pending - tax;
        
        s.claimedRewards += pending;
        s.lastClaimTime = block.timestamp;
        totalRewardsDistributed += pending;
        
        IERC20 rewardToken = IERC20(s.token);
        require(rewardToken.transfer(msg.sender, netAmount), "Transfer failed");
        if (tax > 0 && feeCollector != address(0)) {
            rewardToken.transfer(feeCollector, tax);
        }
        
        emit RewardsClaimed(msg.sender, stakeIndex, netAmount, tax);
    }
    
    function compoundRewards(uint256 stakeIndex) external nonReentrant whenNotPaused {
        require(stakeIndex < userStakes[msg.sender].length, "Invalid stake");
        Stake storage s = userStakes[msg.sender][stakeIndex];
        require(s.isActive, "Stake inactive");
        
        uint256 pending = calculatePendingRewards(msg.sender, stakeIndex);
        require(pending >= MIN_CLAIM, "Below minimum compound");
        
        Plan storage plan = plans[s.planId];
        uint256 newAmount = s.amount + pending;
        require(newAmount <= plan.maxStake, "Exceeds max stake");
        require(plan.currentPoolSize + pending <= plan.maxPoolSize, "Pool full");
        
        // Add rewards to stake amount
        s.amount = newAmount;
        s.claimedRewards += pending;
        s.lastClaimTime = block.timestamp;
        s.totalCompounded += pending;
        
        // Update user stats
        userStats[msg.sender].totalCompounded += pending;
        userStats[msg.sender].compoundCount += 1;
        
        // Add to compound history
        compoundHistory[msg.sender].push(CompoundEntry({
            stakeIndex: stakeIndex,
            amount: pending,
            timestamp: block.timestamp,
            isAutoCompound: false
        }));
        
        // Update pool stats
        plan.currentPoolSize += pending;
        totalStaked[msg.sender] += pending;
        totalStakedGlobal += pending;
        totalRewardsDistributed += pending;
        totalCompoundedGlobal += pending;
        
        emit RewardsCompounded(msg.sender, stakeIndex, pending);
    }
    
    function toggleAutoCompound(uint256 stakeIndex) external {
        require(stakeIndex < userStakes[msg.sender].length, "Invalid stake");
        Stake storage s = userStakes[msg.sender][stakeIndex];
        require(s.isActive, "Stake inactive");
        
        s.autoCompound = !s.autoCompound;
        emit AutoCompoundToggled(msg.sender, stakeIndex, s.autoCompound);
    }
    
    function executeAutoCompound(address user, uint256 stakeIndex) external nonReentrant whenNotPaused {
        require(stakeIndex < userStakes[user].length, "Invalid stake");
        Stake storage s = userStakes[user][stakeIndex];
        require(s.isActive, "Stake inactive");
        require(s.autoCompound, "Auto-compound not enabled");
        
        uint256 pending = calculatePendingRewards(user, stakeIndex);
        require(pending >= AUTO_COMPOUND_THRESHOLD, "Below auto-compound threshold");
        
        Plan storage plan = plans[s.planId];
        uint256 newAmount = s.amount + pending;
        require(newAmount <= plan.maxStake, "Exceeds max stake");
        require(plan.currentPoolSize + pending <= plan.maxPoolSize, "Pool full");
        
        // Add rewards to stake amount
        s.amount = newAmount;
        s.claimedRewards += pending;
        s.lastClaimTime = block.timestamp;
        s.totalCompounded += pending;
        
        // Update user stats
        userStats[user].totalCompounded += pending;
        userStats[user].compoundCount += 1;
        
        // Add to compound history
        compoundHistory[user].push(CompoundEntry({
            stakeIndex: stakeIndex,
            amount: pending,
            timestamp: block.timestamp,
            isAutoCompound: true
        }));
        
        // Update pool stats
        plan.currentPoolSize += pending;
        totalStaked[user] += pending;
        totalStakedGlobal += pending;
        totalRewardsDistributed += pending;
        totalCompoundedGlobal += pending;
        
        emit AutoCompoundExecuted(user, stakeIndex, pending);
    }
    
    function withdrawCapital(uint256 stakeIndex) external nonReentrant whenNotPaused {
        require(stakeIndex < userStakes[msg.sender].length, "Invalid stake");
        Stake storage s = userStakes[msg.sender][stakeIndex];
        require(s.isActive, "Stake inactive");
        require(block.timestamp >= s.endTime, "Still locked");
        
        uint256 pending = calculatePendingRewards(msg.sender, stakeIndex);
        require(pending < MIN_CLAIM, "Claim rewards first");
        
        s.isActive = false;
        Plan storage plan = plans[s.planId];
        plan.currentPoolSize -= s.amount;
        totalStaked[msg.sender] -= s.amount;
        totalStakedGlobal -= s.amount;
        
        IERC20(s.token).transfer(msg.sender, s.amount);
        
        emit CapitalWithdrawn(msg.sender, stakeIndex, s.amount);
    }
    
    // View functions
    function getUserStakes(address user) external view returns (Stake[] memory) {
        return userStakes[user];
    }
    
    function getUserStats(address user) external view returns (uint256 _totalCompounded, uint256 _compoundCount) {
        UserStats storage stats = userStats[user];
        return (stats.totalCompounded, stats.compoundCount);
    }
    
    function getCompoundHistory(address user) external view returns (CompoundEntry[] memory) {
        return compoundHistory[user];
    }
    
    function getCompoundHistoryCount(address user) external view returns (uint256) {
        return compoundHistory[user].length;
    }
    
    function getPlanInfo(uint256 planId) external view returns (Plan memory) {
        require(planId < planCount, "Invalid plan");
        return plans[planId];
    }
    
    function getGlobalStats() external view returns (
        uint256 _totalStaked,
        uint256 _totalRewards,
        uint256 _planCount,
        uint256 _totalCompounded
    ) {
        return (totalStakedGlobal, totalRewardsDistributed, planCount, totalCompoundedGlobal);
    }
    
    function calculateProjectedGrowth(address user, uint256 stakeIndex, uint256 daysForward) external view returns (uint256) {
        require(stakeIndex < userStakes[user].length, "Invalid stake");
        Stake storage s = userStakes[user][stakeIndex];
        if (!s.isActive) return 0;
        
        Plan storage plan = plans[s.planId];
        uint256 currentAmount = s.amount;
        uint256 projectedAmount = currentAmount;
        
        // Calculate compound growth over specified days
        for (uint256 i = 0; i < daysForward; i++) {
            uint256 dailyReward = (projectedAmount * plan.dailyRate) / 10000;
            projectedAmount += dailyReward;
        }
        
        return projectedAmount - currentAmount;
    }
    
    function getAutoCompoundThreshold() external pure returns (uint256) {
        return AUTO_COMPOUND_THRESHOLD;
    }
    
    // Admin functions
    function updatePlan(uint256 planId, bool isActive) external onlyOwner {
        require(planId < planCount, "Invalid plan");
        plans[planId].isActive = isActive;
        emit PlanUpdated(planId);
    }
    
    function setFeeCollector(address _feeCollector) external onlyOwner {
        require(_feeCollector != address(0), "Zero address");
        feeCollector = _feeCollector;
    }
    
    function withdrawRewardPool(address token, uint256 amount) external onlyOwner {
        require(IERC20(token).transfer(msg.sender, amount), "Transfer failed");
    }
    
    function fundRewardPool(address token, uint256 amount) external onlyOwner {
        require(IERC20(token).transferFrom(msg.sender, address(this), amount), "Transfer failed");
    }
}