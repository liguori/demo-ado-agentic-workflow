import unittest

from orders import service, totals


class OrderTotalWithVatTests(unittest.TestCase):
    def test_default_vat(self):
        self.assertEqual(totals.order_total_with_vat(1000), 1220)

    def test_zero_vat(self):
        self.assertEqual(totals.order_total_with_vat(1000, vat_percent=0), 1000)

    def test_negative_net_is_rejected(self):
        with self.assertRaises(service.OrderValidationError):
            totals.order_total_with_vat(-1)

    def test_vat_out_of_range_is_rejected(self):
        with self.assertRaises(service.OrderValidationError):
            totals.order_total_with_vat(1000, vat_percent=101)


if __name__ == "__main__":
    unittest.main()
