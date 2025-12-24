// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

interface IERC20 {
    function transfer(address recipient, uint256 amount) external returns (bool);
    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
}

interface IPancakeRouter {
    function swapExactETHForTokens(
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external payable returns (uint[] memory amounts);
    
    function swapExactTokensForETH(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external returns (uint[] memory amounts);
    
    function swapExactTokensForTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external returns (uint[] memory amounts);
    
    function getAmountsOut(uint amountIn, address[] calldata path) external view returns (uint[] memory amounts);
    
    function WETH() external pure returns (address);
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
 * @title PM Token Swap Contract
 * @notice Wrapper for PancakeSwap with fee collection
 */
contract PMSwap is Ownable {
    IPancakeRouter public pancakeRouter;
    IERC20 public pmToken;
    address public WBNB;
    
    uint256 public swapFee = 30; // 0.3% fee in basis points
    uint256 public constant MAX_FEE = 100; // 1% max fee
    uint256 public constant BASIS_POINTS = 10000;
    
    address public feeCollector;
    uint256 public totalFeesCollected;
    
    mapping(address => bool) public supportedTokens;
    
    event Swapped(
        address indexed user,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        uint256 fee
    );
    event FeeUpdated(uint256 newFee);
    event TokenSupported(address token, bool supported);
    
    constructor(address _pancakeRouter, address _pmToken) {
        pancakeRouter = IPancakeRouter(_pancakeRouter);
        pmToken = IERC20(_pmToken);
        WBNB = pancakeRouter.WETH();
        feeCollector = msg.sender;
        
        // Add default supported tokens
        supportedTokens[_pmToken] = true;
        supportedTokens[WBNB] = true;
    }
    
    function setSupportedToken(address _token, bool _supported) external onlyOwner {
        supportedTokens[_token] = _supported;
        emit TokenSupported(_token, _supported);
    }
    
    function setSwapFee(uint256 _fee) external onlyOwner {
        require(_fee <= MAX_FEE, "Fee too high");
        swapFee = _fee;
        emit FeeUpdated(_fee);
    }
    
    function setFeeCollector(address _collector) external onlyOwner {
        require(_collector != address(0), "Invalid address");
        feeCollector = _collector;
    }
    
    function swapBNBForTokens(
        address _tokenOut,
        uint256 _amountOutMin,
        uint256 _deadline
    ) external payable {
        require(supportedTokens[_tokenOut], "Token not supported");
        require(msg.value > 0, "No BNB sent");
        
        uint256 fee = (msg.value * swapFee) / BASIS_POINTS;
        uint256 swapAmount = msg.value - fee;
        
        if (fee > 0) {
            payable(feeCollector).transfer(fee);
            totalFeesCollected += fee;
        }
        
        address[] memory path = new address[](2);
        path[0] = WBNB;
        path[1] = _tokenOut;
        
        uint256[] memory amounts = pancakeRouter.swapExactETHForTokens{value: swapAmount}(
            _amountOutMin,
            path,
            msg.sender,
            _deadline
        );
        
        emit Swapped(msg.sender, WBNB, _tokenOut, msg.value, amounts[1], fee);
    }
    
    function swapTokensForBNB(
        address _tokenIn,
        uint256 _amountIn,
        uint256 _amountOutMin,
        uint256 _deadline
    ) external {
        require(supportedTokens[_tokenIn], "Token not supported");
        require(_amountIn > 0, "Invalid amount");
        
        require(IERC20(_tokenIn).transferFrom(msg.sender, address(this), _amountIn), "Transfer failed");
        IERC20(_tokenIn).approve(address(pancakeRouter), _amountIn);
        
        address[] memory path = new address[](2);
        path[0] = _tokenIn;
        path[1] = WBNB;
        
        uint256[] memory amounts = pancakeRouter.swapExactTokensForETH(
            _amountIn,
            _amountOutMin,
            path,
            address(this),
            _deadline
        );
        
        uint256 bnbReceived = amounts[1];
        uint256 fee = (bnbReceived * swapFee) / BASIS_POINTS;
        uint256 userAmount = bnbReceived - fee;
        
        if (fee > 0) {
            payable(feeCollector).transfer(fee);
            totalFeesCollected += fee;
        }
        
        payable(msg.sender).transfer(userAmount);
        
        emit Swapped(msg.sender, _tokenIn, WBNB, _amountIn, userAmount, fee);
    }
    
    function swapTokensForTokens(
        address _tokenIn,
        address _tokenOut,
        uint256 _amountIn,
        uint256 _amountOutMin,
        uint256 _deadline
    ) external {
        require(supportedTokens[_tokenIn] && supportedTokens[_tokenOut], "Token not supported");
        require(_amountIn > 0, "Invalid amount");
        
        require(IERC20(_tokenIn).transferFrom(msg.sender, address(this), _amountIn), "Transfer failed");
        IERC20(_tokenIn).approve(address(pancakeRouter), _amountIn);
        
        address[] memory path;
        if (_tokenIn == WBNB || _tokenOut == WBNB) {
            path = new address[](2);
            path[0] = _tokenIn;
            path[1] = _tokenOut;
        } else {
            path = new address[](3);
            path[0] = _tokenIn;
            path[1] = WBNB;
            path[2] = _tokenOut;
        }
        
        uint256[] memory amounts = pancakeRouter.swapExactTokensForTokens(
            _amountIn,
            _amountOutMin,
            path,
            address(this),
            _deadline
        );
        
        uint256 outputAmount = amounts[amounts.length - 1];
        uint256 fee = (outputAmount * swapFee) / BASIS_POINTS;
        uint256 userAmount = outputAmount - fee;
        
        if (fee > 0) {
            IERC20(_tokenOut).transfer(feeCollector, fee);
            totalFeesCollected += fee;
        }
        
        IERC20(_tokenOut).transfer(msg.sender, userAmount);
        
        emit Swapped(msg.sender, _tokenIn, _tokenOut, _amountIn, userAmount, fee);
    }
    
    function getAmountOut(
        address _tokenIn,
        address _tokenOut,
        uint256 _amountIn
    ) external view returns (uint256) {
        address[] memory path;
        if (_tokenIn == WBNB || _tokenOut == WBNB) {
            path = new address[](2);
            path[0] = _tokenIn;
            path[1] = _tokenOut;
        } else {
            path = new address[](3);
            path[0] = _tokenIn;
            path[1] = WBNB;
            path[2] = _tokenOut;
        }
        
        uint256[] memory amounts = pancakeRouter.getAmountsOut(_amountIn, path);
        uint256 outputAmount = amounts[amounts.length - 1];
        uint256 fee = (outputAmount * swapFee) / BASIS_POINTS;
        
        return outputAmount - fee;
    }
    
    function withdrawBNB() external onlyOwner {
        uint256 balance = address(this).balance;
        require(balance > 0, "No BNB to withdraw");
        payable(owner()).transfer(balance);
    }
    
    function withdrawTokens(address _token, uint256 _amount) external onlyOwner {
        require(IERC20(_token).transfer(owner(), _amount), "Transfer failed");
    }
    
    receive() external payable {}
}
