// SPDX-License-Identifier: GPL-3.0

pragma solidity >=0.5.0 <0.7.0;

/// @title Interface that allows a user to draw an address using an index
interface LiquidationInterface {
    /**
     * @notice Checks if the liquidation should be allowed to occur
     */
    function liquidateBorrowAllowed(address controlledToken,address account) external returns (bool);

    /**
     * @notice Calculate number of tokens of collateral asset to seize given an amount
     */
    function liquidateCalculateSeizeTokens(address controlledToken,address borrower) external view returns (uint256);

    /**
     * @notice Calculate the account's current risk value
     */
    function calculateRiskValue(address controlledToken,address account) external  returns (uint256);
    
    function calculateCurrentRiskValue(
    address controlledToken,address account,uint256 borrowAmount,uint256 margin,uint256 interestBorrow) external  returns (uint256);

    function borrowAllowed(address controlledToken,address account,
    uint256 currentPrincipal,uint256 currentBorrowAmount,uint256 currentmargin,
    uint256 borrowAmount,uint256 interestBorrow,uint256 margin,uint256 borrowRateMantissa) external;

    function redeemAllowed(address controlledToken,address account,uint256 borrowAmount,uint256 interestBorrow,uint256 margin) external;

    function changeBorrowAllowed(address controlledToken,address account,uint256 principal,uint256 addBorrowAmount,uint256 borrowAmount,
     uint256 interestBorrow,uint256 margin,uint256 borrowRateMantissa) external;

    function getExitFee(address controlledToken,address account,uint256 addBorrowAmount,
    uint256 borrowAmount)  external returns(uint256);

    function creditPlanOf(address controlledToken) external view returns(uint128,uint128);

    function calculateEarlyExitFee(address account,address controlledToken,uint256 amount) external returns( uint256 exitFee,uint256 burnedCredit);

    function calculateEarlyExitFeeNoCredit(address controlledToken,uint256 amount) external view returns(uint256);
    
}