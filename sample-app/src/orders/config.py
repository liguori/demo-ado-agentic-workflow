"""Configurazione: i valori variabili o sensibili arrivano dall'ambiente."""
import os


def get_database_path() -> str:
    """Percorso del database SQLite (default: file locale)."""
    return os.environ.get("ORDERS_DB_PATH", "orders.db")
