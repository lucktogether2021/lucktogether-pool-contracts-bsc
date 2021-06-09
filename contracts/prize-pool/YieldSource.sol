// SPDX-License-Identifier: GPL-3.0

pragma solidity >=0.6.0 <0.7.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../external/compound/CTokenInterface.sol";

/// @title Defines the functions used to interact with a yield source.  The Prize Pool inherits this contract.
/// @notice Prize Pools subclasses need to implement this interface so that yield can be generated.
interface YieldSource {
  /// @notice Determines whether the passed token can be transferred out as an external award.
  /// @dev Different yield sources will hold the deposits as another kind of token: such a Compound's cToken.  The
  /// prize strategy should not be allowed to move those tokens.
  /// @param _externalToken The address of the token to check
  /// @return True if the token may be awarded, false otherwise
  function canAwardExternal(address _externalToken) external view returns (bool);

  /// @notice Returns the ERC20 asset token used for deposits.
  /// @return The ERC20 asset token
  function token() external view returns (IERC20);

  function cToken() external view returns (address);

  /// @notice Returns the total balance (in asset tokens).  This includes the deposits and incurred_fee.
  /// @return The underlying balance of asset tokens
  function balance() external returns (uint256);

  /// @notice Supplies asset tokens to the yield source.
  /// @param mintAmount The amount of asset tokens to be supplied
  function supply(uint256 mintAmount, address _cToken) external;

  /// @notice Redeems asset tokens from the yield source.
  /// @param redeemAmount The amount of yield-bearing tokens to be redeemed
  function redeem(uint256 redeemAmount, address _cToken) external returns (uint256);

  /// @notice claim
  function claim(address _address) external;

  function priority() external returns (uint256);

  function availableQuota() external returns (uint256);

  function platform() external  pure returns(uint256);
}
