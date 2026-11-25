"""Totali degli ordini."""
import logging

from .service import OrderValidationError

logger = logging.getLogger(__name__)


def order_total_with_vat(net_cents: int, vat_percent: int = 22) -> int:
    """Totale ivato in centesimi, arrotondato all'intero più vicino."""
    if net_cents < 0:
        raise OrderValidationError("net_cents non può essere negativo")
    if not 0 <= vat_percent <= 100:
        raise OrderValidationError("vat_percent fuori intervallo")
    total = round(net_cents * (100 + vat_percent) / 100)
    logger.debug("total_computed", extra={"net_cents": net_cents, "vat_percent": vat_percent})
    return total
