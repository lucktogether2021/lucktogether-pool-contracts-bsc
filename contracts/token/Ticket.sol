// SPDX-License-Identifier: GPL-3.0

pragma solidity >=0.6.0 <0.7.0;

import "sortition-sum-tree-factory/contracts/SortitionSumTreeFactory.sol";
import "@pooltogether/uniform-random-number/contracts/UniformRandomNumber.sol";
import "@pooltogether/fixed-point/contracts/FixedPoint.sol";

import "./ControlledToken.sol";
import "./TicketInterface.sol";
import "./ReduceTicketInterface.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract Ticket is ControlledToken, TicketInterface, Ownable{
  using SortitionSumTreeFactory for SortitionSumTreeFactory.SortitionSumTrees;

  bytes32 constant private TREE_KEY = keccak256("PoolTogether/Ticket");
  uint256 constant private MAX_TREE_LEAVES = 5;
  address public reduceTicket;

  // Ticket-weighted odds
  SortitionSumTreeFactory.SortitionSumTrees internal sortitionSumTrees;

  /**
  * @notice addTicket rate that can ever be applied (0.0002)
  */
  uint public override addTicketRateMantissa = 2314814814;

  /**
  * @notice Total amount of compensation
  */
  uint public totalCompensation;

  /**
  * @notice Total amount of addTickets 
  */
  uint public totalAddTickets;

  /**
  * @notice Incurred_fee on the amount addTicketed
  */
  uint public totalAddTicketsIncurred_fee;

  /**
  * @notice Total amount of addTickets maxfee
  */
  uint public totalsAddTicketsMaxfee;

  /**
  * @notice Timestamp that incurred_fee was last accrued at
  */
  uint public accrualTimestamp;

  /**
  * @notice Accumulator of the total earned incurred_fee rate since the opening of the market
  */
  uint public addTicketIndex;

 /**
 * @notice Container for addTicket balance information
 * @member principal Total balance , after applying the most recent balance-changing action
 * @member incurred_feeIndex Global addTicketIndex as of the most recent balance-changing action
 */
  struct AddTicketSnapshot {
        uint addTicketAmount;
        uint incurred_feeAddTicket;
        uint incurred_feeIndex;
        uint256 maxfee;
  }

  mapping(address => AddTicketSnapshot) public override accountAddTickets;

  /// @dev Emitted when AddTicket 
  event AddTicket(address addTicketer,uint256 principal,uint256 addTicketAmount,uint256 maxfee);

  /// @dev Emitted when Reddem
  event Reddem(uint256 redeemTokens,uint256 redeemAddTicketAmount,uint256 incurredFeeAddTicket,uint256 redeemMaxfee,uint256 exitFee,uint256 burnMaxfee);

  /// @dev Emitted Burn the user's maxfee
  event ExitFeeBurnMaxfee(uint256 burnMaxfee);

  event CaptureUserLiquidationBalance(uint256 balance,uint256 remainingMaxfee,uint256 compensation);

  event ChangeAddTicket(uint256 allAddTicketAmount,uint256 addMaxfeeAmount,uint256 currrentMaxfee);

  /// @dev Emitted when ReduceTicket AddTicket
  event ReduceTicketAddTicketFresh(
    address controlledToken,
    address addTicketer,
    uint256 addTicketAmount,
    uint256 incurred_feeAddTicket,
    uint256 maxfee
   );

  /// @dev Emitted when ReduceTicket AddTicket
  event ReduceTicketAddTicketComplete(
    address addTicketer,
    uint256 compensationTokens
   );
  
  event ExitFeeBurnMaxfeeRiskValue(uint256 _addTicketAmount,uint256 _incurred_feeAddTicket,uint256 _remainingMaxfee,uint256 riskValue);
  /// @dev Emitted Calculate the rewards of the pool
  event CaptureAwardBalance(
    uint256 originalAwardBalance,
    uint256 awardBalance,  
    uint256 totalsAddTicketsMaxfee,
    uint256 totalAddTicketsIncurredFee,
    uint256 totalCompensation
  );

  event CaptureAwardBalanceComplete(
    uint256 totalsAddTicketsMaxfee,
    uint256 totalAddTicketsIncurredFee,
    uint256 totalCompensation
  );
  
  /// @notice Initializes the Controlled Token with Token Details and the Controller
  /// @param _name The name of the Token
  /// @param _symbol The symbol for the Token
  /// @param _decimals The number of decimals for the Token
  /// @param _controller Address of the Controller contract for minting & burning
  constructor(
    string memory _name,
    string memory _symbol,
    uint8 _decimals,
    TokenControllerInterface _controller
  ) public
    ControlledToken(_name, _symbol, _decimals, _controller)
  {
    sortitionSumTrees.createTree(TREE_KEY, MAX_TREE_LEAVES);
    accrualTimestamp  = _currentTime();
  }

  function setAddTicketRateMantissa(uint256 _addTicketRateMantissa) external onlyOwner(){
    accrueIncurred_fee();
    addTicketRateMantissa = _addTicketRateMantissa;
  }

  function setReduceTicket(address _reduceTicket) external onlyOwner() {
    reduceTicket = _reduceTicket;
  }

  /// @notice Returns the user's chance of winning.
  function chanceOf(address user) external view returns (uint256) {
    return sortitionSumTrees.stakeOf(TREE_KEY, bytes32(uint256(user)));
  }


  /// @notice Take the total share, the total share in the first stage is the total votes
  function getAllShares() external  override view returns (uint256) {
    return totalSupply().add(totalAddTickets);
  }

  /// @notice Get the user assets, the first stage user assets is the user balance
  function getUserAssets(address user) external override view returns (uint256) {
    return balanceOf(user).add(accountAddTickets[user].addTicketAmount);
  }

  /// @notice Selects a user using a random number.  The random number will be uniformly bounded to the ticket totalSupply.
  /// @param randomNumber The random number to use to select a user.
  /// @return The winner
  function draw(uint256 randomNumber) external view override returns (address) {
    uint256 bound = totalSupply();
    address selected;
    if (bound == 0) {
      selected = address(0);
    } else {
      uint256 token = UniformRandomNumber.uniform(randomNumber, bound);
      selected = address(uint256(sortitionSumTrees.draw(TREE_KEY, token)));
    }
    return selected;
  }
  
  /**
  * @dev Moves tokens `amount` from `sender` to `recipient`.
  *
  * This is internal function is equivalent to {transfer}, and can be used to
  * e.g. implement automatic token fees, slashing mechanisms, etc.
  *
  * Emits a {Transfer} event.
  *
  * Requirements:
  *
  * - `sender` cannot be the zero address.
  * - `recipient` cannot be the zero address.
  * - `sender` must have a balance of at least `amount`.
  */  
  function _transfer(address sender, address recipient, uint256 amount) internal virtual override {
    require(accountAddTickets[sender].addTicketAmount == 0,"ERC20: transfer from the existence of addTicket amount");
    super._transfer(sender, recipient, amount);
  }
  
  /// @dev Controller hook to provide notifications & rule validations on token transfers to the controller.
  /// This includes minting and burning.
  /// May be overridden to provide more granular control over operator-burning
  /// @param from Address of the account sending the tokens (address(0x0) on minting)
  /// @param to Address of the account receiving the tokens (address(0x0) on burning)
  /// @param amount Amount of tokens being transferred
  function _beforeTokenTransfer(address from, address to, uint256 amount) internal virtual override {
    super._beforeTokenTransfer(from, to, amount);

    // optimize: ignore transfers to self
    if (from == to) {
      return;
    }

    if (from != address(0)) {
      uint256 fromBalance = balanceOf(from).sub(amount);
      uint256 _fromBalance= fromBalance.add(accountAddTickets[from].addTicketAmount);
      sortitionSumTrees.set(TREE_KEY, _fromBalance, bytes32(uint256(from)));
    }

    if (to != address(0)) {
      uint256 toBalance = balanceOf(to).add(amount);
      uint256 _toBalance = toBalance.add(accountAddTickets[to].addTicketAmount);
      sortitionSumTrees.set(TREE_KEY, _toBalance, bytes32(uint256(to)));
    }
  }

  /**
  * @notice Applies accrued incurred_fee to total addTickets 6
  * @dev This calculates incurred_fee accrued from the last checkpointed time
  *  up to the current time and writes new checkpoint to storage.
  */
  function accrueIncurred_fee() public returns (uint256) { 
    uint256 currentTimestamp = _currentTime();
    if(currentTimestamp == accrualTimestamp) return 0;
    uint256 secondsDelta = currentTimestamp.sub(accrualTimestamp);
    uint256 incurred_feeAccumulated;
    if(totalAddTickets != 0){
      uint256 simpleIncurred_feeFactor = secondsDelta.mul(addTicketRateMantissa);
      incurred_feeAccumulated = FixedPoint.multiplyUintByMantissa(simpleIncurred_feeFactor,totalAddTickets);
      uint256 indexDeltaMantissa = FixedPoint.calculateMantissa(incurred_feeAccumulated,totalAddTickets);
      addTicketIndex = addTicketIndex.add(indexDeltaMantissa);
      totalAddTicketsIncurred_fee = totalAddTicketsIncurred_fee.add(incurred_feeAccumulated);
    }
    accrualTimestamp = currentTimestamp;
    return incurred_feeAccumulated;
  }

  /**
   * @notice Sender addTickets assets from the protocol to their own address
   * @param _address The address
   * @param _amount The amount of the asset 
   * 
   */
  function fresh(address _address,uint _amount,uint _maxfee,bool isAddTicket) internal returns (uint256) {
    AddTicketSnapshot memory addTicketSnapshot = accountAddTickets[_address];
    uint256 deltaAddTicketIndexMantissa = uint256(addTicketIndex).sub(addTicketSnapshot.incurred_feeIndex);

    //Calculate the addTicketings incurred
    uint256 newAddTickets = FixedPoint.multiplyUintByMantissa(addTicketSnapshot.addTicketAmount, deltaAddTicketIndexMantissa);

    if(isAddTicket){
      accountAddTickets[_address].addTicketAmount = addTicketSnapshot.addTicketAmount.add(_amount);
    }
    accountAddTickets[_address].incurred_feeAddTicket = uint256(addTicketSnapshot.incurred_feeAddTicket).add(newAddTickets);
    accountAddTickets[_address].incurred_feeIndex = addTicketIndex; 
    accountAddTickets[_address].maxfee = uint256(addTicketSnapshot.maxfee).add(_maxfee);
    return newAddTickets;
  
  }

  /**
   * @notice Increase the user's MaxFee
   * @param addTicketer The address to increase maxFee
   * 
   */
  function addMaxfee(address addTicketer,uint256 maxfeeAmount) internal {
    AddTicketSnapshot memory addTicketSnapshot = accountAddTickets[addTicketer];
    accountAddTickets[addTicketer].maxfee = addTicketSnapshot.maxfee.add(maxfeeAmount);
    totalsAddTicketsMaxfee = totalsAddTicketsMaxfee.add(maxfeeAmount);

  }

  /**
   * @notice Sender addTickets assets from the protocol to their own address
   * @param addTicketAmount The amount of the underlying asset to addTicket
   * 
   */
  function addTicket(address addTicketer,uint256 principal,uint256 addTicketAmount,uint256 maxfee) 
  override external onlyController{
    if(principal == 0 && addTicketAmount == 0 && maxfee != 0){
      addMaxfee(addTicketer,maxfee);
    }else{
      accrueIncurred_fee();
      if(addTicketAmount != 0 || accountAddTickets[addTicketer].addTicketAmount != 0){ 
        addTicketInternal(addTicketer,principal,addTicketAmount,maxfee);
      }
    }

  }

  /**
   * @notice Sender addTickets assets from the protocol to their own address
   * @param addTicketAmount The amount of the underlying asset to addTicket
   * 
   */
  function addTicketInternal(address addTicketer,uint256 principal,uint256 addTicketAmount,uint256 maxfee) internal{
    AddTicketSnapshot memory addTicketSnapshot = accountAddTickets[addTicketer];
    uint256 deltaAddTicketIndexMantissa = uint256(addTicketIndex).sub(addTicketSnapshot.incurred_feeIndex);
    //Calculate the addTicketings incurred
    uint256 newAddTickets = FixedPoint.multiplyUintByMantissa(addTicketSnapshot.addTicketAmount, deltaAddTicketIndexMantissa);
    uint256 _addTicketAmount = addTicketSnapshot.addTicketAmount.add(addTicketAmount);
    uint256 _incurred_feeAddTicket = uint256(addTicketSnapshot.incurred_feeAddTicket).add(newAddTickets);
    uint256 _maxfee = uint256(addTicketSnapshot.maxfee).add(maxfee);
    ReduceTicketInterface(reduceTicket).addTicketAllowed(address(this),addTicketer,principal,addTicketAmount,maxfee,
    _addTicketAmount,_incurred_feeAddTicket,_maxfee,addTicketRateMantissa);
    fresh(addTicketer,addTicketAmount,maxfee,true);
    totalsAddTicketsMaxfee = totalsAddTicketsMaxfee.add(maxfee);
    totalAddTickets = totalAddTickets.add(addTicketAmount);

    emit AddTicket(addTicketer,principal,addTicketAmount,maxfee);
  }
  
  /**
  * @notice Sender redeems ticket in exchange for the asset
  *
  */
  function redeem(address from,
    uint256 amount,
    uint256 maximumExitFee) external override onlyController returns(uint256,uint256,uint256,uint256){

    uint256 exitFee;
    uint256 burnedCredit;
    address _from = from;
    uint256 _amount = amount;
    (uint256 _redeemTokens,uint256 _redeemAddTicketAmount,uint256 _redeemMaxfee,bool isReddemAll) = redeemInternal(_from, _amount);
  
    (exitFee, burnedCredit) = ReduceTicketInterface(reduceTicket).calculateEarlyExitFee(_from, address(this), _redeemTokens.add(_redeemAddTicketAmount));
    require(exitFee <= maximumExitFee, "PrizePool/exit-fee-exceeds-user-maximum");
    uint _maxfee;
    if(_redeemAddTicketAmount != 0 && accountAddTickets[_from].addTicketAmount != 0){
      _maxfee = accountAddTickets[_from].maxfee.sub(accountAddTickets[_from].incurred_feeAddTicket);
       redeemComplete(_from,_redeemAddTicketAmount,isReddemAll);
    }

    (uint256 _exitFee,uint256 _burnMaxfee) = redeemCalculateBurnMaxfee(_redeemTokens,_redeemAddTicketAmount,exitFee);
    
    if(isReddemAll){
      _redeemMaxfee = _maxfee.sub(_burnMaxfee);
    }else{
      exitFeeBurnMaxfee(_from, _burnMaxfee);
    }
    addTotalAddTicketsIncurredFee(_burnMaxfee);

    upDataSubTotalsAddTicketsMaxfee(_redeemMaxfee);
    // redeem the tickets less the fee
    uint256 amountLessFee = _amount.sub(_exitFee).add(_redeemMaxfee);

    emit Reddem(_redeemTokens,_redeemAddTicketAmount,accountAddTickets[_from].incurred_feeAddTicket,_redeemMaxfee,_exitFee,_burnMaxfee);
    return (amountLessFee,_redeemMaxfee,exitFee,burnedCredit);
  }

  function redeemCalculateBurnMaxfee(uint256 _redeemTokens,uint256 _redeemAddTicketAmount,uint256 exitFee) internal pure returns(uint256,uint256){

    uint256 _exitFee;
    uint256 _burnMaxfee;
    if(_redeemAddTicketAmount == 0){
       _exitFee = exitFee;
    }else{
      uint256 _allTokens = _redeemTokens.add(_redeemAddTicketAmount);
      _burnMaxfee = exitFee.mul(_redeemAddTicketAmount).div(_allTokens);
      _exitFee = exitFee.sub(_burnMaxfee);
    }
    return(_exitFee,_burnMaxfee);

  }

  /**
  * @notice Sender redeems ticket in exchange for the asset
  * @param redeemAddress The address of the redeem
  * @param redeemTokens redeemTokens The number of cTokens to redeem
  *
  */
function redeemInternal(address redeemAddress,uint256 redeemTokens) internal returns(uint256,uint256,uint256,bool){
      accrueIncurred_fee();
      uint256 _originalBalance = balanceOf(redeemAddress);
      uint256 _balance = _originalBalance.sub(redeemTokens);
      if(accountAddTickets[redeemAddress].addTicketAmount == 0){
         emit Reddem(redeemTokens,0,0,0,0,0);
         return (redeemTokens,0,0,_balance == 0);
      }
      fresh(redeemAddress,0,0,false);

      address _redeem = redeemAddress;
      uint256 _redeemTokens;
      uint256 _redeemAddTicketAmount;
      uint256 _redeemMaxfee;
      uint256 _addTicketAmountNew;
 
      uint256 _riskValue;
      if(_balance == 0){
        _riskValue = FixedPoint.multiplyUintByMantissa(ReduceTicketInterface(reduceTicket).calculateCurrentRiskValue(address(this),_redeem,
        accountAddTickets[_redeem].addTicketAmount,accountAddTickets[_redeem].incurred_feeAddTicket,accountAddTickets[_redeem].maxfee),1);
        if(_riskValue != 0){
          _redeemMaxfee = redeemMoreThanRiskInternal(_redeem);
          _redeemAddTicketAmount = 0;
        }else{
          _redeemAddTicketAmount = accountAddTickets[_redeem].addTicketAmount;
        }
       
      }else{
        _addTicketAmountNew = accountAddTickets[_redeem].addTicketAmount.mul(_balance).div(_originalBalance);
        _redeemAddTicketAmount = accountAddTickets[_redeem].addTicketAmount.sub(_addTicketAmountNew);
        
        _riskValue = FixedPoint.multiplyUintByMantissa(ReduceTicketInterface(reduceTicket).calculateCurrentRiskValue(address(this),_redeem,
       _addTicketAmountNew,accountAddTickets[_redeem].incurred_feeAddTicket,accountAddTickets[_redeem].maxfee),1);
       if(_riskValue != 0){
          _redeemMaxfee = redeemMoreThanRiskInternal(_redeem);
          _redeemAddTicketAmount = 0;
       }

      }
     _redeemTokens = redeemTokens; 
     return (_redeemTokens,_redeemAddTicketAmount,_redeemMaxfee,_balance == 0);
}
  
  /**
  * @notice It was above the value at risk when it was redeemed
  * @param _redeem The address of the redeem
  *
  */
  function redeemMoreThanRiskInternal(address _redeem) internal returns( uint256 _redeemMaxfee){
          uint256 exitFee = ReduceTicketInterface(reduceTicket).getExitFee(address(this), _redeem, 0, accountAddTickets[_redeem].addTicketAmount);
          addTotalAddTicketsIncurredFee(exitFee);
          uint256 _payAmount = accountAddTickets[_redeem].incurred_feeAddTicket.add(exitFee).add(reduceTicketCalculateSeizeTokens(_redeem));
          uint256 compensationTokens = 0;
          if(accountAddTickets[_redeem].maxfee > _payAmount){
             _redeemMaxfee = accountAddTickets[_redeem].maxfee.sub(_payAmount).add(reduceTicketCalculateSeizeTokens(_redeem));
          }else{
             compensationTokens = _payAmount.sub(accountAddTickets[_redeem].maxfee);
          }
          reduceTicketComplete(_redeem,0,compensationTokens);
          return _redeemMaxfee;
  
  }

  /**
  * @notice Sender redeems ticket in exchange for the asset
  *
  */
  function redeemComplete(address _redeem,uint256 _redeemAddTicketAmount,bool isReddemAll) internal{
    if(isReddemAll){
        totalAddTickets = totalAddTickets.sub(accountAddTickets[_redeem].addTicketAmount);
        accountAddTickets[_redeem].addTicketAmount = 0;
        accountAddTickets[_redeem].incurred_feeAddTicket = 0;
        accountAddTickets[_redeem].maxfee = 0;


    }else{
        uint256 _addTicketAmountNew = accountAddTickets[_redeem].addTicketAmount.sub(_redeemAddTicketAmount);
        accountAddTickets[_redeem].addTicketAmount = _addTicketAmountNew;
        totalAddTickets = totalAddTickets.sub(_redeemAddTicketAmount);
    }

  }

  /// @notice Update the user's value
  function upDataSortitionSumTrees(address _address ,uint256 _amount) external override onlyController {
      sortitionSumTrees.set(TREE_KEY, _amount, bytes32(uint256(_address)));
  }

  /***
   * @notice Burn the user's maxfee
   *
   */
  function exitFeeBurnMaxfee(address account,uint256 _burnAmount) internal {
      if(_burnAmount != 0){
        uint256 _remainingMaxfee = accountAddTickets[account].maxfee.sub(_burnAmount);
        uint256 _addTicketAmount = accountAddTickets[account].addTicketAmount;
        uint256 _incurred_feeAddTicket = accountAddTickets[account].incurred_feeAddTicket;
        uint256 _riskValue = FixedPoint.multiplyUintByMantissa(ReduceTicketInterface(reduceTicket).calculateCurrentRiskValue(address(this),
        account,_addTicketAmount, _incurred_feeAddTicket,_remainingMaxfee),1);
        emit ExitFeeBurnMaxfeeRiskValue(_addTicketAmount,_incurred_feeAddTicket,_remainingMaxfee,_riskValue);
        require(_riskValue == 0,"Ticket-exitFeeBurnMaxfee/excess value at risk");
        accountAddTickets[account].maxfee = _remainingMaxfee;
      }
      emit ExitFeeBurnMaxfee(_burnAmount);
  }


  function addTotalAddTicketsIncurredFee(uint256 amount) internal{
      totalAddTicketsIncurred_fee = totalAddTicketsIncurred_fee.add(amount);
  }

  function upDataSubTotalsAddTicketsMaxfee(uint256 amount) internal{
      if(totalsAddTicketsMaxfee >= amount){
           totalsAddTicketsMaxfee = totalsAddTicketsMaxfee.sub(amount);
      }else{
        if(totalsAddTicketsMaxfee != 0){
           totalsAddTicketsMaxfee = 0;
        }
       
      }

  }

  /**
   * @notice Change the amount addTicketed
   *
   */
  function changeAddTicket(address addTicketer,uint256 addMaxfeeAmount,
  uint256 allAddTicketAmount) external override onlyController returns(uint256,uint256){
     accrueIncurred_fee();
     fresh(addTicketer,0,0,false);
     AddTicketSnapshot memory addTicketSnapshot = accountAddTickets[addTicketer];
     uint256 _principal = balanceOf(addTicketer);
     uint256 _incurred_feeAddTicket = addTicketSnapshot.incurred_feeAddTicket;
     uint256 _maxfee = addTicketSnapshot.maxfee;
     uint256 _currentAddTicketAmount = addTicketSnapshot.addTicketAmount;
     uint256 _addAddTicketAmount;
     if(allAddTicketAmount > _currentAddTicketAmount){
       _addAddTicketAmount = allAddTicketAmount.sub(_currentAddTicketAmount);
     }else{
       _addAddTicketAmount = 0;
     }
     _maxfee = _maxfee.add(addMaxfeeAmount);

     uint256 reduceAddTicketAmount;
     if(_currentAddTicketAmount > allAddTicketAmount){
       reduceAddTicketAmount = _currentAddTicketAmount.sub(allAddTicketAmount);
     }else{
       reduceAddTicketAmount = 0;
     }
     
     ReduceTicketInterface(reduceTicket).changeAddTicketAllowed(address(this),addTicketer,
     _principal,_addAddTicketAmount,allAddTicketAmount,_incurred_feeAddTicket,_maxfee,addTicketRateMantissa);
      
      uint256 exitFee;
      uint256 burnedCredit;
     if(reduceAddTicketAmount > 0){
        (exitFee, burnedCredit) =  ReduceTicketInterface(reduceTicket).calculateEarlyExitFee(addTicketer, address(this), reduceAddTicketAmount);
        changeAddTicketComplete(addTicketer,addMaxfeeAmount,allAddTicketAmount);
        exitFeeBurnMaxfee(addTicketer, exitFee);
        addTotalAddTicketsIncurredFee(exitFee);
      }else{
        changeAddTicketComplete(addTicketer,addMaxfeeAmount,allAddTicketAmount);
     }

     emit ChangeAddTicket(allAddTicketAmount,addMaxfeeAmount,_maxfee);
     return (exitFee,burnedCredit);
     
  }

  function changeAddTicketComplete(address addTicketer,uint256 addMaxfeeAmount,uint256 allAddTicketAmount) internal {
     AddTicketSnapshot memory addTicketSnapshot = accountAddTickets[addTicketer];
     uint256 _maxfee = addTicketSnapshot.maxfee;
     uint256 _addTicketAmount = addTicketSnapshot.addTicketAmount;
     if(allAddTicketAmount > _addTicketAmount){
        totalAddTickets = totalAddTickets.add(allAddTicketAmount.sub(_addTicketAmount));
     }else{
        totalAddTickets = totalAddTickets.sub(_addTicketAmount.sub(allAddTicketAmount));
     }
     _maxfee = _maxfee.add(addMaxfeeAmount);
     totalsAddTicketsMaxfee = totalsAddTicketsMaxfee.add(addMaxfeeAmount);
     accountAddTickets[addTicketer].addTicketAmount = allAddTicketAmount;
     accountAddTickets[addTicketer].maxfee = _maxfee;
     uint256 _toBalance = balanceOf(addTicketer).add(accountAddTickets[addTicketer].addTicketAmount);
     sortitionSumTrees.set(TREE_KEY, _toBalance, bytes32(uint256(addTicketer)));

  }
  
  /**
  * @notice The liquidator reduceTickets the addTicketer
  *
  */
  function reduceAddTicket(address from) external override onlyController returns(uint256,uint256,uint256,uint256){
     reduceAddTicketFresh(from);
    (uint256 addTicketAmount,uint256 _incurred_feeAddTicket,,uint256 _maxfee) = TicketInterface(address(this)).accountAddTickets(from);
    uint256 _seizeToken = reduceTicketCalculateSeizeTokens(from); 
    (uint256 exitFee, uint256 burnedCredit) = ReduceTicketInterface(reduceTicket).calculateEarlyExitFee(from, address(this), addTicketAmount);
    uint256 _payAmount = _seizeToken.add(_incurred_feeAddTicket).add(exitFee);
    addTotalAddTicketsIncurredFee(exitFee);
    uint256 seizeToken;
    uint256 remainingMaxfee;
    if(_maxfee >= _payAmount){
       seizeToken = _seizeToken;
       remainingMaxfee = _maxfee.sub(_payAmount);
       reduceAddTicketComplete(from,remainingMaxfee.add(_seizeToken),0);

    }else{
      if(_maxfee > _seizeToken){
        seizeToken = _seizeToken;
      }
      reduceAddTicketComplete(from,seizeToken,_payAmount.sub(_maxfee));
    }
    return (seizeToken,remainingMaxfee,exitFee,burnedCredit);

  }

  /**
  * @notice The liquidator reduceTickets the addTicketer
  * @param addTicketer The address of the addTicket
  *
  */
  function reduceAddTicketFresh(address addTicketer) internal {
    require(ReduceTicketInterface(reduceTicket).reduceAddTicketAllowed(address(this), addTicketer) == true,"Ticket-reduceAddTicket/AddTicketer are not allowed to reduceTicket");
    accrueIncurred_fee();
    fresh(addTicketer,0,0,false);
    emit ReduceTicketAddTicketFresh(address(this),addTicketer, accountAddTickets[addTicketer].addTicketAmount,
    accountAddTickets[addTicketer].incurred_feeAddTicket,accountAddTickets[addTicketer].maxfee);

  }
  
  /**
  * @notice The liquidator reduceTickets the addTicketer
  * @param addTicketer The addTicketer's address
  * @param compensationTokens The addTicketer's compensation amount
  *
  */
  function reduceAddTicketComplete(address addTicketer,uint256 remainingMaxfee,uint256 compensationTokens) internal {
     reduceTicketComplete(addTicketer,remainingMaxfee,compensationTokens);

     uint256 balance = balanceOf(addTicketer);
     sortitionSumTrees.set(TREE_KEY, balance, bytes32(uint256(addTicketer)));
     emit ReduceTicketAddTicketComplete(addTicketer,compensationTokens);

  }
  
  /**
  * @notice Initialize the addTicketer's clearing data
  * @param  addTicketer  The addTicketer's address
  * @param  compensationTokens The addTicketer's compensation amount
  *
  */
  function reduceTicketComplete(address addTicketer,uint256 remainingMaxfee,uint256 compensationTokens) internal{
    AddTicketSnapshot memory addTicketSnapshot = accountAddTickets[addTicketer];
    upDataSubTotalsAddTicketsMaxfee(remainingMaxfee);
    
    totalAddTickets = totalAddTickets.sub(addTicketSnapshot.addTicketAmount);
    
    accountAddTickets[addTicketer] = AddTicketSnapshot({
      addTicketAmount: 0,
      incurred_feeAddTicket: 0,
      incurred_feeIndex : addTicketIndex,
      maxfee:0
    });

    totalCompensation = totalCompensation.add(compensationTokens); 
  }

  /**
  * @notice returns the current time.  Allows for override in testing
  * @param account The address of the addTicket balance
  *
  */
  function addTicketBalanceCurrent(address account) external override view returns(uint _addTicketAmount, uint _incurred_feeAddTicket,uint256 maxfee){
    AddTicketSnapshot memory addTicketSnapshot = accountAddTickets[account];
    uint256 currentTimestamp = _currentTime();
    uint256 secondsDelta = currentTimestamp.sub(accrualTimestamp);
    if(totalAddTickets == 0 || secondsDelta == 0 ) return(addTicketSnapshot.addTicketAmount,addTicketSnapshot.incurred_feeAddTicket,addTicketSnapshot.maxfee);


    uint256 simpleIncurred_feeFactor = secondsDelta.mul(addTicketRateMantissa);
    uint256 incurred_feeAccumulated = FixedPoint.multiplyUintByMantissa(simpleIncurred_feeFactor,totalAddTickets);
    uint256 indexDeltaMantissa = FixedPoint.calculateMantissa(incurred_feeAccumulated,totalAddTickets);

    uint256 _addTicketIndex = addTicketIndex.add(indexDeltaMantissa);

    uint256 deltaAddTicketIndexMantissa = uint256(_addTicketIndex).sub(addTicketSnapshot.incurred_feeIndex);
    //Calculate the addTicketings incurred
    uint256 newAddTickets = FixedPoint.multiplyUintByMantissa(addTicketSnapshot.addTicketAmount, deltaAddTicketIndexMantissa);
    _addTicketAmount = addTicketSnapshot.addTicketAmount;
    _incurred_feeAddTicket = uint256(addTicketSnapshot.incurred_feeAddTicket).add(newAddTickets);
    return (_addTicketAmount, _incurred_feeAddTicket,addTicketSnapshot.maxfee);
  }

  /// @notice returns the current time.  Allows for override in testing.
  /// @return The current time (block.timestamp)
  function _currentTime() internal virtual view returns (uint256) {
    return block.timestamp;
  }
  
  /// @notice An award to a liquidator.
  function reduceTicketCalculateSeizeTokens(address addTicketer) public override returns(uint256){
    return ReduceTicketInterface(reduceTicket).reduceTicketCalculateSeizeTokens(address(this),addTicketer);
  }

   /// @notice Calculates the user's balance at the time of liquidation.
  function captureUserLiquidationBalance(address user) external override returns(uint256){
    fresh(user,0,0,false); 
    uint256 _incurredFeeAddTicket = accountAddTickets[user].incurred_feeAddTicket;   
    uint256 _maxfee = accountAddTickets[user].maxfee;
    if(_maxfee > _incurredFeeAddTicket){
       emit CaptureUserLiquidationBalance(balanceOf(user),_maxfee.sub(_incurredFeeAddTicket),0);
       return balanceOf(user).add(_maxfee.sub(_incurredFeeAddTicket));
    }else{ 
       totalCompensation = totalCompensation.add(_incurredFeeAddTicket.sub(_maxfee));
       emit CaptureUserLiquidationBalance(balanceOf(user),0,_incurredFeeAddTicket.sub(_maxfee));
       return balanceOf(user);
    } 
  }
  
   /// @notice Update user cleared data
  function liquidationBalanceComplete(address user) override external{
    accrueIncurred_fee();
    reduceAddTicketComplete(user,accountAddTickets[user].maxfee.sub(accountAddTickets[user].incurred_feeAddTicket),0);
  }
  
  /// @notice Captures any available incurred_fee as award balance.
  function captureAwardBalance(uint256 awardBalance) external override returns (uint256){
    accrueIncurred_fee();
    uint256 _awardBalance;
    if(totalsAddTicketsMaxfee > awardBalance){
      _awardBalance = 0;
    }else{
        _awardBalance = awardBalance.sub(totalsAddTicketsMaxfee);
        _awardBalance = _awardBalance.add(totalAddTicketsIncurred_fee);
       if(_awardBalance > totalCompensation){
        _awardBalance = _awardBalance.sub(totalCompensation);
       }else{
         _awardBalance = 0;
     }
    }
    emit CaptureAwardBalance(awardBalance,_awardBalance,totalsAddTicketsMaxfee,totalAddTicketsIncurred_fee,totalCompensation);
    return _awardBalance;
  }
  
  /// @notice Clear the reward data.
  function captureAwardBalanceComplete() external override onlyController(){
    if(totalsAddTicketsMaxfee < totalAddTicketsIncurred_fee){
      totalsAddTicketsMaxfee = 0;
    }else{
      totalsAddTicketsMaxfee = totalsAddTicketsMaxfee.sub(totalAddTicketsIncurred_fee);
    }
    totalAddTicketsIncurred_fee = 0;
    totalCompensation = 0;

    emit CaptureAwardBalanceComplete(totalsAddTicketsMaxfee,totalAddTicketsIncurred_fee,totalCompensation);
  }

  function liquidationComplete() external override onlyController(){
    totalsAddTicketsMaxfee = 0;
    totalAddTicketsIncurred_fee = 0;
    totalCompensation = 0;
  }

  function total() external override view returns(uint256){
      return sortitionSumTrees.total(TREE_KEY);
  }

  function stakeOf(address _address) external override view returns(uint256){
      return sortitionSumTrees.stakeOf(TREE_KEY, bytes32(uint256(_address)));
  }

}
