#!/usr/bin/env python3
"""helpers.py 编译缓存回归测试。

覆盖: cmd_compile_plan / cmd_compile_save (命中与失效: 输入变了、产物变了、
工具版本变了、清单缺失、产物缺失/为空不进清单、已删 tag 的旧产物被清掉)、
_read_tasks / _load_manifest。
注意: 任务里用的函数名是 cmd_compile_plan / cmd_compile_save
(compile_plan / compile_save 是 CLI 命令名, 见 helpers.py 末尾 COMMANDS)。
直接跑:  python3 tests/test_compile_cache.py
"""
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "scripts"))
import helpers as h  # noqa: E402

TOOL_KEY = "mihomo=test-1 singbox=test-1"


class CacheBase(unittest.TestCase):
    def setUp(self):
        self.d = tempfile.TemporaryDirectory()
        self.root = self.d.name
        # 两个目标: mrs (domain 行: behavior\tsrc\tdst) 与 srs (src\tdst)
        self.src_mrs = os.path.join(self.root, "a.txt")
        self.dst_mrs = os.path.join(self.root, "a.mrs")
        self.src_srs = os.path.join(self.root, "a.json")
        self.dst_srs = os.path.join(self.root, "a.srs")
        for p, content in ((self.src_mrs, "example.com\n"),
                           (self.dst_mrs, "FAKE-MRS"),
                           (self.src_srs, '{"version":5,"rules":[]}\n'),
                           (self.dst_srs, "FAKE-SRS")):
            with open(p, "w", encoding="utf-8") as f:
                f.write(content)
        self.mrs_tasks = os.path.join(self.root, "mrs_tasks.txt")
        self.srs_tasks = os.path.join(self.root, "srs_tasks.txt")
        h.write_lines(self.mrs_tasks, [f"domain\t{self.src_mrs}\t{self.dst_mrs}"])
        h.write_lines(self.srs_tasks, [f"{self.src_srs}\t{self.dst_srs}"])
        self.manifest = os.path.join(self.root, "manifest.tsv")
        self.mrs_build = os.path.join(self.root, "mrs_build.txt")
        self.srs_build = os.path.join(self.root, "srs_build.txt")

    def tearDown(self):
        self.d.cleanup()

    def save(self):
        h.cmd_compile_save(self.mrs_tasks, self.srs_tasks, TOOL_KEY, self.manifest)

    def plan(self, manifest=None, tool_key=TOOL_KEY):
        h.cmd_compile_plan(self.mrs_tasks, self.srs_tasks,
                           manifest if manifest is not None else self.manifest,
                           tool_key, self.mrs_build, self.srs_build, [self.root])
        return h.read_lines(self.mrs_build), h.read_lines(self.srs_build)


class TestCompileSave(CacheBase):
    def test_manifest_format(self):
        self.save()
        lines = h.read_lines(self.manifest)
        self.assertEqual(lines[0], f"#key\t{TOOL_KEY}")
        # 按 dst 排序, 每行: dst \t src 哈希 \t 产物哈希
        self.assertEqual(len(lines), 3)
        for line in lines[1:]:
            parts = line.split("\t")
            self.assertEqual(len(parts), 3)
            self.assertTrue(parts[0].endswith((".mrs", ".srs")))
            self.assertEqual(parts[1], h._sha16(
                self.src_mrs if parts[0] == self.dst_mrs else self.src_srs))
            self.assertEqual(parts[2], h._sha16(parts[0]))

    def test_missing_or_empty_dst_not_recorded(self):
        os.remove(self.dst_srs)
        with open(self.dst_mrs, "w") as f:
            f.write("")  # 空产物不进清单, 下次必然重编
        self.save()
        lines = h.read_lines(self.manifest)
        self.assertEqual(lines, [f"#key\t{TOOL_KEY}"])


class TestCompilePlan(CacheBase):
    def test_all_reused_when_nothing_changed(self):
        self.save()
        mrs_build, srs_build = self.plan()
        self.assertEqual(mrs_build, [])
        self.assertEqual(srs_build, [])

    def test_src_changed_rebuilds_only_that_target(self):
        self.save()
        with open(self.src_mrs, "a", encoding="utf-8") as f:
            f.write("other.example.com\n")
        mrs_build, srs_build = self.plan()
        self.assertEqual(len(mrs_build), 1)
        self.assertIn(self.dst_mrs, mrs_build[0])
        self.assertEqual(srs_build, [])

    def test_dst_changed_rebuilds(self):
        # 产物被手改/回滚过: src 哈希对得上, out 哈希对不上 -> 重编, 不沿用错版
        self.save()
        with open(self.dst_srs, "w", encoding="utf-8") as f:
            f.write("TAMPERED")
        mrs_build, srs_build = self.plan()
        self.assertEqual(mrs_build, [])
        self.assertEqual(len(srs_build), 1)

    def test_dst_deleted_rebuilds(self):
        self.save()
        os.remove(self.dst_mrs)
        mrs_build, srs_build = self.plan()
        self.assertEqual(len(mrs_build), 1)

    def test_tool_key_changed_rebuilds_all(self):
        # 工具版本进 key: mihomo / sing-box 一升级就整批重编
        self.save()
        mrs_build, srs_build = self.plan(tool_key="mihomo=test-2 singbox=test-1")
        self.assertEqual(len(mrs_build), 1)
        self.assertEqual(len(srs_build), 1)

    def test_missing_manifest_rebuilds_all(self):
        mrs_build, srs_build = self.plan(
            manifest=os.path.join(self.root, "no-such-manifest.tsv"))
        self.assertEqual(len(mrs_build), 1)
        self.assertEqual(len(srs_build), 1)

    def test_prunes_stale_products(self):
        self.save()
        stale_mrs = os.path.join(self.root, "deleted-tag.mrs")
        stale_srs = os.path.join(self.root, "deleted-tag.srs")
        for p in (stale_mrs, stale_srs):
            with open(p, "w") as f:
                f.write("STALE")
        self.plan()
        # 上游已删 tag 的残留产物被清掉, 本次目标保留
        self.assertFalse(os.path.exists(stale_mrs))
        self.assertFalse(os.path.exists(stale_srs))
        self.assertTrue(os.path.exists(self.dst_mrs))
        self.assertTrue(os.path.exists(self.dst_srs))


class TestReadTasksAndManifest(unittest.TestCase):
    def test_read_tasks(self):
        with tempfile.NamedTemporaryFile("w", delete=False) as f:
            f.write("domain\t/src/a.txt\t/dst/a.mrs\n")
            f.write("/src/b.json\t/dst/b.srs\n")
            f.write("malformed-line\n")
            path = f.name
        try:
            got = h._read_tasks(path)
            self.assertEqual(got, [
                ("domain\t/src/a.txt\t/dst/a.mrs", "/src/a.txt", "/dst/a.mrs"),
                ("/src/b.json\t/dst/b.srs", "/src/b.json", "/dst/b.srs"),
            ])
        finally:
            os.unlink(path)

    def test_load_manifest_wrong_key_is_empty(self):
        with tempfile.NamedTemporaryFile("w", delete=False) as f:
            f.write("#key\tmihomo=old singbox=old\n/dst/a.mrs\tabc\tdef\n")
            path = f.name
        try:
            self.assertEqual(h._load_manifest(path, TOOL_KEY), {})
        finally:
            os.unlink(path)

    def test_load_manifest_missing_is_empty(self):
        self.assertEqual(h._load_manifest("/nonexistent/manifest.tsv", TOOL_KEY), {})


if __name__ == "__main__":
    unittest.main(verbosity=2)
