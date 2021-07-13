pragma solidity >=0.6.0 <0.7.0;

import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@pooltogether/fixed-point/contracts/FixedPoint.sol";

import "../YieldSource.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "../../external/compound/CTokenInterface.sol";
import "../../external/compound/ComptrollerInterface.sol";

contract VenusPrizePool is YieldSource,Ownable {
    using SafeMath for uint256;
    
    event VenesPrizePoolInitialized(address indexed c);
    event Claim(address _address);
    event Transfer(uint256 amount);

    event SetPriority(uint256 _v);
    event SetAvailableQuota(uint256 _v);
    
    CTokenInterface public cTokenObject;
    uint256 internal _priority = 1;
    uint256 internal _availableQuota = uint256(-1);
    
    constructor(CTokenInterface c) public {
        cTokenObject = c;
        emit VenesPrizePoolInitialized(address(c));
    }

    function platform() external override pure returns(uint256){
        return 1;
    }
    
    function canAwardExternal(address _externalToken) external override view returns (bool){
        return _externalToken != address(cTokenObject);
    }
    function token() external override view returns (IERC20){
        return IERC20(cTokenObject.underlying());
    }

    function cToken() external override view returns (address){
        return address(cTokenObject);
    }

    function balance() external override returns (uint256){
        return cTokenObject.balanceOfUnderlying(msg.sender);
    }

    function supply(uint256 mintAmount, address _cToken) external override {
        IERC20(CTokenInterface(_cToken).underlying()).approve(_cToken, mintAmount);
        require(CTokenInterface(_cToken).mint(mintAmount) == 0, "VenusPrizePool/mint-failed");
    }

    function redeem(uint256 redeemAmount, address _cToken) external override returns (uint256) {
        IERC20 assetToken = IERC20(CTokenInterface(_cToken).underlying());
        uint256 before = assetToken.balanceOf(address(this));
        require(CTokenInterface(_cToken).redeemUnderlying(redeemAmount) == 0, "VenusPrizePool/redeem-failed");
        uint256 diff = assetToken.balanceOf(address(this)).sub(before);
        return diff;
    }

    function claim(address _address) external override {
        address comptroller = cTokenObject.comptroller();
        address[] memory cTokens = new address[](1);
        cTokens[0] =address(cTokenObject);
        ComptrollerInterface(comptroller).claimVenus(_address,cTokens);
        emit Claim(_address);
    }

    function priority() external override returns (uint256){
        return _priority;
    }

    function setPriority(uint256 _v) external onlyOwner returns (bool){
        _priority = _v;
        emit SetPriority(_v);
        return true;
    }

    function availableQuota() external override returns (uint256){
        if(_availableQuota <= cTokenObject.balanceOfUnderlying(msg.sender)){
           return 0;
        }else{
           return _availableQuota.sub(cTokenObject.balanceOfUnderlying(msg.sender));
        }
    }

    function setAvailableQuota(uint256 _v) external onlyOwner returns (bool){
        _availableQuota = _v;
        emit SetAvailableQuota(_v);
        return true;
    }
}