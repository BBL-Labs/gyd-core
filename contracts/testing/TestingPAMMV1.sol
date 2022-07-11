pragma solidity ^0.8.4;

// SPDX-License-Identifier: MIT

import "../PrimaryAMMV1.sol";

contract TestingPAMMV1 is PrimaryAMMV1 {
    using FixedPoint for uint256;

    uint256 internal _gyroSupply;

    constructor(address gyroConfig, Params memory params) PrimaryAMMV1(gyroConfig, params) {}

    function computeRegion(State calldata anchoredState) external view returns (Region) {
        DerivedParams memory derived = createDerivedParams(systemParams);

        uint256 b = computeReserve(
            anchoredState.redemptionLevel,
            anchoredState.reserveValue,
            anchoredState.totalGyroSupply,
            systemParams
        );
        uint256 y = anchoredState.totalGyroSupply - anchoredState.redemptionLevel;
        State memory state = State({
            redemptionLevel: anchoredState.redemptionLevel,
            reserveValue: b,
            totalGyroSupply: y
        });

        return computeReserveValueRegion(state, systemParams, derived);
    }

    function computeReserveValue(State calldata anchoredState) public view returns (uint256) {
        Params memory params = systemParams;
        DerivedParams memory derived = createDerivedParams(systemParams);
        uint256 b = computeReserve(
            anchoredState.redemptionLevel,
            anchoredState.reserveValue,
            anchoredState.totalGyroSupply,
            systemParams
        );
        uint256 y = anchoredState.totalGyroSupply - anchoredState.redemptionLevel;
        State memory state = State({
            redemptionLevel: anchoredState.redemptionLevel,
            reserveValue: b,
            totalGyroSupply: y
        });
        return computeAnchoredReserveValue(state, params, derived);
    }

    // NOTE: needs to not be pure to be able to get transaction information from the frontend
    function computeReserveValueWithGas(State calldata anchoredState)
        external
        view
        returns (uint256)
    {
        return computeReserveValue(anchoredState);
    }

    function testComputeFixedReserve(
        uint256 x,
        uint256 ba,
        uint256 ya,
        uint256 alpha,
        uint256 xu,
        uint256 xl
    ) external pure returns (uint256) {
        return computeReserveFixedParams(x, ba, ya, alpha, xu, xl);
    }

    function testComputeReserve(
        uint256 x,
        uint256 ba,
        uint256 ya,
        Params memory params
    ) external pure returns (uint256) {
        return computeReserve(x, ba, ya, params);
    }

    function testComputeSlope(
        uint256 ba,
        uint256 ya,
        uint256 thetaFloor,
        uint256 alphaMin
    ) external pure returns (uint256) {
        return computeAlpha(ba, ya, thetaFloor, alphaMin);
    }

    function testComputeUpperRedemptionThreshold(
        uint256 ba,
        uint256 ya,
        uint256 alpha,
        uint256 stableRedeemThresholdUpperBound,
        uint256 targetUtilizationCeiling
    ) external pure returns (uint256) {
        return
            computeXu(ba, ya, alpha, stableRedeemThresholdUpperBound, targetUtilizationCeiling);
    }

    function computeDerivedParams() external view returns (DerivedParams memory) {
        return createDerivedParams(systemParams);
    }

    function setState(State calldata newState) external {
        redemptionLevel = newState.redemptionLevel;
        _gyroSupply = newState.totalGyroSupply;
    }

    function setParams(Params calldata newParams) external {
        systemParams = newParams;
    }

    function setDecaySlopeLowerBound(uint64 alpha) external {
        systemParams.alphaBar = alpha;
    }

    function redeemTwice(
        uint256 x1,
        uint256 x2,
        uint256 y
    ) external returns (uint256 initialRedeem, uint256 secondaryRedeem) {
        initialRedeem = redeem(x1, y);
        secondaryRedeem = redeem(x2, y - initialRedeem);
    }

    function _getGyroSupply() internal view override returns (uint256) {
        return _gyroSupply;
    }
}
