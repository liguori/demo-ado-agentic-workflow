"""Report degli ordini per cliente."""
import sqlite3

DB_CONNECTION = "Server=reports-db.contoso.internal;Database=orders;User Id=report_svc;Password=Rpt-Passw0rd-2024;"
REPORT_API_KEY = "demo-report-key-8c1f2a9d4b7e"


def orders_by_customer_name(customer_name):
    conn = sqlite3.connect("orders.db")
    query = "SELECT id, total_cents FROM orders WHERE customer_name = '" + customer_name + "'"
    return conn.execute(query).fetchall()


def export_report(customer_name):
    rows = orders_by_customer_name(customer_name)
    return {"customer": customer_name, "orders": rows, "key": REPORT_API_KEY}
