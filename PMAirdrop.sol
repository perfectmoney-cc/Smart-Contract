// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

interface IERC20 {
    function transfer(address recipient, uint256 amount) external returns (bool);
    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

/**
 * @dev Simple Ownable implementation
 */
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

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "Ownable: new owner is zero");
        emit OwnershipTransferred(_owner, newOwner);
        _owner = newOwner;
    }
}

/**
 * @title PM Token Airdrop Contract (SAFETY-ENHANCED)
 */
contract PMAirdrop is Ownable, ReentrancyGuard {
    IERC20 public pmToken;

    bytes32 public merkleRoot;
    uint256 public totalClaimed;
    uint256 public maxClaimable;

    uint256 public startTime;
    uint256 public endTime;
    bool public isActive;

    mapping(address => bool) public hasClaimed;
    mapping(address => uint256) public claimedAmount;

    // Task system
    mapping(address => mapping(uint256 => bool)) public taskCompleted;
    mapping(uint256 => uint256) public taskRewards;
    uint256 public totalTasks;

    event AirdropClaimed(address indexed user, uint256 amount);
    event TaskCompleted(address indexed user, uint256 taskId, uint256 reward);
    event MerkleRootUpdated(bytes32 newRoot);
    event AirdropStarted(uint256 start, uint256 end);
    event AirdropEnded(uint256 endTime);
    event TokensWithdrawn(uint256 amount);

    constructor(address _pmToken) {
        require(_pmToken != address(0), "Token address zero");
        pmToken = IERC20(_pmToken);
        isActive = false;
    }

    // -----------------------------------------------------
    // ADMIN FUNCTIONS
    // -----------------------------------------------------

    /**
     * @notice Start airdrop AFTER prefunding
     */
    function startAirdrop(uint256 duration, uint256 _maxClaimable)
        external
        onlyOwner
    {
        require(!isActive, "Airdrop already active");
        require(_maxClaimable > 0, "Zero max");

        // Prefunding check
        require(
            pmToken.balanceOf(address(this)) >= _maxClaimable,
            "Not enough tokens in contract"
        );

        startTime = block.timestamp;
        endTime = block.timestamp + duration;
        maxClaimable = _maxClaimable;

        isActive = true;
        emit AirdropStarted(startTime, endTime);
    }

    function endAirdrop() external onlyOwner {
        isActive = false;
        emit AirdropEnded(block.timestamp);
    }

    function setMerkleRoot(bytes32 _root) external onlyOwner {
        merkleRoot = _root;
        emit MerkleRootUpdated(_root);
    }

    function setTaskReward(uint256 taskId, uint256 reward) external onlyOwner {
        taskRewards[taskId] = reward;
        if (taskId >= totalTasks) {
            totalTasks = taskId + 1;
        }
    }

    // -----------------------------------------------------
    // CLAIM FUNCTIONS
    // -----------------------------------------------------

    /**
     * @notice Claim airdrop using Merkle proof
     * Merkle leaf = keccak256(abi.encode(msg.sender, amount))
     */
    function claim(uint256 amount, bytes32[] calldata proof)
        external
        nonReentrant
    {
        require(isActive, "Airdrop not active");
        require(block.timestamp >= startTime && block.timestamp <= endTime, "Not in airdrop window");
        require(!hasClaimed[msg.sender], "Already claimed");

        // Verify merkle proof
        bytes32 leaf = keccak256(abi.encode(msg.sender, amount));
        require(verify(proof, merkleRoot, leaf), "Invalid proof");

        require(totalClaimed + amount <= maxClaimable, "Max exceeded");

        hasClaimed[msg.sender] = true;
        claimedAmount[msg.sender] += amount;
        totalClaimed += amount;

        require(pmToken.transfer(msg.sender, amount), "Transfer failed");

        emit AirdropClaimed(msg.sender, amount);
    }

    /**
     * @notice Claim task reward
     */
    function claimTask(uint256 taskId)
        external
        nonReentrant
    {
        require(isActive, "Airdrop not active");
        require(!taskCompleted[msg.sender][taskId], "Task done");

        uint256 reward = taskRewards[taskId];
        require(reward > 0, "Invalid task");

        require(totalClaimed + reward <= maxClaimable, "Max exceeded");

        taskCompleted[msg.sender][taskId] = true;
        claimedAmount[msg.sender] += reward;
        totalClaimed += reward;

        require(pmToken.transfer(msg.sender, reward), "Transfer failed");

        emit TaskCompleted(msg.sender, taskId, reward);
    }

    // -----------------------------------------------------
    // WITHDRAW (SAFE)
    // -----------------------------------------------------

    /**
     * @notice Withdraw leftover tokens only AFTER airdrop ends
     */
    function withdrawTokens(uint256 amount)
        external
        onlyOwner
        nonReentrant
    {
        require(!isActive, "End airdrop first");
        require(block.timestamp > endTime, "Not ended");
        require(pmToken.transfer(owner(), amount), "Withdraw fail");
        emit TokensWithdrawn(amount);
    }

    // -----------------------------------------------------
    // INTERNAL MERKLE FUNCTION
    // -----------------------------------------------------

    function verify(
        bytes32[] calldata proof,
        bytes32 root,
        bytes32 leaf
    ) internal pure returns (bool) {
        bytes32 hash = leaf;
        for (uint256 i = 0; i < proof.length; i++) {
            bytes32 p = proof[i];
            hash = (hash <= p)
                ? keccak256(abi.encodePacked(hash, p))
                : keccak256(abi.encodePacked(p, hash));
        }
        return hash == root;
    }

    // -----------------------------------------------------
    // VIEW FUNCTIONS
    // -----------------------------------------------------

    function getUserTasks(address user) public view returns (uint256[] memory) {
        uint256 count = 0;

        for (uint256 i = 0; i < totalTasks; i++) {
            if (taskCompleted[user][i]) count++;
        }

        uint256[] memory result = new uint256[](count);
        uint256 index = 0;

        for (uint256 i = 0; i < totalTasks; i++) {
            if (taskCompleted[user][i]) {
                result[index] = i;
                index++;
            }
        }

        return result;
    }
}
