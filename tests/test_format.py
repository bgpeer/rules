#!/usr/bin/env python3
"""helpers.py 格式转换 / 排序 / 去重合并回归测试。

覆盖: qx_line 与各格式保留-跳过规则 (QX_SKIP_TYPES / JSON_SKIP_TYPES /
MRS_SKIP_TYPES / LIST_SKIP_TYPES)、sort_typed_lines / sort_qx_lines /
sort_cidr_values、merge_sort_typed_lines / merge_sort_qx_lines /
merge_dedup_lists / rewrite_typed_outputs。
纯标准库, 直接跑:  python3 tests/test_format.py
"""
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "scripts"))
import helpers as h  # noqa: E402


class TestQxLine(unittest.TestCase):
    def test_domain_mapping(self):
        self.assertEqual(h.qx_line("DOMAIN", "example.com"), "HOST, example.com")
        self.assertEqual(h.qx_line("DOMAIN-SUFFIX", "example.com"),
                         "HOST-SUFFIX, example.com")
        self.assertEqual(h.qx_line("DOMAIN-KEYWORD", "example"),
                         "HOST-KEYWORD, example")
        self.assertEqual(h.qx_line("DOMAIN-WILDCARD", "*.example.com"),
                         "HOST-WILDCARD, *.example.com")

    def test_ip_gets_no_resolve_and_v6_renamed(self):
        self.assertEqual(h.qx_line("IP-CIDR", "1.2.3.0/24"),
                         "IP-CIDR, 1.2.3.0/24, no-resolve")
        # QX 的 IPv6 语法是 IP6-CIDR, 不是 Clash 的 IP-CIDR6
        self.assertEqual(h.qx_line("IP-CIDR6", "2606:4700::/32"),
                         "IP6-CIDR, 2606:4700::/32, no-resolve")

    def test_asn_and_user_agent_kept(self):
        self.assertEqual(h.qx_line("IP-ASN", "AS12345"), "IP-ASN, AS12345")
        self.assertEqual(h.qx_line("USER-AGENT", "*test*"), "USER-AGENT, *test*")

    def test_unsupported_types_return_none(self):
        # QX 无 DOMAIN-REGEX (只有作用域不同的 URL-REGEX) 和全部进程类
        for t in ("DOMAIN-REGEX", "PROCESS-NAME", "PROCESS-NAME-WILDCARD",
                  "PROCESS-NAME-REGEX", "PROCESS-PATH", "PROCESS-PATH-WILDCARD",
                  "PROCESS-PATH-REGEX"):
            self.assertIsNone(h.qx_line(t, "x"), t)
        self.assertIsNone(h.qx_line("UNKNOWN", "x"))


class TestSkipSets(unittest.TestCase):
    """各格式的保留/跳过规则是转换矩阵的核心, 锁死集合内容。"""

    def test_qx_skips_regex_and_process(self):
        self.assertIn("DOMAIN-REGEX", h.QX_SKIP_TYPES)
        self.assertIn("PROCESS-NAME", h.QX_SKIP_TYPES)
        self.assertNotIn("USER-AGENT", h.QX_SKIP_TYPES)
        self.assertNotIn("IP-ASN", h.QX_SKIP_TYPES)

    def test_json_skips_wildcard_process_asn_user_agent(self):
        for t in ("DOMAIN-WILDCARD", "PROCESS-NAME", "PROCESS-NAME-REGEX",
                  "PROCESS-PATH", "USER-AGENT", "IP-ASN"):
            self.assertIn(t, h.JSON_SKIP_TYPES, t)
        # DOMAIN-REGEX 在 json 里保留 (进 domain_regex)
        self.assertNotIn("DOMAIN-REGEX", h.JSON_SKIP_TYPES)

    def test_mrs_skips_wildcard_process_user_agent(self):
        for t in ("DOMAIN-WILDCARD", "PROCESS-NAME", "USER-AGENT"):
            self.assertIn(t, h.MRS_SKIP_TYPES, t)

    def test_list_skips_regex_and_process_but_keeps_wildcard(self):
        # .list 供小火箭用: 跳过 DOMAIN-REGEX 与进程类, 保留 WILDCARD/USER-AGENT
        self.assertIn("DOMAIN-REGEX", h.LIST_SKIP_TYPES)
        self.assertIn("PROCESS-NAME", h.LIST_SKIP_TYPES)
        self.assertNotIn("DOMAIN-WILDCARD", h.LIST_SKIP_TYPES)
        self.assertNotIn("USER-AGENT", h.LIST_SKIP_TYPES)
        self.assertNotIn("IP-ASN", h.LIST_SKIP_TYPES)


class TestSortTypedLines(unittest.TestCase):
    def test_type_order(self):
        typed = [
            ("USER-AGENT", "*a*"),
            ("DOMAIN-REGEX", "^x"),
            ("IP-CIDR", "10.0.0.0/8"),
            ("IP-CIDR", "10.0.0.0/32"),
            ("IP-CIDR6", "2606:4700::/32"),
            ("DOMAIN-SUFFIX", "example.com"),
            ("DOMAIN", "example.com"),
            ("IP-ASN", "AS1"),
            ("DOMAIN-KEYWORD", "ex"),
            ("DOMAIN-WILDCARD", "*.example.com"),
            ("PROCESS-NAME", "foo"),
        ]
        got = [t for t, _ in h.sort_typed_lines(typed)]
        self.assertEqual(got, [
            "DOMAIN", "DOMAIN-SUFFIX", "DOMAIN-WILDCARD",
            # 同类型 IP: IPv4 在前, IPv6 在后; 同族内前缀越长越靠前
            "IP-CIDR", "IP-CIDR", "IP-CIDR6",
            "IP-ASN", "DOMAIN-KEYWORD", "DOMAIN-REGEX",
            "PROCESS-NAME", "USER-AGENT",
        ])
        ips = [v for t, v in h.sort_typed_lines(typed) if t.startswith("IP-CIDR")]
        self.assertEqual(ips, ["10.0.0.0/32", "10.0.0.0/8", "2606:4700::/32"])

    def test_same_type_sorted_by_value(self):
        typed = [("DOMAIN-SUFFIX", "z.example.com"),
                 ("DOMAIN-SUFFIX", "a.example.com")]
        self.assertEqual([v for _, v in h.sort_typed_lines(typed)],
                         ["a.example.com", "z.example.com"])

    def test_unknown_type_goes_last(self):
        typed = [("UNKNOWN", "x"), ("DOMAIN", "example.com")]
        self.assertEqual([t for t, _ in h.sort_typed_lines(typed)],
                         ["DOMAIN", "UNKNOWN"])


class TestSortQxLines(unittest.TestCase):
    def test_order(self):
        lines = [
            "IP-CIDR, 10.0.0.0/8, no-resolve",
            "HOST, example.com",
            "HOST-SUFFIX, example.com",
            "IP6-CIDR, 2606:4700::/32, no-resolve",
            "HOST-KEYWORD, ex",
            "USER-AGENT, *a*",
            "HOST-WILDCARD, *.example.com",
            "IP-ASN, AS1",
        ]
        self.assertEqual(h.sort_qx_lines(lines), [
            "HOST, example.com",
            "HOST-SUFFIX, example.com",
            "HOST-WILDCARD, *.example.com",
            "IP-CIDR, 10.0.0.0/8, no-resolve",
            "IP6-CIDR, 2606:4700::/32, no-resolve",
            "IP-ASN, AS1",
            "HOST-KEYWORD, ex",
            "USER-AGENT, *a*",
        ])

    def test_ip_prefix_length_desc(self):
        lines = ["IP-CIDR, 10.0.0.0/8, no-resolve",
                 "IP-CIDR, 10.0.0.0/32, no-resolve",
                 "IP-CIDR, 10.0.0.0/24, no-resolve"]
        self.assertEqual(h.sort_qx_lines(lines), [
            "IP-CIDR, 10.0.0.0/32, no-resolve",
            "IP-CIDR, 10.0.0.0/24, no-resolve",
            "IP-CIDR, 10.0.0.0/8, no-resolve",
        ])


class TestSortCidrValues(unittest.TestCase):
    def test_v4_before_v6_prefix_desc(self):
        self.assertEqual(
            h.sort_cidr_values(["2606:4700::/32", "1.2.3.4/32",
                                "10.0.0.0/8", "1.2.3.0/24"]),
            ["1.2.3.4/32", "1.2.3.0/24", "10.0.0.0/8", "2606:4700::/32"])


class TestMergeSort(unittest.TestCase):
    def test_typed_dedup_by_norm_value(self):
        old = [("DOMAIN-SUFFIX", ".example.com"), ("DOMAIN", "example.com")]
        new = [("DOMAIN-SUFFIX", "example.com"), ("DOMAIN", "other.example.com")]
        got = h.merge_sort_typed_lines(old, new)
        # ".example.com" 与 "example.com" 是同一条, 只留第一条
        self.assertEqual(got, [("DOMAIN", "example.com"),
                               ("DOMAIN", "other.example.com"),
                               ("DOMAIN-SUFFIX", ".example.com")])

    def test_typed_cidr_dedup_case_insensitive(self):
        got = h.merge_sort_typed_lines(
            [("IP-CIDR6", "2606:4700::/32")],
            [("IP-CIDR6", "2606:4700::/32")])
        self.assertEqual(got, [("IP-CIDR6", "2606:4700::/32")])

    def test_qx_merge_dedup_case_insensitive(self):
        got = h.merge_sort_qx_lines(
            ["HOST, Example.COM"],
            ["host, example.com", "HOST-SUFFIX, example.com"])
        self.assertEqual(got, ["HOST, Example.COM", "HOST-SUFFIX, example.com"])

    def test_merge_dedup_lists(self):
        self.assertEqual(
            h.merge_dedup_lists([".example.com", "a.example.com"],
                                ["example.com", "b.example.com"], "suffix"),
            [".example.com", "a.example.com", "b.example.com"])
        self.assertEqual(
            h.merge_dedup_lists(["2606:4700::/32"], ["2606:4700::/32"], "ipcidr"),
            ["2606:4700::/32"])
        # 非 suffix/ipcidr 按原值去重, 保序
        self.assertEqual(
            h.merge_dedup_lists(["a", "b"], ["b", "c"], "domain"),
            ["a", "b", "c"])


class TestRewriteTypedOutputs(unittest.TestCase):
    def setUp(self):
        self.d = tempfile.TemporaryDirectory()

    def tearDown(self):
        self.d.cleanup()

    def test_list_skips_regex_process_yaml_skips_user_agent(self):
        typed = [("DOMAIN", "example.com"),
                 ("DOMAIN-REGEX", "^x"),
                 ("PROCESS-NAME", "foo"),
                 ("USER-AGENT", "*a*"),
                 ("IP-CIDR", "1.2.3.0/24")]
        dst_list = os.path.join(self.d.name, "t.list")
        dst_yaml = os.path.join(self.d.name, "t.yaml")
        h.rewrite_typed_outputs(dst_list, dst_yaml, typed,
                                add_no_resolve_types={"IP-CIDR"})
        # .list: 跳过 DOMAIN-REGEX/进程类, 保留 USER-AGENT, IP 加 no-resolve
        self.assertEqual(h.read_lines(dst_list), [
            "DOMAIN,example.com",
            "USER-AGENT,*a*",
            "IP-CIDR,1.2.3.0/24,no-resolve",
        ])
        # .yaml: 保留 DOMAIN-REGEX/进程类, 跳过 USER-AGENT, IP 加 no-resolve
        self.assertEqual(h.read_lines(dst_yaml), [
            "payload:",
            "  - DOMAIN,example.com",
            "  - DOMAIN-REGEX,^x",
            "  - PROCESS-NAME,foo",
            "  - IP-CIDR,1.2.3.0/24,no-resolve",
        ])


if __name__ == "__main__":
    unittest.main(verbosity=2)
