// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

contract PMStore is Ownable, ReentrancyGuard {
    IERC20 public pmToken;
    
    enum OrderStatus { Pending, Processing, Shipped, Delivered, Cancelled }
    enum ProductCategory { Apparel, Accessories, Collectibles, Digital, Limited }
    
    struct Product {
        uint256 id;
        string name;
        string description;
        string imageUri;
        uint256 price;
        uint256 stock;
        ProductCategory category;
        bool isActive;
        uint256 totalSold;
        uint256 totalRatings;
        uint256 ratingSum;
    }
    
    struct Order {
        uint256 id;
        address buyer;
        uint256[] productIds;
        uint256[] quantities;
        uint256 totalAmount;
        uint256 discountApplied;
        string shippingAddress;
        OrderStatus status;
        uint256 createdAt;
        uint256 updatedAt;
    }
    
    struct VoucherCode {
        string code;
        uint256 discountPercent;
        uint256 maxUses;
        uint256 usedCount;
        uint256 expiresAt;
        bool isActive;
    }
    
    struct Rating {
        address user;
        uint256 productId;
        uint8 rating;
        uint256 timestamp;
        bool rewarded;
    }
    
    // Rating reward amount in PM tokens (with 18 decimals)
    uint256 public ratingReward = 10 * 10**18; // 10 PM tokens per rating
    
    // State variables
    uint256 public productCount;
    uint256 public orderCount;
    uint256 public totalRevenue;
    uint256 public totalOrders;
    
    mapping(uint256 => Product) public products;
    mapping(uint256 => Order) public orders;
    mapping(string => VoucherCode) public vouchers;
    mapping(address => uint256[]) public userOrders;
    mapping(address => mapping(uint256 => bool)) public hasRated; // user => productId => rated
    mapping(uint256 => Rating[]) public productRatings; // productId => ratings
    uint256 public totalRatingsCount;
    
    // Events
    event ProductAdded(uint256 indexed productId, string name, uint256 price, ProductCategory category);
    event ProductUpdated(uint256 indexed productId, string name, uint256 price, uint256 stock);
    event ProductStatusChanged(uint256 indexed productId, bool isActive);
    event OrderCreated(uint256 indexed orderId, address indexed buyer, uint256 totalAmount);
    event OrderStatusUpdated(uint256 indexed orderId, OrderStatus status);
    event VoucherCreated(string code, uint256 discountPercent, uint256 maxUses);
    event VoucherUsed(string code, address indexed user, uint256 discount);
    event FundsWithdrawn(address indexed to, uint256 amount);
    event ProductRated(uint256 indexed productId, address indexed user, uint8 rating, uint256 reward);
    
    constructor(address _pmToken) Ownable(msg.sender) {
        pmToken = IERC20(_pmToken);
    }
    
    // Product Management
    function addProduct(
        string memory _name,
        string memory _description,
        string memory _imageUri,
        uint256 _price,
        uint256 _stock,
        ProductCategory _category
    ) external onlyOwner returns (uint256) {
        productCount++;
        products[productCount] = Product({
            id: productCount,
            name: _name,
            description: _description,
            imageUri: _imageUri,
            price: _price,
            stock: _stock,
            category: _category,
            isActive: true,
            totalSold: 0,
            totalRatings: 0,
            ratingSum: 0
        });
        
        emit ProductAdded(productCount, _name, _price, _category);
        return productCount;
    }
    
    function updateProduct(
        uint256 _productId,
        string memory _name,
        string memory _description,
        string memory _imageUri,
        uint256 _price,
        uint256 _stock
    ) external onlyOwner {
        require(_productId > 0 && _productId <= productCount, "Invalid product");
        Product storage product = products[_productId];
        product.name = _name;
        product.description = _description;
        product.imageUri = _imageUri;
        product.price = _price;
        product.stock = _stock;
        
        emit ProductUpdated(_productId, _name, _price, _stock);
    }
    
    function setProductStatus(uint256 _productId, bool _isActive) external onlyOwner {
        require(_productId > 0 && _productId <= productCount, "Invalid product");
        products[_productId].isActive = _isActive;
        emit ProductStatusChanged(_productId, _isActive);
    }
    
    // Voucher Management
    function createVoucher(
        string memory _code,
        uint256 _discountPercent,
        uint256 _maxUses,
        uint256 _expiresAt
    ) external onlyOwner {
        require(_discountPercent <= 50, "Max 50% discount");
        require(vouchers[_code].maxUses == 0, "Code exists");
        
        vouchers[_code] = VoucherCode({
            code: _code,
            discountPercent: _discountPercent,
            maxUses: _maxUses,
            usedCount: 0,
            expiresAt: _expiresAt,
            isActive: true
        });
        
        emit VoucherCreated(_code, _discountPercent, _maxUses);
    }
    
    function deactivateVoucher(string memory _code) external onlyOwner {
        vouchers[_code].isActive = false;
    }
    
    // Order Functions
    function createOrder(
        uint256[] memory _productIds,
        uint256[] memory _quantities,
        string memory _shippingAddress,
        string memory _voucherCode
    ) external nonReentrant returns (uint256) {
        require(_productIds.length > 0, "Empty order");
        require(_productIds.length == _quantities.length, "Length mismatch");
        
        uint256 totalAmount = 0;
        
        // Calculate total and validate stock
        for (uint256 i = 0; i < _productIds.length; i++) {
            Product storage product = products[_productIds[i]];
            require(product.isActive, "Product inactive");
            require(product.stock >= _quantities[i], "Insufficient stock");
            totalAmount += product.price * _quantities[i];
        }
        
        // Apply voucher discount
        uint256 discount = 0;
        if (bytes(_voucherCode).length > 0) {
            VoucherCode storage voucher = vouchers[_voucherCode];
            if (voucher.isActive && 
                voucher.usedCount < voucher.maxUses && 
                block.timestamp < voucher.expiresAt) {
                discount = (totalAmount * voucher.discountPercent) / 100;
                voucher.usedCount++;
                emit VoucherUsed(_voucherCode, msg.sender, discount);
            }
        }
        
        uint256 finalAmount = totalAmount - discount;
        
        // Transfer PM tokens
        require(pmToken.transferFrom(msg.sender, address(this), finalAmount), "Payment failed");
        
        // Update stock and sales
        for (uint256 i = 0; i < _productIds.length; i++) {
            Product storage product = products[_productIds[i]];
            product.stock -= _quantities[i];
            product.totalSold += _quantities[i];
        }
        
        // Create order
        orderCount++;
        orders[orderCount] = Order({
            id: orderCount,
            buyer: msg.sender,
            productIds: _productIds,
            quantities: _quantities,
            totalAmount: finalAmount,
            discountApplied: discount,
            shippingAddress: _shippingAddress,
            status: OrderStatus.Pending,
            createdAt: block.timestamp,
            updatedAt: block.timestamp
        });
        
        userOrders[msg.sender].push(orderCount);
        totalRevenue += finalAmount;
        totalOrders++;
        
        emit OrderCreated(orderCount, msg.sender, finalAmount);
        return orderCount;
    }
    
    function updateOrderStatus(uint256 _orderId, OrderStatus _status) external onlyOwner {
        require(_orderId > 0 && _orderId <= orderCount, "Invalid order");
        Order storage order = orders[_orderId];
        order.status = _status;
        order.updatedAt = block.timestamp;
        emit OrderStatusUpdated(_orderId, _status);
    }
    
    // View Functions
    function getProduct(uint256 _productId) external view returns (Product memory) {
        return products[_productId];
    }
    
    function getOrder(uint256 _orderId) external view returns (Order memory) {
        return orders[_orderId];
    }
    
    function getUserOrders(address _user) external view returns (uint256[] memory) {
        return userOrders[_user];
    }
    
    function getVoucher(string memory _code) external view returns (VoucherCode memory) {
        return vouchers[_code];
    }
    
    function getActiveProducts() external view returns (Product[] memory) {
        uint256 activeCount = 0;
        for (uint256 i = 1; i <= productCount; i++) {
            if (products[i].isActive) activeCount++;
        }
        
        Product[] memory activeProducts = new Product[](activeCount);
        uint256 index = 0;
        for (uint256 i = 1; i <= productCount; i++) {
            if (products[i].isActive) {
                activeProducts[index] = products[i];
                index++;
            }
        }
        return activeProducts;
    }
    
    function getStoreStats() external view returns (
        uint256 _productCount,
        uint256 _orderCount,
        uint256 _totalRevenue,
        uint256 _totalOrders
    ) {
        return (productCount, orderCount, totalRevenue, totalOrders);
    }
    
    // Admin Functions
    function withdrawFunds(uint256 _amount) external onlyOwner {
        require(pmToken.transfer(msg.sender, _amount), "Withdraw failed");
        emit FundsWithdrawn(msg.sender, _amount);
    }
    
    function setPMToken(address _pmToken) external onlyOwner {
        pmToken = IERC20(_pmToken);
    }
    
    function setRatingReward(uint256 _reward) external onlyOwner {
        ratingReward = _reward;
    }
    
    // Rating Functions
    function rateProduct(uint256 _productId, uint8 _rating) external nonReentrant {
        require(_productId > 0 && _productId <= productCount, "Invalid product");
        require(_rating >= 1 && _rating <= 5, "Rating must be 1-5");
        require(!hasRated[msg.sender][_productId], "Already rated");
        require(products[_productId].isActive, "Product inactive");
        
        hasRated[msg.sender][_productId] = true;
        
        Product storage product = products[_productId];
        product.totalRatings++;
        product.ratingSum += _rating;
        
        productRatings[_productId].push(Rating({
            user: msg.sender,
            productId: _productId,
            rating: _rating,
            timestamp: block.timestamp,
            rewarded: true
        }));
        
        totalRatingsCount++;
        
        // Send reward to user
        if (ratingReward > 0 && pmToken.balanceOf(address(this)) >= ratingReward) {
            require(pmToken.transfer(msg.sender, ratingReward), "Reward failed");
        }
        
        emit ProductRated(_productId, msg.sender, _rating, ratingReward);
    }
    
    function getProductRating(uint256 _productId) external view returns (uint256 avgRating, uint256 totalRatings) {
        Product memory product = products[_productId];
        if (product.totalRatings == 0) {
            return (0, 0);
        }
        return ((product.ratingSum * 10) / product.totalRatings, product.totalRatings);
    }
    
    function getUserRatedProduct(address _user, uint256 _productId) external view returns (bool) {
        return hasRated[_user][_productId];
    }
    
    function getProductRatings(uint256 _productId) external view returns (Rating[] memory) {
        return productRatings[_productId];
    }
}
