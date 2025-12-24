// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract PMMerchant is ReentrancyGuard, Ownable {
    IERC20 public pmToken;
    
    enum SubscriptionTier {
        STARTER,
        PROFESSIONAL
    }
    
    struct Subscription {
        SubscriptionTier tier;
        uint256 startTime;
        uint256 endTime;
        bool active;
        uint256 amountPaid;
        uint256 totalRevenue;
        uint256 totalTransactions;
    }
    
    struct TierConfig {
        uint256 price;
        uint256 duration;
        uint256 transactionLimit;
        uint256 apiCallLimit;
        bool active;
    }

    struct ABTestVariant {
        string name;
        uint256 conversions;
        uint256 impressions;
        bool active;
    }
    
    mapping(address => Subscription) public subscriptions;
    mapping(SubscriptionTier => TierConfig) public tierConfigs;
    mapping(address => uint256) public merchantTransactions;
    mapping(address => uint256) public merchantApiCalls;
    mapping(address => uint256) public merchantRevenue;
    mapping(address => mapping(uint256 => ABTestVariant)) public abTests;
    mapping(address => uint256) public abTestCount;
    
    uint256 public totalSubscribers;
    uint256 public totalRevenue;
    uint256 public totalActiveLinks;
    
    event SubscriptionPurchased(address indexed merchant, SubscriptionTier tier, uint256 amount);
    event SubscriptionRenewed(address indexed merchant, SubscriptionTier tier, uint256 amount);
    event SubscriptionCancelled(address indexed merchant);
    event TierConfigured(SubscriptionTier tier, uint256 price, uint256 duration);
    event PaymentReceived(address indexed merchant, address indexed customer, uint256 amount);
    event ABTestCreated(address indexed merchant, uint256 testId, string variantA, string variantB);
    event ABTestConversion(address indexed merchant, uint256 testId, uint256 variant);
    
    constructor(address _pmToken) Ownable(msg.sender) {
        require(_pmToken != address(0), "Invalid token address");
        pmToken = IERC20(_pmToken);
        
        // Configure default tiers - Starter: 10,000 PM, Professional: 25,000 PM
        tierConfigs[SubscriptionTier.STARTER] = TierConfig({
            price: 10000 * 10**18,      // 10,000 PM tokens
            duration: 365 days,
            transactionLimit: 100,
            apiCallLimit: 1000,
            active: true
        });
        
        tierConfigs[SubscriptionTier.PROFESSIONAL] = TierConfig({
            price: 25000 * 10**18,      // 25,000 PM tokens
            duration: 365 days,
            transactionLimit: type(uint256).max,
            apiCallLimit: type(uint256).max,
            active: true
        });
    }
    
    function subscribe(SubscriptionTier tier) external nonReentrant {
        TierConfig memory config = tierConfigs[tier];
        require(config.active, "Tier not available");
        
        Subscription storage sub = subscriptions[msg.sender];
        require(!sub.active || block.timestamp >= sub.endTime, "Active subscription exists");
        
        require(pmToken.transferFrom(msg.sender, address(this), config.price), "Transfer failed");
        
        if (!sub.active) {
            totalSubscribers++;
        }
        
        subscriptions[msg.sender] = Subscription({
            tier: tier,
            startTime: block.timestamp,
            endTime: block.timestamp + config.duration,
            active: true,
            amountPaid: config.price,
            totalRevenue: sub.totalRevenue,
            totalTransactions: sub.totalTransactions
        });
        
        merchantTransactions[msg.sender] = 0;
        merchantApiCalls[msg.sender] = 0;
        
        totalRevenue += config.price;
        
        emit SubscriptionPurchased(msg.sender, tier, config.price);
    }
    
    function renewSubscription() external nonReentrant {
        Subscription storage sub = subscriptions[msg.sender];
        require(sub.active, "No active subscription");
        
        TierConfig memory config = tierConfigs[sub.tier];
        require(config.active, "Tier not available");
        
        require(pmToken.transferFrom(msg.sender, address(this), config.price), "Transfer failed");
        
        sub.endTime = block.timestamp + config.duration;
        sub.amountPaid = config.price;
        
        merchantTransactions[msg.sender] = 0;
        merchantApiCalls[msg.sender] = 0;
        
        totalRevenue += config.price;
        
        emit SubscriptionRenewed(msg.sender, sub.tier, config.price);
    }
    
    function cancelSubscription() external {
        Subscription storage sub = subscriptions[msg.sender];
        require(sub.active, "No active subscription");
        
        sub.active = false;
        totalSubscribers--;
        
        emit SubscriptionCancelled(msg.sender);
    }
    
    function isSubscriptionActive(address merchant) external view returns (bool) {
        Subscription memory sub = subscriptions[merchant];
        return sub.active && block.timestamp < sub.endTime;
    }
    
    function getSubscriptionInfo(address merchant) external view returns (
        SubscriptionTier tier,
        uint256 endTime,
        bool active,
        uint256 transactionsUsed,
        uint256 apiCallsUsed,
        uint256 transactionLimit,
        uint256 apiCallLimit,
        uint256 revenue,
        uint256 totalTx
    ) {
        Subscription memory sub = subscriptions[merchant];
        TierConfig memory config = tierConfigs[sub.tier];
        
        return (
            sub.tier,
            sub.endTime,
            sub.active && block.timestamp < sub.endTime,
            merchantTransactions[merchant],
            merchantApiCalls[merchant],
            config.transactionLimit,
            config.apiCallLimit,
            sub.totalRevenue,
            sub.totalTransactions
        );
    }

    function getTierConfig(SubscriptionTier tier) external view returns (
        uint256 price,
        uint256 duration,
        uint256 transactionLimit,
        uint256 apiCallLimit,
        bool active
    ) {
        TierConfig memory config = tierConfigs[tier];
        return (config.price, config.duration, config.transactionLimit, config.apiCallLimit, config.active);
    }

    function getMerchantStats(address merchant) external view returns (
        uint256 revenue,
        uint256 transactions,
        uint256 activeLinks
    ) {
        Subscription memory sub = subscriptions[merchant];
        return (sub.totalRevenue, sub.totalTransactions, 0);
    }
    
    function recordTransaction(address merchant, uint256 amount) external {
        require(msg.sender == owner() || msg.sender == merchant, "Unauthorized");
        Subscription storage sub = subscriptions[merchant];
        require(sub.active && block.timestamp < sub.endTime, "No active subscription");
        
        merchantTransactions[merchant]++;
        sub.totalTransactions++;
        sub.totalRevenue += amount;
        merchantRevenue[merchant] += amount;
        
        emit PaymentReceived(merchant, msg.sender, amount);
    }
    
    function recordApiCall(address merchant) external {
        require(msg.sender == owner() || msg.sender == merchant, "Unauthorized");
        merchantApiCalls[merchant]++;
    }

    // A/B Testing Functions
    function createABTest(string memory variantAName, string memory variantBName) external returns (uint256) {
        Subscription memory sub = subscriptions[msg.sender];
        require(sub.active && block.timestamp < sub.endTime, "No active subscription");
        require(sub.tier == SubscriptionTier.PROFESSIONAL, "Professional tier required");
        
        uint256 testId = abTestCount[msg.sender];
        
        abTests[msg.sender][testId] = ABTestVariant({
            name: variantAName,
            conversions: 0,
            impressions: 0,
            active: true
        });
        
        abTests[msg.sender][testId + 1] = ABTestVariant({
            name: variantBName,
            conversions: 0,
            impressions: 0,
            active: true
        });
        
        abTestCount[msg.sender] += 2;
        
        emit ABTestCreated(msg.sender, testId, variantAName, variantBName);
        return testId;
    }

    function recordABTestImpression(uint256 testId) external {
        ABTestVariant storage variant = abTests[msg.sender][testId];
        require(variant.active, "Test not active");
        variant.impressions++;
    }

    function recordABTestConversion(uint256 testId) external {
        ABTestVariant storage variant = abTests[msg.sender][testId];
        require(variant.active, "Test not active");
        variant.conversions++;
        emit ABTestConversion(msg.sender, testId, testId);
    }

    function getABTestResults(address merchant, uint256 testId) external view returns (
        string memory name,
        uint256 conversions,
        uint256 impressions,
        uint256 conversionRate
    ) {
        ABTestVariant memory variant = abTests[merchant][testId];
        uint256 rate = variant.impressions > 0 ? (variant.conversions * 10000) / variant.impressions : 0;
        return (variant.name, variant.conversions, variant.impressions, rate);
    }

    function getABTestCount(address merchant) external view returns (uint256) {
        return abTestCount[merchant];
    }
    
    function configureTier(
        SubscriptionTier tier,
        uint256 price,
        uint256 duration,
        uint256 transactionLimit,
        uint256 apiCallLimit,
        bool active
    ) external onlyOwner {
        tierConfigs[tier] = TierConfig({
            price: price,
            duration: duration,
            transactionLimit: transactionLimit,
            apiCallLimit: apiCallLimit,
            active: active
        });
        
        emit TierConfigured(tier, price, duration);
    }
    
    function withdrawRevenue(uint256 amount) external onlyOwner {
        require(pmToken.transfer(owner(), amount), "Transfer failed");
    }

    function getGlobalStats() external view returns (
        uint256 _totalSubscribers,
        uint256 _totalRevenue,
        uint256 _starterPrice,
        uint256 _professionalPrice
    ) {
        return (
            totalSubscribers,
            totalRevenue,
            tierConfigs[SubscriptionTier.STARTER].price,
            tierConfigs[SubscriptionTier.PROFESSIONAL].price
        );
    }
}
