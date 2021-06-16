// SPDX-License-Identifier: GPL-3.0

pragma solidity >=0.6.0 <0.7.0;

import "../token/ControlledToken.sol";
import "../token/TicketInterface.sol";
import "./EarlyExitFee.sol";
import "./PrizePoolInterface.sol";
import "@pooltogether/fixed-point/contracts/FixedPoint.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
contract Liquidation is Ownable{

    PrizePoolInterface public prizePoolInterface;
    EarlyExitFee public earlyExitFee;
    
    using SafeMath for uint256;
    address public erc20TargetAddress;
    /// @dev Emitted
    event LiquidationUsers(
       address controlledToken,  
       address user,
       uint256 userBalance,
       uint256 burnedCredit,
       uint256 redeemedAmount
    );
    function setPrizePoolInterface(PrizePoolInterface _prizePoolInterface) external onlyOwner{
        prizePoolInterface = _prizePoolInterface;
    }

    function setEarlyExitFee(EarlyExitFee _earlyExitFee) external onlyOwner{
        earlyExitFee = _earlyExitFee;
    }
 
    function setErc20TargetAddress(address _erc20TargetAddress) external onlyOwner{
        erc20TargetAddress = _erc20TargetAddress;
    }

    function getTotalIncurred() internal returns(uint256){
        uint256 balance = prizePoolInterface.balance();
        uint256 accountedBalance = prizePoolInterface.accountedBalance();
        if(balance > accountedBalance){
            return balance.sub(accountedBalance);
        }else{
            return 0;
        }
    }

    function liquidationErc20(address[] calldata erc20Address) external onlyOwner{
        for(uint256 j = 0; j < erc20Address.length; j++){
           uint256 _tbalance = IERC20(erc20Address[j]).balanceOf(address(prizePoolInterface));
           prizePoolInterface.liquidationErc20(erc20Address[j],erc20TargetAddress,_tbalance);
        }   
    }

    function liquidationUsers(address controlledToken,address[] calldata users) external onlyOwner{
         address _controlledToken = controlledToken;
         uint256 totalIncurred = TicketInterface(_controlledToken).captureAwardBalance(getTotalIncurred());
         uint256 allShares = TicketInterface(_controlledToken).getAllShares();    
         for(uint256 i = 0; i < users.length; i++){
                address user = users[i];
                uint256 userAssets = TicketInterface(_controlledToken).getUserAssets(user);
                if (userAssets > 0) {

                (,uint256 burnedCredit) = earlyExitFee.calculateEarlyExitFeeLessBurnedCredit(user,_controlledToken, userAssets); 
            
                uint256 balanceMantissa = FixedPoint.calculateMantissa(userAssets, allShares);
                // calculate user principal + remaining margin
                uint256 liquidationBalance = TicketInterface(_controlledToken).captureUserLiquidationBalance(user);
                // calculate user incurred
                uint256 redeemedAmount = liquidationBalance.add(FixedPoint.multiplyUintByMantissa(totalIncurred, balanceMantissa));
                uint256 userBalance = IERC20(_controlledToken).balanceOf(user);

                emit LiquidationUsers(_controlledToken,user,userBalance,burnedCredit,redeemedAmount);
                prizePoolInterface.liquidationUser(_controlledToken,user,userBalance,burnedCredit,redeemedAmount);
                }

          } 
  
    }
}