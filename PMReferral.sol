// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title PMReferral
 * @dev Multi-token referral system with 10% direct commission on various activities
 * - Vault staking: 10% commission in USDC/USDT
 * - Stake page: 10% commission in PM Token
 * - Airdrop claims: 10% commission in PM Token
 * - Token purchases: 10% commission in PM Token
 */
contract PMReferral is ReentrancyGuard, Ownable {
    IERC20 public pmToken;
    IERC20 public usdtToken;
    IERC20 public usdcToken;
    
    uint256 public constant COMMISSION_RATE = 1000; // 10% = 1000 basis points
    uint256 private constant BASIS_POINTS = 10000;
    
    struct ReferrerStats {
        address referrer;
        uint256 totalReferred;
        uint256 totalEarnedPM;
        uint256 totalEarnedUSDT;
        uint256 totalEarnedUSDC;
        uint256 availablePM;
        uint256 availableUSDT;
        uint256 availableUSDC;
        bool isActive;
    }
    
    enum CommissionType {
        VAULT_STAKE,      // USDC/USDT commission
        PM_STAKE,         // PM Token commission
        AIRDROP_CLAIM,    // PM Token commission
        TOKEN_PURCHASE    // PM Token commission
    }
    
    mapping(address => ReferrerStats) public referrers;
    mapping(address => address) public referredBy;
    mapping(address => uint256) public referralCount;
    
    uint256 public totalReferrals;
    uint256 public totalPMPaid;
    uint256 public totalUSDTPaid;
    uint256 public totalUSDCPaid;
    
    event ReferralRegistered(address indexed referee, address indexed referrer);
    event CommissionEarned(
        address indexed referrer,
        address indexed referee,
        uint256 amount,
        CommissionType commissionType,
        address token
    );
    event CommissionClaimed(address indexed referrer, uint256 amountPM, uint256 amountUSDT, uint256 amountUSDC);
    
    constructor(address _pmToken, address _usdtToken, address _usdcToken) {
        require(_pmToken != address(0), "Invalid PM token");
        require(_usdtToken != address(0), "Invalid USDT token");
        require(_usdcToken != address(0), "Invalid USDC token");
        
        pmToken = IERC20(_pmToken);
        usdtToken = IERC20(_usdtToken);
        usdcToken = IERC20(_usdcToken);
    }
    
    /**
     * @dev Register a new referral relationship
     * @param referrer The address of the referrer
     */
    function registerReferral(address referrer) external {
        require(referrer != address(0), "Invalid referrer");
        require(referrer != msg.sender, "Cannot refer yourself");
        require(referredBy[msg.sender] == address(0), "Already referred");
        
        referredBy[msg.sender] = referrer;
        
        if (!referrers[referrer].isActive) {
            referrers[referrer].isActive = true;
            referrers[referrer].referrer = referrer;
        }
        
        referrers[referrer].totalReferred++;
        referralCount[referrer]++;
        totalReferrals++;
        
        emit ReferralRegistered(msg.sender, referrer);
    }
    
    /**
     * @dev Record commission for Vault staking (USDC/USDT)
     * @param referee The user who staked
     * @param amount The staked amount
     * @param useUSDT True if staking with USDT, false for USDC
     */
    function recordVaultStakeCommission(address referee, uint256 amount, bool useUSDT) external {
        address referrer = referredBy[referee];
        if (referrer == address(0)) return;
        
        uint256 commission = (amount * COMMISSION_RATE) / BASIS_POINTS;
        
        if (useUSDT) {
            referrers[referrer].availableUSDT += commission;
            referrers[referrer].totalEarnedUSDT += commission;
            emit CommissionEarned(referrer, referee, commission, CommissionType.VAULT_STAKE, address(usdtToken));
        } else {
            referrers[referrer].availableUSDC += commission;
            referrers[referrer].totalEarnedUSDC += commission;
            emit CommissionEarned(referrer, referee, commission, CommissionType.VAULT_STAKE, address(usdcToken));
        }
    }
    
    /**
     * @dev Record commission for PM Token staking
     * @param referee The user who staked
     * @param amount The staked amount in PM tokens
     */
    function recordPMStakeCommission(address referee, uint256 amount) external {
        address referrer = referredBy[referee];
        if (referrer == address(0)) return;
        
        uint256 commission = (amount * COMMISSION_RATE) / BASIS_POINTS;
        
        referrers[referrer].availablePM += commission;
        referrers[referrer].totalEarnedPM += commission;
        
        emit CommissionEarned(referrer, referee, commission, CommissionType.PM_STAKE, address(pmToken));
    }
    
    /**
     * @dev Record commission for Airdrop claims
     * @param referee The user who claimed airdrop
     * @param amount The claimed amount in PM tokens
     */
    function recordAirdropCommission(address referee, uint256 amount) external {
        address referrer = referredBy[referee];
        if (referrer == address(0)) return;
        
        uint256 commission = (amount * COMMISSION_RATE) / BASIS_POINTS;
        
        referrers[referrer].availablePM += commission;
        referrers[referrer].totalEarnedPM += commission;
        
        emit CommissionEarned(referrer, referee, commission, CommissionType.AIRDROP_CLAIM, address(pmToken));
    }
    
    /**
     * @dev Record commission for Token purchases (presale/buy)
     * @param referee The user who purchased tokens
     * @param amount The purchased amount in PM tokens
     */
    function recordPurchaseCommission(address referee, uint256 amount) external {
        address referrer = referredBy[referee];
        if (referrer == address(0)) return;
        
        uint256 commission = (amount * COMMISSION_RATE) / BASIS_POINTS;
        
        referrers[referrer].availablePM += commission;
        referrers[referrer].totalEarnedPM += commission;
        
        emit CommissionEarned(referrer, referee, commission, CommissionType.TOKEN_PURCHASE, address(pmToken));
    }
    
    /**
     * @dev Claim all available commissions
     */
    function claimCommissions() external nonReentrant {
        ReferrerStats storage stats = referrers[msg.sender];
        
        uint256 pmAmount = stats.availablePM;
        uint256 usdtAmount = stats.availableUSDT;
        uint256 usdcAmount = stats.availableUSDC;
        
        require(pmAmount > 0 || usdtAmount > 0 || usdcAmount > 0, "No commissions to claim");
        
        stats.availablePM = 0;
        stats.availableUSDT = 0;
        stats.availableUSDC = 0;
        
        if (pmAmount > 0) {
            require(pmToken.transfer(msg.sender, pmAmount), "PM transfer failed");
            totalPMPaid += pmAmount;
        }
        
        if (usdtAmount > 0) {
            require(usdtToken.transfer(msg.sender, usdtAmount), "USDT transfer failed");
            totalUSDTPaid += usdtAmount;
        }
        
        if (usdcAmount > 0) {
            require(usdcToken.transfer(msg.sender, usdcAmount), "USDC transfer failed");
            totalUSDCPaid += usdcAmount;
        }
        
        emit CommissionClaimed(msg.sender, pmAmount, usdtAmount, usdcAmount);
    }
    
    /**
     * @dev Get referrer information
     */
    function getReferrerInfo(address referrer) external view returns (
        uint256 totalReferred,
        uint256 totalEarnedPM,
        uint256 totalEarnedUSDT,
        uint256 totalEarnedUSDC,
        uint256 availablePM,
        uint256 availableUSDT,
        uint256 availableUSDC
    ) {
        ReferrerStats memory stats = referrers[referrer];
        return (
            stats.totalReferred,
            stats.totalEarnedPM,
            stats.totalEarnedUSDT,
            stats.totalEarnedUSDC,
            stats.availablePM,
            stats.availableUSDT,
            stats.availableUSDC
        );
    }
    
    /**
     * @dev Get referrer's direct referrals count
     */
    function getReferralCount(address referrer) external view returns (uint256) {
        return referralCount[referrer];
    }
    
    /**
     * @dev Check if an address has been referred
     */
    function hasReferrer(address user) external view returns (bool) {
        return referredBy[user] != address(0);
    }
    
    /**
     * @dev Get the referrer of a user
     */
    function getReferrer(address user) external view returns (address) {
        return referredBy[user];
    }
    
    /**
     * @dev Fund contract with tokens for commission payouts
     */
    function fundContract(address token, uint256 amount) external onlyOwner {
        require(
            token == address(pmToken) || 
            token == address(usdtToken) || 
            token == address(usdcToken),
            "Invalid token"
        );
        require(IERC20(token).transferFrom(msg.sender, address(this), amount), "Transfer failed");
    }
    
    /**
     * @dev Emergency withdraw tokens
     */
    function emergencyWithdraw(address token, uint256 amount) external onlyOwner {
        require(IERC20(token).transfer(owner(), amount), "Transfer failed");
    }
    
    /**
     * @dev Get contract token balances
     */
    function getContractBalances() external view returns (uint256 pmBalance, uint256 usdtBalance, uint256 usdcBalance) {
        return (
            pmToken.balanceOf(address(this)),
            usdtToken.balanceOf(address(this)),
            usdcToken.balanceOf(address(this))
        );
    }
}