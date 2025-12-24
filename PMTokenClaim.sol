// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

interface IPresale {
    function purchasedAmount(uint8 r, address user) external view returns (uint256);
    function presaleEnded() external view returns (bool);
}

abstract contract Ownable {
    address private _owner;
    event OwnershipTransferred(address indexed prev, address indexed next);

    constructor() { _owner = msg.sender; emit OwnershipTransferred(address(0), msg.sender); }
    function owner() public view returns(address) { return _owner; }

    modifier onlyOwner() { require(msg.sender == _owner, "Not owner"); _; }

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "Zero address");
        emit OwnershipTransferred(_owner, newOwner);
        _owner = newOwner;
    }
}

abstract contract ReentrancyGuard {
    uint256 private constant NOT_ENTERED = 1;
    uint256 private constant ENTERED = 2;
    uint256 private _status;

    constructor() { _status = NOT_ENTERED; }

    modifier nonReentrant() {
        require(_status != ENTERED, "Reentrant");
        _status = ENTERED;
        _;
        _status = NOT_ENTERED;
    }
}

/**
 * @title PM Token Claim Contract
 * @notice Allows presale participants to claim their purchased tokens after presale ends
 * @dev Vesting schedules: Seed (25% TGE + 6mo cliff), Private (50% TGE + 3mo cliff), Public (100% TGE)
 */
contract PMTokenClaim is Ownable, ReentrancyGuard {
    IERC20 public immutable pmToken;
    IPresale public presaleContract;
    
    bool public claimEnabled;
    uint256 public tgeTimestamp; // Token Generation Event timestamp
    
    // Vesting configuration per round
    struct VestingConfig {
        uint256 tgePercent;      // Percent released at TGE (basis points, 10000 = 100%)
        uint256 cliffDuration;   // Cliff duration in seconds
        uint256 vestingDuration; // Total vesting duration after cliff
    }
    
    VestingConfig[3] public vestingConfigs;
    
    // Track claimed amounts per user per round
    mapping(address => mapping(uint8 => uint256)) public claimedAmount;
    
    // Total tokens claimed
    uint256 public totalClaimed;
    
    event ClaimEnabled(uint256 tgeTimestamp);
    event TokensClaimed(address indexed user, uint8 round, uint256 amount);
    event VestingConfigUpdated(uint8 round, uint256 tgePercent, uint256 cliff, uint256 vesting);
    event PresaleContractUpdated(address presaleContract);
    event EmergencyWithdraw(address token, uint256 amount);
    
    constructor(address _pmToken, address _presaleContract) {
        require(_pmToken != address(0), "Zero token");
        require(_presaleContract != address(0), "Zero presale");
        
        pmToken = IERC20(_pmToken);
        presaleContract = IPresale(_presaleContract);
        
        // Default vesting: Seed 25% TGE + 6mo cliff + 12mo vesting
        vestingConfigs[0] = VestingConfig(2500, 180 days, 365 days);
        // Private 50% TGE + 3mo cliff + 6mo vesting
        vestingConfigs[1] = VestingConfig(5000, 90 days, 180 days);
        // Public 100% TGE (no vesting)
        vestingConfigs[2] = VestingConfig(10000, 0, 0);
    }
    
    function setPresaleContract(address _presale) external onlyOwner {
        require(_presale != address(0), "Zero address");
        presaleContract = IPresale(_presale);
        emit PresaleContractUpdated(_presale);
    }
    
    function setVestingConfig(
        uint8 round,
        uint256 tgePercent,
        uint256 cliffDuration,
        uint256 vestingDuration
    ) external onlyOwner {
        require(round < 3, "Invalid round");
        require(tgePercent <= 10000, "TGE > 100%");
        
        vestingConfigs[round] = VestingConfig(tgePercent, cliffDuration, vestingDuration);
        emit VestingConfigUpdated(round, tgePercent, cliffDuration, vestingDuration);
    }
    
    function enableClaim() external onlyOwner {
        require(!claimEnabled, "Already enabled");
        require(presaleContract.presaleEnded(), "Presale not ended");
        
        claimEnabled = true;
        tgeTimestamp = block.timestamp;
        
        emit ClaimEnabled(tgeTimestamp);
    }
    
    function getClaimableAmount(address user, uint8 round) public view returns (uint256) {
        if (!claimEnabled || round >= 3) return 0;
        
        uint256 purchased = presaleContract.purchasedAmount(round, user);
        if (purchased == 0) return 0;
        
        uint256 claimed = claimedAmount[user][round];
        if (claimed >= purchased) return 0;
        
        VestingConfig memory config = vestingConfigs[round];
        uint256 elapsed = block.timestamp - tgeTimestamp;
        
        uint256 vestedAmount;
        
        // TGE release
        uint256 tgeAmount = (purchased * config.tgePercent) / 10000;
        
        if (config.tgePercent == 10000) {
            // 100% at TGE (Public round)
            vestedAmount = purchased;
        } else if (elapsed < config.cliffDuration) {
            // Only TGE amount during cliff
            vestedAmount = tgeAmount;
        } else {
            // After cliff: linear vesting
            uint256 vestingElapsed = elapsed - config.cliffDuration;
            uint256 remainingTokens = purchased - tgeAmount;
            
            if (config.vestingDuration == 0 || vestingElapsed >= config.vestingDuration) {
                vestedAmount = purchased;
            } else {
                uint256 vestedFromSchedule = (remainingTokens * vestingElapsed) / config.vestingDuration;
                vestedAmount = tgeAmount + vestedFromSchedule;
            }
        }
        
        return vestedAmount > claimed ? vestedAmount - claimed : 0;
    }
    
    function getTotalClaimable(address user) external view returns (uint256 total) {
        for (uint8 i = 0; i < 3; i++) {
            total += getClaimableAmount(user, i);
        }
    }
    
    function getTotalPurchased(address user) external view returns (uint256 total) {
        for (uint8 i = 0; i < 3; i++) {
            total += presaleContract.purchasedAmount(i, user);
        }
    }
    
    function getTotalClaimed(address user) external view returns (uint256 total) {
        for (uint8 i = 0; i < 3; i++) {
            total += claimedAmount[user][i];
        }
    }
    
    function claim(uint8 round) external nonReentrant {
        require(claimEnabled, "Claim not enabled");
        require(round < 3, "Invalid round");
        
        uint256 claimable = getClaimableAmount(msg.sender, round);
        require(claimable > 0, "Nothing to claim");
        
        claimedAmount[msg.sender][round] += claimable;
        totalClaimed += claimable;
        
        require(pmToken.transfer(msg.sender, claimable), "Transfer failed");
        
        emit TokensClaimed(msg.sender, round, claimable);
    }
    
    function claimAll() external nonReentrant {
        require(claimEnabled, "Claim not enabled");
        
        uint256 totalClaimable;
        
        for (uint8 i = 0; i < 3; i++) {
            uint256 claimable = getClaimableAmount(msg.sender, i);
            if (claimable > 0) {
                claimedAmount[msg.sender][i] += claimable;
                totalClaimable += claimable;
                emit TokensClaimed(msg.sender, i, claimable);
            }
        }
        
        require(totalClaimable > 0, "Nothing to claim");
        totalClaimed += totalClaimable;
        
        require(pmToken.transfer(msg.sender, totalClaimable), "Transfer failed");
    }
    
    function getUserInfo(address user) external view returns (
        uint256[3] memory purchased,
        uint256[3] memory claimed,
        uint256[3] memory claimable,
        uint256 totalPurchased,
        uint256 totalClaimedUser,
        uint256 totalClaimableUser
    ) {
        for (uint8 i = 0; i < 3; i++) {
            purchased[i] = presaleContract.purchasedAmount(i, user);
            claimed[i] = claimedAmount[user][i];
            claimable[i] = getClaimableAmount(user, i);
            totalPurchased += purchased[i];
            totalClaimedUser += claimed[i];
            totalClaimableUser += claimable[i];
        }
    }
    
    function getVestingInfo(uint8 round) external view returns (
        uint256 tgePercent,
        uint256 cliffDuration,
        uint256 vestingDuration,
        uint256 cliffEndTime,
        uint256 vestingEndTime
    ) {
        require(round < 3, "Invalid round");
        VestingConfig memory config = vestingConfigs[round];
        
        tgePercent = config.tgePercent;
        cliffDuration = config.cliffDuration;
        vestingDuration = config.vestingDuration;
        
        if (claimEnabled) {
            cliffEndTime = tgeTimestamp + config.cliffDuration;
            vestingEndTime = cliffEndTime + config.vestingDuration;
        }
    }
    
    function fundClaimPool(uint256 amount) external onlyOwner {
        require(pmToken.transferFrom(msg.sender, address(this), amount), "Transfer failed");
    }
    
    function emergencyWithdraw(address token, uint256 amount) external onlyOwner {
        if (token == address(0)) {
            payable(owner()).transfer(amount);
        } else {
            IERC20(token).transfer(owner(), amount);
        }
        emit EmergencyWithdraw(token, amount);
    }
    
    receive() external payable {}
}
