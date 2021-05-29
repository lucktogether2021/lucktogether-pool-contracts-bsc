pragma solidity >=0.6.0 <0.7.0;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@pooltogether/fixed-point/contracts/FixedPoint.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/utils/SafeCast.sol";

import "../token/TicketInterface.sol";
import "./EarlyExitFeeInterface.sol";


contract EarlyExitFee is Ownable,EarlyExitFeeInterface {
  using SafeMath for uint256;
  using SafeCast for uint256;

  /// @dev Event emitted when the Credit plan is set
  event CreditPlanSet(
    address token,
    uint128 creditLimitMantissa,
    uint128 creditRateMantissa
  );

  /// @dev Emitted when credit is minted
  event CreditMinted(
    address indexed user,
    address indexed token,
    uint256 amount
  );

  /// @dev Emitted when credit is burned
  event CreditBurned(
    address indexed user,
    address indexed token,
    uint256 amount
  );

  struct CreditPlan {
    uint128 creditLimitMantissa;
    uint128 creditRateMantissa;
  }

  struct CreditBalance {
    uint192 balance;
    uint32 timestamp;
    bool initialized;
  }

  /// @dev Stores the credit plan for each token.
  mapping(address => CreditPlan) internal _tokenCreditPlans;

  /// @dev Stores each users balance of credit per token.
  mapping(address => mapping(address => CreditBalance)) internal _tokenCreditBalances;

  /// @dev The maximum possible exit fee fraction as a fixed point 18 number.
  /// For example, if the maxExitFeeMantissa is "0.1 ether", then the maximum exit fee for a withdrawal of 100 Dai will be 10 Dai
  uint256 public maxExitFeeMantissa;

  uint256 maxTimelockDuration;
  address public controller;

  constructor(
    uint256 _maxExitFeeMantissa,
    uint256 _maxTimelockDuration,
    address _controller
  ) public {
    maxExitFeeMantissa = _maxExitFeeMantissa;
    maxTimelockDuration = _maxTimelockDuration;
    
    controller = _controller;
  }

  /// @dev Calculates the early exit fee for the given amount
  /// @param amount The amount of collateral to be withdrawn
  /// @return Exit fee
  function calculateEarlyExitFeeNoCredit(address controlledToken, uint256 amount) public view override returns (uint256) {
    return _limitExitFee(
      amount,
      FixedPoint.multiplyUintByMantissa(amount, _tokenCreditPlans[controlledToken].creditLimitMantissa)
    );
  }

  /// @notice Limits the exit fee to the maximum as hard-coded into the contract
  /// @param withdrawalAmount The amount that is attempting to be withdrawn
  /// @param exitFee The exit fee to check against the limit
  /// @return The passed exit fee if it is less than the maximum, otherwise the maximum fee is returned.
  function _limitExitFee(uint256 withdrawalAmount, uint256 exitFee) internal view returns (uint256) {
    uint256 maxFee = FixedPoint.multiplyUintByMantissa(withdrawalAmount, maxExitFeeMantissa);
    if (exitFee > maxFee) {
      exitFee = maxFee;
    }
    return exitFee;
  }

  /// @notice Estimates the amount of time it will take for a given amount of funds to accrue the given amount of credit.
  /// @param _principal The principal amount on which interest is accruing
  /// @param _interest The amount of interest that must accrue
  /// @return durationSeconds The duration of time it will take to accrue the given amount of interest, in seconds.
  function estimateCreditAccrualTime(
    address _controlledToken,
    uint256 _principal,
    uint256 _interest
  )
    public
    view
    returns (uint256 durationSeconds)
  {
    // interest = credit rate * principal * time
    // => time = interest / (credit rate * principal)
    uint256 accruedPerSecond = FixedPoint.multiplyUintByMantissa(_principal, _tokenCreditPlans[_controlledToken].creditRateMantissa);
    if (accruedPerSecond == 0) {
      return 0;
    }
    return _interest.div(accruedPerSecond);
  }

  /// @notice Burns a users credit.
  /// @param user The user whose credit should be burned
  /// @param credit The amount of credit to burn
  function burnCredit(address user, address controlledToken, uint256 credit) public onlyController {
    _tokenCreditBalances[controlledToken][user].balance = uint256(_tokenCreditBalances[controlledToken][user].balance).sub(credit).toUint128();

    emit CreditBurned(user, controlledToken, credit);
  }

  /// @notice Accrues ticket credit for a user assuming their current balance is the passed balance.  May burn credit if they exceed their limit.
  /// @param user The user for whom to accrue credit
  /// @param controlledToken The controlled token whose balance we are checking
  /// @param controlledTokenBalance The balance to use for the user
  /// @param extra Additional credit to be added
  function accrueCredit(address user, address controlledToken, uint256 controlledTokenBalance, uint256 extra) public onlyController {
    accrueCreditInternal(user,controlledToken,controlledTokenBalance,extra);
  }

 function accrueCreditInternal(address user, address controlledToken, uint256 controlledTokenBalance, uint256 extra) internal {
    updateCreditBalanceInternal(
      user,
      controlledToken,
      calculateCreditBalance(user, controlledToken, controlledTokenBalance, extra)
    );
  }

 function calculateCreditBalance(address user, address controlledToken, uint256 controlledTokenBalance, uint256 extra) public view returns (uint256) {
    uint256 newBalance;
    CreditBalance storage creditBalance = _tokenCreditBalances[controlledToken][user];
    if (!creditBalance.initialized) {
      newBalance = 0;
    } else {
      uint256 credit = _calculateAccruedCredit(user, controlledToken, controlledTokenBalance);
      newBalance = applyCreditLimit(controlledToken, controlledTokenBalance, uint256(creditBalance.balance).add(credit).add(extra));
    }
    return newBalance;
  }

  function updateCreditBalance(address user, address controlledToken, uint256 newBalance) public onlyController {
    updateCreditBalanceInternal(user,controlledToken,newBalance);
  }

  function updateCreditBalanceInternal(address user, address controlledToken, uint256 newBalance) internal {
    uint256 oldBalance = _tokenCreditBalances[controlledToken][user].balance;

    _tokenCreditBalances[controlledToken][user] = CreditBalance({
      balance: newBalance.toUint128(),
      timestamp: _currentTime().toUint32(),
      initialized: true
    });

    if (oldBalance < newBalance) {
      emit CreditMinted(user, controlledToken, newBalance.sub(oldBalance));
    } else {
      emit CreditBurned(user, controlledToken, oldBalance.sub(newBalance));
    }
  }

  /// @notice Applies the credit limit to a credit balance.  The balance cannot exceed the credit limit.
  /// @param controlledToken The controlled token that the user holds
  /// @param controlledTokenBalance The users ticket balance (used to calculate credit limit)
  /// @param creditBalance The new credit balance to be checked
  /// @return The users new credit balance.  Will not exceed the credit limit.
  function applyCreditLimit(address controlledToken, uint256 controlledTokenBalance, uint256 creditBalance) public view returns (uint256) {
    uint256 creditLimit = FixedPoint.multiplyUintByMantissa(
      controlledTokenBalance,
      _tokenCreditPlans[controlledToken].creditLimitMantissa
    );
    if (creditBalance > creditLimit) {
      creditBalance = creditLimit;
    }

    return creditBalance;
  }

  /// @notice Calculates the accrued interest for a user
  /// @param user The user whose credit should be calculated.
  /// @param controlledToken The controlled token that the user holds
  /// @param controlledTokenBalance The user's current balance of the controlled tokens.
  /// @return The credit that has accrued since the last credit update.
  function _calculateAccruedCredit(address user, address controlledToken, uint256 controlledTokenBalance) internal view returns (uint256) {
    uint256 userTimestamp = _tokenCreditBalances[controlledToken][user].timestamp;

    if (!_tokenCreditBalances[controlledToken][user].initialized) {
      return 0;
    }

    uint256 deltaTime = _currentTime().sub(userTimestamp);
    uint256 creditPerSecond = FixedPoint.multiplyUintByMantissa(controlledTokenBalance, _tokenCreditPlans[controlledToken].creditRateMantissa);
    return deltaTime.mul(creditPerSecond);
  }

  /// @notice Returns the credit balance for a given user.  Not that this includes both minted credit and pending credit.
  /// @param user The user whose credit balance should be returned
  /// @return The balance of the users credit
  function balanceOfCredit(address user, address controlledToken) external returns (uint256) {
    accrueCredit(user, controlledToken, IERC20(controlledToken).balanceOf(user), 0);
    return _tokenCreditBalances[controlledToken][user].balance;
  }

  /// @notice Sets the rate at which credit accrues per second.  The credit rate is a fixed point 18 number (like Ether).
  /// @param _controlledToken The controlled token for whom to set the credit plan
  /// @param _creditRateMantissa The credit rate to set.  Is a fixed point 18 decimal (like Ether).
  /// @param _creditLimitMantissa The credit limit to set.  Is a fixed point 18 decimal (like Ether).
  function setCreditPlanOf(
    address _controlledToken,
    uint128 _creditRateMantissa,
    uint128 _creditLimitMantissa
  )
    external
    onlyOwner
  {
    _tokenCreditPlans[_controlledToken] = CreditPlan({
      creditLimitMantissa: _creditLimitMantissa,
      creditRateMantissa: _creditRateMantissa
    });

    emit CreditPlanSet(_controlledToken, _creditLimitMantissa, _creditRateMantissa);
  }

  /// @notice Returns the credit rate of a controlled token
  /// @param controlledToken The controlled token to retrieve the credit rates for
  /// @return creditLimitMantissa The credit limit fraction.  This number is used to calculate both the credit limit and early exit fee.
  /// @return creditRateMantissa The credit rate. This is the amount of tokens that accrue per second.
  function creditPlanOf(
    address controlledToken
  )
    external
    view
    override
    returns (
      uint128 creditLimitMantissa,
      uint128 creditRateMantissa
    )
  {
    creditLimitMantissa = _tokenCreditPlans[controlledToken].creditLimitMantissa;
    creditRateMantissa = _tokenCreditPlans[controlledToken].creditRateMantissa;
  }

  /// @notice Calculate the early exit for a user given a withdrawal amount.  The user's credit is taken into account.
  /// @param from The user who is withdrawing
  /// @param controlledToken The token they are withdrawing
  /// @param amount The amount of funds they are withdrawing
  /// @return earlyExitFee The additional exit fee that should be charged.
  /// @return creditBurned The amount of credit that will be burned
  function calculateEarlyExitFeeLessBurnedCredit(
    address from,
    address controlledToken,
    uint256 amount
  )
    public
    override
    returns (
      uint256 earlyExitFee,
      uint256 creditBurned
    )
  {
    uint256 controlledTokenBalance = TicketInterface(controlledToken).getUserAssets(from);
    require(controlledTokenBalance >= amount, "PrizePool/insuff-funds");
    accrueCreditInternal(from, controlledToken, controlledTokenBalance, 0);
    /*
    The credit is used *last*.  Always charge the fees up-front.

    How to calculate:

    Calculate their remaining exit fee.  I.e. full exit fee of their balance less their credit.

    If the exit fee on their withdrawal is greater than the remaining exit fee, then they'll have to pay the difference.
    */

    // Determine available usable credit based on withdraw amount
    uint256 remainingExitFee = calculateEarlyExitFeeNoCredit(controlledToken, controlledTokenBalance.sub(amount));

    uint256 availableCredit;
    if (_tokenCreditBalances[controlledToken][from].balance >= remainingExitFee) {
      availableCredit = uint256(_tokenCreditBalances[controlledToken][from].balance).sub(remainingExitFee);
    }

    // Determine amount of credit to burn and amount of fees required
    uint256 totalExitFee = calculateEarlyExitFeeNoCredit(controlledToken, amount);
    creditBurned = (availableCredit > totalExitFee) ? totalExitFee : availableCredit;
    earlyExitFee = totalExitFee.sub(creditBurned);
    return (earlyExitFee, creditBurned);
  }


  /// @notice Calculates a timelocked withdrawal duration and credit consumption.
  /// @param from The user who is withdrawing
  /// @param amount The amount the user is withdrawing
  /// @param controlledToken The type of collateral the user is withdrawing (i.e. ticket or sponsorship)
  /// @return durationSeconds The duration of the timelock in seconds
  function calculateTimelockDuration(
    address from,
    address controlledToken,
    uint256 amount
  )
    external
    returns (
      uint256 durationSeconds,
      uint256 burnedCredit
    )
  {
    return _calculateTimelockDuration(from, controlledToken, amount);
  }

  /// @dev Calculates a timelocked withdrawal duration and credit consumption.
  /// @param from The user who is withdrawing
  /// @param amount The amount the user is withdrawing
  /// @param controlledToken The type of collateral the user is withdrawing (i.e. ticket or sponsorship)
  /// @return durationSeconds The duration of the timelock in seconds
  /// @return burnedCredit The credit that was burned
  function _calculateTimelockDuration(
    address from,
    address controlledToken,
    uint256 amount
  )
    internal
    returns (
      uint256 durationSeconds,
      uint256 burnedCredit
    )
  {
    (uint256 exitFee, uint256 _burnedCredit) = calculateEarlyExitFeeLessBurnedCredit(from, controlledToken, amount);
    uint256 duration = estimateCreditAccrualTime(controlledToken, amount, exitFee);
    if (duration > maxTimelockDuration) {
      duration = maxTimelockDuration;
    }
    return (duration, _burnedCredit);
  }




  /// @dev Gets the current time as represented by the current block
  /// @return The timestamp of the current block
  function _currentTime() internal virtual view returns (uint256) {
    return block.timestamp;
  }
  
  /// @dev Function modifier to ensure that the caller is the controller contract
  modifier onlyController {
    require(_msgSender() == address(controller), "ControlledToken/only-controller");
    _;
  }
}