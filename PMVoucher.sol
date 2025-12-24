// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title PMVoucher
 * @dev On-chain voucher system for PM Token ecosystem
 * Allows merchants to create, distribute, and manage vouchers
 */
contract PMVoucher is Ownable, ReentrancyGuard {
    IERC20 public pmToken;
    
    enum VoucherType { DISCOUNT, GIFT, REWARD }
    enum VoucherStatus { ACTIVE, USED, EXPIRED, CANCELLED }
    
    struct Voucher {
        uint256 id;
        address creator;
        address assignedTo;
        string code;
        string name;
        uint256 value; // In PM tokens (for GIFT/REWARD) or percentage (for DISCOUNT, scaled by 100)
        VoucherType voucherType;
        VoucherStatus status;
        uint256 createdAt;
        uint256 expiryDate;
        uint256 usedAt;
        bool isTransferable;
    }
    
    // Voucher storage
    mapping(uint256 => Voucher) public vouchers;
    mapping(string => uint256) public codeToVoucherId;
    mapping(address => uint256[]) public userVouchers;
    mapping(address => uint256[]) public merchantCreatedVouchers;
    mapping(address => bool) public approvedMerchants;
    
    uint256 public nextVoucherId = 1;
    uint256 public merchantCreationFee = 10 * 10**18; // 10 PM tokens
    address public feeCollector;
    bool public paused;
    
    // Events
    event VoucherCreated(
        uint256 indexed id,
        address indexed creator,
        string code,
        uint256 value,
        VoucherType voucherType,
        uint256 expiryDate
    );
    event VoucherAssigned(uint256 indexed id, address indexed assignedTo);
    event VoucherRedeemed(uint256 indexed id, address indexed redeemedBy, uint256 value);
    event VoucherTransferred(uint256 indexed id, address indexed from, address indexed to);
    event VoucherCancelled(uint256 indexed id);
    event MerchantApproved(address indexed merchant);
    event MerchantRevoked(address indexed merchant);
    event CreationFeeUpdated(uint256 newFee);
    
    modifier onlyMerchant() {
        require(approvedMerchants[msg.sender] || msg.sender == owner(), "Not an approved merchant");
        _;
    }
    
    modifier whenNotPaused() {
        require(!paused, "Contract is paused");
        _;
    }
    
    constructor(address _pmToken, address _feeCollector) {
        pmToken = IERC20(_pmToken);
        feeCollector = _feeCollector;
        approvedMerchants[msg.sender] = true;
    }
    
    /**
     * @dev Create a new voucher (merchant only)
     * @param _code Unique voucher code
     * @param _name Voucher name/description
     * @param _value Value in PM tokens or discount percentage
     * @param _voucherType Type of voucher
     * @param _expiryDate Expiry timestamp
     * @param _isTransferable Whether voucher can be transferred
     */
    function createVoucher(
        string calldata _code,
        string calldata _name,
        uint256 _value,
        VoucherType _voucherType,
        uint256 _expiryDate,
        bool _isTransferable
    ) external onlyMerchant whenNotPaused nonReentrant returns (uint256) {
        require(bytes(_code).length > 0, "Code cannot be empty");
        require(bytes(_code).length <= 32, "Code too long");
        require(codeToVoucherId[_code] == 0, "Code already exists");
        require(_expiryDate > block.timestamp, "Expiry must be in future");
        require(_value > 0, "Value must be greater than 0");
        
        // For discount type, ensure percentage is <= 100%
        if (_voucherType == VoucherType.DISCOUNT) {
            require(_value <= 10000, "Discount cannot exceed 100%");
        }
        
        // Charge creation fee (except for owner)
        if (msg.sender != owner() && merchantCreationFee > 0) {
            require(
                pmToken.transferFrom(msg.sender, feeCollector, merchantCreationFee),
                "Fee transfer failed"
            );
        }
        
        // For GIFT/REWARD types, lock the tokens
        if (_voucherType != VoucherType.DISCOUNT) {
            require(
                pmToken.transferFrom(msg.sender, address(this), _value),
                "Token lock failed"
            );
        }
        
        uint256 voucherId = nextVoucherId++;
        
        vouchers[voucherId] = Voucher({
            id: voucherId,
            creator: msg.sender,
            assignedTo: address(0),
            code: _code,
            name: _name,
            value: _value,
            voucherType: _voucherType,
            status: VoucherStatus.ACTIVE,
            createdAt: block.timestamp,
            expiryDate: _expiryDate,
            usedAt: 0,
            isTransferable: _isTransferable
        });
        
        codeToVoucherId[_code] = voucherId;
        merchantCreatedVouchers[msg.sender].push(voucherId);
        
        emit VoucherCreated(voucherId, msg.sender, _code, _value, _voucherType, _expiryDate);
        
        return voucherId;
    }
    
    /**
     * @dev Assign a voucher to a specific user
     */
    function assignVoucher(uint256 _voucherId, address _to) external whenNotPaused {
        Voucher storage voucher = vouchers[_voucherId];
        require(voucher.id != 0, "Voucher does not exist");
        require(voucher.creator == msg.sender || msg.sender == owner(), "Not authorized");
        require(voucher.status == VoucherStatus.ACTIVE, "Voucher not active");
        require(voucher.assignedTo == address(0), "Already assigned");
        require(_to != address(0), "Invalid recipient");
        
        voucher.assignedTo = _to;
        userVouchers[_to].push(_voucherId);
        
        emit VoucherAssigned(_voucherId, _to);
    }
    
    /**
     * @dev Redeem a voucher by code
     */
    function redeemVoucher(string calldata _code) external whenNotPaused nonReentrant {
        uint256 voucherId = codeToVoucherId[_code];
        require(voucherId != 0, "Invalid voucher code");
        
        Voucher storage voucher = vouchers[voucherId];
        require(voucher.status == VoucherStatus.ACTIVE, "Voucher not active");
        require(block.timestamp <= voucher.expiryDate, "Voucher expired");
        
        // Check assignment
        if (voucher.assignedTo != address(0)) {
            require(voucher.assignedTo == msg.sender, "Voucher not assigned to you");
        }
        
        voucher.status = VoucherStatus.USED;
        voucher.usedAt = block.timestamp;
        
        // If not already in user's list, add it
        if (voucher.assignedTo == address(0)) {
            voucher.assignedTo = msg.sender;
            userVouchers[msg.sender].push(voucherId);
        }
        
        // Transfer tokens for GIFT/REWARD types
        if (voucher.voucherType != VoucherType.DISCOUNT) {
            require(
                pmToken.transfer(msg.sender, voucher.value),
                "Token transfer failed"
            );
        }
        
        emit VoucherRedeemed(voucherId, msg.sender, voucher.value);
    }
    
    /**
     * @dev Transfer a voucher to another user
     */
    function transferVoucher(uint256 _voucherId, address _to) external whenNotPaused {
        Voucher storage voucher = vouchers[_voucherId];
        require(voucher.id != 0, "Voucher does not exist");
        require(voucher.assignedTo == msg.sender, "Not your voucher");
        require(voucher.isTransferable, "Voucher not transferable");
        require(voucher.status == VoucherStatus.ACTIVE, "Voucher not active");
        require(_to != address(0) && _to != msg.sender, "Invalid recipient");
        
        voucher.assignedTo = _to;
        userVouchers[_to].push(_voucherId);
        
        emit VoucherTransferred(_voucherId, msg.sender, _to);
    }
    
    /**
     * @dev Cancel a voucher (creator or owner only)
     */
    function cancelVoucher(uint256 _voucherId) external whenNotPaused nonReentrant {
        Voucher storage voucher = vouchers[_voucherId];
        require(voucher.id != 0, "Voucher does not exist");
        require(voucher.creator == msg.sender || msg.sender == owner(), "Not authorized");
        require(voucher.status == VoucherStatus.ACTIVE, "Voucher not active");
        
        voucher.status = VoucherStatus.CANCELLED;
        
        // Refund locked tokens for GIFT/REWARD types
        if (voucher.voucherType != VoucherType.DISCOUNT) {
            require(
                pmToken.transfer(voucher.creator, voucher.value),
                "Refund failed"
            );
        }
        
        emit VoucherCancelled(_voucherId);
    }
    
    // View functions
    function getVoucherByCode(string calldata _code) external view returns (Voucher memory) {
        uint256 voucherId = codeToVoucherId[_code];
        require(voucherId != 0, "Voucher not found");
        return vouchers[voucherId];
    }
    
    function getUserVouchers(address _user) external view returns (uint256[] memory) {
        return userVouchers[_user];
    }
    
    function getMerchantVouchers(address _merchant) external view returns (uint256[] memory) {
        return merchantCreatedVouchers[_merchant];
    }
    
    function isVoucherValid(string calldata _code) external view returns (bool) {
        uint256 voucherId = codeToVoucherId[_code];
        if (voucherId == 0) return false;
        
        Voucher storage voucher = vouchers[voucherId];
        return voucher.status == VoucherStatus.ACTIVE && block.timestamp <= voucher.expiryDate;
    }
    
    // Admin functions
    function approveMerchant(address _merchant) external onlyOwner {
        approvedMerchants[_merchant] = true;
        emit MerchantApproved(_merchant);
    }
    
    function revokeMerchant(address _merchant) external onlyOwner {
        approvedMerchants[_merchant] = false;
        emit MerchantRevoked(_merchant);
    }
    
    function setCreationFee(uint256 _fee) external onlyOwner {
        merchantCreationFee = _fee;
        emit CreationFeeUpdated(_fee);
    }
    
    function setFeeCollector(address _feeCollector) external onlyOwner {
        require(_feeCollector != address(0), "Invalid address");
        feeCollector = _feeCollector;
    }
    
    function setPaused(bool _paused) external onlyOwner {
        paused = _paused;
    }
    
    function withdrawTokens(address _token, uint256 _amount) external onlyOwner {
        IERC20(_token).transfer(owner(), _amount);
    }
}
