import os
import tempfile
import unittest

from orders import service


class OrderServiceTests(unittest.TestCase):
    def setUp(self):
        handle, self.db_path = tempfile.mkstemp(suffix=".db")
        os.close(handle)
        os.environ["ORDERS_DB_PATH"] = self.db_path

    def tearDown(self):
        os.environ.pop("ORDERS_DB_PATH", None)
        os.remove(self.db_path)

    def test_create_and_read_order(self):
        order_id = service.create_order(customer_id=7, total_cents=1250)
        order = service.get_order(order_id)
        self.assertEqual(order.customer_id, 7)
        self.assertEqual(order.total_cents, 1250)

    def test_get_missing_order_returns_none(self):
        self.assertIsNone(service.get_order(999))

    def test_invalid_input_is_rejected(self):
        with self.assertRaises(service.OrderValidationError):
            service.create_order(customer_id=0, total_cents=100)
        with self.assertRaises(service.OrderValidationError):
            service.create_order(customer_id=1, total_cents=-5)


if __name__ == "__main__":
    unittest.main()
