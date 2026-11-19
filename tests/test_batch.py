#!/usr/bin/env python3
"""helpers.py 批处理回归测试 (batch_geosite / batch_geoip / batch_clash_ip /
batch_domain_link / batch_ip_link)。

用临时目录 + 一小批真实形状的数据跑通全流程, 不碰仓库真实产物, 不碰网络
(Link 类用 monkeypatch 替换拉取函数)。
直接跑:  python3 tests/test_batch.py
"""
import json
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "scripts"))
import helpers as h  # noqa: E402


class BatchBase(unittest.TestCase):
    def setUp(self):
        self.d = tempfile.TemporaryDirectory()
        self.root = self.d.name
        self.workdir = os.path.join(self.root, "work")
        os.makedirs(self.workdir)
        self.mrs_tasks = os.path.join(self.root, "mrs_tasks.txt")
        self.srs_tasks = os.path.join(self.root, "srs_tasks.txt")
        for p in (self.mrs_tasks, self.srs_tasks):
            open(p, "w").close()

    def tearDown(self):
        self.d.cleanup()

    def _mkdir(self, name):
        p = os.path.join(self.root, name)
        os.makedirs(p, exist_ok=True)
        return p

    def _write(self, path, text):
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding="utf-8") as f:
            f.write(text)


class TestBatchGeosite(BatchBase):
    def test_geo_plus_clash_plus_clash_only(self):
        geosite_txt = self._mkdir("geosite_txt")
        clash_dir = self._mkdir("clash")
        out = self._mkdir("geosite")
        out_qx = self._mkdir("qx")
        self._write(os.path.join(geosite_txt, "geosite_example.txt"),
                    "example.com\nfull:www.example.com\nkeyword:example\n")
        self._write(os.path.join(geosite_txt, "geosite_empty.txt"), "")
        self._write(os.path.join(clash_dir, "example.yaml"),
                    "payload:\n"
                    "  - DOMAIN,extra.example.com\n"
                    "  - IP-CIDR,9.9.9.0/24\n"
                    "  - PROCESS-NAME,com.example.tool\n")
        self._write(os.path.join(clash_dir, "clashonly.yaml"),
                    "payload:\n  - DOMAIN-SUFFIX,only.example.com\n")
        h.cmd_batch_geosite(geosite_txt, clash_dir, out, out_qx,
                            self.mrs_tasks, self.srs_tasks, self.workdir)
        # geo + clash 融合
        yaml_lines = h.read_lines(os.path.join(out, "example.yaml"))
        self.assertIn("  - DOMAIN,www.example.com", yaml_lines)
        self.assertIn("  - DOMAIN,extra.example.com", yaml_lines)
        self.assertIn("  - IP-CIDR,9.9.9.0/24,no-resolve", yaml_lines)
        self.assertIn("  - PROCESS-NAME,com.example.tool", yaml_lines)
        # clash-only tag 也建档
        self.assertTrue(os.path.isfile(os.path.join(out, "clashonly.yaml")))
        self.assertTrue(os.path.isfile(os.path.join(out, "clashonly.json")))
        # 空 tag 不出文件
        self.assertFalse(os.path.exists(os.path.join(out, "empty.yaml")))
        # 任务清单登记了 mrs/srs
        self.assertTrue(any("example.mrs" in l for l in h.read_lines(self.mrs_tasks)))
        self.assertTrue(any("example.srs" in l for l in h.read_lines(self.srs_tasks)))
        # clash 带来的 IP 进了 clash_ip 缓存, 供 geoip 阶段用
        cache = os.path.join(self.workdir, "clash_ip", "example.ipcidr.txt")
        self.assertEqual(h.read_lines(cache), ["9.9.9.0/24"])


class TestBatchGeoip(BatchBase):
    def test_geoip_filters_bogon_and_registers_mrs(self):
        geoip_txt = self._mkdir("geoip_txt")
        clash_dir = self._mkdir("clash")
        clash_ip = self._mkdir("clash_ip")
        out = self._mkdir("geoip")
        out_qx = self._mkdir("qx")
        self._write(os.path.join(geoip_txt, "geoip_example.txt"),
                    "8.8.8.0/24\n1.1.1.1/32\n225.1.1.9/32\n10.0.0.0/8\n"
                    "2606:4700::/32\n")
        # geosite 阶段缓存的同名 IP (clash yaml 溢出) 要并进 mrs
        self._write(os.path.join(clash_ip, "example.ipcidr.txt"),
                    "9.9.9.0/24\n")
        h.cmd_batch_geoip(geoip_txt, clash_dir, clash_ip, out, out_qx,
                          self.mrs_tasks, self.srs_tasks, self.workdir)
        yaml_lines = h.read_lines(os.path.join(out, "example.yaml"))
        # 组播/私有已剔, IPv4 在前 IPv6 在后
        self.assertEqual(yaml_lines, [
            "payload:",
            "  - IP-CIDR,1.1.1.1/32",
            "  - IP-CIDR,8.8.8.0/24",
            "  - IP-CIDR6,2606:4700::/32",
        ])
        # mrs 源 = geo 数据 + 缓存溢出, 规范化后按 yaml 同规则排序
        mrs_src = os.path.join(self.workdir, "geoip_mrs", "example.txt")
        self.assertEqual(h.read_lines(mrs_src), [
            "1.1.1.1/32", "8.8.8.0/24", "9.9.9.0/24", "2606:4700::/32"])
        self.assertTrue(any("example.mrs" in l for l in h.read_lines(self.mrs_tasks)))
        self.assertTrue(any("example.srs" in l for l in h.read_lines(self.srs_tasks)))

    def test_geosite_ip_spill_mrs_only(self):
        geoip_txt = self._mkdir("geoip_txt")
        clash_dir = self._mkdir("clash")
        clash_ip = self._mkdir("clash_ip")
        out = self._mkdir("geoip")
        out_qx = self._mkdir("qx")
        # 没有 geoip txt, 只有 geosite 侧溢出的同名 IP: 只补 .mrs, 不出五格式
        self._write(os.path.join(clash_dir, "spill.yaml"),
                    "payload:\n  - IP-CIDR,9.9.9.0/24\n")
        h.cmd_batch_geoip(geoip_txt, clash_dir, clash_ip, out, out_qx,
                          self.mrs_tasks, self.srs_tasks, self.workdir)
        self.assertFalse(os.path.exists(os.path.join(out, "spill.yaml")))
        self.assertFalse(os.path.exists(os.path.join(out, "spill.json")))
        self.assertTrue(any("spill.mrs" in l for l in h.read_lines(self.mrs_tasks)))
        mrs_src = os.path.join(self.workdir, "geoip_mrs", "spill.txt")
        self.assertEqual(h.read_lines(mrs_src), ["9.9.9.0/24"])

    def test_private_tag_kept(self):
        geoip_txt = self._mkdir("geoip_txt")
        out = self._mkdir("geoip")
        out_qx = self._mkdir("qx")
        self._write(os.path.join(geoip_txt, "geoip_private.txt"),
                    "10.0.0.0/8\n192.168.0.0/16\n")
        h.cmd_batch_geoip(geoip_txt, self._mkdir("clash"),
                          self._mkdir("clash_ip"), out, out_qx,
                          self.mrs_tasks, self.srs_tasks, self.workdir)
        self.assertEqual(h.read_lines(os.path.join(out, "private.yaml")), [
            "payload:", "  - IP-CIDR,192.168.0.0/16", "  - IP-CIDR,10.0.0.0/8"])


class TestBatchClashIp(BatchBase):
    def test_merge_into_existing_geoip(self):
        clash_ip_dir = self._mkdir("clash-ip")
        out = self._mkdir("geoip")
        out_qx = self._mkdir("qx")
        self._write(os.path.join(clash_ip_dir, "example.yaml"),
                    "payload:\n"
                    "  - IP-CIDR,9.9.9.0/24\n"
                    "  - IP-CIDR6,2606:4700::/32\n"
                    "  - IP-ASN,AS12345\n"
                    "  - IP-CIDR,10.0.0.0/8\n")  # 私有, 应剔除
        # 已有 geoip 数据 (来自 Loyalsoldier 阶段)
        self._write(os.path.join(out, "example.list"), "IP-CIDR,8.8.8.0/24\n")
        self._write(os.path.join(out, "example.yaml"),
                    "payload:\n  - IP-CIDR,8.8.8.0/24\n")
        h.cmd_batch_clash_ip(clash_ip_dir, out, out_qx,
                             self.mrs_tasks, self.srs_tasks, self.workdir)
        yaml_lines = h.read_lines(os.path.join(out, "example.yaml"))
        self.assertEqual(yaml_lines, [
            "payload:",
            "  - IP-CIDR,8.8.8.0/24",
            "  - IP-CIDR,9.9.9.0/24",
            "  - IP-CIDR6,2606:4700::/32",
            "  - IP-ASN,AS12345",
        ])
        data = json.load(open(os.path.join(out, "example.json"), encoding="utf-8"))
        self.assertEqual(data["rules"][0]["ip_cidr"],
                         ["8.8.8.0/24", "9.9.9.0/24", "2606:4700::/32"])
        qx_lines = h.read_lines(os.path.join(out_qx, "example.list"))
        self.assertIn("IP-CIDR, 9.9.9.0/24, no-resolve", qx_lines)
        self.assertTrue(any("example.mrs" in l for l in h.read_lines(self.mrs_tasks)))

    def test_missing_dir_is_noop(self):
        out = self._mkdir("geoip")
        out_qx = self._mkdir("qx")
        h.cmd_batch_clash_ip(os.path.join(self.root, "no-such-dir"), out, out_qx,
                             self.mrs_tasks, self.srs_tasks, self.workdir)
        self.assertEqual(h.read_lines(self.mrs_tasks), [])


class TestBatchLinks(BatchBase):
    """Link 类入口: monkeypatch 掉网络拉取, 只测「拉取结果 -> 输出文件」的逻辑。"""

    def setUp(self):
        super().setUp()
        self._orig_fetch = h.fetch_link_items

    def tearDown(self):
        h.fetch_link_items = self._orig_fetch
        super().tearDown()

    def test_domain_link_new_tag(self):
        out = self._mkdir("geosite")
        out_qx = self._mkdir("qx")
        link_json = os.path.join(self.root, "DOMAIN-Link.json")
        self._write(link_json, json.dumps(
            [{"name": "example", "url": "https://example.com/rules.txt",
              "format": "clash"}]))
        h.fetch_link_items = lambda items, label, max_workers=8: [
            ("example", "clash",
             "payload:\n  - DOMAIN,example.com\n  - DOMAIN-SUFFIX,.example.net\n"
             "  - IP-CIDR,9.9.9.0/24\n")]
        h.cmd_batch_domain_link(link_json, out, out_qx,
                                self.mrs_tasks, self.srs_tasks, self.workdir)
        yaml_lines = h.read_lines(os.path.join(out, "example.yaml"))
        self.assertIn("  - DOMAIN,example.com", yaml_lines)
        self.assertIn("  - DOMAIN-SUFFIX,example.net", yaml_lines)
        self.assertIn("  - IP-CIDR,9.9.9.0/24,no-resolve", yaml_lines)
        self.assertTrue(os.path.isfile(os.path.join(out, "example.json")))

    def test_domain_link_appends_to_existing(self):
        out = self._mkdir("geosite")
        out_qx = self._mkdir("qx")
        self._write(os.path.join(out, "example.list"), "DOMAIN,old.example.com\n")
        self._write(os.path.join(out, "example.yaml"),
                    "payload:\n  - DOMAIN,old.example.com\n")
        link_json = os.path.join(self.root, "DOMAIN-Link.json")
        self._write(link_json, json.dumps(
            [{"name": "example", "url": "https://example.com/rules.txt",
              "format": "domain-text"}]))
        h.fetch_link_items = lambda items, label, max_workers=8: [
            ("example", "domain-text", "old.example.com\nnew.example.com\n")]
        h.cmd_batch_domain_link(link_json, out, out_qx,
                                self.mrs_tasks, self.srs_tasks, self.workdir)
        yaml_lines = h.read_lines(os.path.join(out, "example.yaml"))
        self.assertEqual(yaml_lines.count("  - DOMAIN,old.example.com"), 1)
        self.assertIn("  - DOMAIN,new.example.com", yaml_lines)

    def test_ip_link_new_tag(self):
        out = self._mkdir("geoip")
        out_qx = self._mkdir("qx")
        link_json = os.path.join(self.root, "IP-Link.json")
        self._write(link_json, json.dumps(
            [{"name": "example", "url": "https://example.com/ips.txt",
              "format": "ip-text"}]))
        h.fetch_link_items = lambda items, label, max_workers=8: [
            ("example", "ip-text", "1.2.3.0/24\n2606:4700::/32\n")]
        h.cmd_batch_ip_link(link_json, out, out_qx,
                            self.mrs_tasks, self.srs_tasks, self.workdir)
        yaml_lines = h.read_lines(os.path.join(out, "example.yaml"))
        self.assertEqual(yaml_lines, [
            "payload:",
            "  - IP-CIDR,1.2.3.0/24",
            "  - IP-CIDR6,2606:4700::/32",
        ])
        self.assertTrue(any("example.mrs" in l for l in h.read_lines(self.mrs_tasks)))

    def test_missing_link_file_is_noop(self):
        out = self._mkdir("geosite")
        out_qx = self._mkdir("qx")
        h.cmd_batch_domain_link(os.path.join(self.root, "nope.json"), out, out_qx,
                                self.mrs_tasks, self.srs_tasks, self.workdir)
        self.assertEqual(h.read_lines(self.mrs_tasks), [])


if __name__ == "__main__":
    unittest.main(verbosity=2)
