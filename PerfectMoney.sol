// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "@openzeppelin/contracts/utils/Context.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

contract PerfectMoney is ERC20, ERC20Burnable, Ownable, ReentrancyGuard {
    uint256 public constant MAX_SUPPLY = 100_000_000_000 * 10**18;
    bool public mintingDisabled = false;

    constructor() ERC20("Perfect Money", "PM") Ownable(msg.sender) {
        _mint(msg.sender, MAX_SUPPLY);
    }

    /// @notice Permanently disables the mint function. Cannot be undone.
    function disableMintingForever() external onlyOwner {
        mintingDisabled = true;
    }

    /// @notice Mint function, permanently disabled once `disableMintingForever` is called
    function mint(address to, uint256 amount) external onlyOwner {
        require(!mintingDisabled, "Minting has been permanently disabled");
        require(totalSupply() + amount <= MAX_SUPPLY, "Max supply exceeded");
        _mint(to, amount);
    }

    /// @notice Override transfer to prevent reentrancy attacks
    function transfer(address to, uint256 amount) 
        public override nonReentrant returns (bool) 
    {
        return super.transfer(to, amount);
    }

    /// @notice Override transferFrom to prevent reentrancy attacks
    function transferFrom(address from, address to, uint256 amount) 
        public override nonReentrant returns (bool) 
    {
        return super.transferFrom(from, to, amount);
    }
}