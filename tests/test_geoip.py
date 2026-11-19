#!/usr/bin/env python3
"""helpers.py geoip 脏数据过滤与 CIDR 规范化回归测试。

覆盖: drop_bogon_cidrs (组播/私有/保留/环回/链路本地, private 表豁免,
非法值原样透传)、normalize_cidrs (裸 IP 补掩码、主机位清零、IPv6 小写、
非法值丢弃、去重保序)、merge_ip_cache、_sha16。
纯标准库, 直接跑:  python3 tests/test_geoip.py
"""
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "scripts"))
import helpers as h  # noqa: E402


class TestDropBogonCidrs(unittest.TestCase):
    def test_multicast_dropped(self):
        # 上游 cn 表实测带过 225.1.1.9/32 这类组播
        self.assertEqual(h.drop_bogon_cidrs(["225.1.1.9/32", "224.0.0.0/4"], "cn"), [])
        self.assertEqual(h.drop_bogon_cidrs(["ff00::/8"], "cn"), [])

    def test_private_dropped(self):
        # 上游 cn 表实测带过 10.255.128.136/32、192.168.10.1/32 这类私有地址
        self.assertEqual(
            h.drop_bogon_cidrs(["10.255.128.136/32", "192.168.10.1/32",
                                "172.16.0.0/12", "fc00::/8"], "cn"), [])

    def test_loopback_linklocal_reserved_unspecified_dropped(self):
        self.assertEqual(
            h.drop_bogon_cidrs(["127.0.0.1/32", "::1/128", "169.254.1.1/32",
                                "fe80::/10", "240.0.0.0/4", "0.0.0.0/8"], "cn"),
            [])

    def test_public_kept(self):
        kept = h.drop_bogon_cidrs(
            ["8.8.8.0/24", "1.1.1.1/32", "2606:4700::/32"], "cn")
        self.assertEqual(kept, ["8.8.8.0/24", "1.1.1.1/32", "2606:4700::/32"])

    def test_mixed_keeps_order(self):
        self.assertEqual(
            h.drop_bogon_cidrs(["8.8.8.0/24", "10.0.0.0/8", "1.1.1.0/24"], "cn"),
            ["8.8.8.0/24", "1.1.1.0/24"])

    def test_private_tag_exempt(self):
        # private 表的存在意义就是装这些段, 一刀切会把 rule-set:private 清空
        self.assertEqual(
            h.drop_bogon_cidrs(["10.0.0.0/8", "192.168.0.0/16",
                                "169.254.0.0/16", "224.0.0.0/4"], "private"),
            ["10.0.0.0/8", "192.168.0.0/16", "169.254.0.0/16", "224.0.0.0/4"])

    def test_invalid_value_passed_through(self):
        # 非法值不归这里管, 交给 normalize_cidrs 丢弃, 这里原样透传
        self.assertEqual(h.drop_bogon_cidrs(["not-an-ip", "8.8.8.0/24"], "cn"),
                         ["not-an-ip", "8.8.8.0/24"])

    def test_none_tag_still_filters(self):
        self.assertEqual(h.drop_bogon_cidrs(["10.0.0.0/8"], None), [])


class TestNormalizeCidrs(unittest.TestCase):
    def test_bare_ip_gets_mask(self):
        self.assertEqual(h.normalize_cidrs(["1.2.3.4"]), ["1.2.3.4/32"])
        self.assertEqual(h.normalize_cidrs(["2001:DB8::1"]), ["2001:db8::1/128"])

    def test_host_bits_cleared(self):
        self.assertEqual(h.normalize_cidrs(["1.2.3.4/24"]), ["1.2.3.0/24"])

    def test_ipv6_lowercased(self):
        self.assertEqual(h.normalize_cidrs(["2606:4700::/32"]), ["2606:4700::/32"])

    def test_invalid_dropped(self):
        self.assertEqual(h.normalize_cidrs(["bad", "999.999.999.999/32",
                                            "1.2.3.0/24"]), ["1.2.3.0/24"])

    def test_dedup_order_preserving(self):
        self.assertEqual(
            h.normalize_cidrs(["1.2.3.4", "1.2.3.4/32", "5.6.7.0/24", "1.2.3.4"]),
            ["1.2.3.4/32", "5.6.7.0/24"])


class TestMergeIpCache(unittest.TestCase):
    def setUp(self):
        self.d = tempfile.TemporaryDirectory()
        self.cache = os.path.join(self.d.name, "clash_ip")
        os.makedirs(self.cache)

    def tearDown(self):
        self.d.cleanup()

    def test_merges_cache_dedup_case_insensitive(self):
        h.write_lines(os.path.join(self.cache, "example.ipcidr.txt"),
                      ["203.0.113.0/24", "2606:4700::/32"])
        got = h.merge_ip_cache("example", ["8.8.8.0/24", "203.0.113.0/24"],
                               self.cache)
        self.assertEqual(got, ["8.8.8.0/24", "203.0.113.0/24", "2606:4700::/32"])

    def test_missing_cache_file_is_noop(self):
        self.assertEqual(h.merge_ip_cache("nope", ["8.8.8.0/24"], self.cache),
                         ["8.8.8.0/24"])


class TestSha16(unittest.TestCase):
    def test_known_content(self):
        import hashlib
        with tempfile.NamedTemporaryFile("wb", delete=False) as f:
            f.write(b"hello\n")
            path = f.name
        try:
            self.assertEqual(h._sha16(path),
                             hashlib.sha256(b"hello\n").hexdigest()[:16])
        finally:
            os.unlink(path)

    def test_missing_file_empty(self):
        self.assertEqual(h._sha16("/nonexistent/path/x.txt"), "")


if __name__ == "__main__":
    unittest.main(verbosity=2)
