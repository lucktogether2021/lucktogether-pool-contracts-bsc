pragma solidity >=0.6.0 <0.7.0;

import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@pooltogether/fixed-point/contracts/FixedPoint.sol";

import "../YieldSource.sol";
import "../../external/compound/CTokenInterface.sol";
import "../../external/compound/ComptrollerInterface.sol";

contract StakePrizePool is YieldSource {
    using SafeMath for uint256;
    
    event StakePrizePoolInitialized(address indexed token);
    event Claim();
    event Transfer(uint256 amount);
    
    IERC20 override public token;
    uint256 internal _priority = 1;
    uint256 internal _availableQuota = uint256(-1);
    
    constructor(IERC20 _token) public {
        token = _token;
        emit StakePrizePoolInitialized(address(token));
    }

    function platform() external override pure returns(uint256){
        return 0;
    }
    
    function canAwardExternal(address) external override view returns (bool){
        return true;
    }

    function balance() external override returns (uint256){
        return token.balanceOf(msg.sender);
    }

    function cToken() external override view returns (address){
        return address(0);
    }

    function supply(uint256 mintAmount, address _cToken) external override {
    }

    function redeem(uint256 redeemAmount, address) external override returns (uint256) {
        return redeemAmount;
    }

    function claim() external override {
    }

    function priority() external override returns (uint256){
        return _priority;
    }

    function setPriority(uint256 _v) external returns (bool){
        _priority = _v;
        return true;
    }

    function availableQuota() external override returns (uint256){
        return _availableQuota;
    }

    function setAvailableQuota(uint256 _v) external returns (bool){
        _availableQuota = _v;
        return true;
    }
}