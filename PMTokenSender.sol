// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

interface IERC20 {
    function transfer(address recipient, uint256 amount) external returns (bool);
    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

abstract contract Ownable {
    address private _owner;
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    constructor() {
        _owner = msg.sender;
        emit OwnershipTransferred(address(0), msg.sender);
    }

    function owner() public view returns (address) {
        return _owner;
    }

    modifier onlyOwner() {
        require(msg.sender == _owner, "Ownable: caller is not the owner");
        _;
    }

    function transferOwnership(address newOwner) public onlyOwner {
        require(newOwner != address(0), "Ownable: new owner is zero");
        emit OwnershipTransferred(_owner, newOwner);
        _owner = newOwner;
    }
}

/**
 * @title PM Token Sender Contract
 * @notice Batch token distribution with multi-send capabilities
 */
contract PMTokenSender is Ownable {
    uint256 public serviceFee; // Fee in native token (BNB)
    uint256 public totalTransactionsSent;
    uint256 public totalAmountSent;
    
    mapping(address => uint256) public userTransactionCount;
    mapping(address => uint256) public userTotalSent;
    
    event BatchTransfer(
        address indexed sender,
        address indexed token,
        uint256 recipientCount,
        uint256 totalAmount
    );
    event SingleTransfer(
        address indexed sender,
        address indexed token,
        address indexed recipient,
        uint256 amount
    );
    event ServiceFeeUpdated(uint256 newFee);
    
    constructor(uint256 _serviceFee) {
        serviceFee = _serviceFee;
    }
    
    function setServiceFee(uint256 _fee) external onlyOwner {
        serviceFee = _fee;
        emit ServiceFeeUpdated(_fee);
    }
    
    function sendToken(
        address _token,
        address _recipient,
        uint256 _amount
    ) external payable {
        require(msg.value >= serviceFee, "Insufficient fee");
        require(_recipient != address(0), "Invalid recipient");
        require(_amount > 0, "Invalid amount");
        
        IERC20 token = IERC20(_token);
        require(token.transferFrom(msg.sender, _recipient, _amount), "Transfer failed");
        
        userTransactionCount[msg.sender]++;
        userTotalSent[msg.sender] += _amount;
        totalTransactionsSent++;
        totalAmountSent += _amount;
        
        emit SingleTransfer(msg.sender, _token, _recipient, _amount);
    }
    
    function batchSendToken(
        address _token,
        address[] calldata _recipients,
        uint256[] calldata _amounts
    ) external payable {
        require(msg.value >= serviceFee, "Insufficient fee");
        require(_recipients.length == _amounts.length, "Arrays length mismatch");
        require(_recipients.length > 0, "No recipients");
        require(_recipients.length <= 500, "Too many recipients");
        
        IERC20 token = IERC20(_token);
        uint256 totalAmount = 0;
        
        for (uint256 i = 0; i < _recipients.length; i++) {
            require(_recipients[i] != address(0), "Invalid recipient");
            require(_amounts[i] > 0, "Invalid amount");
            totalAmount += _amounts[i];
        }
        
        for (uint256 i = 0; i < _recipients.length; i++) {
            require(token.transferFrom(msg.sender, _recipients[i], _amounts[i]), "Transfer failed");
        }
        
        userTransactionCount[msg.sender] += _recipients.length;
        userTotalSent[msg.sender] += totalAmount;
        totalTransactionsSent += _recipients.length;
        totalAmountSent += totalAmount;
        
        emit BatchTransfer(msg.sender, _token, _recipients.length, totalAmount);
    }
    
    function batchSendEqualAmount(
        address _token,
        address[] calldata _recipients,
        uint256 _amountPerRecipient
    ) external payable {
        require(msg.value >= serviceFee, "Insufficient fee");
        require(_recipients.length > 0, "No recipients");
        require(_recipients.length <= 500, "Too many recipients");
        require(_amountPerRecipient > 0, "Invalid amount");
        
        IERC20 token = IERC20(_token);
        uint256 totalAmount = _amountPerRecipient * _recipients.length;
        
        for (uint256 i = 0; i < _recipients.length; i++) {
            require(_recipients[i] != address(0), "Invalid recipient");
            require(token.transferFrom(msg.sender, _recipients[i], _amountPerRecipient), "Transfer failed");
        }
        
        userTransactionCount[msg.sender] += _recipients.length;
        userTotalSent[msg.sender] += totalAmount;
        totalTransactionsSent += _recipients.length;
        totalAmountSent += totalAmount;
        
        emit BatchTransfer(msg.sender, _token, _recipients.length, totalAmount);
    }
    
    function batchSendBNB(
        address[] calldata _recipients,
        uint256[] calldata _amounts
    ) external payable {
        require(_recipients.length == _amounts.length, "Arrays length mismatch");
        require(_recipients.length > 0, "No recipients");
        require(_recipients.length <= 500, "Too many recipients");
        
        uint256 totalAmount = serviceFee;
        for (uint256 i = 0; i < _amounts.length; i++) {
            totalAmount += _amounts[i];
        }
        require(msg.value >= totalAmount, "Insufficient BNB");
        
        for (uint256 i = 0; i < _recipients.length; i++) {
            require(_recipients[i] != address(0), "Invalid recipient");
            payable(_recipients[i]).transfer(_amounts[i]);
        }
        
        userTransactionCount[msg.sender] += _recipients.length;
        totalTransactionsSent += _recipients.length;
        
        emit BatchTransfer(msg.sender, address(0), _recipients.length, totalAmount - serviceFee);
    }
    
    function getUserStats(address _user) external view returns (
        uint256 transactionCount,
        uint256 totalSent
    ) {
        return (userTransactionCount[_user], userTotalSent[_user]);
    }
    
    function getGlobalStats() external view returns (
        uint256 _totalTransactions,
        uint256 _totalAmount,
        uint256 _serviceFee
    ) {
        return (totalTransactionsSent, totalAmountSent, serviceFee);
    }
    
    function withdrawFees() external onlyOwner {
        uint256 balance = address(this).balance;
        require(balance > 0, "No fees to withdraw");
        payable(owner()).transfer(balance);
    }
    
    receive() external payable {}
}
