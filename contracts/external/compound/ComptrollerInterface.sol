pragma solidity >=0.6.0 <0.7.0;

interface ComptrollerInterface{
     function claimVenus(address holder, address[] memory cTokens) external;
     function getCompAddress() external view returns (address);
}