import datetime as dt
import unittest

import bandwidth_check as bc


def sample(year, month, rx, tx, name='eth0'):
    return {'interfaces': [{'name': name, 'traffic': {'month': [
        {'date': {'year': year, 'month': month}, 'rx': rx, 'tx': tx}]}}]}


class BandwidthCheckTests(unittest.TestCase):
    today = dt.date(2026, 10, 31)

    def test_sums_rx_and_tx_for_this_month(self):
        self.assertEqual(bc.month_bytes(sample(2026, 10, 3, 4), self.today), 7)

    def test_last_month_and_other_interfaces_do_not_count(self):
        self.assertEqual(bc.month_bytes(sample(2026, 9, 10**13, 0), self.today), 0)
        self.assertEqual(bc.month_bytes(sample(2026, 10, 10**13, 0, name='docker0'), self.today), 0)

    def test_alert_line_is_half_the_allowance(self):
        self.assertFalse(bc.verdict(4 * 10**12 - 1)[0])
        self.assertTrue(bc.verdict(4 * 10**12)[0])
        self.assertIn('50.0%', bc.verdict(4 * 10**12)[1])


if __name__ == '__main__':
    unittest.main()
