#!/usr/bin/env python3
"""helpers.py 兼容旧命令与 CLI 入口回归测试。

覆盖: cmd_parse_clash / cmd_merge_dedup / cmd_diff_new_entries /
cmd_rebuild_json_from_list, 以及 `python3 scripts/helpers.py` 的 CLI 入口
(无参数、未知命令、parse_clash 子命令)。
直接跑:  python3 tests/test_legacy_cli.py
"""
import json
import os
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "scripts"))
import helpers as h  # noqa: E402

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
HELPERS = os.path.join(REPO_ROOT, "scripts", "helpers.py")


class TestLegacyCommands(unittest.TestCase):
    def setUp(self):
        self.d = tempfile.TemporaryDirectory()
        self.root = self.d.name

    def tearDown(self):
        self.d.cleanup()

    def _write(self, name, text):
        p = os.path.join(self.root, name)
        with open(p, "w", encoding="utf-8") as f:
            f.write(text)
        return p

    def test_parse_clash_writes_per_bucket_files(self):
        yaml = self._write("example.yaml",
                           "payload:\n"
                           "  - DOMAIN-SUFFIX,example.com\n"
                           "  - IP-CIDR,1.2.3.0/24\n")
        out_dir = os.path.join(self.root, "out")
        h.cmd_parse_clash(yaml, out_dir, "example")
        self.assertEqual(h.read_lines(os.path.join(out_dir, "example.suffix.clash.txt")),
                         ["example.com"])
        self.assertEqual(h.read_lines(os.path.join(out_dir, "example.ipcidr.clash.txt")),
                         ["1.2.3.0/24"])

    def test_merge_dedup(self):
        geo = self._write("geo.txt", "example.com\na.example.com\n")
        clash = self._write("clash.txt", ".example.com\nb.example.com\n")
        out = os.path.join(self.root, "out.txt")
        h.cmd_merge_dedup(geo, clash, out, "suffix")
        self.assertEqual(h.read_lines(out),
                         ["example.com", "a.example.com", "b.example.com"])
        # ipcidr 按小写去重
        geo2 = self._write("geo2.txt", "2606:4700::/32\n")
        clash2 = self._write("clash2.txt", "2606:4700::/32\n")
        out2 = os.path.join(self.root, "out2.txt")
        h.cmd_merge_dedup(geo2, clash2, out2, "ipcidr")
        self.assertEqual(h.read_lines(out2), ["2606:4700::/32"])

    def test_diff_new_entries(self):
        exist = self._write("exist.txt", "1.2.3.0/24\n5.6.7.0/24\n")
        new = self._write("new.txt", "1.2.3.0/24\n9.9.9.0/24\n9.9.9.0/24\n")
        out = os.path.join(self.root, "diff.txt")
        h.cmd_diff_new_entries(exist, new, out, "cidr")
        self.assertEqual(h.read_lines(out), ["9.9.9.0/24"])
        # 非 cidr 按原值 (大小写敏感) 对比
        exist2 = self._write("exist2.txt", "example.com\n")
        new2 = self._write("new2.txt", "Example.COM\nexample.com\n")
        out2 = os.path.join(self.root, "diff2.txt")
        h.cmd_diff_new_entries(exist2, new2, out2, "domain")
        self.assertEqual(h.read_lines(out2), ["Example.COM"])

    def test_rebuild_json_from_list(self):
        lst = self._write("t.list", "IP-CIDR,1.2.3.0/24\nIP-CIDR6,2606:4700::/32\n"
                                    "DOMAIN,example.com\n")
        dst = os.path.join(self.root, "t.json")
        h.cmd_rebuild_json_from_list(lst, dst)
        with open(dst, encoding="utf-8") as f:
            data = json.load(f)
        self.assertEqual(data, {"version": 5, "rules": [
            {"ip_cidr": ["1.2.3.0/24", "2606:4700::/32"]}]})


class TestCliEntry(unittest.TestCase):
    def test_no_args_exits_nonzero(self):
        r = subprocess.run([sys.executable, HELPERS],
                           capture_output=True, text=True)
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("Usage", r.stderr)

    def test_unknown_command_exits_nonzero(self):
        r = subprocess.run([sys.executable, HELPERS, "no-such-command"],
                           capture_output=True, text=True)
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("Unknown command", r.stderr)

    def test_parse_clash_subcommand(self):
        with tempfile.TemporaryDirectory() as d:
            yaml = os.path.join(d, "example.yaml")
            with open(yaml, "w", encoding="utf-8") as f:
                f.write("payload:\n  - DOMAIN,example.com\n")
            out_dir = os.path.join(d, "out")
            r = subprocess.run([sys.executable, HELPERS, "parse_clash",
                                yaml, out_dir, "example"],
                               capture_output=True, text=True)
            self.assertEqual(r.returncode, 0, r.stderr)
            self.assertEqual(
                h.read_lines(os.path.join(out_dir, "example.domain.clash.txt")),
                ["example.com"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
