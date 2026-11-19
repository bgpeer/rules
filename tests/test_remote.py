#!/usr/bin/env python3
"""helpers.py 远程规则解析回归测试 (DOMAIN-Link / IP-Link)。

覆盖: parse_remote_domain_entries (clash / QX / sing-box JSON / 纯域名文本、
+. 与前导点、IP 条目排除、去重)、parse_remote_ip_entries (clash / ip-text /
裸 CIDR / QX IP6-CIDR 映射、非法值丢弃、规范化)。
不碰网络, 只测解析函数。直接跑:  python3 tests/test_remote.py
"""
import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "scripts"))
import helpers as h  # noqa: E402


class TestParseRemoteDomainEntries(unittest.TestCase):
    def test_clash_yaml(self):
        text = ("payload:\n"
                "  - DOMAIN,example.com\n"
                "  - DOMAIN-SUFFIX,.example.net\n"
                "  - DOMAIN-KEYWORD,example\n"
                "  - DOMAIN-REGEX,^a{2,6}\\.example\\.com$\n"
                "  - IP-CIDR,1.2.3.0/24\n"
                "  - IP-ASN,AS12345\n")
        b = h.parse_remote_domain_entries(text, "clash")
        self.assertEqual(b["domain"], ["example.com"])
        self.assertEqual(b["suffix"], ["example.net"])
        self.assertEqual(b["keyword"], ["example"])
        self.assertEqual(b["regexp"], [r"^a{2,6}\.example\.com$"])
        # IP 类条目不进域名桶 (桶 dict 里根本没有 ipcidr/asn 键)
        self.assertNotIn("ipcidr", b)
        self.assertNotIn("asn", b)

    def test_clash_qx_host_mapping(self):
        text = ("HOST,example.com,REJECT\n"
                "HOST-SUFFIX,example.net,REJECT\n"
                "HOST-KEYWORD,example,REJECT\n"
                "HOST-WILDCARD,*.example.org,REJECT\n")
        b = h.parse_remote_domain_entries(text, "clash")
        self.assertEqual(b["domain"], ["example.com"])
        self.assertEqual(b["suffix"], ["example.net"])
        self.assertEqual(b["keyword"], ["example"])
        self.assertEqual(b["wildcard"], ["*.example.org"])

    def test_singbox_json(self):
        text = ('{"rules": [{"domain": ["example.com"], '
                '"domain_suffix": ["example.net"], '
                '"domain_keyword": ["example"]}]}')
        b = h.parse_remote_domain_entries(text, "json")
        self.assertEqual(b["domain"], ["example.com"])
        self.assertEqual(b["suffix"], ["example.net"])
        self.assertEqual(b["keyword"], ["example"])

    def test_domain_text_plain_lines(self):
        text = ("example.com\n"
                ".example.net\n"
                "+.example.org\n"
                "# 注释\n"
                "\n"
                "nodot\n"
                "has space.com\n")
        b = h.parse_remote_domain_entries(text, "domain-text")
        self.assertEqual(b["domain"], ["example.com"])
        self.assertEqual(b["suffix"], ["example.net", "example.org"])

    def test_domain_text_typed_lines(self):
        text = "DOMAIN,example.com\nDOMAIN-SUFFIX,.example.net\n"
        b = h.parse_remote_domain_entries(text, "domain-text")
        self.assertEqual(b["domain"], ["example.com"])
        self.assertEqual(b["suffix"], ["example.net"])

    def test_dedup(self):
        text = "example.com\nexample.com\n.example.net\n.example.net\n"
        b = h.parse_remote_domain_entries(text, "domain-text")
        self.assertEqual(b["domain"], ["example.com"])
        self.assertEqual(b["suffix"], ["example.net"])

    def test_process_entries_kept(self):
        text = "PROCESS-NAME,com.example.tool\nPROCESS-NAME-REGEX,^foo.*$\n"
        b = h.parse_remote_domain_entries(text, "clash")
        self.assertEqual(b["process"], ["com.example.tool"])
        self.assertEqual(b["process_re"], ["^foo.*$"])


class TestParseRemoteIpEntries(unittest.TestCase):
    def test_clash(self):
        text = ("payload:\n"
                "  - IP-CIDR,1.2.3.4\n"
                "  - IP-CIDR6,2606:4700::/32\n"
                "  - IP-ASN,AS12345\n"
                "  - DOMAIN,example.com\n")
        cidrs, asn = h.parse_remote_ip_entries(text, "clash")
        # 裸 IP 补 /32 规范化
        self.assertEqual(cidrs, ["1.2.3.4/32", "2606:4700::/32"])
        self.assertEqual(asn, ["AS12345"])

    def test_clash_bare_cidr_line(self):
        text = "1.2.3.0/24\n9.9.9.9\n"
        cidrs, asn = h.parse_remote_ip_entries(text, "clash")
        self.assertEqual(cidrs, ["1.2.3.0/24", "9.9.9.9/32"])
        self.assertEqual(asn, [])

    def test_qx_ip6_cidr_mapped(self):
        text = "IP6-CIDR,2606:4700::/32\nIP-CIDR,1.2.3.0/24\n"
        cidrs, asn = h.parse_remote_ip_entries(text, "clash")
        self.assertEqual(cidrs, ["2606:4700::/32", "1.2.3.0/24"])

    def test_ip_text(self):
        text = ("1.2.3.0/24\n"
                "2606:4700::/32\n"
                "IP-ASN,AS12345\n"
                "# 注释\n"
                "\n")
        cidrs, asn = h.parse_remote_ip_entries(text, "ip-text")
        self.assertEqual(cidrs, ["1.2.3.0/24", "2606:4700::/32"])
        self.assertEqual(asn, ["AS12345"])

    def test_invalid_dropped_and_dedup(self):
        text = "999.999.999.999\n1.2.3.0/24\n1.2.3.0/24\n"
        cidrs, _ = h.parse_remote_ip_entries(text, "ip-text")
        self.assertEqual(cidrs, ["1.2.3.0/24"])

    def test_ipv6_lowercased(self):
        text = "IP-CIDR6,2606:4700::/32\n"
        cidrs, _ = h.parse_remote_ip_entries(text, "clash")
        self.assertEqual(cidrs, ["2606:4700::/32"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
