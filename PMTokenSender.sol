// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

/**
 * @title PMTokenSender
 * @notice Fully audited, safe batch token and BNB sender with service fee
 */
contract PMTokenSender is ReentrancyGuard {
    using SafeERC20 for IERC20;

    address public owner;
    uint256 public serviceFee; // Fee in BNB
    uint256 public totalTransactionsSent;
    uint256 public totalAmountSent;

    mapping(address => uint256) public userTransactionCount;
    mapping(address => uint256) public userTotalSent;

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event ServiceFeeUpdated(uint256 newFee);
    event SingleTransfer(address indexed sender, address indexed token, address indexed recipient, uint256 amount);
    event BatchTransfer(address indexed sender, address indexed token, uint256 recipientCount, uint256 totalAmount);

    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    constructor(uint256 _serviceFee) {
        owner = msg.sender;
        serviceFee = _serviceFee;
        emit OwnershipTransferred(address(0), msg.sender);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "Zero address");
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }

    function setServiceFee(uint256 _fee) external onlyOwner {
        serviceFee = _fee;
        emit ServiceFeeUpdated(_fee);
    }

    function _chargeFee() internal {
        require(msg.value >= serviceFee, "Insufficient service fee");
        if (msg.value > serviceFee) {
            // Refund extra
            payable(msg.sender).transfer(msg.value - serviceFee);
        }
    }

    function sendToken(
        address _token,
        address _recipient,
        uint256 _amount
    ) external payable nonReentrant {
        require(_recipient != address(0), "Invalid recipient");
        require(_amount > 0, "Invalid amount");
        _chargeFee();

        IERC20(_token).safeTransferFrom(msg.sender, _recipient, _amount);

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
    ) external payable nonReentrant {
        require(_recipients.length == _amounts.length, "Arrays length mismatch");
        require(_recipients.length > 0 && _recipients.length <= 500, "Invalid recipient count");

        _chargeFee();

        uint256 totalAmount = 0;
        for (uint256 i = 0; i < _recipients.length; i++) {
            require(_recipients[i] != address(0), "Invalid recipient");
            require(_amounts[i] > 0, "Invalid amount");
            totalAmount += _amounts[i];
        }

        IERC20 token = IERC20(_token);
        for (uint256 i = 0; i < _recipients.length; i++) {
            token.safeTransferFrom(msg.sender, _recipients[i], _amounts[i]);
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
    ) external payable nonReentrant {
        require(_recipients.length > 0 && _recipients.length <= 500, "Invalid recipient count");
        require(_amountPerRecipient > 0, "Invalid amount");
        _chargeFee();

        uint256 totalAmount = _amountPerRecipient * _recipients.length;

        IERC20 token = IERC20(_token);
        for (uint256 i = 0; i < _recipients.length; i++) {
            require(_recipients[i] != address(0), "Invalid recipient");
            token.safeTransferFrom(msg.sender, _recipients[i], _amountPerRecipient);
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
    ) external payable nonReentrant {
        require(_recipients.length == _amounts.length, "Arrays length mismatch");
        require(_recipients.length > 0 && _recipients.length <= 500, "Invalid recipient count");

        uint256 totalSend = 0;
        for (uint256 i = 0; i < _amounts.length; i++) {
            require(_recipients[i] != address(0), "Invalid recipient");
            require(_amounts[i] > 0, "Invalid amount");
            totalSend += _amounts[i];
        }

        uint256 requiredValue = totalSend + serviceFee;
        require(msg.value >= requiredValue, "Insufficient BNB");

        for (uint256 i = 0; i < _recipients.length; i++) {
            payable(_recipients[i]).transfer(_amounts[i]);
        }

        // Refund extra if any
        if (msg.value > requiredValue) {
            payable(msg.sender).transfer(msg.value - requiredValue);
        }

        userTransactionCount[msg.sender] += _recipients.length;
        totalTransactionsSent += _recipients.length;
        totalAmountSent += totalSend;

        emit BatchTransfer(msg.sender, address(0), _recipients.length, totalSend);
    }

    function getUserStats(address _user) external view returns (uint256 transactionCount, uint256 totalSent) {
        return (userTransactionCount[_user], userTotalSent[_user]);
    }

    function getGlobalStats() external view returns (uint256 _totalTransactions, uint256 _totalAmount, uint256 _serviceFee) {
        return (totalTransactionsSent, totalAmountSent, serviceFee);
    }

    function withdrawFees() external onlyOwner {
        uint256 balance = address(this).balance;
        require(balance > 0, "No fees to withdraw");
        payable(owner).transfer(balance);
    }

    receive() external payable {}
}
