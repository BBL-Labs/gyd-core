from decimal import Decimal
from tests.support.quantized_decimal import QuantizedDecimal
from tests.support.utils import scale

RAW_THETA_FLOOR = "0.6"
RAW_XU_MAX_REL = "0.3"
RAW_ALPHA_MIN_REL = "1"

THETA_FLOOR: Decimal = scale(RAW_THETA_FLOOR, 18)
XU_MAX_REL: Decimal = scale(RAW_XU_MAX_REL, 18)  # Relative to ya. Scale by * ya.
ALPHA_MIN_REL: Decimal = scale(RAW_ALPHA_MIN_REL, 18)  # Relative to ya. Scale by / ya.

UNSCALED_THETA_FLOOR = QuantizedDecimal(RAW_THETA_FLOOR)
UNSCALED_XU_MAX_REL = QuantizedDecimal(RAW_XU_MAX_REL)
UNSCALED_ALPHA_MIN_REL = QuantizedDecimal(RAW_ALPHA_MIN_REL)
