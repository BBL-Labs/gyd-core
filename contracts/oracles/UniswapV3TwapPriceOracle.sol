// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.4;

import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableMap.sol";

import "../auth/Governable.sol";

import "../../interfaces/oracles/IRelativePriceOracle.sol";
import "../../interfaces/vendor/uniswap/IUniswapV3Pool.sol";

import "../../libraries/vendor/OracleLibrary.sol";
import "../../libraries/Errors.sol";
import "../../libraries/FixedPoint.sol";
import "../../libraries/EnumerableExtensions.sol";

contract UniswapV3TwapOracle is IRelativePriceOracle, Governable {
    using FixedPoint for uint256;
    using EnumerableMap for EnumerableMap.UintToAddressMap;
    using EnumerableExtensions for EnumerableMap.UintToAddressMap;

    event PoolRegistered(address indexed assetA, address indexed assetB, address indexed pool);
    event PoolDeregistered(address indexed assetA, address indexed assetB, address indexed pool);

    EnumerableMap.UintToAddressMap internal pools;

    uint32 public constant DEFAULT_TIME_WINDOW_LENGTH_SECONDS_AGO = 7_200;

    uint32 public timeWindowLengthSeconds;

    constructor() {
        timeWindowLengthSeconds = DEFAULT_TIME_WINDOW_LENGTH_SECONDS_AGO;
    }

    /// @notice Registers a Uniswap pool to be used as oracle
    /// We can only register a single pool per asset pair
    function registerPool(address pool) external governanceOnly {
        address assetA = IUniswapV3Pool(pool).token0();
        address assetB = IUniswapV3Pool(pool).token1();
        uint256 poolKey = getAssetsPairKey(assetA, assetB);

        require(pools.set(poolKey, pool), Errors.INVALID_ARGUMENT);
        emit PoolRegistered(assetA, assetB, pool);
    }

    /// @notice Deregisters a Uniswap pool
    function deregisterPool(address pool) external governanceOnly {
        address assetA = IUniswapV3Pool(pool).token0();
        address assetB = IUniswapV3Pool(pool).token1();
        uint256 poolKey = getAssetsPairKey(assetA, assetB);
        require(pools.remove(poolKey), Errors.INVALID_ARGUMENT);
        emit PoolDeregistered(assetA, assetB, pool);
    }

    /// @notice Set number of seconds used for the time window of the UniV3 price oracle
    function setTimeWindowLengthSeconds(uint32 _timeWindowLengthSeconds) external governanceOnly {
        timeWindowLengthSeconds = _timeWindowLengthSeconds;
    }

    /// @inheritdoc IRelativePriceOracle
    function getRelativePrice(address baseAsset, address quoteAsset)
        external
        view
        override
        returns (uint256)
    {
        return getRelativePrice(baseAsset, quoteAsset, timeWindowLengthSeconds);
    }

    /// @notice Same as `getRelativePrice(address,address)` but allows to specify
    /// the time in seconds to use to compute the TWAP
    function getRelativePrice(
        address baseAsset,
        address quoteAsset,
        uint32 windowLengthSeconds
    ) public view returns (uint256) {
        address pool = getPool(baseAsset, quoteAsset);
        (int24 tick, ) = OracleLibrary.consult(pool, windowLengthSeconds);

        uint8 baseDecimals = IERC20Metadata(baseAsset).decimals();
        uint8 quoteDecimals = IERC20Metadata(quoteAsset).decimals();

        if (baseAsset < quoteAsset) {
            uint8 decimals = baseDecimals + 18 - quoteDecimals;
            uint128 baseAmount = uint128(10**decimals);
            return OracleLibrary.getQuoteAtTick(tick, baseAmount, baseAsset, quoteAsset);
        } else {
            uint8 decimals = quoteDecimals + 18 - baseDecimals;
            uint128 baseAmount = uint128(10**decimals);
            return
                FixedPoint.ONE.divDown(
                    OracleLibrary.getQuoteAtTick(tick, baseAmount, quoteAsset, baseAsset)
                );
        }
    }

    function isPairSupported(address baseAsset, address quoteAsset)
        external
        view
        override
        returns (bool)
    {
        return pools.contains(getAssetsPairKey(baseAsset, quoteAsset));
    }

    /// @notice Returns all the currently registered pools
    function getPools() external view returns (address[] memory) {
        return pools.valuesArray();
    }

    /// @notice Returns the Uniswap pool used to compute the TWAP between `assetA` and `assetB`
    function getPool(address assetA, address assetB) public view returns (address) {
        uint256 poolKey = getAssetsPairKey(assetA, assetB);
        return pools.get(poolKey);
    }

    function getAssetsPairKey(address assetA, address assetB) internal pure returns (uint256) {
        if (assetB < assetA) {
            (assetA, assetB) = (assetB, assetA);
        }
        return uint256(keccak256(abi.encodePacked(assetA, assetB)));
    }
}
