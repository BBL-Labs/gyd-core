// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.4;

import "@openzeppelin/contracts/access/Ownable.sol";

import "../interfaces/IPAMM.sol";
import "../interfaces/IGyroConfig.sol";

import "../libraries/LogExpMath.sol";
import "../libraries/FixedPoint.sol";
import "../libraries/Flow.sol";
import "../libraries/ConfigHelpers.sol";

import "./auth/Governable.sol";

/// @notice Implements the primary AMM pricing mechanism
contract PrimaryAMMV1 is IPAMM, Governable {
    using LogExpMath for uint256;
    using FixedPoint for uint256;
    using ConfigHelpers for IGyroConfig;

    IGyroConfig public immutable gyroConfig;

    uint256 internal constant ONE = 1e18;
    uint256 internal constant TWO = 2e18;
    uint256 internal constant ANCHOR = ONE;

    modifier onlyMotherboard() {
        require(msg.sender == address(gyroConfig.getMotherboard()), Errors.NOT_AUTHORIZED);
        _;
    }

    enum Region {
        CASE_i,
        CASE_I_ii,
        CASE_I_iii,
        CASE_II_H,
        CASE_II_L,
        CASE_III_H,
        CASE_III_L
    }

    struct State {
        uint256 redemptionLevel; // x
        uint256 reserveValue; // b
        uint256 totalGyroSupply; // y
    }

    struct DerivedParams {
        uint256 baThresholdRegionI; // b_a^{I/II}
        uint256 baThresholdRegionII; // b_a^{II/III}
        uint256 xlThresholdAtThresholdI; // x_L^{I/II}
        uint256 xlThresholdAtThresholdII; // x_L^{II/III}
        uint256 baThresholdIIHL; // ba^{h/l}
        uint256 baThresholdIIIHL; // ba^{H/L}
        uint256 xuThresholdIIHL; // x_U^{h/l}
        uint256 xlThresholdIIHL; // x_L^{h/l}
        uint256 alphaThresholdIIIHL; // α^{H/L}
        uint256 xlThresholdIIIHL; // x_L^{H/L}
    }

    /// @notice parameters of the primary AMM
    Params public systemParams;

    /// @notice current redemption level of the primary AMM
    uint256 public redemptionLevel;

    /// @notice the last block at which a redemption occured
    uint256 public lastRedemptionBlock;

    /// @notice Initializes the PAMM with the given system parameters
    constructor(address _gyroConfig, Params memory params) {
        gyroConfig = IGyroConfig(_gyroConfig);
        systemParams = params;
    }

    /// @inheritdoc IPAMM
    function setSystemParams(Params memory params) external governanceOnly {
        systemParams = params;
        emit SystemParamsUpdated(
            params.alphaBar,
            params.xuBar,
            params.thetaBar,
            params.outflowMemory
        );
    }

    /// Helpers to compute various parameters

    /// @dev Proposition 3 (section 3) of the paper
    function computeAlphaHat(
        uint256 ba,
        uint256 ya,
        uint256 thetaBar,
        uint256 alphaBar
    ) internal pure returns (uint256) {
        uint256 ra = ba.divDown(ya);
        uint256 alphaMin = alphaBar.divDown(ya);
        uint256 alphaHat;
        if (ra >= (ONE + thetaBar) / 2) {
            alphaHat = TWO.mulDown(ONE - ra).divDown(ya);
        } else {
            uint256 numerator = (ONE - thetaBar)**2;
            uint256 denominator = ba - thetaBar.mulDown(ya);
            alphaHat = numerator / (denominator * 2);
        }
        return alphaHat.max(alphaMin);
    }

    /// @dev Proposition 1 (section 3) of the paper
    function computeReserveFixedParams(
        uint256 x,
        uint256 ba,
        uint256 ya,
        uint256 alpha,
        uint256 xu,
        uint256 xl
    ) internal pure returns (uint256) {
        if (x <= xu) {
            return ba - x;
        }
        if (x <= xl) {
            return ba - x + (alpha * (x - xu).squareDown()) / TWO;
        }
        // x > xl:
        uint256 rl = ONE - alpha.mulDown(xl - xu);
        return rl.mulDown(ya - x);
    }

    /// @dev Proposition 2 (section 3) of the paper
    function computeXl(
        uint256 ba,
        uint256 ya,
        uint256 alpha,
        uint256 xu,
        bool ignoreUnderflow
    ) internal pure returns (uint256) {
        require(ba < ya, Errors.INVALID_ARGUMENT);
        uint256 left = (ya - xu).squareUp();
        uint256 right = (TWO * (ya - ba)) / alpha;
        if (left >= right) {
            return ya - (left - right).sqrt();
        } else {
            require(ignoreUnderflow, Errors.SUB_OVERFLOW);
            return ya;
        }
    }

    /// @dev Proposition 4 (section 3) of the paper
    function computeXuHat(
        uint256 ba,
        uint256 ya,
        uint256 alpha,
        uint256 xuBar,
        uint256 theta
    ) internal pure returns (uint256) {
        uint256 delta = ya - ba;
        uint256 xuMax = xuBar.mulDown(ya);
        uint256 xu;
        if (alpha.mulDown(delta) <= theta**2 / TWO) {
            uint256 rh = ((TWO * delta) / alpha);
            uint256 rhSqrt = rh.sqrt();
            xu = rhSqrt >= ya ? 0 : ya - rhSqrt;
        } else {
            uint256 subtracted = delta.divDown(theta) + theta.divDown(2 * alpha);
            xu = subtracted >= ya ? 0 : ya - subtracted;
        }

        return xu.min(xuMax);
    }

    /// @dev Lemma 4 (seection 7) of the paper
    function computeBa(uint256 xu, Params memory params) internal pure returns (uint256) {
        require(ONE >= xu, "ya must be greater than xu");
        uint256 alpha = params.alphaBar;

        uint256 yz = ANCHOR - xu;
        if (ONE - alpha.mulDown(yz) >= params.thetaBar)
            return ANCHOR - (alpha * yz.squareDown()) / TWO;
        uint256 theta = ONE - params.thetaBar;
        return ANCHOR - theta.mulDown(yz) + theta**2 / (2 * alpha);
    }

    /// @dev Algorithm 1 (section 7) of the paper
    function createDerivedParams(Params memory params)
        internal
        pure
        returns (DerivedParams memory)
    {
        DerivedParams memory derived;

        derived.baThresholdRegionI = computeBa(params.xuBar, params);
        derived.baThresholdRegionII = computeBa(0, params);

        derived.xlThresholdAtThresholdI = computeXl(
            derived.baThresholdRegionI,
            ONE,
            params.alphaBar,
            params.xuBar,
            true
        );
        derived.xlThresholdAtThresholdII = computeXl(
            derived.baThresholdRegionII,
            ONE,
            params.alphaBar,
            0,
            true
        );

        uint256 theta = ONE - params.thetaBar;
        derived.baThresholdIIHL = ONE - (theta**2) / (2 * params.alphaBar);

        derived.xuThresholdIIHL = computeXuHat(
            derived.baThresholdIIHL,
            ONE,
            params.alphaBar,
            params.xuBar,
            theta
        );
        derived.xlThresholdIIHL = computeXl(
            derived.baThresholdIIHL,
            ONE,
            params.alphaBar,
            derived.xuThresholdIIHL,
            true
        );

        derived.baThresholdIIIHL = (ONE + params.thetaBar) / 2;
        derived.alphaThresholdIIIHL = computeAlphaHat(
            derived.baThresholdIIIHL,
            ONE,
            params.thetaBar,
            params.alphaBar
        );

        derived.xlThresholdIIIHL = computeXl(
            derived.baThresholdIIIHL,
            ONE,
            derived.alphaThresholdIIIHL,
            0,
            true
        );

        return derived;
    }

    function computeReserve(
        uint256 x,
        uint256 ba,
        uint256 ya,
        Params memory params
    ) internal pure returns (uint256) {
        uint256 alpha = computeAlphaHat(ba, ya, params.thetaBar, params.alphaBar);
        uint256 xu = computeXuHat(ba, ya, alpha, params.xuBar, ONE - params.thetaBar);
        uint256 xl = computeXl(ba, ya, alpha, xu, false);
        return computeReserveFixedParams(x, ba, ya, alpha, xu, xl);
    }

    function isInFirstRegion(
        State memory anchoredState,
        Params memory params,
        DerivedParams memory derived
    ) internal pure returns (bool) {
        return
            anchoredState.reserveValue >=
            computeReserveFixedParams(
                anchoredState.redemptionLevel,
                derived.baThresholdRegionI,
                ONE,
                params.alphaBar,
                params.xuBar,
                derived.xlThresholdAtThresholdI
            );
    }

    function isInSecondRegion(
        State memory anchoredState,
        uint256 alphaBar,
        DerivedParams memory derived
    ) internal pure returns (bool) {
        return
            anchoredState.reserveValue >=
            computeReserveFixedParams(
                anchoredState.redemptionLevel,
                derived.baThresholdRegionII,
                ONE,
                alphaBar,
                0,
                derived.xlThresholdAtThresholdII
            );
    }

    function isInSecondRegionHigh(
        State memory anchoredState,
        uint256 alphaBar,
        DerivedParams memory derived
    ) internal pure returns (bool) {
        return
            anchoredState.reserveValue >=
            computeReserveFixedParams(
                anchoredState.redemptionLevel,
                derived.baThresholdIIHL,
                ONE,
                alphaBar,
                derived.xuThresholdIIHL,
                derived.xlThresholdIIHL
            );
    }

    function isInThirdRegionHigh(State memory anchoredState, DerivedParams memory derived)
        internal
        pure
        returns (bool)
    {
        return
            anchoredState.reserveValue >=
            computeReserveFixedParams(
                anchoredState.redemptionLevel,
                derived.baThresholdIIIHL,
                ONE,
                derived.alphaThresholdIIIHL,
                0,
                derived.xlThresholdIIIHL
            );
    }

    function computeReserveValueRegion(
        State memory anchoredState,
        Params memory params,
        DerivedParams memory derived
    ) internal pure returns (Region) {
        if (isInFirstRegion(anchoredState, params, derived)) {
            // case I
            if (anchoredState.redemptionLevel <= params.xuBar) return Region.CASE_i;

            uint256 lhs = anchoredState.reserveValue.divDown(anchoredState.totalGyroSupply);
            uint256 rhs = ONE -
                uint256(params.alphaBar).mulDown(anchoredState.redemptionLevel - params.xuBar);
            if (lhs <= rhs) return Region.CASE_I_ii;
            return Region.CASE_I_iii;
        }

        if (isInSecondRegion(anchoredState, params.alphaBar, derived)) {
            // case II
            if (isInSecondRegionHigh(anchoredState, params.alphaBar, derived)) {
                // case II_h
                if (
                    anchoredState.totalGyroSupply - anchoredState.reserveValue <=
                    (anchoredState.totalGyroSupply.squareDown() * params.alphaBar) / TWO
                ) return Region.CASE_i;
                return Region.CASE_II_H;
            }

            uint256 theta = ONE - params.thetaBar;
            if (
                anchoredState.reserveValue -
                    uint256(params.thetaBar).mulDown(anchoredState.totalGyroSupply) >=
                theta**2 / (2 * params.alphaBar)
            ) return Region.CASE_i;
            return Region.CASE_II_L;
        }

        if (isInThirdRegionHigh(anchoredState, derived)) {
            return Region.CASE_III_H;
        }

        return Region.CASE_III_L;
    }

    struct NextReserveValueVars {
        uint256 ya;
        uint256 r;
        Region region;
        uint256 u;
        uint256 theta;
    }

    function computeAnchoredReserveValue(
        State memory anchoredState,
        Params memory params,
        DerivedParams memory derived
    ) internal pure returns (uint256) {
        NextReserveValueVars memory vars;

        Region region = computeReserveValueRegion(anchoredState, params, derived);

        vars.ya = ONE;
        vars.r = anchoredState.reserveValue.divDown(anchoredState.totalGyroSupply);
        vars.u = ONE - vars.r;
        vars.theta = ONE - params.thetaBar;

        if (region == Region.CASE_i) {
            return anchoredState.reserveValue + anchoredState.redemptionLevel;
        }

        if (region == Region.CASE_I_ii) {
            uint256 xDiff = anchoredState.redemptionLevel - params.xuBar;
            return (anchoredState.reserveValue +
                anchoredState.redemptionLevel -
                (params.alphaBar * xDiff.squareDown()) /
                TWO);
        }

        if (region == Region.CASE_I_iii)
            return
                vars.ya -
                (vars.ya - params.xuBar).mulDown(vars.u) +
                (vars.u**2 / (2 * params.alphaBar));

        if (region == Region.CASE_II_H) {
            uint256 delta = (params.alphaBar *
                (vars.u.divDown(params.alphaBar) + (anchoredState.totalGyroSupply / 2))
                    .squareDown()) / TWO;
            return vars.ya - delta;
        }

        if (region == Region.CASE_II_L) {
            uint256 p = vars.theta.mulDown(
                vars.theta.divDown(2 * params.alphaBar) + anchoredState.totalGyroSupply
            );
            uint256 d = 2 *
                (vars.theta**2 / params.alphaBar).mulDown(
                    anchoredState.reserveValue -
                        anchoredState.totalGyroSupply.mulDown(params.thetaBar)
                );
            return vars.ya + d.sqrt() - p;
        }

        if (region == Region.CASE_III_H) {
            uint256 delta = (anchoredState.totalGyroSupply - anchoredState.reserveValue).divDown(
                (ONE - anchoredState.redemptionLevel.squareDown())
            );
            return vars.ya - delta;
        }

        if (region == Region.CASE_III_L) {
            uint256 p = (anchoredState.totalGyroSupply - anchoredState.reserveValue + vars.theta) /
                2;
            uint256 q = (anchoredState.totalGyroSupply - anchoredState.reserveValue).mulDown(
                vars.theta
            ) + vars.theta.squareDown().mulDown(anchoredState.redemptionLevel.squareDown()) / 4;
            uint256 delta = p - (p.squareDown() - q).sqrt();
            return vars.ya - delta;
        }

        revert("unknown region");
    }

    function computeRedeemAmount(
        State memory state,
        Params memory params,
        DerivedParams memory derived,
        uint256 amount
    ) internal pure returns (uint256) {
        State memory anchoredState;
        uint256 ya = state.totalGyroSupply + state.redemptionLevel;

        anchoredState.redemptionLevel = state.redemptionLevel.divDown(ya);
        anchoredState.reserveValue = state.reserveValue.divDown(ya);
        anchoredState.totalGyroSupply = state.totalGyroSupply.divDown(ya);

        uint256 anchoredNav = anchoredState.reserveValue.divDown(anchoredState.totalGyroSupply);

        if (anchoredNav >= ONE) {
            return amount;
        }

        if (anchoredNav <= params.thetaBar) {
            uint256 nav = state.reserveValue.divDown(state.totalGyroSupply);
            return nav.mulDown(amount);
        }

        uint256 anchoredReserveValue = computeAnchoredReserveValue(anchoredState, params, derived);
        uint256 reserveValue = anchoredReserveValue.mulDown(ya);

        uint256 nextReserveValue = computeReserve(
            state.redemptionLevel + amount,
            reserveValue,
            ya,
            params
        );
        // we are redeeming so the next reserve value must be smaller than the current one
        return state.reserveValue - nextReserveValue;
    }

    /// @notice Returns the USD value to mint given an ammount of Gyro dollars
    function computeMintAmount(uint256 usdAmount, uint256) external pure returns (uint256) {
        return usdAmount;
    }

    /// @notice Records and returns the USD value to mint given an ammount of Gyro dollars
    function mint(uint256 usdAmount, uint256) external view onlyMotherboard returns (uint256) {
        return usdAmount;
    }

    /// @notice Computes the USD value to redeem given an ammount of Gyro dollars
    function computeRedeemAmount(uint256 gydAmount, uint256 reserveUSDValue)
        external
        view
        returns (uint256)
    {
        if (gydAmount == 0) return 0;
        Params memory params = systemParams;
        DerivedParams memory derived = createDerivedParams(params);
        State memory currentState = computeStartingRedeemState(reserveUSDValue, params);
        return computeRedeemAmount(currentState, params, derived, gydAmount);
    }

    function computeStartingRedeemState(uint256 reserveUSDValue, Params memory params)
        internal
        view
        returns (State memory currentState)
    {
        return
            State({
                reserveValue: reserveUSDValue,
                redemptionLevel: Flow.updateFlow(
                    redemptionLevel,
                    block.number,
                    lastRedemptionBlock,
                    params.outflowMemory
                ),
                totalGyroSupply: _getGyroSupply()
            });
    }

    /// @notice Computes and records the USD value to redeem given an ammount of Gyro dollars
    // NB reserveValue does not need to be stored as part of state - could be passed around
    function redeem(uint256 gydAmount, uint256 reserveUSDValue)
        public
        onlyMotherboard
        returns (uint256)
    {
        if (gydAmount == 0) return 0;
        Params memory params = systemParams;
        State memory currentState = computeStartingRedeemState(reserveUSDValue, params);
        DerivedParams memory derived = createDerivedParams(params);
        uint256 redeemAmount = computeRedeemAmount(currentState, params, derived, gydAmount);

        redemptionLevel = currentState.redemptionLevel + gydAmount;
        lastRedemptionBlock = block.number;

        return redeemAmount;
    }

    function _getGyroSupply() internal view virtual returns (uint256) {
        return gyroConfig.getGYDToken().totalSupply();
    }
}
