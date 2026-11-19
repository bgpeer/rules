#!/usr/bin/env python3
"""helpers.py 单 tag 全格式输出回归测试。

覆盖: emit_geosite_tag (yaml/list/json/QX/mrs 源/srs 任务、IP 加 no-resolve、
USER-AGENT 只进 list/QX、DOMAIN-WILDCARD 转 domain_regex、clash extras 去重
与返回值)、emit_geoip_tag (geoip 不加 no-resolve、不登记 mrs 任务)、
read_geosite_full_typed (list+yaml 并集)、_append_ip_to_geosite。
用临时目录, 不碰仓库真实产物。直接跑:  python3 tests/test_emit.py
"""
import json
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "scripts"))
import helpers as h  # noqa: E402


def read_json(path):
    with open(path, encoding="utf-8") as f:
        return json.load(f)


class EmitBase(unittest.TestCase):
    def setUp(self):
        self.d = tempfile.TemporaryDirectory()
        self.root = self.d.name
        self.out_geosite = os.path.join(self.root, "geosite")
        self.out_qx = os.path.join(self.root, "qx")
        self.out_geoip = os.path.join(self.root, "geoip")
        self.out_qx_ip = os.path.join(self.root, "qx_ip")
        self.workdir = os.path.join(self.root, "work")
        for p in (self.out_geosite, self.out_qx, self.out_geoip,
                  self.out_qx_ip, self.workdir):
            os.makedirs(p)

    def tearDown(self):
        self.d.cleanup()

    def _clash_yaml(self, lines, name="clash.yaml"):
        p = os.path.join(self.root, name)
        with open(p, "w", encoding="utf-8") as f:
            f.write("payload:\n")
            for line in lines:
                f.write(f"  - {line}\n")
        return p


class TestEmitGeositeTag(EmitBase):
    def test_full_outputs(self):
        buckets = {
            "suffix": ["example.com"],
            "domain": ["www.example.com"],
            "keyword": ["example"],
            "regexp": ["^x.*$"],
            "wildcard": ["*.example.com"],
            "process": ["com.example.tool"],
            "process_wildcard": [],
            "process_re": ["^foo.*$"],
            "process_path": [],
            "process_path_wildcard": [],
            "process_path_re": [],
            "user_agent": ["*test*"],
        }
        clash = self._clash_yaml([
            "DOMAIN,extra.example.com",
            "DOMAIN,example.com",          # 与 geo 的 suffix 语义不同, 不去重
            "IP-CIDR,203.0.113.0/24",
            "IP-CIDR6,2606:4700::/32",
            "IP-ASN,AS12345",
            "PROCESS-NAME,com.other.tool",
        ])
        mrs_tasks, srs_tasks = [], []
        extra_ip, extra_asn = h.emit_geosite_tag(
            "example", buckets, clash, self.out_geosite, self.out_qx,
            mrs_tasks, srs_tasks, self.workdir)

        # 返回 clash 带来的 IP 条目供 geoip 阶段用
        self.assertEqual(extra_ip, ["203.0.113.0/24", "2606:4700::/32"])
        self.assertEqual(extra_asn, ["AS12345"])

        # yaml: IP/ASN 加 no-resolve, USER-AGENT 不进 yaml
        yaml_lines = h.read_lines(os.path.join(self.out_geosite, "example.yaml"))
        self.assertEqual(yaml_lines[0], "payload:")
        self.assertIn("  - IP-CIDR,203.0.113.0/24,no-resolve", yaml_lines)
        self.assertIn("  - IP-CIDR6,2606:4700::/32,no-resolve", yaml_lines)
        self.assertIn("  - IP-ASN,AS12345,no-resolve", yaml_lines)
        self.assertNotIn("  - USER-AGENT,*test*", yaml_lines)
        self.assertFalse(any("USER-AGENT" in l for l in yaml_lines))

        # list: 跳过 DOMAIN-REGEX 与进程类, 保留 USER-AGENT, IP 加 no-resolve
        list_lines = h.read_lines(os.path.join(self.out_geosite, "example.list"))
        self.assertNotIn("DOMAIN-REGEX,^x.*$", list_lines)
        self.assertFalse(any(l.startswith("PROCESS-") for l in list_lines))
        self.assertIn("USER-AGENT,*test*", list_lines)
        self.assertIn("IP-CIDR,203.0.113.0/24,no-resolve", list_lines)

        # QX: HOST 系列 + USER-AGENT, IP6-CIDR 写法, 无 DOMAIN-REGEX/进程类
        qx_lines = h.read_lines(os.path.join(self.out_qx, "example.list"))
        self.assertIn("HOST, www.example.com", qx_lines)
        self.assertIn("HOST-SUFFIX, example.com", qx_lines)
        self.assertIn("HOST-WILDCARD, *.example.com", qx_lines)
        self.assertIn("USER-AGENT, *test*", qx_lines)
        self.assertIn("IP6-CIDR, 2606:4700::/32, no-resolve", qx_lines)
        self.assertFalse(any("REGEX" in l for l in qx_lines))

        # json: version 5, wildcard 转 domain_regex, 进程正则进 package_name_regex
        data = read_json(os.path.join(self.out_geosite, "example.json"))
        self.assertEqual(data["version"], 5)
        first = data["rules"][0]
        self.assertEqual(first["domain_suffix"], ["example.com"])
        self.assertIn("^.*\\.example\\.com$", first["domain_regex"])
        by_field = {k: v for r in data["rules"] for k, v in r.items()}
        self.assertEqual(by_field["package_name"],
                         ["com.example.tool", "com.other.tool"])
        self.assertEqual(by_field["package_name_regex"], ["(?i)^foo.*$"])

        # mrs 源: domain 在前, suffix 写 "+." 形式 (mihomo trie 语义)
        mrs_src = os.path.join(self.workdir, "gs_mrs", "example.txt")
        mrs_lines = h.read_lines(mrs_src)
        # clash 的 DOMAIN,example.com 与 geo 的 suffix 同值不同类型, 不去重
        self.assertEqual(mrs_lines, ["example.com", "extra.example.com",
                                     "www.example.com", "+.example.com"])
        self.assertEqual(mrs_tasks,
                         [f"domain\t{mrs_src}\t"
                          f"{os.path.join(self.out_geosite, 'example.mrs')}"])
        # srs 任务登记 json -> srs
        self.assertEqual(srs_tasks,
                         [f"{os.path.join(self.out_geosite, 'example.json')}\t"
                          f"{os.path.join(self.out_geosite, 'example.srs')}"])

    def test_clash_extra_dedup_against_geo(self):
        buckets = {"suffix": ["example.com"], "domain": [], "keyword": [],
                   "regexp": [], "wildcard": [], "process": [],
                   "process_wildcard": [], "process_re": [], "process_path": [],
                   "process_path_wildcard": [], "process_path_re": [],
                   "user_agent": []}
        clash = self._clash_yaml(["DOMAIN-SUFFIX,.example.com",
                                  "DOMAIN-SUFFIX,example.com"])
        mrs_tasks, srs_tasks = [], []
        h.emit_geosite_tag("example", buckets, clash, self.out_geosite,
                           self.out_qx, mrs_tasks, srs_tasks, self.workdir)
        yaml_lines = h.read_lines(os.path.join(self.out_geosite, "example.yaml"))
        self.assertEqual(yaml_lines.count("  - DOMAIN-SUFFIX,example.com"), 1)

    def test_no_clash_yaml(self):
        buckets = {"suffix": ["example.com"], "domain": [], "keyword": [],
                   "regexp": [], "wildcard": [], "process": [],
                   "process_wildcard": [], "process_re": [], "process_path": [],
                   "process_path_wildcard": [], "process_path_re": [],
                   "user_agent": []}
        mrs_tasks, srs_tasks = [], []
        extra_ip, extra_asn = h.emit_geosite_tag(
            "example", buckets, "", self.out_geosite, self.out_qx,
            mrs_tasks, srs_tasks, self.workdir)
        self.assertEqual((extra_ip, extra_asn), ([], []))
        self.assertTrue(os.path.isfile(os.path.join(self.out_geosite, "example.yaml")))


class TestEmitGeoipTag(EmitBase):
    def test_full_outputs_no_resolve(self):
        mrs_tasks, srs_tasks = [], []
        h.emit_geoip_tag("example",
                         ["8.8.8.0/24", "2606:4700::/32", "1.1.1.1/32"],
                         ["AS12345"],
                         self.out_geoip, self.out_qx_ip, mrs_tasks, srs_tasks)
        yaml_lines = h.read_lines(os.path.join(self.out_geoip, "example.yaml"))
        # geoip 侧不加 no-resolve, IPv4 在前 IPv6 在后, ASN 最后
        self.assertEqual(yaml_lines, [
            "payload:",
            "  - IP-CIDR,1.1.1.1/32",
            "  - IP-CIDR,8.8.8.0/24",
            "  - IP-CIDR6,2606:4700::/32",
            "  - IP-ASN,AS12345",
        ])
        list_lines = h.read_lines(os.path.join(self.out_geoip, "example.list"))
        self.assertEqual(list_lines, [
            "IP-CIDR,1.1.1.1/32",
            "IP-CIDR,8.8.8.0/24",
            "IP-CIDR6,2606:4700::/32",
            "IP-ASN,AS12345",
        ])
        qx_lines = h.read_lines(os.path.join(self.out_qx_ip, "example.list"))
        self.assertEqual(qx_lines, [
            "IP-CIDR, 1.1.1.1/32, no-resolve",
            "IP-CIDR, 8.8.8.0/24, no-resolve",
            "IP6-CIDR, 2606:4700::/32, no-resolve",
            "IP-ASN, AS12345",
        ])
        data = read_json(os.path.join(self.out_geoip, "example.json"))
        self.assertEqual(data, {"version": 5, "rules": [
            {"ip_cidr": ["1.1.1.1/32", "8.8.8.0/24", "2606:4700::/32"]}]})
        # mrs 不在这里登记 (等 clash 合并后再登记), srs 登记
        self.assertEqual(mrs_tasks, [])
        self.assertEqual(srs_tasks, [
            f"{os.path.join(self.out_geoip, 'example.json')}\t"
            f"{os.path.join(self.out_geoip, 'example.srs')}"])


class TestReadGeositeFullTyped(EmitBase):
    def test_union_of_list_and_yaml(self):
        # .list 缺 DOMAIN-REGEX, .yaml 缺 USER-AGENT, 必须取并集才全量
        dst_list = os.path.join(self.out_geosite, "example.list")
        dst_yaml = os.path.join(self.out_geosite, "example.yaml")
        h.write_lines(dst_list, ["DOMAIN,example.com", "USER-AGENT,*test*"])
        h.write_lines(dst_yaml, ["payload:", "  - DOMAIN,example.com",
                                 "  - DOMAIN-REGEX,^x.*$"])
        got = h.read_geosite_full_typed(dst_list, dst_yaml)
        self.assertEqual(got, [("DOMAIN", "example.com"),
                               ("USER-AGENT", "*test*"),
                               ("DOMAIN-REGEX", "^x.*$")])


class TestAppendIpToGeosite(EmitBase):
    def test_appends_ip_with_no_resolve_and_caches(self):
        buckets = {"suffix": ["example.com"], "domain": ["www.example.com"],
                   "keyword": [], "regexp": [], "wildcard": [], "process": [],
                   "process_wildcard": [], "process_re": [], "process_path": [],
                   "process_path_wildcard": [], "process_path_re": [],
                   "user_agent": []}
        mrs_tasks, srs_tasks = [], []
        h.emit_geosite_tag("example", buckets, "", self.out_geosite,
                           self.out_qx, mrs_tasks, srs_tasks, self.workdir)
        srs_tasks2 = []
        h._append_ip_to_geosite(
            "example", [("IP-CIDR", "203.0.113.0/24"), ("IP-ASN", "AS12345")],
            self.out_geosite, self.out_qx, srs_tasks2, self.workdir)
        yaml_lines = h.read_lines(os.path.join(self.out_geosite, "example.yaml"))
        self.assertIn("  - IP-CIDR,203.0.113.0/24,no-resolve", yaml_lines)
        self.assertIn("  - IP-ASN,AS12345,no-resolve", yaml_lines)
        qx_lines = h.read_lines(os.path.join(self.out_qx, "example.list"))
        self.assertIn("IP-CIDR, 203.0.113.0/24, no-resolve", qx_lines)
        # IP 条目写入 clash_ip 缓存, 供后续 geoip 阶段合并
        cache = os.path.join(self.workdir, "clash_ip", "example.ipcidr.txt")
        self.assertEqual(h.read_lines(cache), ["203.0.113.0/24"])
        self.assertEqual(len(srs_tasks2), 1)


if __name__ == "__main__":
    unittest.main(verbosity=2)
