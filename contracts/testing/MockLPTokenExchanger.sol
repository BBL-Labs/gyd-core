// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.4;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import "../../libraries/DataTypes.sol";
import "../../interfaces/IGyroVault.sol";
import "../../interfaces/ILPTokenExchangerRegistry.sol";
import "../../interfaces/ILPTokenExchanger.sol";
import "../BaseVaultRouter.sol";

contract MockLPTokenExchanger {
    function getSupportedTokens() external view returns (address[] memory) {
        // address[] memory supportedTokens = []
    }

    function swapIn(DataTypes.MonetaryAmount memory underlyingToken, address userAddress)
        external
        returns (uint256 lpTokenAmount)
    {
        IERC20(underlyingToken.tokenAddress).transferFrom(
            userAddress,
            address(this),
            underlyingToken.amount
        );
        return underlyingToken.amount / 2;
    }

    function swapOut(DataTypes.MonetaryAmount memory lpToken, address userAddress)
        external
        returns (uint256 underlyingTokenAmount)
    {
        IERC20(lpToken.tokenAddress).transferFrom(address(this), userAddress, lpToken.amount);
        return lpToken.amount;
    }
}
