// SPDX-License-Identifier: GPL-3.0

pragma solidity >=0.6.0 <0.7.0;

import "sortition-sum-tree-factory/contracts/SortitionSumTreeFactory.sol";
import "@pooltogether/uniform-random-number/contracts/UniformRandomNumber.sol";
import "@pooltogether/fixed-point/contracts/FixedPoint.sol";

import "./ControlledToken.sol";
import "./TicketInterface.sol";
import "./LiquidationInterface.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract Ticket is ControlledToken, TicketInterface, Ownable{
  using SortitionSumTreeFactory for SortitionSumTreeFactory.SortitionSumTrees;

  bytes32 constant private TREE_KEY = keccak256("PoolTogether/Ticket");
  uint256 constant private MAX_TREE_LEAVES = 5;
  address public liquidation;

  // Ticket-weighted odds
  SortitionSumTreeFactory.SortitionSumTrees internal sortitionSumTrees;

  /**
  * @notice borrow rate that can ever be applied (.0005% / timestamp)
  */
  uint public override borrowRateMantissa = 3170979198;

  /**
  * @notice Total amount of compensation
  */
  uint public totalCompensation;

  /**
  * @notice Total amount of borrows 
  */
  uint public totalBorrows;

  /**
  * @notice Interest on the amount borrowed
  */
  uint public totalBorrowsInterest;

  /**
  * @notice Total amount of borrows margin
  */
  uint public totalsBorrowsMargin;

  /**
  * @notice Timestamp that interest was last accrued at
  */
  uint public accrualTimestamp;

  /**
  * @notice Accumulator of the total earned interest rate since the opening of the market
  */
  uint public borrowIndex;

 /**
 * @notice Container for borrow balance information
 * @member principal Total balance , after applying the most recent balance-changing action
 * @member interestIndex Global borrowIndex as of the most recent balance-changing action
 */
  struct BorrowSnapshot {
        uint borrowAmount;
        uint interestBorrow;
        uint interestIndex;
        uint256 margin;
  }

  mapping(address => BorrowSnapshot) public override accountBorrows;

  /// @dev Emitted when Borrow 
  event Borrow(address borrower,uint256 principal,uint256 borrowAmount,uint256 margin);

  /// @dev Emitted when Reddem
  event Reddem(uint256 _redeemTokens,uint256 _redeemBorrowAmount,uint256 _redeemBmargin,bool isReddemAll);

  /// @dev Emitted Burn the user's margin
  event ExitFeeBurnMargin(uint256 burnMargin);

  event ChangeBorrow(uint256 allBorrowAmount,uint256 addMarginAmount,uint256 currrentMargin);

  /// @dev Emitted when Liquidate Borrow
  event LiquidateBorrowFresh(
    address controlledToken,
    address borrower,
    uint256 borrowAmount,
    uint256 interestBorrow,
    uint256 margin
   );

  /// @dev Emitted when Liquidate Borrow
  event LiquidateBorrowComplete(
    address borrower,
    uint256 compensationTokens
   );
  
  event ExitFeeBurnMarginRiskValue(uint256 _borrowAmount,uint256 _interestBorrow,uint256 _remainingMargin,uint256 riskValue);
  /// @dev Emitted Calculate the rewards of the pool
  event CaptureAwardBalance(
    uint256 originalAwardBalance,
    uint256 awardBalance,  
    uint256 totalsBorrowsMargin,
    uint256 totalBorrowsInterest,
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

  function setBorrowRateMantissa(uint256 _borrowRateMantissa) external onlyOwner(){
    accrueInterest();
    borrowRateMantissa = _borrowRateMantissa;
  }

  function setLiquidation(address _liquidation) external onlyOwner() {
    liquidation = _liquidation;
  }

  /// @notice Returns the user's chance of winning.
  function chanceOf(address user) external view returns (uint256) {
    return sortitionSumTrees.stakeOf(TREE_KEY, bytes32(uint256(user)));
  }


  /// @notice Take the total share, the total share in the first stage is the total votes
  function getAllShares() external  override view returns (uint256) {
    return totalSupply().add(totalBorrows);
  }

  /// @notice Get the user assets, the first stage user assets is the user balance
  function getUserAssets(address user) external override view returns (uint256) {
    return balanceOf(user).add(accountBorrows[user].borrowAmount);
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
    require(accountBorrows[sender].borrowAmount == 0,"ERC20: transfer from the existence of borrow amount");
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
      uint256 _fromBalance= fromBalance.add(accountBorrows[from].borrowAmount);
      sortitionSumTrees.set(TREE_KEY, _fromBalance, bytes32(uint256(from)));
    }

    if (to != address(0)) {
      uint256 toBalance = balanceOf(to).add(amount);
      uint256 _toBalance = toBalance.add(accountBorrows[to].borrowAmount);
      sortitionSumTrees.set(TREE_KEY, _toBalance, bytes32(uint256(to)));
    }
  }

  /**
  * @notice Applies accrued interest to total borrows 6
  * @dev This calculates interest accrued from the last checkpointed time
  *  up to the current time and writes new checkpoint to storage.
  */
  function accrueInterest() public returns (uint256) { 
    uint256 currentTimestamp = _currentTime();
    if(currentTimestamp == accrualTimestamp) return 0;
    uint256 secondsDelta = currentTimestamp.sub(accrualTimestamp);
    uint256 interestAccumulated;
    if(totalBorrows != 0){
      uint256 simpleInterestFactor = secondsDelta.mul(borrowRateMantissa);
      interestAccumulated = FixedPoint.multiplyUintByMantissa(simpleInterestFactor,totalBorrows);
      uint256 indexDeltaMantissa = FixedPoint.calculateMantissa(interestAccumulated,totalBorrows);
      borrowIndex = borrowIndex.add(indexDeltaMantissa);
      totalBorrowsInterest = totalBorrowsInterest.add(interestAccumulated);
    }
    accrualTimestamp = currentTimestamp;
    return interestAccumulated;
  }

  /**
   * @notice Sender borrows assets from the protocol to their own address
   * @param _address The address
   * @param _amount The amount of the asset 
   * 
   */
  function fresh(address _address,uint _amount,uint _margin,bool isBorrow) internal returns (uint256) {
    BorrowSnapshot memory borrowSnapshot = accountBorrows[_address];
    uint256 deltaBorrowIndexMantissa = uint256(borrowIndex).sub(borrowSnapshot.interestIndex);

    //Calculate the borrowings incurred
    uint256 newBorrows = FixedPoint.multiplyUintByMantissa(borrowSnapshot.borrowAmount, deltaBorrowIndexMantissa);

    if(isBorrow){
      accountBorrows[_address].borrowAmount = borrowSnapshot.borrowAmount.add(_amount);
    }
    accountBorrows[_address].interestBorrow = uint256(borrowSnapshot.interestBorrow).add(newBorrows);
    accountBorrows[_address].interestIndex = borrowIndex; 
    accountBorrows[_address].margin = uint256(borrowSnapshot.margin).add(_margin);
    return newBorrows;
  
  }

  /**
   * @notice Sender borrows assets from the protocol to their own address
   * @param borrowAmount The amount of the underlying asset to borrow
   * 
   */
  function borrow(address borrower,uint256 principal,uint256 borrowAmount,uint256 margin) 
  override external onlyController{
    accrueInterest();
    if(borrowAmount != 0 || accountBorrows[borrower].borrowAmount != 0){ 
      boorwInternal(borrower,principal,borrowAmount,margin);
    }
  }

  /**
   * @notice Sender borrows assets from the protocol to their own address
   * @param borrowAmount The amount of the underlying asset to borrow
   * 
   */
  function boorwInternal(address borrower,uint256 principal,uint256 borrowAmount,uint256 margin) internal{
    BorrowSnapshot memory borrowSnapshot = accountBorrows[borrower];
    uint256 deltaBorrowIndexMantissa = uint256(borrowIndex).sub(borrowSnapshot.interestIndex);
    //Calculate the borrowings incurred
    uint256 newBorrows = FixedPoint.multiplyUintByMantissa(borrowSnapshot.borrowAmount, deltaBorrowIndexMantissa);
    uint256 _borrowAmount = borrowSnapshot.borrowAmount.add(borrowAmount);
    uint256 _interestBorrow = uint256(borrowSnapshot.interestBorrow).add(newBorrows);
    uint256 _margin = uint256(borrowSnapshot.margin).add(margin);
    LiquidationInterface(liquidation).borrowAllowed(address(this),borrower,principal,borrowAmount,margin,
    _borrowAmount,_interestBorrow,_margin,borrowRateMantissa);
    fresh(borrower,borrowAmount,margin,true);
    totalsBorrowsMargin = totalsBorrowsMargin.add(margin);
    totalBorrows = totalBorrows.add(borrowAmount);

    emit Borrow(borrower,principal,borrowAmount,margin);
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
    (uint256 _redeemTokens,uint256 _redeemBorrowAmount,uint256 _redeeMargin,bool isReddemAll) = redeemInternal(_from, _amount);
    uint256 _allAmount = _redeemTokens.add(_redeemBorrowAmount);

    (exitFee, burnedCredit) = LiquidationInterface(liquidation).calculateEarlyExitFee(_from, address(this), _allAmount);
    require(exitFee <= maximumExitFee, "PrizePool/exit-fee-exceeds-user-maximum");
    redeemComplete(_from,_redeemBorrowAmount,isReddemAll);
    
    uint _exitFee;
    if(isReddemAll ||_redeemBorrowAmount == 0){
       _exitFee = exitFee;
    }else{
      uint256 _allTokens = _redeemTokens.add(_redeemBorrowAmount);
      _exitFee = exitFee.mul(_redeemTokens).div(_allTokens);
      uint256 _burnMargin = exitFee.sub(_exitFee);
      exitFeeBurnMargin(_from, _burnMargin);
    }
    // redeem the tickets less the fee
    uint256 amountLessFee = _amount.sub(_exitFee).add(_redeeMargin);
    return (amountLessFee,_redeeMargin,exitFee,burnedCredit);
  }


  /**
  * @notice Sender redeems ticket in exchange for the asset
  * @param redeemAddress The address of the redeem
  * @param redeemTokens redeemTokens The number of cTokens to redeem
  *
  */
  function redeemInternal(address redeemAddress,uint256 redeemTokens) internal returns(uint256,uint256,uint256,bool){
      accrueInterest();
      uint256 _originalBalance = balanceOf(redeemAddress);
      uint256 _balance = _originalBalance.sub(redeemTokens);
      if(accountBorrows[redeemAddress].borrowAmount == 0){
         emit Reddem(redeemTokens,0,0,_balance == 0);
         return (redeemTokens,0,0,_balance == 0);
      }
      fresh(redeemAddress,0,0,false);
      address _redeem = redeemAddress;
      uint256 _redeemTokens;
      uint256 _redeemBorrowAmount;
      uint256 _redeemBmargin;
      uint256 _borrowAmountNew;
      uint256 _riskValue = FixedPoint.multiplyUintByMantissa( LiquidationInterface(liquidation).calculateCurrentRiskValue(address(this),_redeem,
      accountBorrows[_redeem].borrowAmount,accountBorrows[_redeem].interestBorrow,accountBorrows[_redeem].margin),1);
      if(_riskValue != 0){
        uint256 exitFee =  LiquidationInterface(liquidation).getExitFee(address(this), _redeem, 0, accountBorrows[_redeem].borrowAmount);
        uint256 _payAmount = accountBorrows[_redeem].interestBorrow.add(exitFee);  
        uint256 compensationTokens = 0;
        
        if(_payAmount > accountBorrows[_redeem].margin){
           compensationTokens = _payAmount.sub(accountBorrows[_redeem].margin);
           _redeemBmargin = 0;
        }else{
           _redeemBmargin = accountBorrows[_redeem].margin.sub(_payAmount);
        }
        liquidateComplete(_redeem,compensationTokens);
        _redeemBorrowAmount = 0;   
      }else{
        if(_balance == 0){
          uint256 _margin = accountBorrows[_redeem].margin;
          uint256 _interestBorrow = accountBorrows[_redeem].interestBorrow;
          if(_margin >= _interestBorrow){
            uint256 remainingMargin = _margin.sub(_interestBorrow);
            _redeemBmargin = remainingMargin;
          }else{
            uint256 _compensationMargin = _interestBorrow.sub(_margin);
            totalCompensation = totalCompensation.add(_compensationMargin); 
          }
          totalBorrows = totalBorrows.sub(accountBorrows[_redeem].borrowAmount);
         _redeemBorrowAmount = accountBorrows[_redeem].borrowAmount;
        }else{
          uint256 _borrowAmount = accountBorrows[_redeem].borrowAmount;
         _borrowAmountNew = _borrowAmount.mul(_balance).div(_originalBalance);
         _redeemBorrowAmount = accountBorrows[_redeem].borrowAmount.sub(_borrowAmountNew);
         }
        
      }
     _redeemTokens = redeemTokens; 
     emit Reddem(_redeemTokens,_redeemBorrowAmount,_redeemBmargin,_balance == 0);
     return (_redeemTokens,_redeemBorrowAmount,_redeemBmargin,_balance == 0);

  }

  /**
  * @notice Sender redeems ticket in exchange for the asset
  *
  */
  function redeemComplete(address _redeem,uint256 _redeemBorrowAmount,bool isReddemAll) internal{
    if(isReddemAll){
        accountBorrows[_redeem].borrowAmount = 0;
        accountBorrows[_redeem].interestBorrow = 0;
        totalsBorrowsMargin = totalsBorrowsMargin.sub(accountBorrows[_redeem].margin);
        accountBorrows[_redeem].margin = 0;
    }else{
        uint256 _borrowAmountNew = accountBorrows[_redeem].borrowAmount.sub(_redeemBorrowAmount);
        accountBorrows[_redeem].borrowAmount = _borrowAmountNew;
        totalBorrows = totalBorrows.sub(_redeemBorrowAmount);
    }

  }

  /// @notice Update the user's value
  function upDataSortitionSumTrees(address _address ,uint256 _amount) external override onlyController {
      sortitionSumTrees.set(TREE_KEY, _amount, bytes32(uint256(_address)));
  }

  /***
   * @notice Burn the user's margin
   *
   */
  function exitFeeBurnMargin(address account,uint256 _burnAmount) internal {
      if(_burnAmount != 0){
        uint256 _margin = accountBorrows[account].margin;
        uint256 _remainingMargin = _margin.sub(_burnAmount);
        totalsBorrowsMargin = totalsBorrowsMargin.sub(_burnAmount);
        uint256 _borrowAmount = accountBorrows[account].borrowAmount;
        uint256 _interestBorrow = accountBorrows[account].interestBorrow;
        uint256 _riskValue = FixedPoint.multiplyUintByMantissa(LiquidationInterface(liquidation).calculateCurrentRiskValue(address(this),
        account,_borrowAmount, _interestBorrow,_remainingMargin),1);
        emit ExitFeeBurnMarginRiskValue(_borrowAmount,_interestBorrow,_remainingMargin,_riskValue);
        require(_riskValue == 0,"Ticket-exitFeeBurnMargin/excess value at risk");
        accountBorrows[account].margin = _remainingMargin;
      }
      emit ExitFeeBurnMargin(_burnAmount);
  }

  /**
   * @notice Change the amount borrowed
   *
   */
  function changeBorrow(address borrower,uint256 addMarginAmount,
  uint256 allBorrowAmount) external override onlyController returns(uint256,uint256){
     accrueInterest();
     fresh(borrower,0,0,false);
     BorrowSnapshot memory borrowSnapshot = accountBorrows[borrower];
     uint256 _principal = balanceOf(borrower);
     uint256 _interestBorrow = borrowSnapshot.interestBorrow;
     uint256 _margin = borrowSnapshot.margin;
     uint256 _currentBorrowAmount = borrowSnapshot.borrowAmount;
     uint256 _addBorrowAmount;
     if(allBorrowAmount > _currentBorrowAmount){
       _addBorrowAmount = allBorrowAmount.sub(_currentBorrowAmount);
     }else{
       _addBorrowAmount = 0;
     }
     _margin = _margin.add(addMarginAmount);

     uint256 reduceBorrowAmount;
     if(_currentBorrowAmount > allBorrowAmount){
       reduceBorrowAmount = _currentBorrowAmount.sub(allBorrowAmount);
     }else{
       reduceBorrowAmount = 0;
     }
     
     LiquidationInterface(liquidation).changeBorrowAllowed(address(this),borrower,
     _principal,_addBorrowAmount,allBorrowAmount,_interestBorrow,_margin,borrowRateMantissa);
      
      uint256 exitFee;
      uint256 burnedCredit;
     if(reduceBorrowAmount > 0){
        (exitFee, burnedCredit) =  LiquidationInterface(liquidation).calculateEarlyExitFee(borrower, address(this), reduceBorrowAmount);
        changeBorrowComplete(borrower,addMarginAmount,allBorrowAmount);
        exitFeeBurnMargin(borrower, exitFee);
      }else{
        changeBorrowComplete(borrower,addMarginAmount,allBorrowAmount);
     }

     emit ChangeBorrow(allBorrowAmount,addMarginAmount,_margin);
     return (exitFee,burnedCredit);
     
  }

  function changeBorrowComplete(address borrower,uint256 addMarginAmount,uint256 allBorrowAmount) internal {
     BorrowSnapshot memory borrowSnapshot = accountBorrows[borrower];
     uint256 _margin = borrowSnapshot.margin;
     uint256 _borrowAmount = borrowSnapshot.borrowAmount;
     if(allBorrowAmount > _borrowAmount){
        totalBorrows = totalBorrows.add(allBorrowAmount.sub(_borrowAmount));
     }else{
        totalBorrows = totalBorrows.sub(_borrowAmount.sub(allBorrowAmount));
     }
     _margin = _margin.add(addMarginAmount);
     totalsBorrowsMargin = totalsBorrowsMargin.add(addMarginAmount);
     accountBorrows[borrower].borrowAmount = allBorrowAmount;
     accountBorrows[borrower].margin = _margin;

     uint256 balance = balanceOf(borrower);
     uint256 _toBalance = balance.add(accountBorrows[borrower].borrowAmount);
     sortitionSumTrees.set(TREE_KEY, _toBalance, bytes32(uint256(borrower)));

  }
  
  /**
  * @notice The liquidator liquidates the borrower
  *
  */
  function liquidateBorrow(address from,
    address controlledToken) external override onlyController returns(uint256,uint256,uint256,uint256){
     liquidateBorrowFresh(from);
    (uint256 borrowAmount,uint256 _interestBorrow,,uint256 _margin) = TicketInterface(controlledToken).accountBorrows(from);
    uint256 _seizeToken = TicketInterface(controlledToken).liquidateCalculateSeizeTokens(from); 
    (uint256 exitFee, uint256 burnedCredit) = LiquidationInterface(liquidation).calculateEarlyExitFee(from, controlledToken, borrowAmount);
    uint256 _payAmount = _seizeToken.add(_interestBorrow).add(exitFee);  
    uint256 seizeToken;
    uint256 remainingMargin;
    if(_margin >= _payAmount){
       seizeToken = _seizeToken;
       remainingMargin = _margin.sub(_payAmount);
       liquidateBorrowComplete(from,0);

    }else{
      if(_margin > _seizeToken){
        seizeToken = _seizeToken;
      }
      liquidateBorrowComplete(from,_payAmount.sub(_margin));
    }
    return (seizeToken,remainingMargin,exitFee,burnedCredit);

  }

  /**
  * @notice The liquidator liquidates the borrower
  * @param borrower The address of the borrow
  *
  */
  function liquidateBorrowFresh(address borrower) internal {
    require(LiquidationInterface(liquidation).liquidateBorrowAllowed(address(this), borrower) == true,"Ticket-liquidateBorrow/Borrower are not allowed to liquidate");
    accrueInterest();
    fresh(borrower,0,0,false);
    emit LiquidateBorrowFresh(address(this),borrower, accountBorrows[borrower].borrowAmount,
    accountBorrows[borrower].interestBorrow,accountBorrows[borrower].margin);

  }
  
  /**
  * @notice The liquidator liquidates the borrower
  * @param borrower The borrower's address
  * @param compensationTokens The borrower's compensation amount
  *
  */
  function liquidateBorrowComplete(address borrower,uint256 compensationTokens) internal {
     liquidateComplete(borrower,compensationTokens);

     uint256 balance = balanceOf(borrower);
     sortitionSumTrees.set(TREE_KEY, balance, bytes32(uint256(borrower)));
     emit LiquidateBorrowComplete(borrower,compensationTokens);

  }
  
  /**
  * @notice Initialize the borrower's clearing data
  * @param  borrower  The borrower's address
  * @param  compensationTokens The borrower's compensation amount
  *
  */
  function liquidateComplete(address borrower,uint256 compensationTokens) internal{
    BorrowSnapshot memory borrowSnapshot = accountBorrows[borrower];
    totalsBorrowsMargin = totalsBorrowsMargin.sub(borrowSnapshot.margin);
    totalBorrows = totalBorrows.sub(borrowSnapshot.borrowAmount);
    accountBorrows[borrower] = BorrowSnapshot({
      borrowAmount: 0,
      interestBorrow: 0,
      interestIndex : borrowIndex,
      margin:0
    });

    totalCompensation = totalCompensation.add(compensationTokens); 
  }

  /**
  * @notice returns the current time.  Allows for override in testing
  * @param account The address of the borrow balance
  *
  */
  function borrowBalanceCurrent(address account) external override view returns(uint _borrowAmount, uint _interestBorrow,uint256 margin){
    BorrowSnapshot memory borrowSnapshot = accountBorrows[account];
    uint256 currentTimestamp = _currentTime();
    uint256 secondsDelta = currentTimestamp.sub(accrualTimestamp);
    if(totalBorrows == 0 || secondsDelta == 0 ) return(borrowSnapshot.borrowAmount,borrowSnapshot.interestBorrow,borrowSnapshot.margin);


    uint256 simpleInterestFactor = secondsDelta.mul(borrowRateMantissa);
    uint256 interestAccumulated = FixedPoint.multiplyUintByMantissa(simpleInterestFactor,totalBorrows);
    uint256 indexDeltaMantissa = FixedPoint.calculateMantissa(interestAccumulated,totalBorrows);

    uint256 _borrowIndex = borrowIndex.add(indexDeltaMantissa);

    uint256 deltaBorrowIndexMantissa = uint256(_borrowIndex).sub(borrowSnapshot.interestIndex);
    //Calculate the borrowings incurred
    uint256 newBorrows = FixedPoint.multiplyUintByMantissa(borrowSnapshot.borrowAmount, deltaBorrowIndexMantissa);
    _borrowAmount = borrowSnapshot.borrowAmount;
    _interestBorrow = uint256(borrowSnapshot.interestBorrow).add(newBorrows);
    return (_borrowAmount, _interestBorrow,borrowSnapshot.margin);
  }

  /// @notice returns the current time.  Allows for override in testing.
  /// @return The current time (block.timestamp)
  function _currentTime() internal virtual view returns (uint256) {
    return block.timestamp;
  }
  
  /// @notice An award to a liquidator.
  function liquidateCalculateSeizeTokens(address borrower) public override returns(uint256){
    return LiquidationInterface(liquidation).liquidateCalculateSeizeTokens(address(this),borrower);
  }
  
  /// @notice Captures any available interest as award balance.
  function captureAwardBalance(uint256 awardBalance) external onlyController override returns (uint256){
    accrueInterest();
    uint256 _awardBalance;
    if(totalsBorrowsMargin > awardBalance){
      _awardBalance = 0;
    }else{
        _awardBalance = awardBalance.sub(totalsBorrowsMargin);
        _awardBalance = _awardBalance.add(totalBorrowsInterest);
       if(_awardBalance > totalCompensation){
        _awardBalance = _awardBalance.sub(totalCompensation);
       }else{
         _awardBalance = 0;
     }
    }
    emit CaptureAwardBalance(awardBalance,_awardBalance,totalsBorrowsMargin,totalBorrowsInterest,totalCompensation);
    return _awardBalance;
  }
  
  /// @notice Clear the reward data.
  function captureAwardBalanceComplete() external override onlyController(){
    totalBorrowsInterest = 0;
    totalCompensation = 0;
  }

  function total() external override view returns(uint256){
      return sortitionSumTrees.total(TREE_KEY);
  }

  function stakeOf(address _address) external override view returns(uint256){
      return sortitionSumTrees.stakeOf(TREE_KEY, bytes32(uint256(_address)));
  }

}
