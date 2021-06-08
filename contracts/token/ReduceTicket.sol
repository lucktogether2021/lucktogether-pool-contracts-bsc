// SPDX-License-Identifier: GPL-3.0

pragma solidity >=0.5.0 <0.7.0;
pragma experimental ABIEncoderV2;

import "./ReduceTicketInterface.sol";
import "./TicketInterface.sol";
import "../prize-pool/EarlyExitFeeInterface.sol";
import "@pooltogether/fixed-point/contracts/FixedPoint.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

import "@openzeppelin/contracts/math/SafeMath.sol";

contract ReduceTicket is Ownable, ReduceTicketInterface{

    event ArriveLossValueMaxfee(uint256 seizeToken,uint256 exitFee,uint256 intersetAddTicket,uint256 calculateMaxfee);
    event ArriveLossValuelossValue(uint256 lossValue,uint256 maxfee);
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

        //The maximum time of incurred_fee addTicketed  = 7 days
        uint maxTimeIncurred_feeAddTicketed;

        //The reduceTicket reward 5u 5e18
        uint reduceTicketReward;
    }

    mapping(address => Market) public markets;

    /**
     * @notice Add measure to be included in account liquidity calculation
     */
    function enterMarkets(address _measure,Market memory _market ) external onlyOwner(){
       markets[_measure] = Market({
           lossRateMantissa:_market.lossRateMantissa,
           riskToleranceTime :_market.riskToleranceTime,
           maxTimeIncurred_feeAddTicketed : _market.maxTimeIncurred_feeAddTicketed,
           reduceTicketReward : _market.reduceTicketReward
       });
    }

    function setReduceTicketReward(address _measure,uint256 _reduceTicketReward) external onlyOwner(){
        markets[_measure].reduceTicketReward = _reduceTicketReward;
    }

    function setEarlyExitFeeInterface(EarlyExitFeeInterface _earlyExitFeeInterface) external onlyOwner(){
        earlyExitFeeInterface = _earlyExitFeeInterface;
    }

    /**
    * @notice Whether the addTicketed assets are allowed
    */
    function addTicketAllowed(address controlledToken,address account,
    uint256 addPrincipal,uint256 addAddTicketAmount,uint256 addMaxfee,
    uint256 addTicketAmount,uint256 incurred_feeAddTicket,uint256 maxfee,uint256 addTicketRateMantissa) external override {
       (uint128 creditLimitMantissa,) = creditPlanOf(controlledToken); 
       uint256 _exitFee = FixedPoint.multiplyUintByMantissa(addAddTicketAmount,creditLimitMantissa);
       if(addAddTicketAmount != 0 || addMaxfee != 0){
         arriveLossValue(controlledToken,account,addPrincipal,addAddTicketAmount,addMaxfee,addTicketRateMantissa,_exitFee);
       }
       arriveRiskValue(controlledToken,account,addAddTicketAmount,addTicketAmount,incurred_feeAddTicket,maxfee);
    }

    /**
     * @notice Whether to allow modification of the access asset
     */
    function changeAddTicketAllowed(address controlledToken,address account,uint256 principal,uint256 addAddTicketAmount,uint256 addTicketAmount,
    uint256 incurred_feeAddTicket,uint256 maxfee,uint256 addTicketRateMantissa) external override {
       uint256 exitFee = getExitFee(controlledToken,account,addAddTicketAmount,addTicketAmount); 
       if(addTicketAmount != 0 || maxfee != 0){
          arriveLossValue(controlledToken,account,principal,addTicketAmount,maxfee,addTicketRateMantissa,exitFee);
       }
       arriveRiskValue(controlledToken,account,addAddTicketAmount,addTicketAmount,incurred_feeAddTicket,maxfee);
    }

    /**
     * @notice More than the reduceTicket threshold
     */
    function arriveLossValue(address controlledToken,address account,uint256 principal,uint256 addTicketAmount,uint256 maxfee,
    uint256 addTicketRateMantissa,uint256 exitFee) public {
        address _controlledToken = controlledToken;
        uint256 seizeToken = reduceTicketCalculateSeizeTokens(_controlledToken,account);
        uint256 _maxTimeIncurred_feeAddTicketed = markets[_controlledToken].maxTimeIncurred_feeAddTicketed;
        uint256 _riskToleranceTime = markets[_controlledToken].riskToleranceTime;
        uint256 _time = _maxTimeIncurred_feeAddTicketed.add(_riskToleranceTime);
        uint256 _intersetAddTicket = FixedPoint.multiplyUintByMantissa(addTicketAmount.mul(_time),addTicketRateMantissa);
        uint256 calculateMaxfee = seizeToken.add(exitFee).add(_intersetAddTicket);
        emit ArriveLossValueMaxfee(seizeToken,exitFee,_intersetAddTicket,calculateMaxfee);
        require(calculateMaxfee <= maxfee,"ReduceTicket-arriveLossValue/excess value at maxfee");
        uint256 _lossValue = FixedPoint.multiplyUintByMantissa(principal, markets[_controlledToken].lossRateMantissa);
        emit ArriveLossValuelossValue(_lossValue,maxfee);
        require(maxfee <= _lossValue,"ReduceTicket-arriveLossValue/excess value at lossValue");
    }

    /**
     * @notice More than the maximum loss
     */
    function arriveRiskValue(address controlledToken,address account,uint256 addAddTicketAmount,uint256 addTicketAmount,
    uint256 incurred_feeAddTicket,uint256 maxfee) public  {
       uint256 _riskValue =  FixedPoint.multiplyUintByMantissa(calculateRiskValueInternal(controlledToken,account,addAddTicketAmount,
       addTicketAmount,incurred_feeAddTicket,maxfee),1);
       emit ArriveRiskValue(_riskValue);
       require(_riskValue == 0,"ReduceTicket-addTicketAllowed/excess value at risk");
    }

    /**
     * @notice Whether to allow reduceTicket
     * @param controlledToken The address of the type of token the user
     * @param account The address of account 
     *
     */
    function reduceAddTicketAllowed(address controlledToken,address account) external override returns (bool){
       uint256 riskValue  = calculateRiskValue(controlledToken,account);
       uint256 _riskValue = FixedPoint.multiplyUintByMantissa(riskValue,1);
       return _riskValue != 0;
    }
    
    /**
     * @notice Calculate number of tokens of collateral asset to seize given an amount
     * @param controlledToken The address of the type of token the user
     *
     */
    function reduceTicketCalculateSeizeTokens(address controlledToken,address) public view override returns (uint256){
        return markets[controlledToken].reduceTicketReward;
    }
    
    /**
     * @notice Calculate the risk value of the user's pledge
     * @param controlledToken The address of the type of token the user
     */
    function calculateRiskValue(
    address controlledToken,address account) public override returns (uint256){
        (uint256 _addTicketAmount,uint256 _incurred_feeAddTicket,uint256 _maxfee) = TicketInterface(controlledToken).addTicketBalanceCurrent(account);
        uint256 _riskValue = calculateRiskValueInternal(controlledToken,account,0,_addTicketAmount,_incurred_feeAddTicket,_maxfee);
        emit CalculateCurrentRiskValue(_riskValue);
        return _riskValue;
        
    }

    function calculateCurrentRiskValue(
    address controlledToken,address account,uint256 addTicketAmount,uint256 incurred_feeAddTicket,uint256 maxfee) public  override returns (uint256){
        uint256 _riskValue = calculateRiskValueInternal(controlledToken,account,0,addTicketAmount,incurred_feeAddTicket,maxfee);
        return _riskValue;
        
    }
    
    /**
     * @notice Calculate the risk value of the user's pledge
     * @param controlledToken The address of the type of token the user
     *
     * risk = (reduceTicketReward + exitFee + toleranceIncurred_fee）/（alImaxfee - allIncurred_feeAddTicket)
     *
     */
    function calculateRiskValueInternal(
    address controlledToken,address account,uint256 addAddTicketAmount,uint256 addTicketAmount,uint256 incurred_feeAddTicket,uint256 maxfee) private returns(uint256){
        uint256 _riskValue;
        if(maxfee == 0 && incurred_feeAddTicket == 0){
            return 0;
        }
        if(maxfee > incurred_feeAddTicket){
           uint256 seizeTokens = reduceTicketCalculateSeizeTokens(controlledToken,account);
           uint256 exitFee = getExitFee(controlledToken,account,addAddTicketAmount,addTicketAmount);
           uint256 riskToleranceFee = FixedPoint.multiplyUintByMantissa(markets[controlledToken].riskToleranceTime.mul(addTicketAmount),
           TicketInterface(controlledToken).addTicketRateMantissa());
           uint256 molecular = seizeTokens.add(exitFee).add(riskToleranceFee);
           uint256 denominator = maxfee.sub(incurred_feeAddTicket);
           _riskValue = FixedPoint.calculateMantissa(molecular, denominator);
        }else{
          _riskValue = FixedPoint.calculateMantissa(1, 1);
        }
        return _riskValue;
        
    }
    
 function getExitFee(address controlledToken,address account,uint256 addAddTicketAmount,
    uint256 addTicketAmount) public override returns(uint256){
         uint256 exitFee;
         if(addAddTicketAmount == 0){
            (exitFee,) = calculateEarlyExitFee(account,controlledToken,addTicketAmount); 
         }else{
             uint256 currentAddTicketAmount =  addTicketAmount.sub(addAddTicketAmount);
             uint256 addTicketAmountexitFee;
             if(currentAddTicketAmount != 0){
                (addTicketAmountexitFee,) = calculateEarlyExitFee(account,controlledToken,
                currentAddTicketAmount);
             }
             uint256 addAddTicketAmountexitFee = calculateEarlyExitFeeNoCredit(controlledToken,addAddTicketAmount);
             exitFee = addTicketAmountexitFee.add(addAddTicketAmountexitFee);
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
