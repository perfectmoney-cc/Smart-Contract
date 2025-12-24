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

abstract contract ReentrancyGuard {
    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED = 2;
    uint256 private _status;

    constructor() {
        _status = _NOT_ENTERED;
    }

    modifier nonReentrant() {
        require(_status != _ENTERED, "ReentrancyGuard: reentrant call");
        _status = _ENTERED;
        _;
        _status = _NOT_ENTERED;
    }
}

/**
 * @title PM Token Locker Contract
 * @notice Time-locked token vesting with extension capabilities
 */
contract PMTokenLocker is Ownable, ReentrancyGuard {
    struct Lock {
        address token;
        address owner;
        uint256 amount;
        uint256 lockDate;
        uint256 unlockDate;
        bool withdrawn;
        string description;
    }
    
    Lock[] public locks;
    mapping(address => uint256[]) public userLocks;
    mapping(address => uint256) public totalLockedByToken;
    
    uint256 public lockFee; // Fee in BNB
    uint256 public totalLocks;
    uint256 public totalValueLocked;
    
    event TokensLocked(
        uint256 indexed lockId,
        address indexed token,
        address indexed owner,
        uint256 amount,
        uint256 unlockDate
    );
    event TokensUnlocked(uint256 indexed lockId, address indexed owner, uint256 amount);
    event LockExtended(uint256 indexed lockId, uint256 newUnlockDate);
    event LockFeeUpdated(uint256 newFee);
    
    constructor(uint256 _lockFee) {
        lockFee = _lockFee;
    }
    
    function setLockFee(uint256 _fee) external onlyOwner {
        lockFee = _fee;
        emit LockFeeUpdated(_fee);
    }
    
    function lockTokens(
        address _token,
        uint256 _amount,
        uint256 _unlockDate,
        string calldata _description
    ) external payable nonReentrant {
        require(msg.value >= lockFee, "Insufficient fee");
        require(_token != address(0), "Invalid token");
        require(_amount > 0, "Invalid amount");
        require(_unlockDate > block.timestamp, "Unlock date must be in future");
        
        IERC20 token = IERC20(_token);
        require(token.transferFrom(msg.sender, address(this), _amount), "Transfer failed");
        
        uint256 lockId = locks.length;
        locks.push(Lock({
            token: _token,
            owner: msg.sender,
            amount: _amount,
            lockDate: block.timestamp,
            unlockDate: _unlockDate,
            withdrawn: false,
            description: _description
        }));
        
        userLocks[msg.sender].push(lockId);
        totalLockedByToken[_token] += _amount;
        totalLocks++;
        totalValueLocked += _amount;
        
        emit TokensLocked(lockId, _token, msg.sender, _amount, _unlockDate);
    }
    
    function unlockTokens(uint256 _lockId) external nonReentrant {
        require(_lockId < locks.length, "Invalid lock ID");
        Lock storage lock = locks[_lockId];
        
        require(lock.owner == msg.sender, "Not lock owner");
        require(!lock.withdrawn, "Already withdrawn");
        require(block.timestamp >= lock.unlockDate, "Lock not expired");
        
        lock.withdrawn = true;
        totalLockedByToken[lock.token] -= lock.amount;
        totalValueLocked -= lock.amount;
        
        require(IERC20(lock.token).transfer(msg.sender, lock.amount), "Transfer failed");
        
        emit TokensUnlocked(_lockId, msg.sender, lock.amount);
    }
    
    function extendLock(uint256 _lockId, uint256 _newUnlockDate) external {
        require(_lockId < locks.length, "Invalid lock ID");
        Lock storage lock = locks[_lockId];
        
        require(lock.owner == msg.sender, "Not lock owner");
        require(!lock.withdrawn, "Already withdrawn");
        require(_newUnlockDate > lock.unlockDate, "New date must be later");
        
        lock.unlockDate = _newUnlockDate;
        
        emit LockExtended(_lockId, _newUnlockDate);
    }
    
    function getLock(uint256 _lockId) external view returns (
        address token,
        address owner,
        uint256 amount,
        uint256 lockDate,
        uint256 unlockDate,
        bool withdrawn,
        string memory description
    ) {
        require(_lockId < locks.length, "Invalid lock ID");
        Lock storage lock = locks[_lockId];
        return (
            lock.token,
            lock.owner,
            lock.amount,
            lock.lockDate,
            lock.unlockDate,
            lock.withdrawn,
            lock.description
        );
    }
    
    function getUserLocks(address _user) external view returns (uint256[] memory) {
        return userLocks[_user];
    }
    
    function getUserActiveLocks(address _user) external view returns (Lock[] memory) {
        uint256[] storage lockIds = userLocks[_user];
        uint256 activeCount = 0;
        
        for (uint256 i = 0; i < lockIds.length; i++) {
            if (!locks[lockIds[i]].withdrawn) {
                activeCount++;
            }
        }
        
        Lock[] memory activeLocks = new Lock[](activeCount);
        uint256 index = 0;
        
        for (uint256 i = 0; i < lockIds.length; i++) {
            if (!locks[lockIds[i]].withdrawn) {
                activeLocks[index] = locks[lockIds[i]];
                index++;
            }
        }
        
        return activeLocks;
    }
    
    function getTokenLockInfo(address _token) external view returns (
        uint256 totalLocked,
        uint256 lockCount
    ) {
        uint256 count = 0;
        for (uint256 i = 0; i < locks.length; i++) {
            if (locks[i].token == _token && !locks[i].withdrawn) {
                count++;
            }
        }
        return (totalLockedByToken[_token], count);
    }
    
    function getGlobalStats() external view returns (
        uint256 _totalLocks,
        uint256 _totalValueLocked,
        uint256 _lockFee
    ) {
        return (totalLocks, totalValueLocked, lockFee);
    }
    
    function withdrawFees() external onlyOwner {
        uint256 balance = address(this).balance;
        require(balance > 0, "No fees to withdraw");
        payable(owner()).transfer(balance);
    }
    
    receive() external payable {}
}
