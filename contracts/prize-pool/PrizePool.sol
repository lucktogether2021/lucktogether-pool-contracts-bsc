// SPDX-License-Identifier: GPL-3.0

pragma solidity >=0.6.0 <0.7.0;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/introspection/ERC165Checker.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";

import "@pooltogether/fixed-point/contracts/FixedPoint.sol";
import "../registry/RegistryInterface.sol";
import "../reserve/ReserveInterface.sol";
import "./YieldSource.sol";
import "../token/TokenListenerInterface.sol";
import "../token/TokenListenerLibrary.sol";
import "../token/ControlledToken.sol";
import "../token/TicketInterface.sol";
import "../token/TokenControllerInterface.sol";
import "../utils/MappedSinglyLinkedList.sol";
import "./PrizePoolInterface.sol";
import "./EarlyExitFee.sol";

/// @title Escrows assets and deposits them into a yield source.  Exposes incurred_fee to Prize Strategy.  Users deposit and withdraw from this contract to participate in Prize Pool.
/// @notice Accounting is managed using Controlled Tokens, whose mint and burn functions can only be called by this contract.
/// @dev Must be inherited to provide specific yield-bearing asset control, such as Compound cTokens
contract PrizePool is PrizePoolInterface, Ownable, ReentrancyGuard, TokenControllerInterface {
  using SafeMath for uint256;
  using SafeERC20 for IERC20;
  using MappedSinglyLinkedList for MappedSinglyLinkedList.Mapping;
  using ERC165Checker for address;

  /// @dev Emitted when an instance is initialized
  event Initialized(
    address reserveRegistry
  );

  /// @dev Event emitted when controlled token is added
  event ControlledTokenAdded(
    ControlledTokenInterface indexed token
  );

  /// @dev Emitted when reserve is captured.
  event ReserveFeeCaptured(
    address indexed token,
    uint256 amount
  );

  event AwardCaptured(
    address indexed token,
    uint256 amount
  );

  event Balance(
    uint256 balance
  );

  /// @dev Event emitted when assets are deposited
  event Deposited(
    address indexed operator,
    address indexed to,
    address indexed token,
    uint256 amount,
    uint256 addTicketAmount,
    uint256 maxfee,
    address referrer
  );

  /// @dev Event emitted when the amount addTicketed
  event ChangeAddTicket(
    address indexed operator,
    address indexed to,
    uint256 addMaxfeeAmount,
    uint256 allAddTicketAmount
  );

  /// @dev Event emitted when incurred_fee is awarded to a winner
  event Awarded(
    address indexed winner,
    address indexed token,
    uint256 amount
  );

  /// @dev Event emitted when external ERC20s are awarded to a winner
  event AwardedExternalERC20(
    address indexed winner,
    address indexed token,
    uint256 amount
  );

  /// @dev Event emitted when external ERC20s are transferred out
  event TransferredExternalERC20(
    address indexed to,
    address indexed token,
    uint256 amount
  );

  /// @dev Event emitted when external ERC721s are awarded to a winner
  event AwardedExternalERC721(
    address indexed winner,
    address indexed token,
    uint256[] tokenIds
  );

  /// @dev Event emitted when assets are withdrawn instantly
  event InstantWithdrawal(
    address indexed operator,
    address indexed from,
    address indexed token,
    uint256 amount,
    uint256 redeemed,
    uint256 redeemedMaxfee,
    uint256 realExitFee
  );
  
  /// @dev Event emitted the reduceTicket addTicketer
  event ReduceExtraTicket(
    address indexed operator,
    address indexed from,
    address indexed token,
    uint256 exitFee
  );

  event ReserveWithdrawal(
    address indexed token,
    address indexed to,
    uint256 amount
  );

  /// @dev Event emitted when the Liquidity Cap is set
  event LiquidityCapSet(
    uint256 liquidityCap
  );

  /// @dev Event emitted when the Prize Strategy is set
  event PrizeStrategySet(
    address indexed prizeStrategy
  );

  event EarlyExitFeeSet(
    address indexed earlyExitFee
  );

  struct ExternalErc20Reserve {
    uint256 reserveTotal;
    uint256 awardBalance;
    bool isExist;
  }

  /// @dev Reserve to which reserve fees are sent
  RegistryInterface public reserveRegistry;

  /// @dev A linked list of all the controlled tokens
  MappedSinglyLinkedList.Mapping internal _tokens;

  /// @dev The Prize Strategy that this Prize Pool is bound to.
  TokenListenerInterface public prizeStrategy;

  EarlyExitFee public earlyExitFee;

  /// @dev The total funds that have been allocated to the reserve
  uint256 public reserveTotalSupply;

  /// @dev The total amount of funds that the prize pool can hold.
  uint256 public liquidityCap;

  mapping(address => ExternalErc20Reserve) public externalErc20ReserveMap;

  address[] public externalErc20ReserveAddresses;

  /// @dev the The awardable balance
  uint256 internal _currentAwardBalance;

  /// @dev The unlock timestamps for each user
  mapping(address => uint256) internal _unlockTimestamps;

  YieldSource[] public yieldSourceArray;

  /// @notice Initializes the Prize Pool
  constructor (
    RegistryInterface _reserveRegistry,
    YieldSource[] memory _yieldSourceArray

  )
    public
  {
    _setLiquidityCap(uint256(-1));

    require(address(_reserveRegistry) != address(0), "PrizePool/reserveRegistry-not-zero");

    reserveRegistry = _reserveRegistry;
    yieldSourceArray = _yieldSourceArray;

    emit Initialized(
      address(_reserveRegistry)
    );
  }

  /// @dev Returns the address of the underlying ERC20 asset
  /// @return The address of the asset
  function token() public view override hasYieldSource returns (address) {
    return address(yieldSourceArray[0].token());
  }

  function getYieldSource() external view returns(YieldSource[] memory){
    return yieldSourceArray;
  }

  /// @dev Returns the total underlying balance of all assets. This includes both principal and incurred_fee.
  /// @return The underlying balance of assets
  function balance() public hasYieldSource override returns (uint256) {
    uint256 _balance = 0;
    for (uint256 i = 0; i < yieldSourceArray.length;i++) {
      _balance = yieldSourceArray[i].balance().add(_balance);
    }
    emit Balance(_balance);
    return _balance;
  }

  /// @dev Checks with the Prize Pool if a specific token type may be awarded as an external prize
  /// @param _externalToken The address of the token to check
  /// @return True if the token may be awarded, false otherwise
  function canAwardExternal(address _externalToken) public view returns (bool) {
    for (uint256 i = 0; i < yieldSourceArray.length;i++) {
      if(!yieldSourceArray[i].canAwardExternal(_externalToken)) {
        return false;
      }
    }
    return true;
  }

  function _prioritySupplyYieldSource(uint256 amount) internal hasYieldSource returns(YieldSource, uint256) {
    YieldSource best;
    for (uint256 i = 0; i < yieldSourceArray.length;i++) {
      if (yieldSourceArray[i].availableQuota() == 0) {
        continue;
      }
      if (address(0) == address(best)) {
        best = yieldSourceArray[i];
      }
      if (yieldSourceArray[i].priority() > best.priority()) {
        best =  yieldSourceArray[i];
      }
    }
    require(address(0) != address(best), "PrizePool/no-suitable-supply-yieldsource");
    return (best, amount < best.availableQuota() ? amount : best.availableQuota());
  }
  
  function _supply(uint256 amount) public hasYieldSource {
    YieldSource best;
    uint256 _tempAmount;
    while(amount > 0) {
      (best, _tempAmount) = _prioritySupplyYieldSource(amount);
      (bool success, ) = address(best).delegatecall(abi.encodeWithSignature("supply(uint256,address)", _tempAmount, best.cToken()));
      require(success, "PrizePool/supply-call-error");
      amount = amount.sub(_tempAmount);
    }
  }

  function pureSupply(uint256 _amount, YieldSource _yieldSource) external onlyOwner {
    require(_yieldSource.availableQuota() >= _amount, "PrizePool/not-enough-quota");
    (bool success, ) = address(_yieldSource).delegatecall(abi.encodeWithSignature("supply(uint256,address)", _amount, _yieldSource.cToken()));
    require(success, "PrizePool/pure-supply-call-error");
  }

  function _priorityRedeemYieldSource(uint256 amount) internal hasYieldSource returns(YieldSource, uint256) {
    YieldSource best;
    for (uint256 i = 0; i < yieldSourceArray.length;i++) {
      if (yieldSourceArray[i].balance() == 0) {
        continue;
      }
      if (address(0) == address(best)) {
        best = yieldSourceArray[i];
      }
      if (yieldSourceArray[i].priority() < best.priority()) {
        best =  yieldSourceArray[i];
      }
    }
    require(address(0) != address(best), "PrizePool/no-suitable-redeem-yieldsource");
    return (best, amount < best.balance() ? amount : best.balance());
  }

  function _redeem(uint256 amount) internal returns (uint256) {
    YieldSource best;
    uint256 _tempAmount;
    uint256 diff = 0;
    while(amount > 0) {
      (best, _tempAmount) = _priorityRedeemYieldSource(amount);
      (bool success, bytes memory _diff) = address(best).delegatecall(abi.encodeWithSignature("redeem(uint256,address)", _tempAmount, best.cToken()));
      require(success, "PrizePool/redeem-call-error");
      diff = diff.add(bytesToUint(_diff));
      amount = amount.sub(_tempAmount);
    }
    return diff;
  }

  function pureRedeem(uint256 _amount, YieldSource _yieldSource) external onlyOwner returns (uint256) {
    require(_yieldSource.balance() >= _amount, "PrizePool/not-enough-balance");
    (bool success, bytes memory _diff) = address(_yieldSource).delegatecall(abi.encodeWithSignature("redeem(uint256,address)", _amount, _yieldSource.cToken()));
    require(success, "PrizePool/pure-redeem-call-error");
    return bytesToUint(_diff);
  }
          
  function bytesToUint(bytes memory b) internal pure returns (uint256){
      uint256 number;
      for(uint i= 0; i<b.length; i++){
        number = number + uint8(b[i])*(2**(8*(b.length-(i+1))));
      }
      return number;
  }

  /// @notice Deposit assets into the Prize Pool in exchange for tokens
  /// @param amount The amount of assets to deposit
  /// @param extraTicketAmount The extraTicketAmount of assets to deposit
  /// @param maxfee The maxfee of assets to deposit
  /// @param controlledToken The address of the type of token the user is minting
  /// @param referrer The referrer of the deposit
  function depositTo(
    address to,
    uint256 amount,
    uint256 extraTicketAmount, 
    uint256 maxfee, 
    address controlledToken,
    address referrer
  )
    external override
    onlyControlledToken(controlledToken)
    canAddLiquidity(amount)
    nonReentrant
  {
    address operator = _msgSender();
    TicketInterface(controlledToken).addTicket(to, amount, extraTicketAmount, maxfee);
    _mint(to, amount, controlledToken, referrer);
    uint256 _totalAmount =  amount.add(maxfee);
    IERC20(token()).safeTransferFrom(operator, address(this), _totalAmount);
    _supply(_totalAmount);
    emit Deposited(operator,to, controlledToken, amount,extraTicketAmount,maxfee,referrer);
  }

  /// @notice Change the amount extraTicket
  function changeExtraTicket(
    uint256 addMaxfeeAmount,
    uint256 allExtraTicketAmount,
    address controlledToken
  ) 
    external onlyControlledToken(controlledToken)
    canAddLiquidity(addMaxfeeAmount) {
    address operator = _msgSender();
    (, uint256 burnedCredit) = TicketInterface(controlledToken).changeAddTicket(operator,addMaxfeeAmount,allExtraTicketAmount);
    // burn the credit
    earlyExitFee.burnCredit(operator, controlledToken, burnedCredit);
    if(addMaxfeeAmount > 0){
      IERC20(token()).safeTransferFrom(operator, address(this), addMaxfeeAmount);
      _supply(addMaxfeeAmount);
    }
    emit ChangeAddTicket(operator,controlledToken,addMaxfeeAmount,allExtraTicketAmount);
  }

  /// @notice Reduce the number of extra ticket for user
  function reduceExtraTicket(
    address from,
    address controlledToken,
    address referrer
  ) public onlyControlledToken(controlledToken){
    (uint256 seizeToken,uint256 remainingMaxfee,uint256 exitFee,uint256 burnedCredit) = TicketInterface(controlledToken).reduceAddTicket(from);
    // burn the credit
    earlyExitFee.burnCredit(from, controlledToken, burnedCredit);
    if(seizeToken > 0){
       uint256 redeemed = _redeem(seizeToken);
       IERC20(token()).safeTransfer(msg.sender, redeemed);
    }
    if(remainingMaxfee > 0){
       _mint(from, remainingMaxfee, controlledToken, referrer);
    }
   emit ReduceExtraTicket(_msgSender(),from,controlledToken,exitFee);

  }
  /// @notice Withdraw assets from the Prize Pool instantly.  A fairness fee may be charged for an early exit.
  /// @param from The address to redeem tokens from.
  /// @param amount The amount of tokens to redeem for assets.
  /// @param controlledToken The address of the token to redeem (i.e. ticket or sponsorship)
  /// @param maximumExitFee The maximum exit fee the caller is willing to pay.  This should be pre-calculated by the calculateExitFee() fxn.
  /// @return The actual exit fee paid
  function withdrawInstantlyFrom(
    address from,
    uint256 amount,
    address controlledToken,
    uint256 maximumExitFee
  )
    external override
    nonReentrant
    onlyControlledToken(controlledToken)
    returns (uint256)
  {
    (uint256 amountLessFee,uint256 redeeMaxfee,uint256 exitFee,uint256 burnCredit) = TicketInterface(controlledToken).redeem(
    from, amount,maximumExitFee);
    // burn the credit
    earlyExitFee.burnCredit(from, controlledToken, burnCredit);
    ControlledToken(controlledToken).controllerBurnFrom(_msgSender(), from, amount);

    uint256 redeemed = _redeem(amountLessFee);
    IERC20(token()).safeTransfer(from, redeemed);
    emit InstantWithdrawal(_msgSender(),from,controlledToken,amount, redeemed,redeeMaxfee,exitFee);
    return exitFee;
  }

  /// @notice Updates the Prize Strategy when tokens are transferred between holders.
  /// @param from The address the tokens are being transferred from (0 if minting)
  /// @param to The address the tokens are being transferred to (0 if burning)
  /// @param amount The amount of tokens being trasferred
  function beforeTokenTransfer(address from, address to, uint256 amount) external override onlyControlledToken(msg.sender) {
    if (from != address(0)) {
      uint256 fromBeforeBalance = IERC20(msg.sender).balanceOf(from);
      // first accrue credit for their old balance
      uint256 newCreditBalance = earlyExitFee.calculateCreditBalance(from, msg.sender, fromBeforeBalance, 0);

      if (from != to) {
        // if they are sending funds to someone else, we need to limit their accrued credit to their new balance
        newCreditBalance = earlyExitFee.applyCreditLimit(msg.sender, fromBeforeBalance.sub(amount), newCreditBalance);
      }

      earlyExitFee.updateCreditBalance(from, msg.sender, newCreditBalance);
    }
    if (to != address(0) && to != from) {
      earlyExitFee.accrueCredit(to, msg.sender, IERC20(msg.sender).balanceOf(to), 0);
    }
    // if we aren't minting
    if (from != address(0) && address(prizeStrategy) != address(0)) {
      prizeStrategy.beforeTokenTransfer(from, to, amount, msg.sender);
    }
  }

  /// @notice Returns the balance that is available to award.
  /// @dev captureAwardBalance() should be called first
  /// @return The total amount of assets to be awarded for the current prize
  function awardBalance() external override view returns (uint256) {
    return _currentAwardBalance;
  }

  function addExternalErc20Reserve(address[] calldata _addrs) external onlyOwner() returns (bool)  {
    for (uint256 i = 0; i < _addrs.length; i++) {
      require(externalErc20ReserveMap[_addrs[i]].isExist == false, "PrizePool:addExternalErc20Reserve/address-is-exist");
      externalErc20ReserveAddresses.push(_addrs[i]);
      externalErc20ReserveMap[_addrs[i]].isExist = true;
    }
    return true;
  }

  function removeExternalErc20Reserve(address[] calldata _addrs) external onlyOwner() returns (bool)  {
    for (uint256 i = 0; i < _addrs.length; i++) {
      require(address(0) != _addrs[i], "PrizePool::removeExternalErc20Reserve/address-invalid");
      uint256 length = externalErc20ReserveAddresses.length;
      while(length > 0) {
        length--;
        if (_addrs[i] != externalErc20ReserveAddresses[length]) {
          continue;
        }
        uint256 _l = externalErc20ReserveAddresses.length;
        externalErc20ReserveAddresses[length] = externalErc20ReserveAddresses[_l - 1];
        externalErc20ReserveAddresses.pop();
        externalErc20ReserveMap[_addrs[i]].isExist = false;
        externalErc20ReserveMap[_addrs[i]].reserveTotal = 0;
        externalErc20ReserveMap[_addrs[i]].awardBalance = 0;
      }
    }
    return true;
  }

  /// @notice Captures any available incurred_fee as award balance.
  /// @dev This function also captures the reserve fees.
  /// @return The total amount of assets to be awarded for the current prize
  function captureAwardBalance(address ticket) public override nonReentrant returns (uint256) {
    uint256 tokenTotalSupply = _tokenTotalSupply();
    // it's possible for the balance to be slightly less due to rounding errors in the underlying yield source
    uint256 currentBalance = balance();
    uint256 totalIncurred_fee = (currentBalance > tokenTotalSupply) ? currentBalance.sub(tokenTotalSupply) : 0;
    uint256 unaccountedPrizeBalance = (totalIncurred_fee > _currentAwardBalance) ? totalIncurred_fee.sub(_currentAwardBalance) : 0;

    unaccountedPrizeBalance = TicketInterface(ticket).captureAwardBalance(unaccountedPrizeBalance);

    if (unaccountedPrizeBalance > 0) {
      uint256 reserveFee = calculateReserveFee(unaccountedPrizeBalance);
      if (reserveFee > 0) {
        reserveTotalSupply = reserveTotalSupply.add(reserveFee);
        unaccountedPrizeBalance = unaccountedPrizeBalance.sub(reserveFee);
        emit ReserveFeeCaptured(address(token()), reserveFee);
      }
      _currentAwardBalance = _currentAwardBalance.add(unaccountedPrizeBalance);
      emit AwardCaptured(address(token()), unaccountedPrizeBalance);
    }
  

    for (uint256 i = 0; i < externalErc20ReserveAddresses.length; i++) {
      captureAwardErc20Balance(externalErc20ReserveAddresses[i]);
    }

    return _currentAwardBalance;
  }

  function captureAwardBalanceComplete(address ticket) external override onlyPrizeStrategy(){
    TicketInterface(ticket).captureAwardBalanceComplete();
  }

  function captureAwardErc20Balance(address _exAddr) public returns (uint256) {
    require(externalErc20ReserveMap[_exAddr].isExist == true, "PrizePool:captureAwardErc20Balance/address-is-not-exist");
    uint256 currentBalance = IERC20(_exAddr).balanceOf(address(this));
    uint256 _awardBalance = externalErc20ReserveMap[_exAddr].awardBalance;
    uint256 _reserveTotal = externalErc20ReserveMap[_exAddr].reserveTotal;
    uint256 tokenTotalSupply = _awardBalance.add(_reserveTotal);

    uint256 unaccountedPrizeBalance = (currentBalance > tokenTotalSupply) ? currentBalance.sub(tokenTotalSupply) : 0;

    if (unaccountedPrizeBalance > 0) {
      uint256 reserveFee = calculateReserveFee(unaccountedPrizeBalance);
      if (reserveFee > 0) {
        externalErc20ReserveMap[_exAddr].reserveTotal = _reserveTotal.add(reserveFee);
        unaccountedPrizeBalance = unaccountedPrizeBalance.sub(reserveFee);
        emit ReserveFeeCaptured(_exAddr, reserveFee);
      }
      externalErc20ReserveMap[_exAddr].awardBalance = _awardBalance.add(unaccountedPrizeBalance);
      emit AwardCaptured(_exAddr, unaccountedPrizeBalance);
    }
    return _awardBalance;
  }

  function withdrawReserve(address to) external override onlyReserve returns (uint256) {

    uint256 amount = reserveTotalSupply;
    reserveTotalSupply = 0;
    uint256 redeemed = _redeem(amount);
    IERC20(token()).safeTransfer(address(to), redeemed);
    emit ReserveWithdrawal(address(token()), to, amount);
    for (uint256 i = 0; i < externalErc20ReserveAddresses.length; i++) {
      address _exAddr = externalErc20ReserveAddresses[i];
      uint256 _reserveTotal = externalErc20ReserveMap[_exAddr].reserveTotal;
      if (_reserveTotal > 0) {
        externalErc20ReserveMap[_exAddr].reserveTotal = 0;
        IERC20(_exAddr).transfer(to, _reserveTotal);
        emit ReserveWithdrawal(_exAddr, to, amount);
      }
    }
    return redeemed;
  }

  /// @notice Called by the prize strategy to award prizes.
  /// @dev The amount awarded must be less than the awardBalance()
  /// @param to The address of the winner that receives the award
  /// @param amount The amount of assets to be awarded
  /// @param controlledToken The address of the asset token being awarded
  function award(
    address to,
    uint256 amount,
    address controlledToken
  )
    external override
    onlyPrizeStrategy
    onlyControlledToken(controlledToken)
  {
    if (amount == 0) {
      return;
    }
    require(amount <= _currentAwardBalance, "PrizePool/award-exceeds-avail");
    _currentAwardBalance = _currentAwardBalance.sub(amount);
    _mint(to, amount, controlledToken, address(0));
    uint256 extraCredit = earlyExitFee.calculateEarlyExitFeeNoCredit(controlledToken, amount);
    earlyExitFee.accrueCredit(to, controlledToken, IERC20(controlledToken).balanceOf(to), extraCredit);
    emit Awarded(to, controlledToken, amount);
  }
  // @notice Called by the Prize-Strategy to transfer out external ERC20 tokens
  /// @dev Used to transfer out tokens held by the Prize Pool.  Could be reduceTicketd, or anything.
  /// @param to The address of the winner that receives the award
  /// @param amount The amount of external assets to be awarded
  /// @param externalToken The address of the external asset token being awarded
  function transferExternalERC20(
    address to,
    address externalToken,
    uint256 amount
  )
    external override
    onlyPrizeStrategy
  {
    if (_transferOut(to, externalToken, amount)) {
      emit TransferredExternalERC20(to, externalToken, amount);
    }
  }

  /// @notice Called by the Prize-Strategy to award external ERC20 prizes
  /// @dev Used to award any arbitrary tokens held by the Prize Pool
  /// @param to The address of the winner that receives the award
  /// @param amount The amount of external assets to be awarded
  /// @param externalToken The address of the external asset token being awarded
  function awardExternalERC20(
    address to,
    address externalToken,
    uint256 amount
  )
    external override
    onlyPrizeStrategy
  {
    if (_transferOut(to, externalToken, amount)) {
      emit AwardedExternalERC20(to, externalToken, amount);
    }
  }

  function _transferOut(
    address to,
    address externalToken,
    uint256 amount
  )
    internal
    returns (bool)
  {
    require(canAwardExternal(externalToken), "PrizePool/invalid-external-token");

    if (amount == 0) {
      return false;
    }

    if (externalErc20ReserveMap[externalToken].isExist) {
        externalErc20ReserveMap[externalToken].awardBalance = 0;
    }

    IERC20(externalToken).safeTransfer(to, amount);

    return true;
  }

  /// @notice Called to mint controlled tokens.  Ensures that token listener callbacks are fired.
  /// @param to The user who is receiving the tokens
  /// @param amount The amount of tokens they are receiving
  /// @param controlledToken The token that is going to be minted
  /// @param referrer The user who referred the minting
  function _mint(address to, uint256 amount, address controlledToken, address referrer) internal {
    if (address(prizeStrategy) != address(0)) {
      prizeStrategy.beforeTokenMint(to, amount, controlledToken, referrer);
    }
    ControlledToken(controlledToken).controllerMint(to, amount);
  }

  /// @notice Called by the prize strategy to award external ERC721 prizes
  /// @dev Used to award any arbitrary NFTs held by the Prize Pool
  /// @param to The address of the winner that receives the award
  /// @param externalToken The address of the external NFT token being awarded
  /// @param tokenIds An array of NFT Token IDs to be transferred
  function awardExternalERC721(
    address to,
    address externalToken,
    uint256[] calldata tokenIds
  )
    external override
    onlyPrizeStrategy
  {
    require(canAwardExternal(externalToken), "PrizePool/invalid-external-token");

    if (tokenIds.length == 0) {
      return;
    }

    for (uint256 i = 0; i < tokenIds.length; i++) {
      IERC721(externalToken).transferFrom(address(this), to, tokenIds[i]);
    }

    emit AwardedExternalERC721(to, externalToken, tokenIds);
  }

  function getExternalErc20ReserveAddresses() external override view returns(address[] memory){
    return externalErc20ReserveAddresses;
  }

  /// @notice Allows the Governor to set a cap on the amount of liquidity that he pool can hold
  /// @param _liquidityCap The new liquidity cap for the prize pool
  function setLiquidityCap(uint256 _liquidityCap) external override onlyOwner {
    _setLiquidityCap(_liquidityCap);
  }

  function _setLiquidityCap(uint256 _liquidityCap) internal {
    liquidityCap = _liquidityCap;
    emit LiquidityCapSet(_liquidityCap);
  }

  /// @notice Adds new controlled token, only can called once
  /// @param _controlledTokens Array of ControlledTokens that are controlled by this Prize Pool.
  function addControlledToken(ControlledTokenInterface[] memory _controlledTokens) public onlyOwner{
    _tokens.initialize();
    for (uint256 i = 0; i < _controlledTokens.length; i++) {
      require(_controlledTokens[i].controller() == this, "PrizePool/token-ctrlr-mismatch");
      _tokens.addAddress(address(_controlledTokens[i]));
      emit ControlledTokenAdded(_controlledTokens[i]);
    }
  }

  /// @notice Sets the prize strategy of the prize pool.  Only callable by the owner.
  /// @param _prizeStrategy The new prize strategy
  function setPrizeStrategy(TokenListenerInterface _prizeStrategy) external override onlyOwner {
    require(address(_prizeStrategy) != address(0), "PrizePool/prizeStrategy-not-zero");
    require(address(_prizeStrategy).supportsInterface(TokenListenerLibrary.ERC165_INTERFACE_ID_TOKEN_LISTENER), "PrizePool/prizeStrategy-invalid");
    prizeStrategy = _prizeStrategy;

    emit PrizeStrategySet(address(_prizeStrategy));
  }

  /// @notice Sets the prize early exit fee of the prize pool.  Only callable by the owner.
  /// @param _earlyExitFee early exit fee
  function setEarlyExitFee(EarlyExitFee _earlyExitFee) external onlyOwner {
    require(address(_earlyExitFee) != address(0), "PrizePool/EarlyExitFee-not-zero");
    require(address(earlyExitFee) == address(0), "PrizePool/EarlyExitFee-have-been-set");
    earlyExitFee = _earlyExitFee;
    emit EarlyExitFeeSet(address(_earlyExitFee));
  }

  /// @notice Calculates the reserve portion of the given amount of funds.  If there is no reserve address, the portion will be zero.
  /// @param amount The prize amount
  /// @return The size of the reserve portion of the prize
  function calculateReserveFee(uint256 amount) public view returns (uint256) {
    ReserveInterface reserve = ReserveInterface(reserveRegistry.lookup());
    if (address(reserve) == address(0)) {
      return 0;
    }
    uint256 reserveRateMantissa = reserve.reserveRateMantissa(address(this));
    if (reserveRateMantissa == 0) {
      return 0;
    }
    return FixedPoint.multiplyUintByMantissa(amount, reserveRateMantissa);
  }

  function upDataSortitionSumTrees(address _ticket,address _address,uint256 _amount) external override onlyPrizeStrategy{
    TicketInterface(_ticket).upDataSortitionSumTrees(_address,_amount);
  }

  /// @notice An array of the Tokens controlled by the Prize Pool (ie. Tickets, Sponsorship)
  /// @return An array of controlled token addresses
  function tokens() external override view returns (address[] memory) {
    return _tokens.addressArray();
  }

  /// @dev Gets the current time as represented by the current block
  /// @return The timestamp of the current block
  function _currentTime() internal virtual view returns (uint256) {
    return block.timestamp;
  }

  /// @notice The total of all controlled tokens.
  /// @return The current total of all tokens.
  function accountedBalance() external override view returns (uint256) {
    return _tokenTotalSupply();
  }

  /// @notice The total of all controlled tokens.
  /// @return The current total of all tokens.
  function _tokenTotalSupply() internal view returns (uint256) {
    uint256 total = reserveTotalSupply;
    address currentToken = _tokens.start();
    while (currentToken != address(0) && currentToken != _tokens.end()) {
      total = total.add(IERC20(currentToken).totalSupply());
      currentToken = _tokens.next(currentToken);
    }
    return total;
  }

  /// @dev Checks if the Prize Pool can receive liquidity based on the current cap
  /// @param _amount The amount of liquidity to be added to the Prize Pool
  /// @return True if the Prize Pool can receive the specified amount of liquidity
  function _canAddLiquidity(uint256 _amount) internal view returns (bool) {
    uint256 tokenTotalSupply = _tokenTotalSupply();
    return (tokenTotalSupply.add(_amount) <= liquidityCap);
  }

  /// @dev Checks if a specific token is controlled by the Prize Pool
  /// @param controlledToken The address of the token to check
  /// @return True if the token is a controlled token, false otherwise
  function _isControlled(address controlledToken) internal view returns (bool) {
    return _tokens.contains(controlledToken);
  }

  /// @dev Function modifier to ensure usage of tokens controlled by the Prize Pool
  /// @param controlledToken The address of the token to check
  modifier onlyControlledToken(address controlledToken) {
    require(_isControlled(controlledToken), "PrizePool/unknown-token");
    _;
  }

  /// @dev Function modifier to ensure caller is the prize-strategy
  modifier onlyPrizeStrategy() {
    require(_msgSender() == address(prizeStrategy), "PrizePool/only-prizeStrategy");
    _;
  }

  /// @dev Function modifier to ensure the deposit amount does not exceed the liquidity cap (if set)
  modifier canAddLiquidity(uint256 _amount) {
    require(_canAddLiquidity(_amount), "PrizePool/exceeds-liquidity-cap");
    _;
  }

  modifier onlyReserve() {
    ReserveInterface reserve = ReserveInterface(reserveRegistry.lookup());
    require(address(reserve) == msg.sender, "PrizePool/only-reserve");
    _;
  }

  modifier hasYieldSource() {
    require(yieldSourceArray.length > 0, "PrizePool/yield-source-null");
    _;
  }
}
