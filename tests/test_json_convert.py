#!/usr/bin/env python3
"""helpers.py sing-box JSON 转换回归测试。

覆盖: _build_geosite_json_from_typed (DOMAIN-WILDCARD -> domain_regex、
PROCESS-NAME-REGEX -> package_name_regex、进程类单独成 rule、IP-ASN /
USER-AGENT 跳过、DOMAIN-SUFFIX 裸形式、version 5)、cmd_srs_source 剥字段、
_glob_to_re / _is_android_pkg / _ci、_iter_rule_lines / _norm_link_fmt。
纯标准库, 直接跑:  python3 tests/test_json_convert.py
"""
import json
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "scripts"))
import helpers as h  # noqa: E402


def build_json(typed):
    d = tempfile.mkdtemp()
    p = os.path.join(d, "t.json")
    h._build_geosite_json_from_typed(typed, p)
    with open(p, encoding="utf-8") as f:
        return json.load(f)


class TestBuildGeositeJson(unittest.TestCase):
    def test_domain_fields(self):
        d = build_json([
            ("DOMAIN", "www.example.com"),
            ("DOMAIN-SUFFIX", ".example.com"),
            ("DOMAIN-KEYWORD", "example"),
            ("DOMAIN-REGEX", "^x.*$"),
            ("IP-CIDR", "1.2.3.0/24"),
            ("IP-CIDR6", "2606:4700::/32"),
        ])
        self.assertEqual(d["version"], 5)
        self.assertEqual(len(d["rules"]), 1)
        rule = d["rules"][0]
        self.assertEqual(rule["domain"], ["www.example.com"])
        # DOMAIN-SUFFIX 写裸形式 (带点只匹配子域名, 裸形式才含主域名)
        self.assertEqual(rule["domain_suffix"], ["example.com"])
        self.assertEqual(rule["domain_keyword"], ["example"])
        self.assertEqual(rule["domain_regex"], ["^x.*$"])
        self.assertEqual(rule["ip_cidr"], ["1.2.3.0/24", "2606:4700::/32"])

    def test_wildcard_to_domain_regex(self):
        d = build_json([("DOMAIN-WILDCARD", "*.example.com"),
                        ("DOMAIN-WILDCARD", "a?.example.net")])
        rule = d["rules"][0]
        # mihomo 通配: * 含点、? 单字符、不分大小写, 转正则并锚定
        self.assertEqual(rule["domain_regex"],
                         ["^.*\\.example\\.com$", "^a.\\.example\\.net$"])

    def test_asn_and_user_agent_skipped(self):
        d = build_json([("DOMAIN", "example.com"),
                        ("IP-ASN", "AS12345"),
                        ("USER-AGENT", "*test*")])
        self.assertEqual(d["rules"], [{"domain": ["example.com"]}])

    def test_ip_cidr_dedup_case_insensitive(self):
        d = build_json([("IP-CIDR6", "2606:4700::/32"),
                        ("IP-CIDR6", "2606:4700::/32"),
                        ("IP-CIDR", "1.2.3.0/24")])
        self.assertEqual(d["rules"][0]["ip_cidr"],
                         ["2606:4700::/32", "1.2.3.0/24"])

    def test_process_name_android_vs_desktop(self):
        d = build_json([("PROCESS-NAME", "com.example.tool"),
                        ("PROCESS-NAME", "chrome.exe"),
                        ("PROCESS-NAME", "Claude")])
        by_field = {k: v for r in d["rules"] for k, v in r.items()}
        # 包名长相进 package_name, 其余进 process_name
        self.assertEqual(by_field["package_name"], ["com.example.tool"])
        self.assertEqual(by_field["process_name"], ["chrome.exe", "Claude"])

    def test_process_name_regex_to_package_name_regex(self):
        d = build_json([("PROCESS-NAME-REGEX", "^foo.*$"),
                        ("PROCESS-NAME-REGEX", "(?i)^bar.*$")])
        by_field = {k: v for r in d["rules"] for k, v in r.items()}
        # v5 专有字段, 只进 json; mihomo 进程正则不分大小写, 统一补 (?i)
        self.assertEqual(by_field["package_name_regex"],
                         ["(?i)^foo.*$", "(?i)^bar.*$"])

    def test_process_name_wildcard_dual_output(self):
        d = build_json([("PROCESS-NAME-WILDCARD", "chrome*")])
        by_field = {k: v for r in d["rules"] for k, v in r.items()}
        # 进程名 = 路径最后一段 (* 不跨目录) 进 process_path_regex,
        # 同时整条进 package_name_regex (Android 上拿包名比)
        self.assertEqual(by_field["process_path_regex"],
                         ["(?i)(?:^|[/\\\\])chrome[^/\\\\]*$"])
        self.assertEqual(by_field["package_name_regex"], ["(?i)^chrome.*$"])

    def test_process_path_forms(self):
        d = build_json([("PROCESS-PATH", "/usr/bin/foo"),
                        ("PROCESS-PATH-REGEX", "^/usr/.*"),
                        ("PROCESS-PATH-WILDCARD", "/opt/*")])
        by_field = {k: v for r in d["rules"] for k, v in r.items()}
        self.assertEqual(by_field["process_path"], ["/usr/bin/foo"])
        self.assertEqual(by_field["process_path_regex"],
                         ["(?i)^/usr/.*", "(?i)^/opt/.*$"])

    def test_process_rules_are_separate_objects(self):
        # 同一 rule 对象里域名/IP 组与进程字段是 AND, 必须拆成多个 rule (OR)
        d = build_json([("DOMAIN", "example.com"),
                        ("PROCESS-NAME", "chrome.exe")])
        self.assertEqual(len(d["rules"]), 2)
        self.assertEqual(d["rules"][0], {"domain": ["example.com"]})
        self.assertEqual(d["rules"][1], {"process_name": ["chrome.exe"]})

    def test_empty_typed(self):
        self.assertEqual(build_json([]), {"version": 5, "rules": []})


class TestSrsSource(unittest.TestCase):
    def setUp(self):
        self.d = tempfile.TemporaryDirectory()

    def tearDown(self):
        self.d.cleanup()

    def _run(self, data):
        src = os.path.join(self.d.name, "in.json")
        out = os.path.join(self.d.name, "out.json")
        with open(src, "w", encoding="utf-8") as f:
            json.dump(data, f)
        h.cmd_srs_source(src, out)
        with open(out, encoding="utf-8") as f:
            return json.load(f)

    def test_strips_package_name_regex(self):
        got = self._run({"version": 5, "rules": [
            {"domain": ["example.com"],
             "package_name_regex": ["(?i)^foo.*$"]},
            {"package_name_regex": ["(?i)^bar.*$"]},
        ]})
        # 只剩 package_name_regex 的 rule 剥空后整个丢掉
        self.assertEqual(got, {"version": 5,
                               "rules": [{"domain": ["example.com"]}]})

    def test_no_regex_fields_unchanged(self):
        got = self._run({"version": 5, "rules": [
            {"domain_suffix": ["example.com"], "ip_cidr": ["1.2.3.0/24"]}]})
        self.assertEqual(got["rules"][0]["domain_suffix"], ["example.com"])


class TestGlobAndPkg(unittest.TestCase):
    def test_glob_to_re(self):
        self.assertEqual(h._glob_to_re("*.example.com"), ".*\\.example\\.com")
        self.assertEqual(h._glob_to_re("a?b"), "a.b")
        self.assertEqual(h._glob_to_re("a+b"), "a\\+b")

    def test_ci(self):
        self.assertEqual(h._ci("^foo"), "(?i)^foo")
        self.assertEqual(h._ci("(?i)^foo"), "(?i)^foo")

    def test_is_android_pkg(self):
        self.assertTrue(h._is_android_pkg("com.example.tool"))
        self.assertTrue(h._is_android_pkg("a.b"))
        # 单段不是包名
        self.assertFalse(h._is_android_pkg("Claude"))
        # 桌面可执行后缀不算包名 (注意 .app 也是桌面后缀)
        self.assertFalse(h._is_android_pkg("chrome.exe"))
        self.assertFalse(h._is_android_pkg("com.example.app"))


class TestIterRuleLines(unittest.TestCase):
    def test_clash_json_payload(self):
        text = '{"payload": ["DOMAIN,example.com", "DOMAIN-SUFFIX,example.net"]}'
        self.assertEqual(h._iter_rule_lines(text),
                         ["DOMAIN,example.com", "DOMAIN-SUFFIX,example.net"])

    def test_singbox_json_rules_expanded(self):
        text = json.dumps({"rules": [
            {"domain": ["example.com"], "domain_suffix": ["example.net"],
             "ip_cidr": ["1.2.3.0/24"], "ip_asn": ["AS12345"]}]})
        self.assertEqual(h._iter_rule_lines(text), [
            "DOMAIN,example.com", "DOMAIN-SUFFIX,example.net",
            "IP-CIDR,1.2.3.0/24", "IP-ASN,AS12345"])

    def test_yaml_list_block(self):
        text = "payload:\n  - DOMAIN,example.com\n  - 'DOMAIN-SUFFIX,example.net'\n"
        self.assertEqual(h._iter_rule_lines(text),
                         ["DOMAIN,example.com", "DOMAIN-SUFFIX,example.net"])

    def test_plain_text_passthrough(self):
        self.assertEqual(h._iter_rule_lines("example.com\nexample.net\n"),
                         ["example.com", "example.net"])

    def test_empty(self):
        self.assertEqual(h._iter_rule_lines(""), [])
        self.assertEqual(h._iter_rule_lines("   "), [])


class TestNormLinkFmt(unittest.TestCase):
    def test_explicit_formats(self):
        self.assertEqual(h._norm_link_fmt("yaml", "x"), "clash")
        self.assertEqual(h._norm_link_fmt("json", "x"), "clash")
        self.assertEqual(h._norm_link_fmt("list", "x"), "domain-text")
        self.assertEqual(h._norm_link_fmt("list", "x", for_ip=True), "ip-text")
        self.assertEqual(h._norm_link_fmt("txt", "x", for_ip=True), "ip-text")
        self.assertEqual(h._norm_link_fmt("ip-text", "x"), "ip-text")

    def test_auto_detect_json(self):
        self.assertEqual(h._norm_link_fmt("auto", '{"payload": []}'), "clash")
        self.assertEqual(h._norm_link_fmt("auto", '[{"domain": []}]'), "clash")

    def test_auto_detect_clash_lines(self):
        self.assertEqual(h._norm_link_fmt("auto", "payload:\n  - DOMAIN,a.com"),
                         "clash")
        self.assertEqual(h._norm_link_fmt("auto", "DOMAIN,example.com"), "clash")
        self.assertEqual(h._norm_link_fmt("auto", "HOST,example.com"), "clash")

    def test_auto_falls_back_to_text(self):
        self.assertEqual(h._norm_link_fmt("auto", "example.com\nexample.net"),
                         "domain-text")
        self.assertEqual(h._norm_link_fmt("auto", "1.2.3.0/24", for_ip=True),
                         "ip-text")


if __name__ == "__main__":
    unittest.main(verbosity=2)
