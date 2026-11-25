"""Creazione e lettura ordini."""
import logging
import sqlite3
from dataclasses import dataclass

from .config import get_database_path

logger = logging.getLogger(__name__)


class OrderValidationError(ValueError):
    """Dati dell'ordine non validi."""


@dataclass(frozen=True)
class Order:
    id: int
    customer_id: int
    total_cents: int


def _connect() -> sqlite3.Connection:
    conn = sqlite3.connect(get_database_path())
    conn.execute(
        "CREATE TABLE IF NOT EXISTS orders ("
        "id INTEGER PRIMARY KEY AUTOINCREMENT, "
        "customer_id INTEGER NOT NULL, "
        "total_cents INTEGER NOT NULL)"
    )
    return conn


def create_order(customer_id: int, total_cents: int) -> int:
    """Crea un ordine e ne restituisce l'id."""
    if customer_id <= 0:
        raise OrderValidationError("customer_id deve essere positivo")
    if total_cents <= 0:
        raise OrderValidationError("total_cents deve essere positivo")
    conn = _connect()
    try:
        with conn:
            cur = conn.execute(
                "INSERT INTO orders (customer_id, total_cents) VALUES (?, ?)",
                (customer_id, total_cents),
            )
        logger.info("order_created", extra={"order_id": cur.lastrowid, "customer_id": customer_id})
        return int(cur.lastrowid)
    finally:
        conn.close()


def get_order(order_id: int) -> Order | None:
    """Restituisce l'ordine oppure None se non esiste."""
    if order_id <= 0:
        raise OrderValidationError("order_id deve essere positivo")
    conn = _connect()
    try:
        row = conn.execute(
            "SELECT id, customer_id, total_cents FROM orders WHERE id = ?",
            (order_id,),
        ).fetchone()
    finally:
        conn.close()
    return Order(*row) if row else None
