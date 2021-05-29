// SPDX-License-Identifier: GPL-3.0

pragma solidity >=0.5.0 <0.7.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title Interface that allows a user to draw an address using an index
interface TicketInterface is IERC20 {
  /// @notice Selects a user using a random number.  The random number will be uniformly bounded to the ticket totalSupply.
  /// @param randomNumber The random number to use to select a user.
  /// @return The winner
  function draw(uint256 randomNumber) external view returns (address);

  function borrow(address borrower,uint256 principal,uint256 borrowAmount,uint256 margin) external;

  function changeBorrow(address borrower,uint256 addMarginAmount,
  uint256 allBorrowAmount) external returns(uint256,uint256);

  function redeem(address from,
    uint256 amount,
    uint256 maximumExitFee) external returns (uint256,uint256,uint256,uint256);

  function borrowRateMantissa() external view returns (uint256);

  function borrowBalanceCurrent(address account) external view returns(uint _principal, uint _interestBorrow,uint256 margin);

  function accountBorrows(address _borrower) external returns(uint,uint,uint,uint);

  function liquidateCalculateSeizeTokens(address borrower) external returns(uint256);

  function liquidateBorrow(address from,
    address controlledToken) external returns(uint256,uint256,uint256,uint256);

  function captureAwardBalance(uint256 awardBalance) external returns (uint256);

  function captureAwardBalanceComplete() external;

  /// @notice Update the user's value
  function upDataSortitionSumTrees(address _address ,uint256 amount) external;

  function total() external view returns(uint256);

  function stakeOf(address _address) external view returns(uint256);

  function getAllShares() external view returns (uint256);
  function getUserAssets(address user) external view returns (uint256);
}
