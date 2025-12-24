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

contract PMVirtualCard is Ownable, ReentrancyGuard, Pausable {
    IERC20 public immutable pmToken;
    
    enum CardTier { Novice, Bronze, Silver, Gold, Platinum, Diamond }
    
    struct Card {
        bool isActive;
        CardTier tier;
        uint256 balance;
        uint256 totalDeposited;
        uint256 totalSpent;
        uint256 createdAt;
        uint256 lastTopUpAt;
        string cardNumber; // Derived from wallet address
    }
    
    struct TierInfo {
        uint256 minBalance;
        uint256 dailyLimit;
        uint256 monthlyLimit;
        uint256 cashbackRate; // in basis points (100 = 1%)
        bool isActive;
    }
    
    mapping(address => Card) public cards;
    mapping(CardTier => TierInfo) public tierInfo;
    
    uint256 public totalCards;
    uint256 public totalDeposits;
    uint256 public topUpFee; // in basis points (100 = 1%)
    address public feeCollector;
    
    event CardCreated(address indexed user, string cardNumber, CardTier tier);
    event CardTopUp(address indexed user, uint256 amount, uint256 fee, uint256 newBalance);
    event CardSpent(address indexed user, uint256 amount, uint256 cashback);
    event CardWithdraw(address indexed user, uint256 amount);
    event TierUpgraded(address indexed user, CardTier oldTier, CardTier newTier);
    event TierInfoUpdated(CardTier tier, uint256 minBalance, uint256 dailyLimit, uint256 monthlyLimit, uint256 cashbackRate);
    
    constructor(address _pmToken) {
        pmToken = IERC20(_pmToken);
        feeCollector = msg.sender;
        topUpFee = 50; // 0.5% fee
        
        // Initialize tier info
        tierInfo[CardTier.Novice] = TierInfo({
            minBalance: 0,
            dailyLimit: 100 * 1e18,
            monthlyLimit: 1000 * 1e18,
            cashbackRate: 50, // 0.5%
            isActive: true
        });
        
        tierInfo[CardTier.Bronze] = TierInfo({
            minBalance: 1000 * 1e18,
            dailyLimit: 500 * 1e18,
            monthlyLimit: 5000 * 1e18,
            cashbackRate: 100, // 1%
            isActive: true
        });
        
        tierInfo[CardTier.Silver] = TierInfo({
            minBalance: 5000 * 1e18,
            dailyLimit: 2000 * 1e18,
            monthlyLimit: 20000 * 1e18,
            cashbackRate: 150, // 1.5%
            isActive: true
        });
        
        tierInfo[CardTier.Gold] = TierInfo({
            minBalance: 25000 * 1e18,
            dailyLimit: 10000 * 1e18,
            monthlyLimit: 100000 * 1e18,
            cashbackRate: 200, // 2%
            isActive: true
        });
        
        tierInfo[CardTier.Platinum] = TierInfo({
            minBalance: 100000 * 1e18,
            dailyLimit: 50000 * 1e18,
            monthlyLimit: 500000 * 1e18,
            cashbackRate: 250, // 2.5%
            isActive: true
        });
        
        tierInfo[CardTier.Diamond] = TierInfo({
            minBalance: 500000 * 1e18,
            dailyLimit: 0, // Unlimited
            monthlyLimit: 0, // Unlimited
            cashbackRate: 300, // 3%
            isActive: true
        });
    }
    
    function _generateCardNumber(address user) internal pure returns (string memory) {
        bytes memory addressBytes = abi.encodePacked(user);
        bytes memory cardNumber = new bytes(16);
        
        // Take first 8 characters (after 0x) and last 8 characters
        for (uint i = 0; i < 8; i++) {
            cardNumber[i] = _toHexChar(uint8(addressBytes[i / 2]) >> (4 * (1 - (i % 2))));
            cardNumber[8 + i] = _toHexChar(uint8(addressBytes[12 + i / 2]) >> (4 * (1 - (i % 2))));
        }
        
        return string(cardNumber);
    }
    
    function _toHexChar(uint8 value) internal pure returns (bytes1) {
        value = value & 0x0f;
        if (value < 10) {
            return bytes1(uint8(48 + value)); // 0-9
        }
        return bytes1(uint8(55 + value)); // A-F
    }
    
    function _determineTier(uint256 balance) internal view returns (CardTier) {
        if (balance >= tierInfo[CardTier.Diamond].minBalance) return CardTier.Diamond;
        if (balance >= tierInfo[CardTier.Platinum].minBalance) return CardTier.Platinum;
        if (balance >= tierInfo[CardTier.Gold].minBalance) return CardTier.Gold;
        if (balance >= tierInfo[CardTier.Silver].minBalance) return CardTier.Silver;
        if (balance >= tierInfo[CardTier.Bronze].minBalance) return CardTier.Bronze;
        return CardTier.Novice;
    }
    
    function createCard() external nonReentrant whenNotPaused {
        require(!cards[msg.sender].isActive, "Card already exists");
        
        string memory cardNumber = _generateCardNumber(msg.sender);
        
        cards[msg.sender] = Card({
            isActive: true,
            tier: CardTier.Novice,
            balance: 0,
            totalDeposited: 0,
            totalSpent: 0,
            createdAt: block.timestamp,
            lastTopUpAt: 0,
            cardNumber: cardNumber
        });
        
        totalCards++;
        
        emit CardCreated(msg.sender, cardNumber, CardTier.Novice);
    }
    
    function topUp(uint256 amount) external nonReentrant whenNotPaused {
        require(cards[msg.sender].isActive, "Card not active");
        require(amount > 0, "Amount must be greater than 0");
        
        uint256 fee = (amount * topUpFee) / 10000;
        uint256 netAmount = amount - fee;
        
        require(pmToken.transferFrom(msg.sender, address(this), amount), "Transfer failed");
        
        if (fee > 0 && feeCollector != address(0)) {
            pmToken.transfer(feeCollector, fee);
        }
        
        Card storage card = cards[msg.sender];
        card.balance += netAmount;
        card.totalDeposited += netAmount;
        card.lastTopUpAt = block.timestamp;
        
        totalDeposits += netAmount;
        
        // Check for tier upgrade
        CardTier newTier = _determineTier(card.balance);
        if (newTier > card.tier) {
            CardTier oldTier = card.tier;
            card.tier = newTier;
            emit TierUpgraded(msg.sender, oldTier, newTier);
        }
        
        emit CardTopUp(msg.sender, netAmount, fee, card.balance);
    }
    
    function spend(uint256 amount) external nonReentrant whenNotPaused {
        Card storage card = cards[msg.sender];
        require(card.isActive, "Card not active");
        require(card.balance >= amount, "Insufficient balance");
        
        TierInfo memory tier = tierInfo[card.tier];
        if (tier.dailyLimit > 0) {
            require(amount <= tier.dailyLimit, "Exceeds daily limit");
        }
        
        uint256 cashback = (amount * tier.cashbackRate) / 10000;
        
        card.balance -= amount;
        card.totalSpent += amount;
        
        if (cashback > 0) {
            card.balance += cashback;
        }
        
        emit CardSpent(msg.sender, amount, cashback);
    }
    
    function withdraw(uint256 amount) external nonReentrant whenNotPaused {
        Card storage card = cards[msg.sender];
        require(card.isActive, "Card not active");
        require(card.balance >= amount, "Insufficient balance");
        
        card.balance -= amount;
        
        require(pmToken.transfer(msg.sender, amount), "Transfer failed");
        
        emit CardWithdraw(msg.sender, amount);
    }
    
    // View functions
    function getCardInfo(address user) external view returns (Card memory) {
        return cards[user];
    }
    
    function getCardNumber(address user) external view returns (string memory) {
        require(cards[user].isActive, "Card not active");
        return cards[user].cardNumber;
    }
    
    function getCardBalance(address user) external view returns (uint256) {
        return cards[user].balance;
    }
    
    function getTierInfo(CardTier tier) external view returns (TierInfo memory) {
        return tierInfo[tier];
    }
    
    function getUserTier(address user) external view returns (CardTier) {
        return cards[user].tier;
    }
    
    function getGlobalStats() external view returns (
        uint256 _totalCards,
        uint256 _totalDeposits,
        uint256 _topUpFee
    ) {
        return (totalCards, totalDeposits, topUpFee);
    }
    
    function hasCard(address user) external view returns (bool) {
        return cards[user].isActive;
    }
    
    // Admin functions
    function setTopUpFee(uint256 _fee) external onlyOwner {
        require(_fee <= 500, "Fee too high"); // Max 5%
        topUpFee = _fee;
    }
    
    function setFeeCollector(address _feeCollector) external onlyOwner {
        require(_feeCollector != address(0), "Zero address");
        feeCollector = _feeCollector;
    }
    
    function updateTierInfo(
        CardTier tier,
        uint256 minBalance,
        uint256 dailyLimit,
        uint256 monthlyLimit,
        uint256 cashbackRate,
        bool isActive
    ) external onlyOwner {
        tierInfo[tier] = TierInfo({
            minBalance: minBalance,
            dailyLimit: dailyLimit,
            monthlyLimit: monthlyLimit,
            cashbackRate: cashbackRate,
            isActive: isActive
        });
        
        emit TierInfoUpdated(tier, minBalance, dailyLimit, monthlyLimit, cashbackRate);
    }
    
    function emergencyWithdraw(address token, uint256 amount) external onlyOwner {
        require(IERC20(token).transfer(msg.sender, amount), "Transfer failed");
    }
}
