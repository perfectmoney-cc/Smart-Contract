// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721URIStorage.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface IERC20 {
    function transferFrom(address,address,uint256) external returns(bool);
    function transfer(address,uint256) external returns(bool);
    function balanceOf(address) external view returns(uint256);
    function allowance(address,address) external view returns(uint256);
}

/// @title PMNFT - NFT Minting Contract
/// @dev ERC721 with minting, metadata, royalties, and category management
contract PMNFT is ERC721, ERC721URIStorage, Ownable, ReentrancyGuard {
    IERC20 public immutable pm;
    uint256 private _tid;
    uint256 public mFee;
    address public col;
    bool public paused;
    
    string[] public cats;
    mapping(string=>bool) public vCat;
    mapping(uint256=>M) public ms;
    mapping(address=>uint256) public mCnt;
    uint256 public tMint;

    struct M{string n;string d;string c;uint256 r;address cr;uint256 t;}

    event Mint(uint256 indexed i,address indexed c,string n,string ct,uint256 r);

    error Z();error LB();error LA();error BR();error BC();error F();error P();error CE();

    constructor(address _p)ERC721("Perfect Money NFT","PMNFT")Ownable(msg.sender){
        if(_p==address(0))revert Z();
        pm=IERC20(_p);col=msg.sender;mFee=10000e18;
        _ac("PM Digital Card");_ac("PM Voucher Card");_ac("PM Gift Cards");
        _ac("PM Partner Badge");_ac("PM Discount Card");_ac("PM VIP Exclusive Card");
    }

    modifier wP(){if(paused)revert P();_;}

    function _ac(string memory c)internal{cats.push(c);vCat[c]=true;}
    
    function _pt(address f,address t,uint256 a)internal{
        if(a==0)return;
        bool ok=f==address(this)?pm.transfer(t,a):pm.transferFrom(f,t,a);
        if(!ok)revert F();
    }

    function mint(string calldata u,string calldata n,string calldata d,string calldata c,uint256 r)external nonReentrant wP returns(uint256){
        if(r>10)revert BR();if(!vCat[c])revert BC();
        if(pm.balanceOf(msg.sender)<mFee)revert LB();
        if(pm.allowance(msg.sender,address(this))<mFee)revert LA();
        uint256 i=_tid++;
        ms[i]=M(n,d,c,r,msg.sender,block.timestamp);
        mCnt[msg.sender]++;tMint++;
        _pt(msg.sender,col,mFee);
        _safeMint(msg.sender,i);_setTokenURI(i,u);
        emit Mint(i,msg.sender,n,c,r);
        return i;
    }

    function getMs(uint256 i)external view returns(M memory){return ms[i];}
    function getCats()external view returns(string[] memory){return cats;}
    function getTotalMinted()external view returns(uint256){return tMint;}
    function getNextTokenId()external view returns(uint256){return _tid;}

    function setMFee(uint256 f)external onlyOwner{mFee=f;}
    function setCol(address c)external onlyOwner{if(c==address(0))revert Z();col=c;}
    function addCat(string calldata c)external onlyOwner{if(vCat[c])revert CE();_ac(c);}
    function wd(uint256 a)external onlyOwner{_pt(address(this),msg.sender,a);}
    function setPause(bool p)external onlyOwner{paused=p;}

    function tokenURI(uint256 i)public view override(ERC721,ERC721URIStorage)returns(string memory){return super.tokenURI(i);}
    function supportsInterface(bytes4 f)public view override(ERC721,ERC721URIStorage)returns(bool){return super.supportsInterface(f);}
}
