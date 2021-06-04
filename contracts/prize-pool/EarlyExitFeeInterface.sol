pragma solidity >=0.6.0 <0.7.0;

interface EarlyExitFeeInterface{
    
      /// @dev Calculates the early exit fee for the given amount
  /// @param amount The amount of collateral to be withdrawn
    function calculateEarlyExitFeeNoCredit(address controlledToken, uint256 amount) external view returns (uint256);
    

      /// @notice Calculate the early exit for a user given a withdrawal amount.  The user's credit is taken into account.
  /// @param from The user who is withdrawing
  /// @param controlledToken The token they are withdrawing
  /// @param amount The amount of funds they are withdrawing
    function calculateEarlyExitFeeLessBurnedCredit(    address from,
    address controlledToken,
    uint256 amount  )     external
    returns (
      uint256 earlyExitFee,
      uint256 creditBurned
    );
    
      /// @notice Returns the credit rate of a controlled token
  /// @param controlledToken The controlled token to retrieve the credit rates for
     function creditPlanOf(
    address controlledToken
  )
    external
    view
    returns (
      uint128 creditLimitMantissa,
      uint128 creditRateMantissa
    );

  

}