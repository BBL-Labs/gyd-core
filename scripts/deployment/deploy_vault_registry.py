from brownie import GyroConfig, VaultRegistry  # type: ignore
from scripts.utils import (
    deploy_proxy,
    get_deployer,
    make_tx_params,
    with_deployed,
    with_gas_usage,
    as_singleton,
)
from tests.support import config_keys


@with_gas_usage
@with_deployed(VaultRegistry)
def proxy(vault_registry):
    deploy_proxy(vault_registry, config_key=config_keys.VAULT_REGISTRY_ADDRESS)


@with_gas_usage
@with_deployed(GyroConfig)
@as_singleton(VaultRegistry)
def main(gyro_config):
    deployer = get_deployer()
    deployer.deploy(VaultRegistry, gyro_config, **make_tx_params())
