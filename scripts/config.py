from brownie import ZERO_ADDRESS
from tests.support import constants
from tests.support.types import VaultToDeploy, VaultType
from tests.support.utils import scale


vaults = {
    1: [
        VaultToDeploy(
            pool_id=constants.BALANCER_POOL_IDS[1]["USDP_GUSD"],
            vault_type=VaultType.BALANCER_ECLP,
            name="Gyroscope ECLP USDP/GUSD Vault",
            symbol="V-ECLP-USDP-GUSD",
            initial_weight=int(scale("0.08")),
            short_flow_memory=int(constants.OUTFLOW_MEMORY),
            short_flow_threshold=4_400_000,  # USD value
            mint_fee=0,
            redeem_fee=int(scale("0.0002")),
        ),
        VaultToDeploy(
            pool_id=constants.BALANCER_POOL_IDS[1]["LUSD_CRVUSD"],
            vault_type=VaultType.BALANCER_ECLP,
            name="Gyroscope ECLP LUSD/crvUSD Vault",
            symbol="V-ECLP-LUSD-crvUSD",
            initial_weight=int(scale("0.1")),
            short_flow_memory=int(constants.OUTFLOW_MEMORY),
            short_flow_threshold=5_500_000,  # USD value
            mint_fee=int(scale("0.001")),
            redeem_fee=int(scale("0.005")),
        ),
        VaultToDeploy(
            pool_id=constants.BALANCER_POOL_IDS["WBTC_WETH"],
            vault_type=VaultType.BALANCER_CPMM,
            name="Balancer CPMM WBTC-WETH",
            symbol="BAL-CPMM-WBTC-WETH",
            initial_weight=int(scale("0.1")),
            short_flow_memory=int(constants.OUTFLOW_MEMORY),
            short_flow_threshold=int(scale(1_000_000)),
            mint_fee=int(scale("0.004")),
            redeem_fee=int(scale("0.015")),
        ),
    ],
    137: [
        VaultToDeploy(
            pool_id=constants.BALANCER_POOL_IDS["WETH_DAI"],
            vault_type=VaultType.BALANCER_CPMM,
            name="Balancer CPMM WETH-DAI",
            symbol="BAL-CPMM-WETH-DAI",
            initial_weight=int(scale("0.5")),
            short_flow_memory=int(constants.OUTFLOW_MEMORY),
            short_flow_threshold=int(scale(1_000_000)),
            mint_fee=int(scale("0.005")),
            redeem_fee=int(scale("0.01")),
        ),
        VaultToDeploy(
            pool_id=constants.BALANCER_POOL_IDS["WETH_USDC"],
            vault_type=VaultType.BALANCER_CPMM,
            name="Balancer CPMM WETH-USDC",
            symbol="BAL-CPMM-WETH-USDC",
            initial_weight=int(scale("0.4")),
            short_flow_memory=int(constants.OUTFLOW_MEMORY),
            short_flow_threshold=int(scale(1_000_000)),
            mint_fee=int(scale("0.002")),
            redeem_fee=int(scale("0.005")),
        ),
        VaultToDeploy(
            pool_id=constants.BALANCER_POOL_IDS["WBTC_WETH"],
            vault_type=VaultType.BALANCER_CPMM,
            name="Balancer CPMM WBTC-WETH",
            symbol="BAL-CPMM-WBTC-WETH",
            initial_weight=int(scale("0.1")),
            short_flow_memory=int(constants.OUTFLOW_MEMORY),
            short_flow_threshold=int(scale(1_000_000)),
            mint_fee=int(scale("0.004")),
            redeem_fee=int(scale("0.015")),
        ),
    ],
}

vaults[1337] = vaults[1]
