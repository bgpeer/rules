#!/usr/bin/env python3
"""helpers.py 规则行解析回归测试。

覆盖: split_rule_line / parse_clash_entries / parse_clash_to_buckets /
parse_geosite_txt / norm_value / read_lines / write_lines。
纯标准库, 直接跑:  python3 tests/test_parse.py
"""
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "scripts"))
import helpers as h  # noqa: E402


class TestSplitRuleLine(unittest.TestCase):
    def test_basic(self):
        self.assertEqual(h.split_rule_line("DOMAIN-SUFFIX,example.com"),
                         ("DOMAIN-SUFFIX", "example.com"))

    def test_type_uppercased_and_trimmed(self):
        self.assertEqual(h.split_rule_line("  domain-suffix , example.com "),
                         ("DOMAIN-SUFFIX", "example.com"))

    def test_no_resolve_tail_stripped(self):
        self.assertEqual(
            h.split_rule_line("DOMAIN-SUFFIX,example.com,no-resolve"),
            ("DOMAIN-SUFFIX", "example.com"))
        self.assertEqual(
            h.split_rule_line("IP-CIDR,1.2.3.0/24, no-resolve"),
            ("IP-CIDR", "1.2.3.0/24"))
        # 大写 NO-RESOLVE 也剥
        self.assertEqual(
            h.split_rule_line("IP-CIDR,1.2.3.0/24,NO-RESOLVE"),
            ("IP-CIDR", "1.2.3.0/24"))

    def test_regex_internal_comma_kept(self):
        # DOMAIN-REGEX 量词里的逗号必须保留, 只剥末尾 no-resolve
        self.assertEqual(
            h.split_rule_line(r"DOMAIN-REGEX,^a{2,6}\.example\.com$,no-resolve"),
            ("DOMAIN-REGEX", r"^a{2,6}\.example\.com$"))
        self.assertEqual(
            h.split_rule_line("DOMAIN-REGEX,^x{1,3},y$"),
            ("DOMAIN-REGEX", "^x{1,3},y$"))

    def test_no_comma_returns_none(self):
        self.assertIsNone(h.split_rule_line("example.com"))
        self.assertIsNone(h.split_rule_line(""))

    def test_empty_value(self):
        self.assertEqual(h.split_rule_line("DOMAIN,"), ("DOMAIN", ""))


class TestParseClashEntries(unittest.TestCase):
    def setUp(self):
        self.d = tempfile.TemporaryDirectory()
        self.yaml = os.path.join(self.d.name, "example.yaml")

    def tearDown(self):
        self.d.cleanup()

    def _write(self, text):
        with open(self.yaml, "w", encoding="utf-8") as f:
            f.write(text)

    def test_basic_yaml(self):
        self._write(
            "payload:\n"
            "  - DOMAIN-SUFFIX,example.com\n"
            "  - DOMAIN,www.example.com,no-resolve\n"
            "  - IP-CIDR,1.2.3.0/24\n")
        self.assertEqual(h.parse_clash_entries(self.yaml), [
            ("DOMAIN-SUFFIX", "example.com"),
            ("DOMAIN", "www.example.com"),
            ("IP-CIDR", "1.2.3.0/24"),
        ])

    def test_comments_and_blank_lines_skipped(self):
        self._write(
            "payload:\n"
            "  # 注释行\n"
            "  - DOMAIN-SUFFIX,example.com # 行尾注释\n"
            "\n"
            "  - DOMAIN-KEYWORD,example\n")
        self.assertEqual(h.parse_clash_entries(self.yaml), [
            ("DOMAIN-SUFFIX", "example.com"),
            ("DOMAIN-KEYWORD", "example"),
        ])

    def test_non_item_lines_skipped(self):
        self._write("payload:\nnot an item\n- DOMAIN,example.com\n")
        # 顶格 "- ..." 同样是合法 list 项, 会被解析
        self.assertEqual(h.parse_clash_entries(self.yaml),
                         [("DOMAIN", "example.com")])

    def test_empty_value_skipped(self):
        self._write("payload:\n  - DOMAIN,\n  - DOMAIN,example.com\n")
        self.assertEqual(h.parse_clash_entries(self.yaml),
                         [("DOMAIN", "example.com")])

    def test_missing_file_returns_empty(self):
        self.assertEqual(h.parse_clash_entries(os.path.join(self.d.name, "nope.yaml")), [])
        self.assertEqual(h.parse_clash_entries(""), [])
        self.assertEqual(h.parse_clash_entries(None), [])


class TestParseClashToBuckets(unittest.TestCase):
    def setUp(self):
        self.d = tempfile.TemporaryDirectory()
        self.yaml = os.path.join(self.d.name, "example.yaml")

    def tearDown(self):
        self.d.cleanup()

    def test_buckets(self):
        with open(self.yaml, "w", encoding="utf-8") as f:
            f.write(
                "payload:\n"
                "  - DOMAIN-SUFFIX,.example.com\n"
                "  - DOMAIN,www.example.com\n"
                "  - DOMAIN-KEYWORD,example\n"
                "  - DOMAIN-REGEX,^x.*$\n"
                "  - DOMAIN-WILDCARD,*.example.com\n"
                "  - IP-CIDR,1.2.3.0/24\n"
                "  - IP-CIDR6,2606:4700::/32\n"
                "  - IP-ASN,AS12345\n"
                "  - PROCESS-NAME,com.example.tool\n"
                "  - PROCESS-NAME-REGEX,^foo.*$\n"
                "  - PROCESS-PATH,/usr/bin/foo\n"
                "  - USER-AGENT,*test*\n"
                "  - UNKNOWN-TYPE,whatever\n")
        b = h.parse_clash_to_buckets(self.yaml)
        # suffix 去前导点
        self.assertEqual(b["suffix"], ["example.com"])
        self.assertEqual(b["domain"], ["www.example.com"])
        self.assertEqual(b["keyword"], ["example"])
        self.assertEqual(b["regexp"], ["^x.*$"])
        self.assertEqual(b["wildcard"], ["*.example.com"])
        # IPv4/IPv6 进同一个 ipcidr 桶
        self.assertEqual(b["ipcidr"], ["1.2.3.0/24", "2606:4700::/32"])
        self.assertEqual(b["asn"], ["AS12345"])
        self.assertEqual(b["process"], ["com.example.tool"])
        self.assertEqual(b["process_re"], ["^foo.*$"])
        self.assertEqual(b["process_path"], ["/usr/bin/foo"])
        self.assertEqual(b["user_agent"], ["*test*"])
        # 未知类型直接丢弃, 不进任何桶
        self.assertNotIn("whatever", sum(b.values(), []))

    def test_missing_file_empty_buckets(self):
        b = h.parse_clash_to_buckets(os.path.join(self.d.name, "nope.yaml"))
        self.assertTrue(all(v == [] for v in b.values()))


class TestParseGeositeTxt(unittest.TestCase):
    def setUp(self):
        self.d = tempfile.TemporaryDirectory()
        self.txt = os.path.join(self.d.name, "geosite_example.txt")

    def tearDown(self):
        self.d.cleanup()

    def test_buckets(self):
        with open(self.txt, "w", encoding="utf-8") as f:
            f.write("example.com\n.example.net\n")
            f.write("full:www.example.com\nkeyword:example\nregexp:^x.*$\n")
        b = h.parse_geosite_txt(self.txt)
        self.assertEqual(b["suffix"], ["example.com", "example.net"])
        self.assertEqual(b["domain"], ["www.example.com"])
        self.assertEqual(b["keyword"], ["example"])
        self.assertEqual(b["regexp"], ["^x.*$"])

    def test_missing_file_empty(self):
        b = h.parse_geosite_txt(os.path.join(self.d.name, "nope.txt"))
        self.assertTrue(all(v == [] for v in b.values()))


class TestNormValue(unittest.TestCase):
    def test_suffix_strips_dot(self):
        self.assertEqual(h.norm_value("DOMAIN-SUFFIX", ".example.com"), "example.com")

    def test_cidr_lowercased(self):
        self.assertEqual(h.norm_value("IP-CIDR", "2001:DB8::1/32"), "2001:db8::1/32")
        self.assertEqual(h.norm_value("IP-CIDR6", "2001:DB8::/32"), "2001:db8::/32")

    def test_other_unchanged(self):
        self.assertEqual(h.norm_value("DOMAIN", "Example.COM"), "Example.COM")


class TestReadWriteLines(unittest.TestCase):
    def setUp(self):
        self.d = tempfile.TemporaryDirectory()

    def tearDown(self):
        self.d.cleanup()

    def test_missing_file_returns_empty(self):
        self.assertEqual(h.read_lines(os.path.join(self.d.name, "nope.txt")), [])
        self.assertEqual(h.read_lines(""), [])

    def test_blank_lines_skipped(self):
        p = os.path.join(self.d.name, "a.txt")
        with open(p, "w", encoding="utf-8") as f:
            f.write("a\n\n   \nb\n")
        self.assertEqual(h.read_lines(p), ["a", "b"])

    def test_write_creates_parent_dirs(self):
        p = os.path.join(self.d.name, "x", "y", "a.txt")
        h.write_lines(p, ["a", "b"])
        self.assertEqual(h.read_lines(p), ["a", "b"])

    def test_write_failure_raises_with_path(self):
        with self.assertRaises(RuntimeError) as cm:
            h.write_lines("/proc/nope/a.txt", ["x"])
        self.assertIn("/proc/nope/a.txt", str(cm.exception))


if __name__ == "__main__":
    unittest.main(verbosity=2)
