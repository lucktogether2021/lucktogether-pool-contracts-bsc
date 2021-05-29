// SPDX-License-Identifier: GPL-3.0

pragma solidity >=0.5.0 <0.7.0;
pragma experimental ABIEncoderV2;

import "./LiquidationInterface.sol";
import "./TicketInterface.sol";
import "../prize-pool/EarlyExitFeeInterface.sol";
import "@pooltogether/fixed-point/contracts/FixedPoint.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

import "@openzeppelin/contracts/math/SafeMath.sol";

contract Liquidation is Ownable, LiquidationInterface{

    event ArriveLossValueMargin(uint256 seizeToken,uint256 exitFee,uint256 intersetBorrow,uint256 calculateMargin);
    event ArriveLossValuelossValue(uint256 lossValue,uint256 margin);
    event ArriveRiskValue(uint256 riskValue);
    event CalculateCurrentRiskValue(uint256 riskValue);

    using SafeMath for uint256;
    uint256 internal constant FULL = 1e18;

    EarlyExitFeeInterface public earlyExitFeeInterface;

    struct Market {
        //Maximum loss rate  = 0.5e18;
        uint lossRateMantissa;

        //5 days;
        uint riskToleranceTime;

        //The maximum time of interest borrowed  = 7 days
        uint maxTimeInterestBorrowed;

        //The liquidation reward 5u 5e18
        uint liquidateReward;
    }

    mapping(address => Market) public markets;

    /**
     * @notice Add measure to be included in account liquidity calculation
     */
    function enterMarkets(address _measure,Market memory _market ) external onlyOwner(){
       markets[_measure] = Market({
           lossRateMantissa:_market.lossRateMantissa,
           riskToleranceTime :_market.riskToleranceTime,
           maxTimeInterestBorrowed : _market.maxTimeInterestBorrowed,
           liquidateReward : _market.liquidateReward
       });
    }

    function setLiquidateReward(address _measure,uint256 _liquidateReward) external onlyOwner(){
        markets[_measure].liquidateReward = _liquidateReward;
    }

    function setEarlyExitFeeInterface(EarlyExitFeeInterface _earlyExitFeeInterface) external onlyOwner(){
        earlyExitFeeInterface = _earlyExitFeeInterface;
    }

    /**
    * @notice Whether the borrowed assets are allowed
    */
    function borrowAllowed(address controlledToken,address account,
    uint256 addPrincipal,uint256 addBorrowAmount,uint256 addMargin,
    uint256 borrowAmount,uint256 interestBorrow,uint256 margin,uint256 borrowRateMantissa) external override {
       (uint128 creditLimitMantissa,) = creditPlanOf(controlledToken); 
       uint256 _exitFee = FixedPoint.multiplyUintByMantissa(borrowAmount,creditLimitMantissa);
       if(addBorrowAmount != 0 || addMargin != 0){
         arriveLossValue(controlledToken,account,addPrincipal,addBorrowAmount,addMargin,borrowRateMantissa,_exitFee);
       }
       arriveRiskValue(controlledToken,account,addBorrowAmount,borrowAmount,interestBorrow,margin);
    }

    /**
     * @notice Whether to allow modification of the access asset
     */
    function changeBorrowAllowed(address controlledToken,address account,uint256 principal,uint256 addBorrowAmount,uint256 borrowAmount,
    uint256 interestBorrow,uint256 margin,uint256 borrowRateMantissa) external override {
       uint256 exitFee = calculateEarlyExitFeeNoCredit(controlledToken,borrowAmount);
       if(borrowAmount != 0 || margin != 0){
          arriveLossValue(controlledToken,account,principal,borrowAmount,margin,borrowRateMantissa,exitFee);
       }
       arriveRiskValue(controlledToken,account,addBorrowAmount,borrowAmount,interestBorrow,margin);
    }

    /**
     * @notice Whether to allow the redeem of assets
     */
     function redeemAllowed(address controlledToken,address account,uint256 borrowAmount,uint256 interestBorrow,
     uint256 margin) external override {
       arriveRiskValue(controlledToken,account,0,borrowAmount,interestBorrow,margin);
     }

    /**
     * @notice More than the liquidation threshold
     */
    function arriveLossValue(address controlledToken,address account,uint256 principal,uint256 borrowAmount,uint256 margin,
    uint256 borrowRateMantissa,uint256 exitFee) public {
        address _controlledToken = controlledToken;
        uint256 seizeToken = liquidateCalculateSeizeTokens(_controlledToken,account);
        uint256 _maxTimeInterestBorrowed = markets[_controlledToken].maxTimeInterestBorrowed;
        uint256 _riskToleranceTime = markets[_controlledToken].riskToleranceTime;
        uint256 _time = _maxTimeInterestBorrowed.add(_riskToleranceTime);
        uint256 _intersetBorrow = FixedPoint.multiplyUintByMantissa(borrowAmount.mul(_time),borrowRateMantissa);
        uint256 calculateMargin = seizeToken.add(exitFee).add(_intersetBorrow);
        emit ArriveLossValueMargin(seizeToken,exitFee,_intersetBorrow,calculateMargin);
        require(calculateMargin <= margin,"Liquidation-arriveLossValue/excess value at margin");
        uint256 _lossValue = FixedPoint.multiplyUintByMantissa(principal, markets[_controlledToken].lossRateMantissa);
        emit ArriveLossValuelossValue(_lossValue,margin);
        require(margin <= _lossValue,"Liquidation-arriveLossValue/excess value at lossValue");
    }

    /**
     * @notice More than the maximum loss
     */
    function arriveRiskValue(address controlledToken,address account,uint256 addBorrowAmount,uint256 borrowAmount,
    uint256 interestBorrow,uint256 margin) public  {
       uint256 _riskValue =  FixedPoint.multiplyUintByMantissa(calculateRiskValueInternal(controlledToken,account,addBorrowAmount,
       borrowAmount,interestBorrow,margin),1);
       emit ArriveRiskValue(_riskValue);
       require(_riskValue == 0,"Liquidation-borrowAllowed/excess value at risk");
    }

    /**
     * @notice Whether to allow liquidate
     * @param controlledToken The address of the type of token the user
     * @param account The address of account 
     *
     */
    function liquidateBorrowAllowed(address controlledToken,address account) external override returns (bool){
       uint256 riskValue  = calculateRiskValue(controlledToken,account);
       uint256 _riskValue = FixedPoint.multiplyUintByMantissa(riskValue,1);
       return _riskValue != 0;
    }
    
    /**
     * @notice Calculate number of tokens of collateral asset to seize given an amount
     * @param controlledToken The address of the type of token the user
     *
     */
    function liquidateCalculateSeizeTokens(address controlledToken,address) public view override returns (uint256){
        return markets[controlledToken].liquidateReward;
    }
    
    /**
     * @notice Calculate the risk value of the user's pledge
     * @param controlledToken The address of the type of token the user
     */
    function calculateRiskValue(
    address controlledToken,address account) public override returns (uint256){
        (uint256 _borrowAmount,uint256 _interestBorrow,uint256 _margin) = TicketInterface(controlledToken).borrowBalanceCurrent(account);
        uint256 _riskValue = calculateRiskValueInternal(controlledToken,account,0,_borrowAmount,_interestBorrow,_margin);
        emit CalculateCurrentRiskValue(_riskValue);
        return _riskValue;
        
    }

    function calculateCurrentRiskValue(
    address controlledToken,address account,uint256 borrowAmount,uint256 interestBorrow,uint256 margin) public  override returns (uint256){
        uint256 _riskValue = calculateRiskValueInternal(controlledToken,account,0,borrowAmount,interestBorrow,margin);
        return _riskValue;
        
    }
    
    /**
     * @notice Calculate the risk value of the user's pledge
     * @param controlledToken The address of the type of token the user
     *
     * risk = (liquidateReward + exitFee + toleranceInterest）/（alImargin - allInterestBorrow)
     *
     */
    function calculateRiskValueInternal(
    address controlledToken,address account,uint256 addBorrowAmount,uint256 borrowAmount,uint256 interestBorrow,uint256 margin) private returns(uint256){
        uint256 _riskValue;
        if(margin == 0 && interestBorrow == 0){
            return 0;
        }
        if(margin > interestBorrow){
           uint256 seizeTokens = liquidateCalculateSeizeTokens(controlledToken,account);
           uint256 exitFee = getExitFee(controlledToken,account,addBorrowAmount,borrowAmount);
           uint256 riskToleranceFee = FixedPoint.multiplyUintByMantissa(markets[controlledToken].riskToleranceTime.mul(borrowAmount),
           TicketInterface(controlledToken).borrowRateMantissa());
           uint256 molecular = seizeTokens.add(exitFee).add(riskToleranceFee);
           uint256 denominator = margin.sub(interestBorrow);
           _riskValue = FixedPoint.calculateMantissa(molecular, denominator);
        }else{
          _riskValue = FixedPoint.calculateMantissa(1, 1);
        }
        return _riskValue;
        
    }
    
 function getExitFee(address controlledToken,address account,uint256 addBorrowAmount,
    uint256 borrowAmount) public override returns(uint256){
         uint256 exitFee;
         if(addBorrowAmount == 0){
            (exitFee,) = calculateEarlyExitFee(account,controlledToken,borrowAmount); 
         }else{
             uint256 currentBorrowAmount =  borrowAmount.sub(addBorrowAmount);
             uint256 borrowAmountexitFee;
             if(currentBorrowAmount != 0){
                (borrowAmountexitFee,) = calculateEarlyExitFee(account,controlledToken,
                currentBorrowAmount);
             }
             uint256 addBorrowAmountexitFee = calculateEarlyExitFeeNoCredit(controlledToken,addBorrowAmount);
             exitFee = borrowAmountexitFee.add(addBorrowAmountexitFee);
         }
        
        return exitFee;
    }

    function creditPlanOf(address controlledToken) public view override returns(uint128,uint128) {
        return earlyExitFeeInterface.creditPlanOf(controlledToken); 
    }

    function calculateEarlyExitFee(address account,address controlledToken,uint256 amount) public override returns( uint256 exitFee,uint256 burnedCredit) {
        return earlyExitFeeInterface.calculateEarlyExitFeeLessBurnedCredit(account,controlledToken,amount);
    }

    function calculateEarlyExitFeeNoCredit(address controlledToken,uint256 amount) public view override returns(uint256) {
        return earlyExitFeeInterface.calculateEarlyExitFeeNoCredit(controlledToken, amount);
    }    

}
