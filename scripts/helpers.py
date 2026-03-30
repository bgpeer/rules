#!/usr/bin/env python3
"""
helpers.py — sync_loy_geo_mrs.sh 的统一 Python 工具模块
所有格式转换、clash 解析、去重融合逻辑集中在此。

用法:
  python3 helpers.py <command> [args...]

命令:
  parse_clash       <yaml> <out_dir> <tag>
  merge_dedup       <geo_file> <clash_file> <out_file> <bucket_type>
  make_yaml_domain  <f_suffix> <f_domain> <f_keyword> <f_regexp> <f_process> <f_process_re> <clash_yaml|""> <dst>
  make_yaml_ipcidr  <f_ipcidr> <f_asn> <clash_yaml|""> <dst>
  make_list_domain  <f_suffix> <f_domain> <f_keyword> <f_regexp> <f_process> <f_process_re> <clash_yaml|""> <dst>
  make_list_ipcidr  <f_ipcidr> <f_asn> <clash_yaml|""> <dst>
  make_qx_domain    <f_suffix> <f_domain> <f_keyword> <f_ipcidr> <clash_yaml|""> <dst>
  make_qx_ipcidr    <f_ipcidr> <clash_yaml|""> <dst>
  make_json_domain  <f_suffix> <f_domain> <f_keyword> <f_regexp> <f_ipcidr> <clash_yaml|""> <dst>
  make_json_ipcidr  <f_ipcidr> <clash_yaml|""> <dst>
  diff_new_entries  <exist_file> <new_file> <out_file> <type>    # type: cidr | asn
  rebuild_json_from_list  <list_file> <json_dst>
"""

import sys
import os
import re
import json

# ═══════════════════════════════════════════════════════════════════════════════
# 通用工具
# ═══════════════════════════════════════════════════════════════════════════════

def read_lines(path):
    """读取文件非空行，文件不存在返回空列表"""
    if not path or path == "":
        return []
    try:
        with open(path, encoding="utf-8") as f:
            return [l.rstrip("\n") for l in f if l.strip()]
    except FileNotFoundError:
        return []


def norm_value(rule_type, value):
    """归一化规则值用于去重比较"""
    if rule_type == "DOMAIN-SUFFIX":
        return value.lstrip(".")
    if rule_type in ("IP-CIDR", "IP-CIDR6"):
        return value.lower()
    return value


RE_ITEM = re.compile(r"^\s*-\s+(.+)$")

def parse_clash_entries(yaml_path):
    """
    解析 clash yaml 文件，返回 (rule_type, value) 列表。
    去掉行尾注释，跳过无效行。
    """
    if not yaml_path or yaml_path == "":
        return []
    entries = []
    try:
        with open(yaml_path, encoding="utf-8") as f:
            for raw in f:
                m = RE_ITEM.match(raw.rstrip())
                if not m:
                    continue
                entry = re.sub(r"\s+#.*$", "", m.group(1).strip())
                if not entry or "," not in entry:
                    continue
                parts = [p.strip() for p in entry.split(",")]
                if len(parts) < 2:
                    continue
                entries.append((parts[0].upper(), parts[1]))
    except FileNotFoundError:
        pass
    return entries


# ═══════════════════════════════════════════════════════════════════════════════
# clash 融合：读取 clash yaml 中的额外条目，与 geo 数据宽松去重
# ═══════════════════════════════════════════════════════════════════════════════

def _clash_extras_domain(clash_yaml, geo_seen):
    """
    从 clash yaml 提取域名类+IP类+进程类条目，
    与 geo_seen 去重后返回额外行列表 ["TYPE,value", ...]
    """
    extras = []
    clash_seen = {}
    for t, v in parse_clash_entries(clash_yaml):
        nv = norm_value(t, v)
        if nv in geo_seen.get(t, set()):
            continue
        if nv in clash_seen.get(t, set()):
            continue
        clash_seen.setdefault(t, set()).add(nv)
        extras.append(f"{t},{v}")
    return extras


def _build_geo_seen(lines_with_type):
    """从 [(type, value), ...] 构建 {type: set(norm_value)} 字典"""
    seen = {}
    for t, v in lines_with_type:
        seen.setdefault(t, set()).add(norm_value(t, v))
    return seen


# ═══════════════════════════════════════════════════════════════════════════════
# 格式过滤规则
# ═══════════════════════════════════════════════════════════════════════════════

# mrs 仅接受的规则类型
MRS_DOMAIN_TYPES = {"DOMAIN-SUFFIX", "DOMAIN"}
MRS_IP_TYPES     = {"IP-CIDR", "IP-CIDR6"}

# json/srs 跳过的规则类型
JSON_SKIP_TYPES = {"PROCESS-NAME", "PROCESS-NAME-REGEX", "IP-ASN"}

# QX 跳过的规则类型
QX_SKIP_TYPES = {"DOMAIN-REGEX", "PROCESS-NAME", "PROCESS-NAME-REGEX", "IP-ASN"}

# QX 规则类型映射
QX_TYPE_MAP = {
    "DOMAIN-SUFFIX":  "HOST-SUFFIX",
    "DOMAIN":         "HOST",
    "DOMAIN-KEYWORD": "HOST-KEYWORD",
    "IP-CIDR":        "IP-CIDR",
    "IP-CIDR6":       "IP-CIDR6",
}


# ═══════════════════════════════════════════════════════════════════════════════
# 命令实现
# ═══════════════════════════════════════════════════════════════════════════════

def cmd_parse_clash(yaml_path, out_dir, tag):
    """解析 clash yaml，按规则类型分桶写入 out_dir/tag.{bucket}.clash.txt"""
    buckets = {
        "suffix": [], "domain": [], "keyword": [], "regexp": [],
        "ipcidr": [], "process": [], "process_re": [], "asn": [],
    }
    TYPE_TO_BUCKET = {
        "DOMAIN-SUFFIX":       "suffix",
        "DOMAIN":              "domain",
        "DOMAIN-KEYWORD":      "keyword",
        "DOMAIN-REGEX":        "regexp",
        "IP-CIDR":             "ipcidr",
        "IP-CIDR6":            "ipcidr",
        "PROCESS-NAME":        "process",
        "PROCESS-NAME-REGEX":  "process_re",
        "IP-ASN":              "asn",
    }
    for t, v in parse_clash_entries(yaml_path):
        bucket = TYPE_TO_BUCKET.get(t)
        if bucket is None:
            continue
        if bucket == "suffix":
            v = v.lstrip(".")
        buckets[bucket].append(v)

    os.makedirs(out_dir, exist_ok=True)
    for bname, items in buckets.items():
        out_path = os.path.join(out_dir, f"{tag}.{bname}.clash.txt")
        with open(out_path, "w", encoding="utf-8") as f:
            for item in items:
                f.write(item + "\n")


def cmd_merge_dedup(geo_file, clash_file, out_file, bucket_type):
    """合并 geo + clash 文件，宽松去重"""
    geo_lines   = read_lines(geo_file)
    clash_lines = read_lines(clash_file)
    seen  = set()
    order = []
    for val in geo_lines + clash_lines:
        key = norm_value(
            "DOMAIN-SUFFIX" if bucket_type == "suffix" else
            "IP-CIDR"       if bucket_type == "ipcidr" else
            val, val
        )
        # 简化：suffix -> lstrip('.'), ipcidr -> lower(), 其他原样
        if bucket_type == "suffix":
            key = val.lstrip(".")
        elif bucket_type == "ipcidr":
            key = val.lower()
        else:
            key = val
        if key not in seen:
            seen.add(key)
            order.append(val)
    with open(out_file, "w", encoding="utf-8") as f:
        for item in order:
            f.write(item + "\n")


# ── geosite 读取辅助 ─────────────────────────────────────────────────────────

def _read_geosite_buckets(f_suffix, f_domain, f_keyword, f_regexp,
                          f_process, f_process_re):
    """读取 geo 分桶文件，返回 (geo_lines, geo_seen)"""
    geo_lines = []
    geo_typed = []  # (type, value) for seen

    for line in read_lines(f_suffix):
        v = line.lstrip(".")
        geo_lines.append(("DOMAIN-SUFFIX", v))
        geo_typed.append(("DOMAIN-SUFFIX", v))
    for line in read_lines(f_domain):
        geo_lines.append(("DOMAIN", line))
        geo_typed.append(("DOMAIN", line))
    for line in read_lines(f_keyword):
        geo_lines.append(("DOMAIN-KEYWORD", line))
        geo_typed.append(("DOMAIN-KEYWORD", line))
    for line in read_lines(f_regexp):
        geo_lines.append(("DOMAIN-REGEX", line))
        geo_typed.append(("DOMAIN-REGEX", line))
    for line in read_lines(f_process):
        geo_lines.append(("PROCESS-NAME", line))
        geo_typed.append(("PROCESS-NAME", line))
    for line in read_lines(f_process_re):
        geo_lines.append(("PROCESS-NAME-REGEX", line))
        geo_typed.append(("PROCESS-NAME-REGEX", line))

    geo_seen = _build_geo_seen(geo_typed)
    return geo_lines, geo_seen


def _read_geoip_buckets(f_ipcidr, f_asn):
    """读取 geoip 分桶文件，返回 (geo_lines, geo_seen_cidr, geo_seen_asn)"""
    geo_lines = []
    geo_seen_cidr = set()
    geo_seen_asn  = set()
    for line in read_lines(f_ipcidr):
        t = "IP-CIDR6" if ":" in line else "IP-CIDR"
        geo_lines.append((t, line))
        geo_seen_cidr.add(line.lower())
    for line in read_lines(f_asn):
        geo_lines.append(("IP-ASN", line))
        geo_seen_asn.add(line)
    return geo_lines, geo_seen_cidr, geo_seen_asn


def _clash_ip_extras(clash_yaml, geo_seen_cidr, geo_seen_asn):
    """从 clash yaml 提取 IP/ASN 条目，去重后返回 [(type, value), ...]"""
    extras = []
    clash_seen_cidr = set()
    clash_seen_asn  = set()
    for t, v in parse_clash_entries(clash_yaml):
        if t in ("IP-CIDR", "IP-CIDR6"):
            nv = v.lower()
            if nv in geo_seen_cidr or nv in clash_seen_cidr:
                continue
            clash_seen_cidr.add(nv)
            extras.append((t, v))
        elif t == "IP-ASN":
            if v in geo_seen_asn or v in clash_seen_asn:
                continue
            clash_seen_asn.add(v)
            extras.append(("IP-ASN", v))
    return extras


# ── yaml 输出 ────────────────────────────────────────────────────────────────

def cmd_make_yaml_domain(f_suffix, f_domain, f_keyword, f_regexp,
                         f_process, f_process_re, clash_yaml, dst):
    geo_lines, geo_seen = _read_geosite_buckets(
        f_suffix, f_domain, f_keyword, f_regexp, f_process, f_process_re)
    clash_extras = _clash_extras_domain(clash_yaml, geo_seen)

    with open(dst, "w", encoding="utf-8") as f:
        f.write("payload:\n")
        for t, v in geo_lines:
            f.write(f"  - {t},{v}\n")
        for line in clash_extras:
            f.write(f"  - {line}\n")


def cmd_make_yaml_ipcidr(f_ipcidr, f_asn, clash_yaml, dst):
    geo_lines, geo_seen_cidr, geo_seen_asn = _read_geoip_buckets(f_ipcidr, f_asn)
    extras = _clash_ip_extras(clash_yaml, geo_seen_cidr, geo_seen_asn)

    with open(dst, "w", encoding="utf-8") as f:
        f.write("payload:\n")
        for t, v in geo_lines + extras:
            f.write(f"  - {t},{v}\n")


# ── list 输出 ────────────────────────────────────────────────────────────────

def cmd_make_list_domain(f_suffix, f_domain, f_keyword, f_regexp,
                         f_process, f_process_re, clash_yaml, dst):
    geo_lines, geo_seen = _read_geosite_buckets(
        f_suffix, f_domain, f_keyword, f_regexp, f_process, f_process_re)
    clash_extras = _clash_extras_domain(clash_yaml, geo_seen)

    with open(dst, "w", encoding="utf-8") as f:
        for t, v in geo_lines:
            f.write(f"{t},{v}\n")
        for line in clash_extras:
            f.write(f"{line}\n")


def cmd_make_list_ipcidr(f_ipcidr, f_asn, clash_yaml, dst):
    geo_lines, geo_seen_cidr, geo_seen_asn = _read_geoip_buckets(f_ipcidr, f_asn)
    extras = _clash_ip_extras(clash_yaml, geo_seen_cidr, geo_seen_asn)

    with open(dst, "w", encoding="utf-8") as f:
        for t, v in geo_lines + extras:
            f.write(f"{t},{v}\n")


# ── QX list 输出 ─────────────────────────────────────────────────────────────

def cmd_make_qx_domain(f_suffix, f_domain, f_keyword, f_ipcidr, clash_yaml, dst):
    """QX geosite list: HOST-SUFFIX / HOST / HOST-KEYWORD / IP-CIDR，跳过 DOMAIN-REGEX 等"""
    lines = []
    for line in read_lines(f_suffix):
        lines.append(f"HOST-SUFFIX, {line.lstrip('.')}")
    for line in read_lines(f_domain):
        lines.append(f"HOST, {line}")
    for line in read_lines(f_keyword):
        lines.append(f"HOST-KEYWORD, {line}")
    for line in read_lines(f_ipcidr):
        t = "IP-CIDR6" if ":" in line else "IP-CIDR"
        lines.append(f"{t}, {line}")

    # clash extras for QX（跳过 QX_SKIP_TYPES）
    if clash_yaml:
        geo_seen = {}
        for line in read_lines(f_suffix):
            geo_seen.setdefault("DOMAIN-SUFFIX", set()).add(line.lstrip("."))
        for line in read_lines(f_domain):
            geo_seen.setdefault("DOMAIN", set()).add(line)
        for line in read_lines(f_keyword):
            geo_seen.setdefault("DOMAIN-KEYWORD", set()).add(line)
        for line in read_lines(f_ipcidr):
            nv = line.lower()
            t = "IP-CIDR6" if ":" in line else "IP-CIDR"
            geo_seen.setdefault(t, set()).add(nv)

        clash_seen = {}
        for t, v in parse_clash_entries(clash_yaml):
            if t in QX_SKIP_TYPES:
                continue
            qx_t = QX_TYPE_MAP.get(t)
            if qx_t is None:
                continue
            nv = norm_value(t, v)
            if nv in geo_seen.get(t, set()):
                continue
            if nv in clash_seen.get(t, set()):
                continue
            clash_seen.setdefault(t, set()).add(nv)
            lines.append(f"{qx_t}, {v}")

    with open(dst, "w", encoding="utf-8") as f:
        for line in lines:
            f.write(line + "\n")


def cmd_make_qx_ipcidr(f_ipcidr, clash_yaml, dst):
    """QX geoip list: IP-CIDR / IP-CIDR6"""
    lines = []
    geo_seen = set()
    for line in read_lines(f_ipcidr):
        t = "IP-CIDR6" if ":" in line else "IP-CIDR"
        lines.append(f"{t}, {line}")
        geo_seen.add(line.lower())

    clash_seen = set()
    for t, v in parse_clash_entries(clash_yaml):
        if t not in ("IP-CIDR", "IP-CIDR6"):
            continue
        nv = v.lower()
        if nv in geo_seen or nv in clash_seen:
            continue
        clash_seen.add(nv)
        qt = "IP-CIDR6" if ":" in v else "IP-CIDR"
        lines.append(f"{qt}, {v}")

    with open(dst, "w", encoding="utf-8") as f:
        for line in lines:
            f.write(line + "\n")


# ── sing-box json 输出（version 3）───────────────────────────────────────────

def cmd_make_json_domain(f_suffix, f_domain, f_keyword, f_regexp, f_ipcidr,
                         clash_yaml, dst):
    """sing-box json for geosite: 跳过 PROCESS-NAME / PROCESS-NAME-REGEX / IP-ASN"""
    suffixes = read_lines(f_suffix)
    domains  = read_lines(f_domain)
    keywords = read_lines(f_keyword)
    regexps  = read_lines(f_regexp)
    cidrs    = read_lines(f_ipcidr)

    # clash extras（仅 json 可用的类型）
    if clash_yaml:
        geo_seen = {}
        for v in suffixes:
            geo_seen.setdefault("DOMAIN-SUFFIX", set()).add(v.lstrip("."))
        for v in domains:
            geo_seen.setdefault("DOMAIN", set()).add(v)
        for v in keywords:
            geo_seen.setdefault("DOMAIN-KEYWORD", set()).add(v)
        for v in regexps:
            geo_seen.setdefault("DOMAIN-REGEX", set()).add(v)
        for v in cidrs:
            t = "IP-CIDR6" if ":" in v else "IP-CIDR"
            geo_seen.setdefault(t, set()).add(v.lower())

        clash_seen = {}
        for t, v in parse_clash_entries(clash_yaml):
            if t in JSON_SKIP_TYPES:
                continue
            nv = norm_value(t, v)
            if nv in geo_seen.get(t, set()):
                continue
            if nv in clash_seen.get(t, set()):
                continue
            clash_seen.setdefault(t, set()).add(nv)
            if t == "DOMAIN-SUFFIX":
                suffixes.append(v.lstrip("."))
            elif t == "DOMAIN":
                domains.append(v)
            elif t == "DOMAIN-KEYWORD":
                keywords.append(v)
            elif t == "DOMAIN-REGEX":
                regexps.append(v)
            elif t in ("IP-CIDR", "IP-CIDR6"):
                cidrs.append(v)

    rule = {}
    if domains:   rule["domain"]         = domains
    if suffixes:  rule["domain_suffix"]  = suffixes
    if keywords:  rule["domain_keyword"] = keywords
    if regexps:   rule["domain_regex"]   = regexps
    if cidrs:     rule["ip_cidr"]        = cidrs
    out = {"version": 3, "rules": [rule] if rule else []}
    with open(dst, "w") as f:
        json.dump(out, f, ensure_ascii=False, separators=(",", ":"))
        f.write("\n")


def cmd_make_json_ipcidr(f_ipcidr, clash_yaml, dst):
    """sing-box json for geoip"""
    geo_cidrs = read_lines(f_ipcidr)
    geo_seen = set(v.lower() for v in geo_cidrs)

    clash_seen = set()
    for t, v in parse_clash_entries(clash_yaml):
        if t not in ("IP-CIDR", "IP-CIDR6"):
            continue
        nv = v.lower()
        if nv in geo_seen or nv in clash_seen:
            continue
        clash_seen.add(nv)
        geo_cidrs.append(v)

    rule = {"ip_cidr": geo_cidrs} if geo_cidrs else {}
    out = {"version": 3, "rules": [rule] if rule else []}
    with open(dst, "w") as f:
        json.dump(out, f, ensure_ascii=False, separators=(",", ":"))
        f.write("\n")


# ── 差集计算 ─────────────────────────────────────────────────────────────────

def cmd_diff_new_entries(exist_file, new_file, out_file, entry_type):
    """计算 new_file 中 exist_file 没有的条目"""
    if entry_type == "cidr":
        exist = set(v.strip().lower() for v in read_lines(exist_file))
    else:
        exist = set(v.strip() for v in read_lines(exist_file))

    new = []
    seen = set()
    for v in read_lines(new_file):
        k = v.lower() if entry_type == "cidr" else v
        if k not in exist and k not in seen:
            seen.add(k)
            new.append(v)
    with open(out_file, "w") as f:
        for item in new:
            f.write(item + "\n")


# ── 从 list 文件重建 json ────────────────────────────────────────────────────

def cmd_rebuild_json_from_list(list_file, json_dst):
    """从 .list 文件提取 IP-CIDR/IP-CIDR6 重建 sing-box json"""
    cidrs = []
    for line in read_lines(list_file):
        if line.startswith("IP-CIDR6,"):
            cidrs.append(line[9:])
        elif line.startswith("IP-CIDR,"):
            cidrs.append(line[8:])
    rule = {"ip_cidr": cidrs} if cidrs else {}
    out = {"version": 3, "rules": [rule] if rule else []}
    with open(json_dst, "w") as f:
        json.dump(out, f, ensure_ascii=False, separators=(",", ":"))
        f.write("\n")


# ═══════════════════════════════════════════════════════════════════════════════
# 主入口
# ═══════════════════════════════════════════════════════════════════════════════

COMMANDS = {
    "parse_clash":          lambda a: cmd_parse_clash(a[0], a[1], a[2]),
    "merge_dedup":          lambda a: cmd_merge_dedup(a[0], a[1], a[2], a[3]),
    "make_yaml_domain":     lambda a: cmd_make_yaml_domain(*a[:8]),
    "make_yaml_ipcidr":     lambda a: cmd_make_yaml_ipcidr(*a[:4]),
    "make_list_domain":     lambda a: cmd_make_list_domain(*a[:8]),
    "make_list_ipcidr":     lambda a: cmd_make_list_ipcidr(*a[:4]),
    "make_qx_domain":       lambda a: cmd_make_qx_domain(*a[:6]),
    "make_qx_ipcidr":       lambda a: cmd_make_qx_ipcidr(*a[:3]),
    "make_json_domain":     lambda a: cmd_make_json_domain(*a[:7]),
    "make_json_ipcidr":     lambda a: cmd_make_json_ipcidr(*a[:3]),
    "diff_new_entries":     lambda a: cmd_diff_new_entries(*a[:4]),
    "rebuild_json_from_list": lambda a: cmd_rebuild_json_from_list(a[0], a[1]),
}

def main():
    if len(sys.argv) < 2:
        print(f"Usage: {sys.argv[0]} <command> [args...]", file=sys.stderr)
        print(f"Commands: {', '.join(sorted(COMMANDS))}", file=sys.stderr)
        sys.exit(1)

    cmd = sys.argv[1]
    args = sys.argv[2:]

    if cmd not in COMMANDS:
        print(f"Unknown command: {cmd}", file=sys.stderr)
        print(f"Commands: {', '.join(sorted(COMMANDS))}", file=sys.stderr)
        sys.exit(1)

    COMMANDS[cmd](args)

if __name__ == "__main__":
    main()
