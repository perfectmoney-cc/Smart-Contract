// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract PMPayment is ReentrancyGuard, Ownable {
    IERC20 public pmToken;
    
    struct Payment {
        address from;
        address to;
        uint256 amount;
        uint256 timestamp;
        string memo;
        bytes32 paymentHash;
    }
    
    struct PaymentLink {
        address merchant;
        uint256 amount;
        string description;
        bool active;
        uint256 expiresAt;
    }
    
    mapping(bytes32 => Payment) public payments;
    mapping(bytes32 => PaymentLink) public paymentLinks;
    mapping(address => bytes32[]) public userPayments;
    mapping(address => bytes32[]) public merchantLinks;
    
    uint256 public totalPayments;
    uint256 public totalVolume;
    
    event PaymentSent(address indexed from, address indexed to, uint256 amount, bytes32 paymentHash);
    event PaymentLinkCreated(bytes32 indexed linkId, address indexed merchant, uint256 amount);
    event PaymentLinkPaid(bytes32 indexed linkId, address indexed payer, uint256 amount);
    event PaymentLinkCancelled(bytes32 indexed linkId);
    
    constructor(address _pmToken) {
        require(_pmToken != address(0), "Invalid token address");
        pmToken = IERC20(_pmToken);
    }
    
    function sendPayment(address to, uint256 amount, string memory memo) external nonReentrant returns (bytes32) {
        require(to != address(0), "Invalid recipient");
        require(amount > 0, "Amount must be greater than 0");
        
        bytes32 paymentHash = keccak256(abi.encodePacked(msg.sender, to, amount, block.timestamp, totalPayments));
        
        require(pmToken.transferFrom(msg.sender, to, amount), "Transfer failed");
        
        payments[paymentHash] = Payment({
            from: msg.sender,
            to: to,
            amount: amount,
            timestamp: block.timestamp,
            memo: memo,
            paymentHash: paymentHash
        });
        
        userPayments[msg.sender].push(paymentHash);
        userPayments[to].push(paymentHash);
        
        totalPayments++;
        totalVolume += amount;
        
        emit PaymentSent(msg.sender, to, amount, paymentHash);
        
        return paymentHash;
    }
    
    function createPaymentLink(uint256 amount, string memory description, uint256 expiresIn) external returns (bytes32) {
        require(amount > 0, "Amount must be greater than 0");
        
        bytes32 linkId = keccak256(abi.encodePacked(msg.sender, amount, description, block.timestamp));
        
        paymentLinks[linkId] = PaymentLink({
            merchant: msg.sender,
            amount: amount,
            description: description,
            active: true,
            expiresAt: block.timestamp + expiresIn
        });
        
        merchantLinks[msg.sender].push(linkId);
        
        emit PaymentLinkCreated(linkId, msg.sender, amount);
        
        return linkId;
    }
    
    function payLink(bytes32 linkId) external nonReentrant {
        PaymentLink storage link = paymentLinks[linkId];
        require(link.active, "Payment link not active");
        require(block.timestamp <= link.expiresAt, "Payment link expired");
        
        require(pmToken.transferFrom(msg.sender, link.merchant, link.amount), "Transfer failed");
        
        link.active = false;
        
        bytes32 paymentHash = keccak256(abi.encodePacked(msg.sender, link.merchant, link.amount, block.timestamp));
        
        payments[paymentHash] = Payment({
            from: msg.sender,
            to: link.merchant,
            amount: link.amount,
            timestamp: block.timestamp,
            memo: link.description,
            paymentHash: paymentHash
        });
        
        userPayments[msg.sender].push(paymentHash);
        userPayments[link.merchant].push(paymentHash);
        
        totalPayments++;
        totalVolume += link.amount;
        
        emit PaymentLinkPaid(linkId, msg.sender, link.amount);
    }
    
    function cancelPaymentLink(bytes32 linkId) external {
        PaymentLink storage link = paymentLinks[linkId];
        require(link.merchant == msg.sender, "Not link owner");
        require(link.active, "Link already inactive");
        
        link.active = false;
        
        emit PaymentLinkCancelled(linkId);
    }
    
    function getUserPayments(address user) external view returns (bytes32[] memory) {
        return userPayments[user];
    }
    
    function getMerchantLinks(address merchant) external view returns (bytes32[] memory) {
        return merchantLinks[merchant];
    }
    
    function getPayment(bytes32 paymentHash) external view returns (Payment memory) {
        return payments[paymentHash];
    }
    
    function getPaymentLink(bytes32 linkId) external view returns (PaymentLink memory) {
        return paymentLinks[linkId];
    }
}
