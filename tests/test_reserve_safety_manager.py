from asyncio import constants
from curses import meta
from decimal import Decimal

import hypothesis.strategies as st
from brownie.test import given

from tests.reserve.reserve_math_implementation import (
    build_metadata,
    calculate_ideal_weights,
    calculate_weights_and_total,
    is_mint_safe,
    is_redeem_safe,
    safe_to_execute_outside_epsilon,
    update_metadata_with_epsilon_status,
    update_metadata_with_price_safety,
    update_vault_with_price_safety,
    vault_weight_off_peg_falls,
)
from tests.support import constants
from tests.support.quantized_decimal import QuantizedDecimal as D
from tests.support.utils import scale, to_decimal

# pytestmark = pytest.mark.usefixtures("set_data_for_mock_bal_vault")

amount_generator = st.integers(
    min_value=int(scale("0.001")), max_value=int(scale(1_000_000_000))
)
price_generator = st.integers(
    min_value=int(scale("0.001")), max_value=int(scale(1_000_000_000))
)
weight_generator = st.integers(min_value=int(scale("0.001")), max_value=int(scale(1)))

boolean_generator = st.booleans()

stablecoin_price_generator = st.integers(
    min_value=int(scale("0.94")), max_value=int(scale("1.06"))
)


def vault_builder(price_generator, amount_generator, weight_generator):
    persisted_metadata = (price_generator, weight_generator, constants.BALANCER_POOL_ID)
    vault_info = (
        "0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599",
        price_generator,
        persisted_metadata,
        amount_generator,
        weight_generator,
    )
    return (vault_info, amount_generator)


def vault_builder_two(price_generator, amount_generator, weight_generator):
    persisted_metadata = (
        price_generator,
        weight_generator,
        constants.BALANCER_POOL_ID_2,
    )
    vault_info = (
        "0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C566",
        price_generator,
        persisted_metadata,
        amount_generator,
        weight_generator,
    )
    return (vault_info, amount_generator)


def vault_metadata_builder(
    ideal_weight,
    current_weight,
    resulting_weight,
    delta_weight,
    price,
    all_stablecoins_on_peg,
    all_token_prices_large_enough,
    vault_within_epsilon,
):
    vault_meta_data = (
        constants.BALANCER_POOL_ID,
        ideal_weight,
        current_weight,
        resulting_weight,
        delta_weight,
        price,
        all_stablecoins_on_peg,
        all_token_prices_large_enough,
        vault_within_epsilon,
    )

    return vault_meta_data


def bundle_to_metadata(bundle):
    (
        ideal_weight,
        current_weight,
        resulting_weight,
        delta_weight,
        price,
        all_stablecoins_on_peg,
        all_token_prices_large_enough,
        vault_within_epsilon,
        all_vaults_within_epsilon,
        all_stablecoins_all_vaults_on_peg,
        all_vaults_using_large_enough_prices,
        mint,
    ) = [list(v) for v in zip(*bundle)]

    vaultmetadata = []
    for i in range(len(ideal_weight)):
        vault = vault_metadata_builder(
            ideal_weight[i],
            current_weight[i],
            resulting_weight[i],
            delta_weight[i],
            price[i],
            all_stablecoins_on_peg[i],
            all_token_prices_large_enough[i],
            vault_within_epsilon[i],
        )
        vaultmetadata.append(vault)

    metadata = (
        vaultmetadata,
        all_vaults_within_epsilon[0],
        all_stablecoins_all_vaults_on_peg[0],
        all_vaults_using_large_enough_prices[0],
        mint[0],
    )

    return metadata


@given(amounts_and_prices=st.lists(st.tuples(amount_generator, price_generator)))
def test_calculate_weights_and_total(reserve_safety_manager, amounts_and_prices):
    if not amounts_and_prices:
        return

    amounts, prices = [list(v) for v in zip(*amounts_and_prices)]

    weights_exp, total_exp = calculate_weights_and_total(
        to_decimal(amounts), to_decimal(prices)
    )
    weights_sol, total_sol = reserve_safety_manager.calculateWeightsAndTotal(
        amounts, prices
    )

    approxed_expected_weights = [scale(i).approxed() for i in weights_exp]

    assert to_decimal(weights_sol) == approxed_expected_weights
    assert total_exp == scale(total_sol).approxed()


def bundle_to_vaults(bundle):
    prices, amounts, weights = [list(v) for v in zip(*bundle)]

    vaults_with_amount = []
    for i in range(len(prices)):
        vault = vault_builder(prices[i], amounts[i], weights[i])
        vaults_with_amount.append(vault)

    return vaults_with_amount


@given(bundle=st.lists(st.tuples(price_generator, amount_generator, weight_generator)))
def test_calculate_ideal_weights(reserve_safety_manager, bundle):
    if not bundle:
        return

    vaults_with_amount = bundle_to_vaults(bundle)

    result_exp = calculate_ideal_weights(vaults_with_amount)

    result_sol = reserve_safety_manager.calculateIdealWeights(vaults_with_amount)

    assert scale(result_exp) == to_decimal(result_sol)


@given(
    bundle_metadata=st.lists(
        st.tuples(
            weight_generator,
            weight_generator,
            weight_generator,
            weight_generator,
            price_generator,
            boolean_generator,
            boolean_generator,
            boolean_generator,
            boolean_generator,
            boolean_generator,
            boolean_generator,
            boolean_generator,
        )
    )
)
def test_check_any_off_peg_vault_would_move_closer_to_ideal_weight(
    reserve_safety_manager, bundle_metadata
):
    if not bundle_metadata:
        return
    metadata = bundle_to_metadata(bundle_metadata)

    result_sol = reserve_safety_manager.vaultWeightWithOffPegFalls(metadata)
    result_exp = vault_weight_off_peg_falls(metadata)

    assert result_sol == result_exp


def order_builder(
    mint,
    initial_price,
    initial_weight,
    reserve_balance,
    current_vault_price,
    amount,
    current_weight,
):
    vaults_with_amount = []

    for i in range(len(initial_price)):

        persisted_metadata = (
            initial_price[i],
            initial_weight[i],
            constants.BALANCER_POOL_ID,
        )

        vault_info = (
            "0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599",
            current_vault_price[i],
            persisted_metadata,
            reserve_balance[i],
            current_weight[i],
        )

        vault = (vault_info, amount[i])
        vaults_with_amount.append(vault)

    return [vaults_with_amount, mint]


@given(
    order_bundle=st.lists(
        st.tuples(
            price_generator,
            weight_generator,
            amount_generator,
            price_generator,
            amount_generator,
            weight_generator,
        ),
        min_size=1,
        max_size=15,
    )
)
def test_build_metadata(reserve_safety_manager, order_bundle):
    if not order_bundle:
        return
    (
        initial_price,
        initial_weight,
        reserve_balance,
        current_vault_price,
        amount,
        current_weight,
    ) = [list(v) for v in zip(*order_bundle)]

    mint_order = order_builder(
        True,
        initial_price,
        initial_weight,
        reserve_balance,
        current_vault_price,
        amount,
        current_weight,
    )

    metadata = reserve_safety_manager.buildMetaData(mint_order)
    metadata_exp = build_metadata(mint_order)

    vaults_metadata = metadata[0]
    allVaultsWithinEpsilon = metadata[1]
    allStablecoinsAllVaultsOnPeg = metadata[2]
    allVaultsUsingLargeEnoughPrices = metadata[3]
    mint = metadata[4]

    assert mint == True

    for meta in vaults_metadata:
        assert meta[0] == mint_order[0][vaults_metadata.index(meta)][0][2][2]
        assert meta[5] == mint_order[0][vaults_metadata.index(meta)][0][1]

        assert meta[1] == to_decimal(metadata[0][vaults_metadata.index(meta)][1])
        assert meta[2] == to_decimal(metadata[0][vaults_metadata.index(meta)][2])
        assert meta[3] == to_decimal(metadata[0][vaults_metadata.index(meta)][3])
        assert meta[4] == to_decimal(metadata[0][vaults_metadata.index(meta)][4])
        assert meta[5] == to_decimal(metadata[0][vaults_metadata.index(meta)][5])


@given(
    bundle_metadata=st.lists(
        st.tuples(
            weight_generator,
            weight_generator,
            weight_generator,
            weight_generator,
            price_generator,
            boolean_generator,
            boolean_generator,
            boolean_generator,
            boolean_generator,
            boolean_generator,
            boolean_generator,
            boolean_generator,
        )
    )
)
def test_update_metadata_with_epsilon_status(reserve_safety_manager, bundle_metadata):
    if not bundle_metadata:
        return
    metadata = bundle_to_metadata(bundle_metadata)

    result_sol = reserve_safety_manager.updateMetaDataWithEpsilonStatus(metadata)
    result_exp = update_metadata_with_epsilon_status(metadata)

    assert result_sol[1] == result_exp[1]


@given(
    bundle_vault_metadata=st.tuples(
        weight_generator,
        weight_generator,
        weight_generator,
        weight_generator,
        price_generator,
        boolean_generator,
        boolean_generator,
        boolean_generator,
    )
)
def test_update_vault_with_price_safety(
    reserve_safety_manager,
    bundle_vault_metadata,
    mock_price_oracle,
    mock_balancer_vault,
    dai,
    usdc,
    asset_registry,
    admin,
):
    asset_registry.setAssetAddress("DAI", dai)
    asset_registry.addStableAsset(dai, {"from": admin})

    asset_registry.setAssetAddress("USDC", usdc)
    asset_registry.addStableAsset(usdc, {"from": admin})

    mock_balancer_vault.setPoolTokens(
        constants.BALANCER_POOL_ID, [usdc, dai], [D("2e20"), D("2e20")]
    )

    vault_metadata = vault_metadata_builder(
        bundle_vault_metadata[0],
        bundle_vault_metadata[1],
        bundle_vault_metadata[2],
        bundle_vault_metadata[3],
        bundle_vault_metadata[4],
        bundle_vault_metadata[5],
        bundle_vault_metadata[6],
        bundle_vault_metadata[7],
    )

    mock_price_oracle.setUSDPrice(dai, D("1e18"))
    mock_price_oracle.setUSDPrice(usdc, D("1e18"))
    vault_metadata_sol = reserve_safety_manager.updateVaultWithPriceSafety(
        vault_metadata
    )

    status_of_all_stablecoins = vault_metadata_sol[6]
    assert status_of_all_stablecoins == True

    mock_price_oracle.setUSDPrice(dai, D("0.8e18"))

    vault_metadata_sol = reserve_safety_manager.updateVaultWithPriceSafety(
        vault_metadata
    )
    status_of_all_stablecoins = vault_metadata_sol[6]
    assert status_of_all_stablecoins == False

    mock_price_oracle.setUSDPrice(dai, D("0.95e18"))

    vault_metadata_sol = reserve_safety_manager.updateVaultWithPriceSafety(
        vault_metadata
    )
    status_of_all_stablecoins = vault_metadata_sol[6]
    assert status_of_all_stablecoins == True

    mock_price_oracle.setUSDPrice(dai, D("0.94e18"))

    vault_metadata_sol = reserve_safety_manager.updateVaultWithPriceSafety(
        vault_metadata
    )
    status_of_all_stablecoins = vault_metadata_sol[6]
    assert status_of_all_stablecoins == False


@given(
    bundle_vault_metadata=st.tuples(
        weight_generator,
        weight_generator,
        weight_generator,
        weight_generator,
        price_generator,
        boolean_generator,
        boolean_generator,
        boolean_generator,
    )
)
def test_update_vault_with_price_safety_tiny_prices(
    reserve_safety_manager,
    bundle_vault_metadata,
    mock_price_oracle,
    mock_balancer_vault,
    abc,
    sdt,
    asset_registry,
    admin,
):
    asset_registry.setAssetAddress("ABC", abc)
    asset_registry.setAssetAddress("SDT", sdt)

    mock_balancer_vault.setPoolTokens(
        constants.BALANCER_POOL_ID, [sdt, abc], [D("2e20"), D("2e20")]
    )

    vault_metadata = vault_metadata_builder(
        bundle_vault_metadata[0],
        bundle_vault_metadata[1],
        bundle_vault_metadata[2],
        bundle_vault_metadata[3],
        bundle_vault_metadata[4],
        bundle_vault_metadata[5],
        bundle_vault_metadata[6],
        bundle_vault_metadata[7],
    )

    mock_price_oracle.setUSDPrice(abc, D("1e16"))
    mock_price_oracle.setUSDPrice(sdt, D("1e16"))
    vault_metadata_sol = reserve_safety_manager.updateVaultWithPriceSafety(
        vault_metadata
    )

    prices_large_enough = vault_metadata_sol[7]
    assert prices_large_enough == True

    mock_price_oracle.setUSDPrice(abc, D("1e12"))
    mock_price_oracle.setUSDPrice(sdt, D("1e12"))
    vault_metadata_sol = reserve_safety_manager.updateVaultWithPriceSafety(
        vault_metadata
    )

    prices_large_enough = vault_metadata_sol[7]
    assert prices_large_enough == False

    mock_price_oracle.setUSDPrice(abc, D("1e13"))
    mock_price_oracle.setUSDPrice(sdt, D("1e13"))
    vault_metadata_sol = reserve_safety_manager.updateVaultWithPriceSafety(
        vault_metadata
    )

    prices_large_enough = vault_metadata_sol[7]
    assert prices_large_enough == True

    mock_price_oracle.setUSDPrice(abc, D("0.95e12"))
    mock_price_oracle.setUSDPrice(sdt, D("1e13"))
    vault_metadata_sol = reserve_safety_manager.updateVaultWithPriceSafety(
        vault_metadata
    )

    prices_large_enough = vault_metadata_sol[7]
    assert prices_large_enough == True

    mock_price_oracle.setUSDPrice(abc, D("0.95e12"))
    mock_price_oracle.setUSDPrice(sdt, D("0.95e12"))
    vault_metadata_sol = reserve_safety_manager.updateVaultWithPriceSafety(
        vault_metadata
    )

    prices_large_enough = vault_metadata_sol[7]
    assert prices_large_enough == False


@given(
    bundle_metadata=st.lists(
        st.tuples(
            weight_generator,
            weight_generator,
            weight_generator,
            weight_generator,
            price_generator,
            boolean_generator,
            boolean_generator,
            boolean_generator,
            boolean_generator,
            boolean_generator,
            boolean_generator,
            boolean_generator,
        )
    )
)
def test_update_metadata_with_price_safety_peg(
    bundle_metadata,
    reserve_safety_manager,
    asset_registry,
    dai,
    usdc,
    mock_balancer_vault,
    admin,
    mock_price_oracle,
):
    if not bundle_metadata:
        return
    metadata = bundle_to_metadata(bundle_metadata)

    asset_registry.setAssetAddress("DAI", dai)
    asset_registry.addStableAsset(dai, {"from": admin})

    asset_registry.setAssetAddress("USDC", usdc)
    asset_registry.addStableAsset(usdc, {"from": admin})

    mock_balancer_vault.setPoolTokens(
        constants.BALANCER_POOL_ID, [usdc, dai], [D("2e20"), D("2e20")]
    )

    mock_price_oracle.setUSDPrice(dai, D("1e18"))
    mock_price_oracle.setUSDPrice(usdc, D("1e18"))

    updated_metadata = reserve_safety_manager.updateMetadataWithPriceSafety(metadata)
    onenotonpeg = False
    for vault in updated_metadata[0]:
        if vault[6] == False:
            onenotonpeg = True

    if onenotonpeg:
        assert updated_metadata[2] == False
    else:
        assert updated_metadata[2] == True

    mock_price_oracle.setUSDPrice(usdc, D("0.92e18"))

    updated_metadata = reserve_safety_manager.updateMetadataWithPriceSafety(metadata)
    onenotonpeg = False
    for vault in updated_metadata[0]:
        if vault[6] == False:
            onenotonpeg = True

    if onenotonpeg:
        assert updated_metadata[2] == False
    else:
        assert updated_metadata[2] == True


@given(
    bundle_metadata=st.lists(
        st.tuples(
            weight_generator,
            weight_generator,
            weight_generator,
            weight_generator,
            price_generator,
            boolean_generator,
            boolean_generator,
            boolean_generator,
            boolean_generator,
            boolean_generator,
            boolean_generator,
            boolean_generator,
        )
    )
)
def test_update_metadata_with_price_safety_tiny_prices(
    bundle_metadata,
    reserve_safety_manager,
    abc,
    sdt,
    asset_registry,
    mock_balancer_vault,
    mock_price_oracle,
):
    if not bundle_metadata:
        return
    metadata = bundle_to_metadata(bundle_metadata)

    asset_registry.setAssetAddress("ABC", abc)
    asset_registry.setAssetAddress("SDT", sdt)

    mock_balancer_vault.setPoolTokens(
        constants.BALANCER_POOL_ID, [sdt, abc], [D("2e20"), D("2e20")]
    )

    mock_price_oracle.setUSDPrice(abc, D("1e16"))
    mock_price_oracle.setUSDPrice(sdt, D("1e16"))

    updated_metadata = reserve_safety_manager.updateMetadataWithPriceSafety(metadata)
    onevaultpricestoosmall = False
    for vault in updated_metadata[0]:
        if vault[7] == False:
            onevaultpricestoosmall = True

    if onevaultpricestoosmall:
        assert updated_metadata[3] == False
    else:
        assert updated_metadata[3] == True

    mock_price_oracle.setUSDPrice(sdt, D("1e12"))
    mock_price_oracle.setUSDPrice(abc, D("1e12"))

    updated_metadata = reserve_safety_manager.updateMetadataWithPriceSafety(metadata)
    onevaultpricestoosmall = False
    for vault in updated_metadata[0]:
        if vault[7] == False:
            onevaultpricestoosmall = True

    if onevaultpricestoosmall:
        assert updated_metadata[3] == False
    else:
        assert updated_metadata[3] == True


@given(
    bundle_metadata=st.lists(
        st.tuples(
            weight_generator,
            weight_generator,
            weight_generator,
            weight_generator,
            price_generator,
            boolean_generator,
            boolean_generator,
            boolean_generator,
            boolean_generator,
            boolean_generator,
            boolean_generator,
            boolean_generator,
        )
    )
)
def test_safe_to_execute_outside_epsilon(bundle_metadata, reserve_safety_manager):
    if not bundle_metadata:
        return
    metadata = bundle_to_metadata(bundle_metadata)

    result_exp = safe_to_execute_outside_epsilon(metadata)

    result_sol = reserve_safety_manager.safeToExecuteOutsideEpsilon(metadata)

    assert result_exp == result_sol


@given(
    order_bundle=st.lists(
        st.tuples(
            price_generator,
            weight_generator,
            amount_generator,
            price_generator,
            amount_generator,
            weight_generator,
        ),
        min_size=1,
        max_size=5,
    )
)
def test_is_mint_safe_normal(
    reserve_safety_manager,
    order_bundle,
    asset_registry,
    admin,
    dai,
    usdc,
    sdt,
    abc,
    mock_price_oracle,
    mock_balancer_vault,
):
    if not order_bundle:
        return
    (
        initial_price,
        initial_weight,
        reserve_balance,
        current_vault_price,
        amount,
        current_weight,
    ) = [list(v) for v in zip(*order_bundle)]

    mint_order = order_builder(
        True,
        initial_price,
        initial_weight,
        reserve_balance,
        current_vault_price,
        amount,
        current_weight,
    )

    asset_registry.setAssetAddress("DAI", dai)
    asset_registry.addStableAsset(dai, {"from": admin})

    asset_registry.setAssetAddress("USDC", usdc)
    asset_registry.addStableAsset(usdc, {"from": admin})

    asset_registry.setAssetAddress("ABC", abc)
    asset_registry.addStableAsset(abc, {"from": admin})

    asset_registry.setAssetAddress("SDT", sdt)

    mock_balancer_vault.setPoolTokens(
        constants.BALANCER_POOL_ID, [usdc, dai], [D("2e20"), D("2e20")]
    )
    mock_balancer_vault.setPoolTokens(
        constants.BALANCER_POOL_ID_2, [usdc, sdt], [D("2e20"), D("2e20")]
    )
    mock_balancer_vault.setPoolTokens(
        constants.BALANCER_POOL_ID_3, [sdt, dai], [D("2e20"), D("2e20")]
    )
    mock_balancer_vault.setPoolTokens(
        constants.BALANCER_POOL_ID_4, [abc, dai], [D("2e20"), D("2e20")]
    )
    mock_balancer_vault.setPoolTokens(
        constants.BALANCER_POOL_ID_5, [usdc, abc], [D("2e20"), D("2e20")]
    )

    mock_price_oracle.setUSDPrice(dai, D("1e18"))
    mock_price_oracle.setUSDPrice(usdc, D("1e18"))
    mock_price_oracle.setUSDPrice(abc, D("1e18"))
    mock_price_oracle.setUSDPrice(sdt, D("1e18"))

    response = reserve_safety_manager.isMintSafe(mint_order)

    response_expected = is_mint_safe(
        mint_order, mock_balancer_vault, mock_price_oracle, asset_registry
    )

    assert response == response_expected


@given(
    order_bundle=st.lists(
        st.tuples(
            price_generator,
            weight_generator,
            amount_generator,
            price_generator,
            amount_generator,
            weight_generator,
        ),
        min_size=2,
        max_size=2,
    )
)
def test_is_mint_safe_small_prices(
    reserve_safety_manager,
    order_bundle,
    asset_registry,
    admin,
    dai,
    usdc,
    sdt,
    abc,
    mock_price_oracle,
    mock_balancer_vault,
):
    if not order_bundle:
        return
    (
        initial_price,
        initial_weight,
        reserve_balance,
        current_vault_price,
        amount,
        current_weight,
    ) = [list(v) for v in zip(*order_bundle)]

    mint_order = order_builder(
        True,
        initial_price,
        initial_weight,
        reserve_balance,
        current_vault_price,
        amount,
        current_weight,
    )

    asset_registry.setAssetAddress("ABC", abc)

    asset_registry.setAssetAddress("SDT", sdt)

    asset_registry.setAssetAddress("DAI", dai)
    asset_registry.addStableAsset(dai, {"from": admin})

    asset_registry.setAssetAddress("USDC", usdc)
    asset_registry.addStableAsset(usdc, {"from": admin})

    mock_balancer_vault.setPoolTokens(
        constants.BALANCER_POOL_ID, [sdt, abc], [D("2e20"), D("2e20")]
    )

    mock_balancer_vault.setPoolTokens(
        constants.BALANCER_POOL_ID_2, [usdc, dai], [D("2e20"), D("2e20")]
    )

    mock_price_oracle.setUSDPrice(abc, D("1e11"))
    mock_price_oracle.setUSDPrice(sdt, D("1e11"))
    mock_price_oracle.setUSDPrice(dai, D("1e18"))
    mock_price_oracle.setUSDPrice(usdc, D("1e18"))

    response = reserve_safety_manager.isMintSafe(mint_order)

    response_expected = is_mint_safe(
        mint_order, mock_balancer_vault, mock_price_oracle, asset_registry
    )

    assert response == response_expected == "55"


@given(
    order_bundle=st.lists(
        st.tuples(
            price_generator,
            weight_generator,
            amount_generator,
            price_generator,
            amount_generator,
            weight_generator,
        ),
        min_size=1,
        max_size=5,
    )
)
def test_is_mint_safe_off_peg(
    reserve_safety_manager,
    order_bundle,
    asset_registry,
    admin,
    dai,
    usdc,
    sdt,
    abc,
    mock_price_oracle,
    mock_balancer_vault,
):
    if not order_bundle:
        return
    (
        initial_price,
        initial_weight,
        reserve_balance,
        current_vault_price,
        amount,
        current_weight,
    ) = [list(v) for v in zip(*order_bundle)]

    mint_order = order_builder(
        True,
        initial_price,
        initial_weight,
        reserve_balance,
        current_vault_price,
        amount,
        current_weight,
    )

    asset_registry.setAssetAddress("DAI", dai)
    asset_registry.addStableAsset(dai, {"from": admin})

    asset_registry.setAssetAddress("USDC", usdc)
    asset_registry.addStableAsset(usdc, {"from": admin})

    asset_registry.setAssetAddress("ABC", abc)
    asset_registry.addStableAsset(abc, {"from": admin})

    asset_registry.setAssetAddress("SDT", sdt)

    mock_balancer_vault.setPoolTokens(
        constants.BALANCER_POOL_ID, [usdc, dai], [D("2e20"), D("2e20")]
    )
    mock_balancer_vault.setPoolTokens(
        constants.BALANCER_POOL_ID_2, [usdc, sdt], [D("2e20"), D("2e20")]
    )
    mock_balancer_vault.setPoolTokens(
        constants.BALANCER_POOL_ID_3, [sdt, dai], [D("2e20"), D("2e20")]
    )
    mock_balancer_vault.setPoolTokens(
        constants.BALANCER_POOL_ID_4, [abc, dai], [D("2e20"), D("2e20")]
    )
    mock_balancer_vault.setPoolTokens(
        constants.BALANCER_POOL_ID_5, [usdc, abc], [D("2e20"), D("2e20")]
    )

    mock_price_oracle.setUSDPrice(dai, D("0.8e18"))
    mock_price_oracle.setUSDPrice(usdc, D("1e18"))
    mock_price_oracle.setUSDPrice(abc, D("1e18"))
    mock_price_oracle.setUSDPrice(sdt, D("1e18"))

    response = reserve_safety_manager.isMintSafe(mint_order)

    response_expected = is_mint_safe(
        mint_order, mock_balancer_vault, mock_price_oracle, asset_registry
    )

    assert response == response_expected


@given(
    order_bundle=st.lists(
        st.tuples(
            price_generator,
            weight_generator,
            amount_generator,
            price_generator,
            amount_generator,
            weight_generator,
        ),
        min_size=1,
        max_size=5,
    )
)
def test_is_redeem_safe_normal(
    reserve_safety_manager,
    order_bundle,
    asset_registry,
    admin,
    dai,
    usdc,
    sdt,
    abc,
    mock_price_oracle,
    mock_balancer_vault,
):
    if not order_bundle:
        return
    (
        initial_price,
        initial_weight,
        reserve_balance,
        current_vault_price,
        amount,
        current_weight,
    ) = [list(v) for v in zip(*order_bundle)]

    for i in range(len(reserve_balance)):
        if reserve_balance[i] <= amount[i]:
            amount[i] = reserve_balance[i] - 10

    redeem_order = order_builder(
        False,
        initial_price,
        initial_weight,
        reserve_balance,
        current_vault_price,
        amount,
        current_weight,
    )

    asset_registry.setAssetAddress("DAI", dai)
    asset_registry.addStableAsset(dai, {"from": admin})

    asset_registry.setAssetAddress("USDC", usdc)
    asset_registry.addStableAsset(usdc, {"from": admin})

    asset_registry.setAssetAddress("ABC", abc)
    asset_registry.addStableAsset(abc, {"from": admin})

    asset_registry.setAssetAddress("SDT", sdt)

    mock_balancer_vault.setPoolTokens(
        constants.BALANCER_POOL_ID, [usdc, dai], [D("2e20"), D("2e20")]
    )
    mock_balancer_vault.setPoolTokens(
        constants.BALANCER_POOL_ID_2, [usdc, sdt], [D("2e20"), D("2e20")]
    )
    mock_balancer_vault.setPoolTokens(
        constants.BALANCER_POOL_ID_3, [sdt, dai], [D("2e20"), D("2e20")]
    )
    mock_balancer_vault.setPoolTokens(
        constants.BALANCER_POOL_ID_4, [abc, dai], [D("2e20"), D("2e20")]
    )
    mock_balancer_vault.setPoolTokens(
        constants.BALANCER_POOL_ID_5, [usdc, abc], [D("2e20"), D("2e20")]
    )

    mock_price_oracle.setUSDPrice(dai, D("1e18"))
    mock_price_oracle.setUSDPrice(usdc, D("1e18"))
    mock_price_oracle.setUSDPrice(abc, D("1e18"))
    mock_price_oracle.setUSDPrice(sdt, D("1e18"))

    response = reserve_safety_manager.isRedeemSafe(redeem_order)

    response_expected = is_redeem_safe(
        redeem_order, mock_balancer_vault, mock_price_oracle, asset_registry
    )

    assert response == response_expected
