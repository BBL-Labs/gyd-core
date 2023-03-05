pragma solidity ^0.8.0;

import "./auth/Governable.sol";
import "../interfaces/IGyroConfig.sol";
import "../interfaces/IGYDToken.sol";
import "../interfaces/IReserveStewardshipIncentives.sol";
import "../libraries/ConfigHelpers.sol";
import "../libraries/FixedPoint.sol";

contract ReserveStewardshipIncentives is IReserveStewardshipIncentives, Governable {
    using ConfigHelpers for IGyroConfig;
    using FixedPoint for uint256;

    uint256 internal constant MAX_REWARD_PERCENTAGE = 0.5e18;
    uint256 internal constant OVERESTIMATION_PENALTY_FACTOR = 0.1e18;  // SOMEDAY maybe review
    uint256 internal constant MAX_MAX_HEALTH_VIOLATIONS = 10;
    uint256 internal constant MIN_MIN_COLLATERAL_RATIO = 1e18;
    uint256 internal constant MIN_INITIATIVE_DURATION = 365 days;

    /// @dev We call the collection of incentive start and end times and parameters an "initiative".
    struct Initiative {
        // SOMEDAY optimization: could be stored with fewer bits to save a slot
        uint256 startTime; // timestamp
        uint256 endTime; // timestamp
        uint256 minCollateralRatio;
        uint256 maxHealthViolations;
        uint256 rewardPercentage;
    }
    Initiative public activeInitiative; // .endTime = 0 means none is there.

    struct ReserveHealthViolations {
        // SOMEDAY optimization: could be stored with fewer bits to save a slot
        uint256 lastViolatedDate; // date
        uint256 nViolations;
    }
    ReserveHealthViolations public reserveHealthViolations;

    /// @dev We store the time integral of the GYD supply to compute the reward at the end based on avg supply.
    struct AggSupply {
        uint256 lastUpdatedTime;
        uint256 aggSupply;
    }
    AggSupply public aggSupply;

    IGyroConfig public immutable gyroConfig;
    IGYDToken public immutable gydToken;

    constructor(address _governor, address _gyroConfig) Governable(_governor) {
        gyroConfig = IGyroConfig(_gyroConfig);
        gydToken = gyroConfig.getGYDToken();
    }

    function startInitiative(uint256 rewardPercentage) external governanceOnly {
        require(rewardPercentage <= MAX_REWARD_PERCENTAGE, "reward percentage too high");
        require(activeInitiative.endTime == 0, "active initiative already present");

        uint256 minCollateralRatio = gyroConfig.getStewardshipIncMinCollateralRatio();
        uint256 maxHealthViolations = gyroConfig.getStewardshipIncMaxHealthViolations();
        uint256 duration = gyroConfig.getStewardshipIncDuration();

        require(minCollateralRatio >= MIN_MIN_COLLATERAL_RATIO, "min collateral ratio too low");
        require(maxHealthViolations <= MAX_MAX_HEALTH_VIOLATIONS, "max health violations too high");
        require(duration >= MIN_INITIATIVE_DURATION, "incentive duration too short");

        DataTypes.ReserveState memory reserveState = gyroConfig
            .getReserveManager()
            .getReserveState();
        uint256 gydSupply = gydToken.totalSupply();

        uint256 collateralRatio = reserveState.totalUSDValue.divDown(gydSupply);
        require(collateralRatio >= minCollateralRatio, "collateral ratio too low");

        uint256 today = timestampToDatestamp(block.timestamp);
        reserveHealthViolations = ReserveHealthViolations(0, 0);

        aggSupply = AggSupply(block.timestamp, 0);

        Initiative memory initiative = Initiative({
            startTime: block.timestamp,
            endTime: block.timestamp + duration,
            minCollateralRatio: minCollateralRatio,
            maxHealthViolations: maxHealthViolations,
            rewardPercentage: rewardPercentage
        });
        activeInitiative = initiative;
        emit InitiativeStarted(
            initiative.endTime,
            initiative.minCollateralRatio,
            initiative.rewardPercentage
        );
    }

    function cancelInitiative() external governanceOnly {
        activeInitiative.endTime = 0;
        emit InitiativeCanceled();
    }

    function completeInitiative() external {
        DataTypes.ReserveState memory reserveState = gyroConfig
            .getReserveManager()
            .getReserveState();
        _checkpoint(reserveState);

        Initiative memory initiative = activeInitiative;

        require(initiative.endTime > 0, "no active initiative");
        require(initiative.endTime <= block.timestamp, "initiative not yet complete");

        // TODO add view methods for easier checking by others. Then use these functions, too, here.

        // Check incentive success
        require(
            reserveHealthViolations.nViolations <= initiative.maxHealthViolations,
            "initiative failed: too many health violations"
        );

        // Compute target reward
        uint256 gydSupply = gydToken.totalSupply();
        uint256 initiativeLength = initiative.endTime - initiative.startTime;
        uint256 avgGYDSupply = aggSupply.aggSupply / initiativeLength;
        uint256 targetReward = initiative.rewardPercentage.mulDown(avgGYDSupply);

        // Compute max available reward
        uint256 maxAllowedGYDSupply = reserveState.totalUSDValue.divDown(
            initiative.minCollateralRatio
        );

        // The following fails if the current collateral ratio is below the minimum set in the incentive. This is almost
        // but not quite redundant with _checkpoint() above: it might be that now is the first time we're below the
        // minimum, but we wouldn't allow incentive completion in this situation.
        require(gydSupply < maxAllowedGYDSupply, "collateral ratio too low");
        uint256 maxReward = maxAllowedGYDSupply - gydSupply;

        // Marry target reward with max available reward. We could take the minimum here but we use a slightly different
        // function to incentivize governance towards moderation when choosing rewardPercentage. We introduce a linear
        // penalty for over-estimation here.
        uint256 reward = targetReward;
        if (reward > maxReward) {
            uint256 reduction = (FixedPoint.ONE + OVERESTIMATION_PENALTY_FACTOR).mulDown(
                reward - maxReward
            );
            reward = reduction < reward ? reward - reduction : 0;
        }

        gyroConfig.getMotherboard().mintStewardshipIncRewards(reward);
        emit InitiativeCompleted(initiative.startTime, reward);

        activeInitiative.endTime = 0;
    }

    function _checkpoint(DataTypes.ReserveState memory reserveState) internal {
        /*
        if (activeInitiative.endTime == 0 || activeInitiative.endTime <= block.timestamp)
            // NB it's important to not track anything after the initiative has ended: may introduce manipulability.
            return;
        */
        uint256 endTime = activeInitiative.endTime;
        if (endTime == 0)
            return;

        uint256 nowTime = block.timestamp;

        // Update aggSupply. If the active initiative has ended, we complete the update wrt. endTime to catch all of the
        // GYD supply during the period.
        uint256 aggSupplyUpdateTime = nowTime <= endTime ? nowTime : endTime;
        uint256 gydSupply = gydToken.totalSupply();
        aggSupply.aggSupply += (aggSupplyUpdateTime - aggSupply.lastUpdatedTime) * gydSupply;
        aggSupply.lastUpdatedTime = aggSupplyUpdateTime;

        if (nowTime > endTime)
            return;

        // Update reserveHealthViolations. (only if the active initiative is still running)
        uint256 collateralRatio = reserveState.totalUSDValue.divDown(gydSupply);
        if (collateralRatio < activeInitiative.minCollateralRatio) {
            uint256 today = timestampToDatestamp(block.timestamp);
            if (reserveHealthViolations.lastViolatedDate < today) {
                ++reserveHealthViolations.nViolations;
                reserveHealthViolations.lastViolatedDate = today;
            }
        }
    }

    function checkpoint(DataTypes.ReserveState memory reserveState) external {
        require(msg.sender == address(gyroConfig.getMotherboard()), "not authorized");
        return _checkpoint(reserveState);
    }

    function checkpoint() external {
        DataTypes.ReserveState memory reserveState = gyroConfig
            .getReserveManager()
            .getReserveState();
        _checkpoint(reserveState);
    }

    /// @dev Approximately days since epoch. Not quite correct but good enough to distinguish different days, which is
    /// all we need here.
    function timestampToDatestamp(uint256 timestamp) internal returns (uint256) {
        return timestamp / 1 days;
    }
}
