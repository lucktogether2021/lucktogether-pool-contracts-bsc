// SPDX-License-Identifier: GPL-3.0

pragma solidity >=0.5.0 <0.7.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title Interface that allows a user to draw an address using an index
interface TicketInterface is IERC20 {
  /// @notice Selects a user using a random number.  The random number will be uniformly bounded to the ticket totalSupply.
  /// @param randomNumber The random number to use to select a user.
  /// @return The winner
  function draw(uint256 randomNumber) external view returns (address);
  function addTicket(address addTicketer,uint256 principal,uint256 addTicketAmount,uint256 maxfee) external;

  function changeAddTicket(address addTicketer,uint256 addMaxfeeAmount,
  uint256 allAddTicketAmount) external returns(uint256,uint256);

  function redeem(address from,
    uint256 amount,
    uint256 maximumExitFee) external returns (uint256,uint256,uint256,uint256);

  function addTicketRateMantissa() external view returns (uint256);

  function addTicketBalanceCurrent(address account) external view returns(uint _principal, uint _incurred_feeAddTicket,uint256 maxfee);

  function accountAddTickets(address _addTicketer) external returns(uint,uint,uint,uint);

  function reduceTicketCalculateSeizeTokens(address addTicketer) external returns(uint256);

  function reduceAddTicket(address from) external returns(uint256,uint256,uint256,uint256);

  function captureAwardBalance(uint256 awardBalance) external returns (uint256);

  function captureAwardBalanceComplete() external;

  /// @notice Update the user's value
  function upDataSortitionSumTrees(address _address ,uint256 amount) external;

  function total() external view returns(uint256);

  function stakeOf(address _address) external view returns(uint256);

  function getAllShares() external view returns (uint256);
  function getUserAssets(address user) external view returns (uint256);

   /// @notice Calculates the user's balance at the time of liquidation.
  function captureUserLiquidationBalance(address user) external returns(uint256);

  function liquidationBalanceComplete(address user) external;
}
