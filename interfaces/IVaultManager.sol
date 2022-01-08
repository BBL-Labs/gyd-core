// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.4;

import "../interfaces/IVaultWeightManager.sol";
import "../interfaces/IVaultPriceOracle.sol";
import "../libraries/DataTypes.sol";

interface IVaultManager {
    event NewVaultWeightManager(address indexed oldManager, address indexed newManager);
    event NewVaultPriceOracle(address indexed oldOracle, address indexed newOracle);

    /// @notice Returns a list of vaults without including any metadata
    function listVaults() external view returns (DataTypes.VaultInfo[] memory);

    /// @notice Returns a list of vaults with requested metadata
    function listVaults(
        bool includeIdealWeight,
        bool includePrice,
        bool includeCurrentWeight
    ) external view returns (DataTypes.VaultInfo[] memory);

    /// @notice Returns the current vault weight manager
    function getVaultWeightManager() external view returns (IVaultWeightManager);

    /// @notice Set the vault weight manager
    function setVaultWeightManager(address vaultManager) external;

    /// @notice Returns the current vault price oracle
    function getVaultPriceOracle() external view returns (IVaultPriceOracle);

    /// @notice Set the vault price oracle
    function setVaultPriceOracle(address priceOracle) external;
}
