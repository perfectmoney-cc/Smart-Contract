// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

abstract contract Ownable {
    address private _owner;
    event OwnershipTransferred(address indexed prev, address indexed next);

    constructor() { _owner = msg.sender; emit OwnershipTransferred(address(0), msg.sender); }
    function owner() public view returns(address) { return _owner; }

    modifier onlyOwner() { require(msg.sender == _owner, "Not owner"); _; }

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "Zero address");
        emit OwnershipTransferred(_owner, newOwner);
        _owner = newOwner;
    }
}

abstract contract ReentrancyGuard {
    uint256 private constant NOT_ENTERED = 1;
    uint256 private constant ENTERED     = 2;
    uint256 private status;

    constructor() { status = NOT_ENTERED; }

    modifier nonReentrant() {
        require(status != ENTERED, "Reentrant");
        status = ENTERED;
        _;
        status = NOT_ENTERED;
    }
}

/**
 * @title Multi-Round Token Presale (Seed → Private → Public)
 */
contract MultiRoundPresale is Ownable, ReentrancyGuard {
    IERC20 public immutable token;
    uint8  public immutable tokenDecimals;

    bool public presaleEnded;

    struct Round {
        uint256 price;         // BNB price per token (wei)
        uint256 supply;        // tokens allocated
        uint256 sold;          // tokens sold
        uint256 start;         // timestamp
        uint256 end;           // timestamp
        uint256 minBuy;        // min purchase in wei
        uint256 maxBuyTokens;  // max tokens per wallet
        bool whitelistEnabled;
        mapping(address=>bool) whitelist; 
        mapping(address=>uint256) purchased;
    }

    Round[3] public rounds;  // 0=Seed, 1=Private, 2=Public

    event TokensPurchased(address indexed buyer, uint8 round, uint256 bnbAmount, uint256 tokenAmount);
    event RoundConfigured(uint8 round);
    event PresaleEnded();
    event ClaimContractSet(address claimContract);

    address public claimContract;

    constructor(address _token, uint8 _decimals) {
        require(_token != address(0), "Zero token");
        token = IERC20(_token);
        tokenDecimals = _decimals;
    }

    modifier onlyActiveRound(uint8 r) {
        require(!presaleEnded, "Presale ended");
        require(r < 3, "Invalid round");
        Round storage rd = rounds[r];
        require(block.timestamp >= rd.start && block.timestamp <= rd.end, "Round not active");
        _;
    }

    function configureRound(
        uint8 r,
        uint256 price,
        uint256 supply,
        uint256 start,
        uint256 end,
        uint256 minBuy,
        uint256 maxBuyTokens,
        bool whitelistEnabled
    ) external onlyOwner {
        require(r < 3, "Invalid");
        require(start < end, "Bad time");
        require(price > 0 && supply > 0, "Zero values");

        Round storage rd = rounds[r];
        rd.price = price;
        rd.supply = supply;
        rd.start = start;
        rd.end = end;
        rd.minBuy = minBuy;
        rd.maxBuyTokens = maxBuyTokens;
        rd.whitelistEnabled = whitelistEnabled;

        emit RoundConfigured(r);
    }

    function setClaimContract(address cc) external onlyOwner {
        require(cc != address(0), "Zero");
        claimContract = cc;
        emit ClaimContractSet(cc);
    }

    function setWhitelist(uint8 roundId, address[] calldata users, bool status) external onlyOwner {
        require(roundId < 3, "Invalid");
        Round storage r = rounds[roundId];
        for (uint i; i < users.length; i++) {
            r.whitelist[users[i]] = status;
        }
    }

    function buyTokens(uint8 r) external payable nonReentrant onlyActiveRound(r) {
        Round storage rd = rounds[r];

        if (rd.whitelistEnabled)
            require(rd.whitelist[msg.sender], "Not whitelisted");

        require(msg.value >= rd.minBuy, "Below min");

        uint256 tokens = (msg.value * (10 ** tokenDecimals)) / rd.price;
        require(tokens > 0, "Zero tokens");

        require(rd.sold + tokens <= rd.supply, "Exceeds round supply");
        require(rd.purchased[msg.sender] + tokens <= rd.maxBuyTokens, "Exceeds max");

        rd.purchased[msg.sender] += tokens;
        rd.sold += tokens;

        emit TokensPurchased(msg.sender, r, msg.value, tokens);
    }

    function endPresale() external onlyOwner {
        presaleEnded = true;
        emit PresaleEnded();
    }

    function withdrawBNB() external onlyOwner {
        require(presaleEnded, "Not ended");
        payable(owner()).transfer(address(this).balance);
    }

    function withdrawUnsoldTokens() external onlyOwner {
        require(presaleEnded, "Not ended");
        uint256 bal = token.balanceOf(address(this));
        require(bal > 0, "None");
        token.transfer(owner(), bal);
    }

    function purchasedAmount(uint8 r, address user) external view returns(uint256) {
        return rounds[r].purchased[user];
    }

    function isWhitelisted(uint8 r, address user) external view returns(bool) {
        return rounds[r].whitelist[user];
    }

    function getRoundInfo(uint8 r) external view returns(
        uint256 price,
        uint256 supply,
        uint256 sold,
        uint256 start,
        uint256 end,
        uint256 minBuy,
        uint256 maxBuyTokens,
        bool whitelistEnabled
    ) {
        Round storage rd = rounds[r];
        return (rd.price, rd.supply, rd.sold, rd.start, rd.end, rd.minBuy, rd.maxBuyTokens, rd.whitelistEnabled);
    }

    function getTotalSold() external view returns(uint256) {
        return rounds[0].sold + rounds[1].sold + rounds[2].sold;
    }

    function getTotalSupply() external view returns(uint256) {
        return rounds[0].supply + rounds[1].supply + rounds[2].supply;
    }

    function getActiveRound() external view returns(int8) {
        if (presaleEnded) return -1;
        for (uint8 i = 0; i < 3; i++) {
            if (block.timestamp >= rounds[i].start && block.timestamp <= rounds[i].end) {
                return int8(i);
            }
        }
        return -1;
    }
}
