// SPDX-License-Identifier: GPL-3.0

pragma solidity >=0.5.0 <0.7.0;

/// @title Interface that allows a user to draw an address using an index
interface ReduceTicketInterface {
    /**
     * @notice Checks if the reduceTicket should be allowed to occur
     */
    function reduceAddTicketAllowed(address controlledToken,address account) external returns (bool);

    /**
     * @notice Calculate number of tokens of collateral asset to seize given an amount
     */
    function reduceTicketCalculateSeizeTokens(address controlledToken,address addTicketer) external view returns (uint256);

    /**
     * @notice Calculate the account's current risk value
     */
    function calculateRiskValue(address controlledToken,address account) external  returns (uint256);
    
    function calculateCurrentRiskValue(
    address controlledToken,address account,uint256 addTicketAmount,uint256 maxfee,uint256 incurred_feeAddTicket) external  returns (uint256);

    function addTicketAllowed(address controlledToken,address account,
    uint256 currentPrincipal,uint256 currentAddTicketAmount,uint256 currentmaxfee,
    uint256 addTicketAmount,uint256 incurred_feeAddTicket,uint256 maxfee,uint256 addTicketRateMantissa) external;

    function changeAddTicketAllowed(address controlledToken,address account,uint256 principal,uint256 addAddTicketAmount,uint256 addTicketAmount,
     uint256 incurred_feeAddTicket,uint256 maxfee,uint256 addTicketRateMantissa) external;

    function getExitFee(address controlledToken,address account,uint256 addAddTicketAmount,
    uint256 addTicketAmount)  external returns(uint256);

    function creditPlanOf(address controlledToken) external view returns(uint128,uint128);

    function calculateEarlyExitFee(address account,address controlledToken,uint256 amount) external returns( uint256 exitFee,uint256 burnedCredit);

    function calculateEarlyExitFeeNoCredit(address controlledToken,uint256 amount) external view returns(uint256);
    
}
