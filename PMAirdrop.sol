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

contract PMAirdrop is Ownable {
    IERC20 public pmToken;
    
    bytes32 public merkleRoot;
    uint256 public airdropAmount;
    uint256 public totalClaimed;
    uint256 public maxClaimable;
    
    uint256 public startTime;
    uint256 public endTime;
    bool public isActive;

    // Flat BNB fees (in wei)
    uint256 public claimFeeBNB = 0.00001 ether;  
    uint256 public networkFeeBNB = 0.00001 ether;  

    uint256 public totalFeesCollected;
    uint256 public totalNetworkFeesCollected;

    address public feeCollector;

    mapping(address => bool) public hasClaimed;
    mapping(address => uint256) public claimedAmount;

    mapping(address => mapping(uint256 => bool)) public taskCompleted;
    mapping(uint256 => uint256) public taskRewards;

    uint256 public totalTasks;

    mapping(uint256 => string) public taskNames;
    mapping(uint256 => string) public taskLinks;
    mapping(uint256 => bool) public taskEnabled;

    event AirdropClaimed(address indexed user, uint256 amount);
    event TaskCompleted(address indexed user, uint256 taskId, uint256 reward, uint256 claimFeePaid, uint256 networkFeePaid);
    event MerkleRootUpdated(bytes32 newRoot);
    event AirdropStarted(uint256 startTime, uint256 endTime);
    event FeesWithdrawn(address indexed to, uint256 claimFees, uint256 networkFees);
    event FeeCollectorUpdated(address indexed newCollector);
    event TaskConfigured(uint256 indexed taskId, string name, string link, uint256 reward, bool enabled);
    event AirdropAmountUpdated(uint256 newAmount);
    event MaxClaimableUpdated(uint256 newMaxClaimable);
    event ClaimFeeUpdated(uint256 newFee);
    event NetworkFeeUpdated(uint256 newFee);

    constructor(address _pmToken, uint256 _airdropAmount) {
        pmToken = IERC20(_pmToken);
        airdropAmount = _airdropAmount;
        feeCollector = msg.sender;
        isActive = false;
    }

    function setClaimFeeBNB(uint256 _fee) external onlyOwner {
        claimFeeBNB = _fee;
        emit ClaimFeeUpdated(_fee);
    }

    function setNetworkFeeBNB(uint256 _fee) external onlyOwner {
        networkFeeBNB = _fee;
        emit NetworkFeeUpdated(_fee);
    }

    function startAirdrop(uint256 _duration, uint256 _maxClaimable) external onlyOwner {
        require(!isActive, "Airdrop already active");
        startTime = block.timestamp;
        endTime = block.timestamp + _duration;
        maxClaimable = _maxClaimable;
        isActive = true;
        emit AirdropStarted(startTime, endTime);
    }

    function endAirdrop() external onlyOwner {
        isActive = false;
    }

    function resumeAirdrop() external onlyOwner {
        require(block.timestamp <= endTime, "Airdrop ended");
        isActive = true;
    }

    function setMerkleRoot(bytes32 _merkleRoot) external onlyOwner {
        merkleRoot = _merkleRoot;
        emit MerkleRootUpdated(_merkleRoot);
    }

    function setAirdropAmount(uint256 _amount) external onlyOwner {
        airdropAmount = _amount;
        emit AirdropAmountUpdated(_amount);
    }

    function setMaxClaimable(uint256 _maxClaimable) external onlyOwner {
        maxClaimable = _maxClaimable;
        emit MaxClaimableUpdated(_maxClaimable);
    }

    function setFeeCollector(address _collector) external onlyOwner {
        require(_collector != address(0), "Invalid collector");
        feeCollector = _collector;
        emit FeeCollectorUpdated(_collector);
    }

    function claim(bytes32[] calldata _merkleProof) external {
        require(isActive, "Airdrop inactive");
        require(block.timestamp >= startTime && block.timestamp <= endTime, "Not in time");
        require(!hasClaimed[msg.sender], "Already claimed");
        require(totalClaimed + airdropAmount <= maxClaimable, "Limit reached");

        bytes32 leaf = keccak256(abi.encodePacked(msg.sender));
        require(verify(_merkleProof, merkleRoot, leaf), "Invalid proof");

        hasClaimed[msg.sender] = true;
        claimedAmount[msg.sender] = airdropAmount;
        totalClaimed += airdropAmount;

        require(pmToken.transfer(msg.sender, airdropAmount), "Transfer failed");

        emit AirdropClaimed(msg.sender, airdropAmount);
    }

    function claimTask(uint256 _taskId) external payable {
        require(isActive, "Airdrop inactive");
        require(!taskCompleted[msg.sender][_taskId], "Already completed");
        require(taskRewards[_taskId] > 0, "Invalid task");
        require(taskEnabled[_taskId], "Task disabled");

        uint256 requiredFee = claimFeeBNB + networkFeeBNB;
        require(msg.value >= requiredFee, "Insufficient fee");

        uint256 reward = taskRewards[_taskId];
        require(totalClaimed + reward <= maxClaimable, "Limit reached");

        taskCompleted[msg.sender][_taskId] = true;
        claimedAmount[msg.sender] += reward;
        totalClaimed += reward;

        totalFeesCollected += claimFeeBNB;
        totalNetworkFeesCollected += networkFeeBNB;

        require(pmToken.transfer(msg.sender, reward), "Transfer failed");

        if (msg.value > requiredFee) {
            payable(msg.sender).transfer(msg.value - requiredFee);
        }

        emit TaskCompleted(msg.sender, _taskId, reward, claimFeeBNB, networkFeeBNB);
    }

    function configureTask(uint256 _taskId, string calldata _name, string calldata _link, uint256 _reward, bool _enabled) external onlyOwner {
        taskNames[_taskId] = _name;
        taskLinks[_taskId] = _link;
        taskRewards[_taskId] = _reward;
        taskEnabled[_taskId] = _enabled;

        if (_taskId >= totalTasks) {
            totalTasks = _taskId + 1;
        }

        emit TaskConfigured(_taskId, _name, _link, _reward, _enabled);
    }

    function setTaskEnabled(uint256 _taskId, bool _enabled) external onlyOwner {
        taskEnabled[_taskId] = _enabled;
        emit TaskConfigured(_taskId, taskNames[_taskId], taskLinks[_taskId], taskRewards[_taskId], _enabled);
    }

    function getFeeInfo() external view returns (uint256 claimFee, uint256 networkFee, uint256 totalFee) {
        return (claimFeeBNB, networkFeeBNB, claimFeeBNB + networkFeeBNB);
    }

    function getTaskInfo(uint256 _taskId) external view returns (string memory name, string memory link, uint256 reward, bool enabled) {
        return (taskNames[_taskId], taskLinks[_taskId], taskRewards[_taskId], taskEnabled[_taskId]);
    }

    function getAllTasks() external view returns (string[] memory names, string[] memory links, uint256[] memory rewards, bool[] memory enabledList) {
        names = new string[](totalTasks);
        links = new string[](totalTasks);
        rewards = new uint256[](totalTasks);
        enabledList = new bool[](totalTasks);

        for (uint256 i = 0; i < totalTasks; i++) {
            names[i] = taskNames[i];
            links[i] = taskLinks[i];
            rewards[i] = taskRewards[i];
            enabledList[i] = taskEnabled[i];
        }
    }

    function getUserTasks(address _user) external view returns (uint256[] memory completedTaskIds) {
        uint256 count = 0;
        for (uint256 i = 0; i < totalTasks; i++) {
            if (taskCompleted[_user][i]) count++;
        }

        completedTaskIds = new uint256[](count);
        uint256 idx = 0;
        for (uint256 i = 0; i < totalTasks; i++) {
            if (taskCompleted[_user][i]) {
                completedTaskIds[idx] = i;
                idx++;
            }
        }
    }

    function getAirdropInfo() external view returns (
        uint256 _startTime, uint256 _endTime, uint256 _maxClaimable, uint256 _totalClaimed,
        uint256 _airdropAmount, bool _isActive, uint256 _totalTasks, bytes32 _merkleRoot,
        uint256 _totalFeesCollected, uint256 _totalNetworkFeesCollected
    ) {
        return (startTime, endTime, maxClaimable, totalClaimed, airdropAmount, isActive, totalTasks, merkleRoot, totalFeesCollected, totalNetworkFeesCollected);
    }

    function getAdminInfo() external view returns (address _owner, address _feeCollector, uint256 _claimFeeBNB, uint256 _networkFeeBNB, uint256 _contractBalance) {
        return (owner(), feeCollector, claimFeeBNB, networkFeeBNB, address(this).balance);
    }

    function verify(bytes32[] calldata proof, bytes32 root, bytes32 leaf) internal pure returns (bool) {
        bytes32 hash = leaf;
        for (uint256 i = 0; i < proof.length; i++) {
            bytes32 proofElement = proof[i];
            if (hash <= proofElement) {
                hash = keccak256(abi.encodePacked(hash, proofElement));
            } else {
                hash = keccak256(abi.encodePacked(proofElement, hash));
            }
        }
        return hash == root;
    }

    function withdrawTokens(uint256 amount) external onlyOwner {
        require(pmToken.transfer(owner(), amount), "Transfer failed");
    }

    function withdrawFees() external onlyOwner {
        uint256 balance = address(this).balance;
        require(balance > 0, "Nothing to withdraw");
        uint256 claimFees = totalFeesCollected;
        uint256 networkFees = totalNetworkFeesCollected;
        totalFeesCollected = 0;
        totalNetworkFeesCollected = 0;
        payable(feeCollector).transfer(balance);
        emit FeesWithdrawn(feeCollector, claimFees, networkFees);
    }

    receive() external payable {}
}
