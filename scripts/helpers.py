#!/usr/bin/env python3
"""
helpers.py — sync_loy_geo_mrs.sh 的统一 Python 引擎
一次调用处理所有 tag，输出全部格式，消除数千次进程启动开销。

用法:
  python3 helpers.py batch_geosite    <geosite_txt_dir> <clash_dir> <out_geosite> <out_qx_geosite> <mrs_tasks> <srs_tasks> <workdir>
  python3 helpers.py batch_geoip      <geoip_txt_dir> <clash_dir> <clash_ip_dir_from_geosite> <out_geoip> <out_qx_geoip> <mrs_tasks> <srs_tasks> <workdir>
  python3 helpers.py batch_clash_ip   <clash_ip_dir> <out_geoip> <out_qx_geoip> <mrs_tasks> <srs_tasks> <workdir>
  python3 helpers.py batch_domain_link <link_json> <out_geosite> <out_qx_geosite> <mrs_tasks> <srs_tasks> <workdir>
  python3 helpers.py batch_ip_link     <link_json> <out_geoip> <out_qx_geoip> <mrs_tasks> <srs_tasks> <workdir>

  link_json 格式（clash/DOMAIN-Link 或 clash-ip/IP-Link）：
    [{"name":"示例","url":"https://...","format":"clash"}]
    format 可选：clash/yaml/json（Clash 规则格式）、list/txt/domain-text（纯域名列表）、
                 ip-text（纯 CIDR 列表）、auto（自动检测，默认）

  还保留单条命令供 shell 零星调用:
  python3 helpers.py parse_clash            <yaml> <out_dir> <tag>
  python3 helpers.py merge_dedup            <geo_file> <clash_file> <out_file> <bucket_type>
  python3 helpers.py diff_new_entries       <exist_file> <new_file> <out_file> <type>
  python3 helpers.py rebuild_json_from_list <list_file> <json_dst>
"""

import sys
import os
import re
import json
import glob
import ipaddress
from urllib.request import Request, urlopen

# ═══════════════════════════════════════════════════════════════════════════════
# 通用工具
# ═══════════════════════════════════════════════════════════════════════════════

def read_lines(path):
    """读取文件非空行，文件不存在返回空列表"""
    if not path:
        return []
    try:
        with open(path, encoding="utf-8") as f:
            return [l.rstrip("\n") for l in f if l.strip()]
    except FileNotFoundError:
        return []


def write_lines(path, lines):
    """写入行列表"""
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        for line in lines:
            f.write(line + "\n")


def norm_value(rule_type, value):
    if rule_type == "DOMAIN-SUFFIX":
        return value.lstrip(".")
    if rule_type in ("IP-CIDR", "IP-CIDR6"):
        return value.lower()
    return value


RE_ITEM = re.compile(r"^\s*-\s+(.+)$")
RE_COMMENT = re.compile(r"\s+#.*$")

def parse_clash_entries(yaml_path):
    """解析 clash yaml，返回 [(rule_type, value), ...]"""
    if not yaml_path or yaml_path == "" or not os.path.isfile(yaml_path):
        return []
    entries = []
    with open(yaml_path, encoding="utf-8") as f:
        for raw in f:
            m = RE_ITEM.match(raw.rstrip())
            if not m:
                continue
            entry = RE_COMMENT.sub("", m.group(1).strip())
            if not entry or "," not in entry:
                continue
            parts = [p.strip() for p in entry.split(",")]
            if len(parts) < 2:
                continue
            entries.append((parts[0].upper(), parts[1]))
    return entries


TYPE_TO_BUCKET = {
    "DOMAIN-SUFFIX":       "suffix",
    "DOMAIN":              "domain",
    "DOMAIN-KEYWORD":      "keyword",
    "DOMAIN-REGEX":        "regexp",
    "DOMAIN-WILDCARD":     "wildcard",
    "IP-CIDR":             "ipcidr",
    "IP-CIDR6":            "ipcidr",
    "PROCESS-NAME":        "process",
    "PROCESS-NAME-REGEX":  "process_re",
    "IP-ASN":              "asn",
}

QX_SKIP_TYPES = {"DOMAIN-REGEX", "DOMAIN-WILDCARD", "PROCESS-NAME", "PROCESS-NAME-REGEX", "IP-ASN"}
QX_TYPE_MAP = {
    "DOMAIN-SUFFIX":  "HOST-SUFFIX",
    "DOMAIN":         "HOST",
    "DOMAIN-KEYWORD": "HOST-KEYWORD",
    "IP-CIDR":        "IP-CIDR",
    "IP-CIDR6":       "IP-CIDR6",
}
JSON_SKIP_TYPES = {"DOMAIN-WILDCARD", "PROCESS-NAME", "PROCESS-NAME-REGEX", "IP-ASN"}
MRS_SKIP_TYPES = {"DOMAIN-WILDCARD"}

# ═══════════════════════════════════════════════════════════════════════════════
# 统一排序
# ═══════════════════════════════════════════════════════════════════════════════
# 排序优先级：
#   1. DOMAIN          2. DOMAIN-SUFFIX     3. DOMAIN-WILDCARD
#   4. DOMAIN-KEYWORD  5. IP-CIDR/IP-CIDR6  6. IP-ASN
#   7. PROCESS-NAME / PROCESS-NAME-REGEX    8. DOMAIN-REGEX

TYPE_ORDER = {
    "DOMAIN":              0,
    "DOMAIN-SUFFIX":       1,
    "DOMAIN-WILDCARD":     2,
    "DOMAIN-KEYWORD":      3,
    "IP-CIDR":             4,
    "IP-CIDR6":            4,
    "IP-ASN":              5,
    "PROCESS-NAME":        6,
    "PROCESS-NAME-REGEX":  6,
    "DOMAIN-REGEX":        7,
}

# QX 类型也纳入排序
QX_TYPE_ORDER = {
    "HOST":            0,
    "HOST-SUFFIX":     1,
    "HOST-KEYWORD":    3,
    "IP-CIDR":         4,
    "IP-CIDR6":        4,
}


def sort_typed_lines(lines):
    """对 [(type, value), ...] 按 TYPE_ORDER 排序。
    IP 类型：IPv4 全部在前，IPv6 全部在后；同类型内按前缀长度降序（/32→/24→/16→/8，精确在前）。"""
    def key(tv):
        t, v = tv
        order = TYPE_ORDER.get(t, 99)
        if t in ("IP-CIDR", "IP-CIDR6") and "/" in v:
            try:
                is_v6 = 1 if t == "IP-CIDR6" else 0
                return (order, is_v6, -int(v.split("/")[1]), v)
            except ValueError:
                pass
        return (order, 0, 0, v)
    return sorted(lines, key=key)


def sort_qx_lines(lines):
    """对 QX 行 "TYPE, value" 按 QX_TYPE_ORDER 排序"""
    def qx_key(line):
        t = line.split(",", 1)[0].strip()
        return QX_TYPE_ORDER.get(t, 99)
    return sorted(lines, key=qx_key)


def parse_clash_to_buckets(yaml_path):
    """解析 clash yaml 并分桶返回 dict"""
    buckets = {k: [] for k in ("suffix", "domain", "keyword", "regexp", "wildcard",
                                "ipcidr", "process", "process_re", "asn")}
    for t, v in parse_clash_entries(yaml_path):
        bucket = TYPE_TO_BUCKET.get(t)
        if bucket is None:
            continue
        if bucket == "suffix":
            v = v.lstrip(".")
        buckets[bucket].append(v)
    return buckets


def merge_dedup_lists(geo_vals, clash_vals, bucket_type):
    """合并去重，返回合并后列表"""
    seen = set()
    order = []
    for val in geo_vals + clash_vals:
        if bucket_type == "suffix":
            key = val.lstrip(".")
        elif bucket_type == "ipcidr":
            key = val.lower()
        else:
            key = val
        if key not in seen:
            seen.add(key)
            order.append(val)
    return order


# ═══════════════════════════════════════════════════════════════════════════════
# 解析 v2dat 解包的 geosite txt
# ═══════════════════════════════════════════════════════════════════════════════

def parse_geosite_txt(filepath):
    """解析 v2dat 的 geosite txt，返回分桶 dict"""
    buckets = {"suffix": [], "domain": [], "keyword": [], "regexp": []}
    for line in read_lines(filepath):
        if line.startswith("keyword:"):
            buckets["keyword"].append(line[8:])
        elif line.startswith("regexp:"):
            buckets["regexp"].append(line[7:])
        elif line.startswith("full:"):
            buckets["domain"].append(line[5:])
        else:
            if line.startswith("."):
                buckets["suffix"].append(line)
            else:
                buckets["suffix"].append("." + line)
    return buckets


# ═══════════════════════════════════════════════════════════════════════════════
# 单 tag 全格式输出（内存中完成，不启动子进程）
# ═══════════════════════════════════════════════════════════════════════════════

def emit_geosite_tag(tag, buckets, clash_yaml, out_geosite,
                     out_qx_geosite, mrs_tasks, srs_tasks, workdir):
    """
    为一个 geosite tag 输出全部格式。
    buckets: {"suffix":[], "domain":[], "keyword":[], "regexp":[],
              "wildcard":[], "process":[], "process_re":[]}
              注意：不含 ipcidr/asn（由 clash_extras 从 clash_yaml 中提取）
    clash_yaml: clash yaml 路径（用于提取 extras 追加进 yaml/list/json/QX）
    返回 (extra_ipcidr_list, extra_asn_list) 供 geoip 阶段使用
    """
    suffix   = buckets.get("suffix", [])
    domain   = buckets.get("domain", [])
    keyword  = buckets.get("keyword", [])
    regexp   = buckets.get("regexp", [])
    wildcard = buckets.get("wildcard", [])
    process  = buckets.get("process", [])
    process_re = buckets.get("process_re", [])

    # 构建 geo_seen 用于 clash 去重（不含 ipcidr/asn，让 IP 类条目通过 extras 输出）
    geo_seen = {}
    for v in suffix:
        geo_seen.setdefault("DOMAIN-SUFFIX", set()).add(v.lstrip("."))
    for v in domain:
        geo_seen.setdefault("DOMAIN", set()).add(v)
    for v in keyword:
        geo_seen.setdefault("DOMAIN-KEYWORD", set()).add(v)
    for v in regexp:
        geo_seen.setdefault("DOMAIN-REGEX", set()).add(v)
    for v in wildcard:
        geo_seen.setdefault("DOMAIN-WILDCARD", set()).add(v)
    for v in process:
        geo_seen.setdefault("PROCESS-NAME", set()).add(v)
    for v in process_re:
        geo_seen.setdefault("PROCESS-NAME-REGEX", set()).add(v)

    # clash extras（包含域名类 + IP 类 + 进程类，与 geo_seen 去重）
    clash_extras = []  # [(type, value), ...]
    clash_seen = {}
    for t, v in parse_clash_entries(clash_yaml):
        nv = norm_value(t, v)
        if nv in geo_seen.get(t, set()):
            continue
        if nv in clash_seen.get(t, set()):
            continue
        clash_seen.setdefault(t, set()).add(nv)
        clash_extras.append((t, v))

    # 所有 geo 行（type, value）— 仅域名类 + 进程类，不含 IP
    geo_lines = (
        [("DOMAIN-SUFFIX", v.lstrip(".")) for v in suffix] +
        [("DOMAIN", v) for v in domain] +
        [("DOMAIN-KEYWORD", v) for v in keyword] +
        [("DOMAIN-REGEX", v) for v in regexp] +
        [("DOMAIN-WILDCARD", v) for v in wildcard] +
        [("PROCESS-NAME", v) for v in process] +
        [("PROCESS-NAME-REGEX", v) for v in process_re]
    )
    # clash_extras 包含 IP-CIDR/IP-ASN 等，会被追加进 yaml/list
    all_lines = sort_typed_lines(geo_lines + clash_extras)

    # ── yaml（geosite 侧 IP 条目加 ,no-resolve）─────────────────────────
    yaml_out = ["payload:"]
    for t, v in all_lines:
        if t in ("IP-CIDR", "IP-CIDR6", "IP-ASN"):
            yaml_out.append(f"  - {t},{v},no-resolve")
        else:
            yaml_out.append(f"  - {t},{v}")
    write_lines(os.path.join(out_geosite, f"{tag}.yaml"), yaml_out)

    # ── list（geosite 侧 IP 条目加 ,no-resolve）─────────────────────────
    list_out = []
    for t, v in all_lines:
        if t in ("IP-CIDR", "IP-CIDR6", "IP-ASN"):
            list_out.append(f"{t},{v},no-resolve")
        else:
            list_out.append(f"{t},{v}")
    write_lines(os.path.join(out_geosite, f"{tag}.list"), list_out)

    # ── QX list（跳过 DOMAIN-REGEX / DOMAIN-WILDCARD / PROCESS-NAME 等）──
    # geosite 侧 IP 条目加 ,no-resolve
    qx_out = []
    for v in domain:
        qx_out.append(f"HOST, {v}")
    for v in suffix:
        qx_out.append(f"HOST-SUFFIX, {v.lstrip('.')}")
    for v in keyword:
        qx_out.append(f"HOST-KEYWORD, {v}")
    # wildcard: QX 不支持，跳过
    # clash extras for QX（clash_extras 已去重，IP 加 no-resolve）
    for t, v in clash_extras:
        if t in QX_SKIP_TYPES:
            continue
        if t in ("IP-CIDR", "IP-CIDR6"):
            qx_out.append(f"{t}, {v}, no-resolve")
            continue
        qx_t = QX_TYPE_MAP.get(t)
        if qx_t:
            qx_out.append(f"{qx_t}, {v}")
    # 排序 QX 输出
    qx_out = sort_qx_lines(qx_out)
    write_lines(os.path.join(out_qx_geosite, f"{tag}.list"), qx_out)

    # ── json（sing-box v3，不加 no-resolve）──────────────────────────────
    # suffix 列表混合了带点(geo)和不带点(clash merge)的值，统一加点
    j_suffix = [v if v.startswith(".") else "." + v for v in suffix]
    j_domain = list(domain)
    j_keyword = list(keyword)
    j_regexp = list(regexp)
    # wildcard: json/srs 不支持，跳过
    j_cidrs = []  # IP 条目从 clash_extras 获取（与 yaml/list 一致）
    for t, v in clash_extras:
        if t in JSON_SKIP_TYPES:
            continue
        if t == "DOMAIN-SUFFIX":
            j_suffix.append("." + v.lstrip("."))
        elif t == "DOMAIN":
            j_domain.append(v)
        elif t == "DOMAIN-KEYWORD":
            j_keyword.append(v)
        elif t == "DOMAIN-REGEX":
            j_regexp.append(v)
        elif t in ("IP-CIDR", "IP-CIDR6"):
            j_cidrs.append(v)

    # 去重（clash_extras 内 IP 条目大小写可能不一致）
    if j_cidrs:
        seen_cidr = set()
        deduped = []
        for v in j_cidrs:
            k = v.lower()
            if k not in seen_cidr:
                seen_cidr.add(k)
                deduped.append(v)
        j_cidrs = deduped

    # json 按 key 顺序排列（domain → domain_suffix → domain_keyword → ip_cidr → domain_regex）
    rule = {}
    if j_domain:   rule["domain"]         = j_domain
    if j_suffix:   rule["domain_suffix"]  = j_suffix
    if j_keyword:  rule["domain_keyword"] = j_keyword
    if j_cidrs:    rule["ip_cidr"]        = j_cidrs
    if j_regexp:   rule["domain_regex"]   = j_regexp
    json_path = os.path.join(out_geosite, f"{tag}.json")
    with open(json_path, "w") as f:
        json.dump({"version": 3, "rules": [rule] if rule else []},
                  f, ensure_ascii=False, separators=(",", ":"))
        f.write("\n")

    # ── mrs 源文件（suffix + domain，跳过 wildcard）─────────────────────
    # mrs 排序：domain 在前，suffix 在后
    mrs_src = os.path.join(workdir, "gs_mrs", f"{tag}.txt")
    os.makedirs(os.path.dirname(mrs_src), exist_ok=True)
    mrs_lines = list(domain) + [v if v.startswith(".") else "." + v for v in suffix]
    if mrs_lines:
        write_lines(mrs_src, mrs_lines)
        mrs_tasks.append(f"domain\t{mrs_src}\t{os.path.join(out_geosite, f'{tag}.mrs')}")

    # srs 任务
    srs_tasks.append(f"{json_path}\t{os.path.join(out_geosite, f'{tag}.srs')}")

    # 返回 clash 带来的 IP 条目供 geoip 使用
    extra_ipcidr = []
    extra_asn = []
    for t, v in clash_extras:
        if t in ("IP-CIDR", "IP-CIDR6"):
            extra_ipcidr.append(v)
        elif t == "IP-ASN":
            extra_asn.append(v)
    return extra_ipcidr, extra_asn


def emit_geoip_tag(tag, ipcidr_lines, asn_lines, out_geoip, out_qx_geoip,
                   mrs_tasks, srs_tasks):
    """为一个 geoip tag 输出全部格式（纯 Loyalsoldier 数据）
    geoip 侧不加 no-resolve"""
    # 构建 typed lines 用于排序
    typed = []
    for v in ipcidr_lines:
        t = "IP-CIDR6" if ":" in v else "IP-CIDR"
        typed.append((t, v))
    for v in asn_lines:
        typed.append(("IP-ASN", v))
    typed = sort_typed_lines(typed)

    # ── yaml（geoip 不加 no-resolve）──
    yaml_out = ["payload:"]
    for t, v in typed:
        yaml_out.append(f"  - {t},{v}")
    write_lines(os.path.join(out_geoip, f"{tag}.yaml"), yaml_out)

    # ── list（geoip 不加 no-resolve）──
    list_out = [f"{t},{v}" for t, v in typed]
    write_lines(os.path.join(out_geoip, f"{tag}.list"), list_out)

    # ── QX list（跳过 ASN，加 no-resolve）──
    qx_out = []
    for t, v in typed:
        if t == "IP-ASN":
            continue
        qx_out.append(f"{t}, {v}, no-resolve")
    write_lines(os.path.join(out_qx_geoip, f"{tag}.list"), qx_out)

    # ── json ──
    sorted_cidrs = [v for t, v in typed if t in ("IP-CIDR", "IP-CIDR6")]
    rule = {"ip_cidr": sorted_cidrs} if sorted_cidrs else {}
    json_path = os.path.join(out_geoip, f"{tag}.json")
    with open(json_path, "w") as f:
        json.dump({"version": 3, "rules": [rule] if rule else []},
                  f, ensure_ascii=False, separators=(",", ":"))
        f.write("\n")

    # mrs + srs 任务
    srs_tasks.append(f"{json_path}\t{os.path.join(out_geoip, f'{tag}.srs')}")
    # mrs 先不登记，等 clash merge 后再登记（见 batch_geoip）


# ═══════════════════════════════════════════════════════════════════════════════
# batch_geosite：一次处理所有 geosite tag
# ═══════════════════════════════════════════════════════════════════════════════

def cmd_batch_geosite(geosite_txt_dir, clash_dir, out_geosite, out_qx_geosite,
                      mrs_tasks_file, srs_tasks_file, workdir):
    os.makedirs(out_geosite, exist_ok=True)
    os.makedirs(out_qx_geosite, exist_ok=True)

    mrs_tasks = []
    srs_tasks = []
    processed = set()
    clash_ip_cache = {}  # tag -> (ipcidr_list, asn_list)

    ok = 0
    skip = 0

    # ── 1. 处理 Loyalsoldier geosite txt ─────────────────────────────────
    txt_files = sorted(glob.glob(os.path.join(geosite_txt_dir, "*.txt")))
    for f in txt_files:
        base = os.path.basename(f)
        tag = base
        if tag.startswith("geosite_"):
            tag = tag[8:]
        tag = tag.removesuffix(".txt")

        geo_buckets = parse_geosite_txt(f)

        # clash 融合（只融合域名/进程/通配类桶，ipcidr/asn 单独缓存）
        clash_yaml = os.path.join(clash_dir, f"{tag}.yaml")
        clash_ipcidr = []
        if os.path.isfile(clash_yaml):
            print(f"[MERGE] geosite/{tag} <- {clash_yaml}")
            cb = parse_clash_to_buckets(clash_yaml)
            for btype in ("suffix", "domain", "keyword", "regexp",
                          "wildcard", "process", "process_re"):
                geo_buckets.setdefault(btype, [])
                geo_buckets[btype] = merge_dedup_lists(
                    geo_buckets[btype], cb.get(btype, []), btype)
            # ipcidr/asn 单独缓存，不放进 geo_buckets
            clash_ipcidr = cb.get("ipcidr", [])
        else:
            clash_yaml = ""

        geo_buckets.setdefault("wildcard", [])
        geo_buckets.setdefault("process", [])
        geo_buckets.setdefault("process_re", [])

        # 检查空
        has_data = any(geo_buckets.get(k) for k in
                       ("suffix", "domain", "keyword", "regexp", "wildcard",
                        "process", "process_re")) or clash_ipcidr
        if not has_data:
            skip += 1
            processed.add(tag)
            continue

        ci, ca = emit_geosite_tag(
            tag, geo_buckets, clash_yaml,
            out_geosite, out_qx_geosite,
            mrs_tasks, srs_tasks, workdir)

        # 缓存 clash 带来的 IP 条目（extra_ipcidr 已去重，直接使用）
        all_ci = ci
        all_ca = ca
        if all_ci or all_ca:
            clash_ip_cache[tag] = (all_ci, all_ca)

        processed.add(tag)
        ok += 1

    print(f"[INFO] geosite geo pass: ok={ok}  skipped_empty={skip}")

    # ── 2. clash-only geosite ────────────────────────────────────────────
    clash_only_ok = 0
    if os.path.isdir(clash_dir):
        for cyaml in sorted(glob.glob(os.path.join(clash_dir, "*.yaml"))):
            tag = os.path.basename(cyaml).removesuffix(".yaml")
            if tag in processed:
                continue

            print(f"[CLASH-ONLY] geosite/{tag} <- {cyaml}")
            cb = parse_clash_to_buckets(cyaml)

            # 构建 buckets（不含 ipcidr/asn）
            buckets = {
                "suffix": cb.get("suffix", []),
                "domain": cb.get("domain", []),
                "keyword": cb.get("keyword", []),
                "regexp": cb.get("regexp", []),
                "wildcard": cb.get("wildcard", []),
                "process": cb.get("process", []),
                "process_re": cb.get("process_re", []),
            }
            clash_ipcidr = cb.get("ipcidr", [])

            has_data = any(buckets.get(k) for k in
                           ("suffix", "domain", "keyword", "regexp", "wildcard",
                            "process", "process_re")) or clash_ipcidr
            if not has_data:
                continue

            ci, ca = emit_geosite_tag(
                tag, buckets, cyaml,
                out_geosite, out_qx_geosite,
                mrs_tasks, srs_tasks, workdir)

            all_ci = ci
            all_ca = ca
            if all_ci or all_ca:
                clash_ip_cache[tag] = (all_ci, all_ca)

            processed.add(tag)
            clash_only_ok += 1

    print(f"[INFO] geosite clash-only: ok={clash_only_ok}")

    # 写出编译任务
    with open(mrs_tasks_file, "a", encoding="utf-8") as f:
        for line in mrs_tasks:
            f.write(line + "\n")
    with open(srs_tasks_file, "a", encoding="utf-8") as f:
        for line in srs_tasks:
            f.write(line + "\n")

    # 保存 clash_ip 缓存供 geoip 阶段使用
    clash_ip_dir = os.path.join(workdir, "clash_ip")
    os.makedirs(clash_ip_dir, exist_ok=True)
    for tag, (ci, ca) in clash_ip_cache.items():
        write_lines(os.path.join(clash_ip_dir, f"{tag}.ipcidr.txt"), ci)
        write_lines(os.path.join(clash_ip_dir, f"{tag}.asn.txt"), ca)


# ═══════════════════════════════════════════════════════════════════════════════
# batch_geoip：一次处理所有 geoip tag
# ═══════════════════════════════════════════════════════════════════════════════

def cmd_batch_geoip(geoip_txt_dir, clash_dir, clash_ip_from_geosite_dir,
                    out_geoip, out_qx_geoip, mrs_tasks_file, srs_tasks_file, workdir):
    os.makedirs(out_geoip, exist_ok=True)
    os.makedirs(out_qx_geoip, exist_ok=True)

    mrs_tasks = []
    srs_tasks = []
    processed = set()

    ok = 0

    txt_files = sorted(glob.glob(os.path.join(geoip_txt_dir, "*.txt")))
    for f in txt_files:
        base = os.path.basename(f)
        tag = base
        if tag.startswith("geoip_"):
            tag = tag[6:]
        tag = tag.removesuffix(".txt")

        ipcidr_lines = read_lines(f)
        if not ipcidr_lines:
            continue

        # 五种格式 + QX（纯 Loyalsoldier 数据）
        emit_geoip_tag(tag, ipcidr_lines, [], out_geoip, out_qx_geoip,
                       mrs_tasks, srs_tasks)

        # clash 合并后的 mrs（用合并后数据覆盖纯 geo 数据）
        # 先收集所有需要合并的 IP 条目
        merged_cidr = list(ipcidr_lines)
        merged_cidr_seen = set(v.lower() for v in ipcidr_lines)

        # 从 geosite 阶段缓存的 clash IP 条目
        ci_cache_file = os.path.join(clash_ip_from_geosite_dir, f"{tag}.ipcidr.txt")
        for v in read_lines(ci_cache_file):
            nv = v.lower()
            if nv not in merged_cidr_seen:
                merged_cidr_seen.add(nv)
                merged_cidr.append(v)

        # 直接以 geoip tag 命名的 clash yaml
        clash_yaml = os.path.join(clash_dir, f"{tag}.yaml")
        if os.path.isfile(clash_yaml):
            print(f"[MERGE] geoip/{tag} <- {clash_yaml}")
            for t, v in parse_clash_entries(clash_yaml):
                if t in ("IP-CIDR", "IP-CIDR6"):
                    nv = v.lower()
                    if nv not in merged_cidr_seen:
                        merged_cidr_seen.add(nv)
                        merged_cidr.append(v)

        # mrs 用合并后数据（最终版本，覆盖 emit_geoip_tag 里可能登记的）
        if merged_cidr:
            mrs_src = os.path.join(workdir, "geoip_mrs", f"{tag}.txt")
            os.makedirs(os.path.dirname(mrs_src), exist_ok=True)
            write_lines(mrs_src, merged_cidr)
            mrs_tasks.append(f"ipcidr\t{mrs_src}\t{os.path.join(out_geoip, f'{tag}.mrs')}")

        processed.add(tag)
        ok += 1

    print(f"[INFO] geoip geo pass: ok={ok}")

    # ── clash-only geoip ─────────────────────────────────────────────────
    clash_only_ok = 0
    if os.path.isdir(clash_dir):
        for cyaml in sorted(glob.glob(os.path.join(clash_dir, "*.yaml"))):
            tag = os.path.basename(cyaml).removesuffix(".yaml")
            if tag in processed:
                continue

            # 尝试从 geosite 缓存获取 IP 条目
            ci_file = os.path.join(clash_ip_from_geosite_dir, f"{tag}.ipcidr.txt")
            ipcidr = read_lines(ci_file) if os.path.isfile(ci_file) else []

            if not ipcidr:
                # 直接从 clash yaml 解析
                for t, v in parse_clash_entries(cyaml):
                    if t in ("IP-CIDR", "IP-CIDR6"):
                        ipcidr.append(v)

            if not ipcidr:
                continue

            print(f"[CLASH-ONLY] geoip/{tag} <- {cyaml} (mrs only)")
            mrs_src = os.path.join(workdir, "geoip_mrs", f"{tag}.txt")
            os.makedirs(os.path.dirname(mrs_src), exist_ok=True)
            write_lines(mrs_src, ipcidr)
            mrs_tasks.append(f"ipcidr\t{mrs_src}\t{os.path.join(out_geoip, f'{tag}.mrs')}")
            clash_only_ok += 1

    print(f"[INFO] geoip clash-only: ok={clash_only_ok}")

    with open(mrs_tasks_file, "a", encoding="utf-8") as f:
        for line in mrs_tasks:
            f.write(line + "\n")
    with open(srs_tasks_file, "a", encoding="utf-8") as f:
        for line in srs_tasks:
            f.write(line + "\n")


# ═══════════════════════════════════════════════════════════════════════════════
# 远程链接拉取 + 格式解析（DOMAIN-Link / IP-Link）
# ═══════════════════════════════════════════════════════════════════════════════

def fetch_url(url, timeout=60):
    """拉取 URL，返回 UTF-8 文本"""
    req = Request(url, headers={"User-Agent": "Mozilla/5.0"})
    with urlopen(req, timeout=timeout) as r:
        return r.read().decode("utf-8", errors="ignore")


# sing-box JSON 字段名 → Clash 规则类型
_SINGBOX_TO_TYPE = {
    "domain":         "DOMAIN",
    "domain_suffix":  "DOMAIN-SUFFIX",
    "domain_keyword": "DOMAIN-KEYWORD",
    "domain_regex":   "DOMAIN-REGEX",
    "ip_cidr":        "IP-CIDR",
    "ip_asn":         "IP-ASN",
}


def _iter_rule_lines(text):
    """
    从 Clash YAML / JSON / sing-box JSON / 纯文本中提取规则行列表。
    支持: Clash JSON(payload:[])、sing-box JSON(rules:[{domain:[],…}])、
          YAML list 块("  - value" 或 "  - 'value'")、纯文本行。
    单引号/双引号包裹的 YAML scalar 值自动去除引号。
    """
    text = (text or "").strip()
    if not text:
        return []

    # JSON：{ payload/rules: [...] } 或 [ ... ]
    if text[:1] in "{[":
        try:
            obj = json.loads(text)
            if isinstance(obj, dict):
                payload = obj.get("payload")
                rules   = obj.get("rules")
                if payload is not None:
                    items = payload
                elif rules is not None:
                    # sing-box 格式：rules 是 dict 列表，展开为 TYPE,value 字符串
                    expanded = []
                    for rule in (rules if isinstance(rules, list) else []):
                        if isinstance(rule, str):
                            expanded.append(rule)
                        elif isinstance(rule, dict):
                            for key, vals in rule.items():
                                clash_t = _SINGBOX_TO_TYPE.get(key)
                                if clash_t and isinstance(vals, list):
                                    for v in vals:
                                        expanded.append(f"{clash_t},{v}")
                    items = expanded
                else:
                    items = []
            elif isinstance(obj, list):
                items = obj
            else:
                items = []
            out = []
            for x in items:
                s = str(x).strip().lstrip("-").strip().strip("'\"")
                if s and not s.startswith("#"):
                    out.append(s)
            return out
        except Exception:
            pass

    # YAML list 块（"  - RULE,value" 或 "  - 'value'" 格式，去除引号）
    out = []
    for raw in text.splitlines():
        m = RE_ITEM.match(raw.rstrip())
        if m:
            entry = RE_COMMENT.sub("", m.group(1).strip()).strip("'\"")
            if entry:
                out.append(entry)
    if out:
        return out

    # 纯文本兜底（去除可能的引号包裹）
    return [s.strip().strip("'\"") for s in text.splitlines()
            if s.strip() and not s.strip().startswith("#")]


def _norm_link_fmt(fmt, text, for_ip=False):
    """
    规范化 format 字符串，auto 时根据内容自动检测。
    返回: "clash" | "domain-text" | "ip-text"
    """
    f = (fmt or "auto").lower().strip().replace("_", "-")
    if f in ("clash", "yaml", "json"):
        return "clash"
    if f in ("list", "txt", "domain-text"):
        return "ip-text" if for_ip else "domain-text"
    if f == "ip-text":
        return "ip-text"

    # auto 检测
    t = (text or "").strip()
    if t[:1] in "{[":
        return "clash"
    for line in t.splitlines():
        s = line.strip()
        if not s or s.startswith("#"):
            continue
        if s in ("payload:", "rules:"):
            return "clash"
        if "," in s:
            # 去除 "  - " 前缀和引号后取第一字段
            prefix = s.lstrip("- ").strip().strip("'\"").split(",", 1)[0].strip().upper()
            if prefix in {"DOMAIN", "DOMAIN-SUFFIX", "DOMAIN-KEYWORD", "DOMAIN-REGEX",
                          "DOMAIN-WILDCARD", "IP-CIDR", "IP-CIDR6", "IP-ASN",
                          "PROCESS-NAME", "PROCESS-NAME-REGEX",
                          "HOST", "HOST-SUFFIX", "HOST-KEYWORD"}:
                return "clash"
        break
    return "ip-text" if for_ip else "domain-text"


# QX 类型 → 标准 Clash 类型
_QX_TYPE_REVERSE = {
    "HOST":         "DOMAIN",
    "HOST-SUFFIX":  "DOMAIN-SUFFIX",
    "HOST-KEYWORD": "DOMAIN-KEYWORD",
}


def parse_remote_domain_entries(text, fmt):
    """
    从远程内容提取域名类条目，返回分桶 dict（不含 IP 条目）。
    fmt: clash/yaml/json → Clash 规则格式; list/txt/domain-text → 纯域名文本; auto → 自动
    支持格式:
      - Clash list: DOMAIN,x / DOMAIN-SUFFIX,x
      - Clash YAML: payload: - DOMAIN,x
      - QX list:    HOST,x,policy / HOST-SUFFIX,x,policy
      - sing-box JSON: {"rules":[{"domain":[...],"domain_suffix":[...]}]}
      - 纯域名文本: 无前缀→DOMAIN，.前缀→DOMAIN-SUFFIX，+.前缀→DOMAIN-SUFFIX
    """
    resolved = _norm_link_fmt(fmt, text, for_ip=False)
    buckets = {k: [] for k in ("suffix", "domain", "keyword", "regexp",
                                "wildcard", "process", "process_re")}
    seen = {k: set() for k in buckets}

    if resolved == "clash":
        for raw_line in _iter_rule_lines(text):
            if "," not in raw_line:
                continue
            parts = [p.strip() for p in raw_line.split(",")]
            if len(parts) < 2:
                continue
            t, v = parts[0].upper(), parts[1]
            t = _QX_TYPE_REVERSE.get(t, t)  # 映射 QX HOST/HOST-SUFFIX/HOST-KEYWORD
            if not v or t in ("IP-CIDR", "IP-CIDR6", "IP-ASN"):
                continue
            bucket = TYPE_TO_BUCKET.get(t)
            if bucket is None or bucket in ("ipcidr", "asn"):
                continue
            if bucket == "suffix":
                v = v.lstrip(".")
            if v not in seen[bucket]:
                seen[bucket].add(v)
                buckets[bucket].append(v)
    else:  # domain-text：一行一个域名
        for line in (text or "").splitlines():
            s = line.strip().lstrip("-").strip().strip("'\"")  # 去除引号包裹
            if not s or s.startswith("#"):
                continue
            # TYPE,VALUE 格式（含 QX HOST/HOST-SUFFIX）
            if "," in s:
                parts = [p.strip() for p in s.split(",", 2)]
                t, v = parts[0].upper(), parts[1] if len(parts) > 1 else ""
                t = _QX_TYPE_REVERSE.get(t, t)
                if not v:
                    continue
                if t == "DOMAIN" and v not in seen["domain"]:
                    seen["domain"].add(v)
                    buckets["domain"].append(v)
                elif t == "DOMAIN-SUFFIX":
                    v = v.lstrip(".")
                    if v not in seen["suffix"]:
                        seen["suffix"].add(v)
                        buckets["suffix"].append(v)
                continue
            # 纯域名行：必须有点，不含空格/斜线/冒号
            if "." not in s or " " in s or "/" in s or ":" in s:
                continue
            # +. 前缀（QX/Surge DOMAIN-SUFFIX 写法）
            if s.startswith("+."):
                v = s[2:]
                if v and v not in seen["suffix"]:
                    seen["suffix"].add(v)
                    buckets["suffix"].append(v)
            # 前导点 → DOMAIN-SUFFIX
            elif s.startswith("."):
                v = s.lstrip(".")
                if v and v not in seen["suffix"]:
                    seen["suffix"].add(v)
                    buckets["suffix"].append(v)
            # 无前缀 → DOMAIN（精确子域名匹配）
            else:
                if s not in seen["domain"]:
                    seen["domain"].add(s)
                    buckets["domain"].append(s)

    return buckets


def parse_remote_ip_entries(text, fmt):
    """
    从远程内容提取 IP 类条目，返回 (ipcidr_lines, asn_lines)。
    只保留 IP-CIDR (IPv4) / IP-CIDR6 (IPv6) / IP-ASN。
    """
    resolved = _norm_link_fmt(fmt, text, for_ip=True)

    ipcidr, ipcidr_seen = [], set()
    asn,    asn_seen    = [], set()

    def add_cidr(v):
        v = v.strip()
        try:
            ipaddress.ip_network(v, strict=False)
            nv = v.lower()
            if nv not in ipcidr_seen:
                ipcidr_seen.add(nv)
                ipcidr.append(v)
        except ValueError:
            pass

    def add_asn(v):
        v = str(v).strip()
        if v and v not in asn_seen:
            asn_seen.add(v)
            asn.append(v)

    if resolved == "clash":
        for raw_line in _iter_rule_lines(text):
            if "," not in raw_line:
                # 裸 CIDR 行
                s = raw_line.strip()
                if s and ("/" in s or "::" in s):
                    add_cidr(s)
                continue
            parts = [p.strip() for p in raw_line.split(",")]
            if len(parts) < 2:
                continue
            t, v = parts[0].upper(), parts[1]
            if t in ("IP-CIDR", "IP-CIDR6"):
                add_cidr(v)
            elif t == "IP-ASN":
                add_asn(v)
    else:  # ip-text：一行一个 CIDR
        for line in (text or "").splitlines():
            s = line.strip().lstrip("-").strip().strip("'\"")  # 去除引号包裹
            if not s or s.startswith("#"):
                continue
            if "," in s:
                parts = [p.strip() for p in s.split(",", 2)]
                t, v = parts[0].upper(), parts[1] if len(parts) > 1 else ""
                if not v:
                    continue
                if t in ("IP-CIDR", "IP-CIDR6"):
                    add_cidr(v)
                elif t == "IP-ASN":
                    add_asn(v)
                continue
            # 裸 CIDR
            if "/" in s or "::" in s:
                add_cidr(s)

    return ipcidr, asn


# ═══════════════════════════════════════════════════════════════════════════════
# batch_domain_link：处理 clash/DOMAIN-Link，输出到 geo/geosite/
# ═══════════════════════════════════════════════════════════════════════════════

# bucket key → Clash rule type（用于对比现有 .list 文件）
_BUCKET_TO_TYPE = {
    "suffix":     "DOMAIN-SUFFIX",
    "domain":     "DOMAIN",
    "keyword":    "DOMAIN-KEYWORD",
    "regexp":     "DOMAIN-REGEX",
    "wildcard":   "DOMAIN-WILDCARD",
    "process":    "PROCESS-NAME",
    "process_re": "PROCESS-NAME-REGEX",
}


def _read_geosite_list_seen(list_path):
    """读取 geo/geosite/<tag>.list，返回 {type: set(norm_value)} 用于去重"""
    seen = {}
    for line in read_lines(list_path):
        # 格式: TYPE,value 或 TYPE,value,no-resolve
        parts = line.split(",")
        if len(parts) < 2:
            continue
        t = parts[0].strip().upper()
        v = parts[1].strip()
        seen.setdefault(t, set()).add(norm_value(t, v))
    return seen


def _rebuild_geosite_json_from_list(list_path, json_path):
    """从 geo/geosite/<tag>.list 全量重建 .json（sing-box v3）"""
    j_domain, j_suffix, j_keyword, j_regexp, j_cidrs = [], [], [], [], []
    for line in read_lines(list_path):
        parts = line.split(",")
        if len(parts) < 2:
            continue
        t, v = parts[0].strip().upper(), parts[1].strip()
        if t == "DOMAIN":
            j_domain.append(v)
        elif t == "DOMAIN-SUFFIX":
            j_suffix.append("." + v.lstrip("."))
        elif t == "DOMAIN-KEYWORD":
            j_keyword.append(v)
        elif t == "DOMAIN-REGEX":
            j_regexp.append(v)
        elif t in ("IP-CIDR", "IP-CIDR6"):
            j_cidrs.append(v)
    rule = {}
    if j_domain:   rule["domain"]          = j_domain
    if j_suffix:   rule["domain_suffix"]   = j_suffix
    if j_keyword:  rule["domain_keyword"]  = j_keyword
    if j_cidrs:    rule["ip_cidr"]         = j_cidrs
    if j_regexp:   rule["domain_regex"]    = j_regexp
    with open(json_path, "w") as f:
        json.dump({"version": 3, "rules": [rule] if rule else []},
                  f, ensure_ascii=False, separators=(",", ":"))
        f.write("\n")


def cmd_batch_domain_link(link_json_path, out_geosite, out_qx_geosite,
                          mrs_tasks_file, srs_tasks_file, workdir):
    """
    读取 clash/DOMAIN-Link JSON，拉取远程规则，提取域名类条目。
    去重优先级：Loyalsoldier → clash/*.yaml → DOMAIN-Link（对比前两者已写入的 .list 文件）
    - 若 geo/geosite/<name>.list 不存在（全新 tag）：直接 emit
    - 若已存在（Loyalsoldier/clash 已处理）：只追加新增条目，原有数据不动
    """
    if not os.path.isfile(link_json_path):
        print("[INFO] batch_domain_link: link file not found, skip")
        return

    with open(link_json_path, encoding="utf-8") as f:
        items = json.load(f)

    if not items:
        print("[INFO] batch_domain_link: empty, skip")
        return

    os.makedirs(out_geosite, exist_ok=True)
    os.makedirs(out_qx_geosite, exist_ok=True)

    mrs_tasks = []
    srs_tasks = []
    ok = 0

    for it in items:
        name = (it.get("name") or "").strip()
        url  = (it.get("url")  or "").strip()
        fmt  = (it.get("format") or "auto").strip()

        if not name or not url:
            print(f"[DOMAIN-LINK] skip invalid entry: {it}")
            continue

        print(f"[DOMAIN-LINK] {name}  fmt={fmt}")

        try:
            text = fetch_url(url)
        except Exception as e:
            print(f"[DOMAIN-LINK] {name}: fetch failed: {e}")
            continue

        raw_buckets = parse_remote_domain_entries(text, fmt)

        # ── 对比已有 .list 去重 ──────────────────────────────────────────────
        exist_list = os.path.join(out_geosite, f"{name}.list")
        exist_seen = _read_geosite_list_seen(exist_list)  # {} if file absent

        new_buckets = {k: [] for k in raw_buckets}
        for bkey, vals in raw_buckets.items():
            t = _BUCKET_TO_TYPE.get(bkey, bkey.upper())
            for v in vals:
                if norm_value(t, v) not in exist_seen.get(t, set()):
                    new_buckets[bkey].append(v)

        has_new = any(new_buckets.values())
        total_new = sum(len(v) for v in new_buckets.values())

        if not has_new:
            print(f"[DOMAIN-LINK] {name}: all entries already covered, skip")
            continue

        print(f"[DOMAIN-LINK] {name}: +{total_new} new entries  "
              f"(suffix={len(new_buckets['suffix'])} domain={len(new_buckets['domain'])} "
              f"keyword={len(new_buckets['keyword'])} regexp={len(new_buckets['regexp'])})")

        if not exist_seen:
            # ── 全新 tag：直接 emit ──────────────────────────────────────────
            emit_geosite_tag(name, new_buckets, "",
                             out_geosite, out_qx_geosite,
                             mrs_tasks, srs_tasks, workdir)
        else:
            # ── 已有数据：APPEND 模式（同 cmd_batch_clash_ip 风格）───────────
            dst_yaml = os.path.join(out_geosite, f"{name}.yaml")
            dst_list = os.path.join(out_geosite, f"{name}.list")
            dst_json = os.path.join(out_geosite, f"{name}.json")
            dst_srs  = os.path.join(out_geosite, f"{name}.srs")
            dst_mrs  = os.path.join(out_geosite, f"{name}.mrs")
            dst_qx   = os.path.join(out_qx_geosite, f"{name}.list")

            new_typed = []
            for bkey, vals in new_buckets.items():
                t = _BUCKET_TO_TYPE.get(bkey, bkey.upper())
                for v in vals:
                    new_typed.append((t, v))
            new_typed = sort_typed_lines(new_typed)

            # yaml 追加（geosite 侧 IP 加 no-resolve，此处纯域名类无需）
            with open(dst_yaml, "a", encoding="utf-8") as f:
                for t, v in new_typed:
                    f.write(f"  - {t},{v}\n")

            # list 追加
            with open(dst_list, "a", encoding="utf-8") as f:
                for t, v in new_typed:
                    f.write(f"{t},{v}\n")

            # json 从全量 list 重建
            _rebuild_geosite_json_from_list(dst_list, dst_json)
            srs_tasks.append(f"{dst_json}\t{dst_srs}")

            # mrs 全量重建（domain + suffix）
            mrs_lines = []
            for line in read_lines(dst_list):
                if line.startswith("DOMAIN,"):
                    mrs_lines.append(line[7:])
                elif line.startswith("DOMAIN-SUFFIX,"):
                    v = line[14:].split(",")[0]
                    mrs_lines.append("." + v.lstrip("."))
            if mrs_lines:
                mrs_src = os.path.join(workdir, "dl_mrs", f"{name}.txt")
                os.makedirs(os.path.dirname(mrs_src), exist_ok=True)
                write_lines(mrs_src, mrs_lines)
                mrs_tasks.append(f"domain\t{mrs_src}\t{dst_mrs}")

            # QX 追加（跳过不支持类型）
            qx_lines = []
            for t, v in new_typed:
                if t in QX_SKIP_TYPES:
                    continue
                qx_t = QX_TYPE_MAP.get(t)
                if qx_t:
                    qx_lines.append(f"{qx_t}, {v}")
            if qx_lines:
                with open(dst_qx, "a", encoding="utf-8") as f:
                    for line in qx_lines:
                        f.write(line + "\n")

        ok += 1

    print(f"[INFO] batch_domain_link: ok={ok}")

    with open(mrs_tasks_file, "a", encoding="utf-8") as f:
        for line in mrs_tasks:
            f.write(line + "\n")
    with open(srs_tasks_file, "a", encoding="utf-8") as f:
        for line in srs_tasks:
            f.write(line + "\n")


# ═══════════════════════════════════════════════════════════════════════════════
# batch_ip_link：处理 clash-ip/IP-Link，输出到 geo/geoip/
# ═══════════════════════════════════════════════════════════════════════════════

def cmd_batch_ip_link(link_json_path, out_geoip, out_qx_geoip,
                      mrs_tasks_file, srs_tasks_file, workdir):
    """
    读取 clash-ip/IP-Link JSON，拉取远程规则，提取 IPv4/IPv6/ASN 条目。
    去重优先级：Loyalsoldier → clash-ip/*.yaml → IP-Link（对比前两者已写入的 .list 文件）
    - 若 geo/geoip/<name>.list 不存在（全新 tag）：直接 emit
    - 若已存在：只追加新增条目（同 cmd_batch_clash_ip 风格）
    """
    if not os.path.isfile(link_json_path):
        print("[INFO] batch_ip_link: link file not found, skip")
        return

    with open(link_json_path, encoding="utf-8") as f:
        items = json.load(f)

    if not items:
        print("[INFO] batch_ip_link: empty, skip")
        return

    os.makedirs(out_geoip, exist_ok=True)
    os.makedirs(out_qx_geoip, exist_ok=True)

    mrs_tasks = []
    srs_tasks = []
    ok = 0

    for it in items:
        name = (it.get("name") or "").strip()
        url  = (it.get("url")  or "").strip()
        fmt  = (it.get("format") or "auto").strip()

        if not name or not url:
            print(f"[IP-LINK] skip invalid entry: {it}")
            continue

        print(f"[IP-LINK] {name}  fmt={fmt}")

        try:
            text = fetch_url(url)
        except Exception as e:
            print(f"[IP-LINK] {name}: fetch failed: {e}")
            continue

        all_cidr, all_asn = parse_remote_ip_entries(text, fmt)

        if not all_cidr and not all_asn:
            print(f"[IP-LINK] {name}: no IP entries, skip")
            continue

        # ── 对比已有 .list 去重 ──────────────────────────────────────────────
        exist_list = os.path.join(out_geoip, f"{name}.list")
        exist_cidr, exist_asn = set(), set()
        for line in read_lines(exist_list):
            if line.startswith("IP-CIDR6,"):
                exist_cidr.add(line[9:].lower())
            elif line.startswith("IP-CIDR,"):
                exist_cidr.add(line[8:].lower())
            elif line.startswith("IP-ASN,"):
                exist_asn.add(line[7:])

        new_cidr = [v for v in all_cidr if v.lower() not in exist_cidr]
        new_asn  = [v for v in all_asn  if v not in exist_asn]

        if not new_cidr and not new_asn:
            print(f"[IP-LINK] {name}: all entries already covered, skip")
            continue

        print(f"[IP-LINK] {name}: +{len(new_cidr)} CIDRs  +{len(new_asn)} ASNs")

        if not exist_cidr and not exist_asn:
            # ── 全新 tag：直接 emit ──────────────────────────────────────────
            emit_geoip_tag(name, all_cidr, all_asn,
                           out_geoip, out_qx_geoip,
                           mrs_tasks, srs_tasks)
            if all_cidr:
                mrs_src = os.path.join(workdir, "il_mrs", f"{name}.txt")
                os.makedirs(os.path.dirname(mrs_src), exist_ok=True)
                write_lines(mrs_src, all_cidr)
                mrs_tasks.append(
                    f"ipcidr\t{mrs_src}\t{os.path.join(out_geoip, f'{name}.mrs')}"
                )
        else:
            # ── 已有数据：APPEND 模式（同 cmd_batch_clash_ip）────────────────
            dst_yaml = os.path.join(out_geoip, f"{name}.yaml")
            dst_list = os.path.join(out_geoip, f"{name}.list")
            dst_json = os.path.join(out_geoip, f"{name}.json")
            dst_srs  = os.path.join(out_geoip, f"{name}.srs")
            dst_mrs  = os.path.join(out_geoip, f"{name}.mrs")
            dst_qx   = os.path.join(out_qx_geoip, f"{name}.list")

            # 统一排序：IPv4 → IPv6 → ASN
            new_typed = sort_typed_lines(
                [(("IP-CIDR6" if ":" in v else "IP-CIDR"), v) for v in new_cidr] +
                [("IP-ASN", v) for v in new_asn]
            )

            # yaml 追加（geoip 侧不加 no-resolve）
            yaml_lines = []
            if not os.path.isfile(dst_yaml):
                yaml_lines.append("payload:")
            for t, v in new_typed:
                yaml_lines.append(f"  - {t},{v}")
            with open(dst_yaml, "a", encoding="utf-8") as f:
                for line in yaml_lines:
                    f.write(line + "\n")

            # list 追加
            with open(dst_list, "a", encoding="utf-8") as f:
                for t, v in new_typed:
                    f.write(f"{t},{v}\n")

            # json 从全量 list 重建
            all_cidrs_full = []
            for line in read_lines(dst_list):
                if line.startswith("IP-CIDR6,"):
                    all_cidrs_full.append(line[9:])
                elif line.startswith("IP-CIDR,"):
                    all_cidrs_full.append(line[8:])
            rule = {"ip_cidr": all_cidrs_full} if all_cidrs_full else {}
            with open(dst_json, "w") as f:
                json.dump({"version": 3, "rules": [rule] if rule else []},
                          f, ensure_ascii=False, separators=(",", ":"))
                f.write("\n")

            srs_tasks.append(f"{dst_json}\t{dst_srs}")

            # mrs 全量重建
            if all_cidrs_full:
                mrs_src = os.path.join(workdir, "il_mrs", f"{name}.txt")
                os.makedirs(os.path.dirname(mrs_src), exist_ok=True)
                write_lines(mrs_src, all_cidrs_full)
                mrs_tasks.append(f"ipcidr\t{mrs_src}\t{dst_mrs}")

            # QX 追加（跳过 ASN，加 no-resolve）
            qx_new = [(t, v) for t, v in new_typed if t != "IP-ASN"]
            if qx_new:
                with open(dst_qx, "a", encoding="utf-8") as f:
                    for t, v in qx_new:
                        f.write(f"{t}, {v}, no-resolve\n")

        ok += 1

    print(f"[INFO] batch_ip_link: ok={ok}")

    with open(mrs_tasks_file, "a", encoding="utf-8") as f:
        for line in mrs_tasks:
            f.write(line + "\n")
    with open(srs_tasks_file, "a", encoding="utf-8") as f:
        for line in srs_tasks:
            f.write(line + "\n")


# ═══════════════════════════════════════════════════════════════════════════════
# batch_clash_ip：处理 clash-ip/ 目录，合并进 geo/geoip/ 五格式 + QX
# ═══════════════════════════════════════════════════════════════════════════════

def cmd_batch_clash_ip(clash_ip_dir, out_geoip, out_qx_geoip,
                       mrs_tasks_file, srs_tasks_file, workdir):
    if not os.path.isdir(clash_ip_dir):
        print("[INFO] clash-ip: ok=0")
        return

    mrs_tasks = []
    srs_tasks = []
    ok = 0

    for cyaml in sorted(glob.glob(os.path.join(clash_ip_dir, "*.yaml"))):
        tag = os.path.basename(cyaml).removesuffix(".yaml")
        print(f"[CLASH-IP] processing {tag} <- {cyaml}")

        cb = parse_clash_to_buckets(cyaml)
        ci_ipcidr = cb.get("ipcidr", [])
        ci_asn = cb.get("asn", [])

        if not ci_ipcidr and not ci_asn:
            print(f"[CLASH-IP] {tag}: no IP entries, skip")
            continue

        # 现有数据（从已生成的 list 文件读取）
        exist_list = os.path.join(out_geoip, f"{tag}.list")
        exist_cidr = set()
        exist_asn = set()
        for line in read_lines(exist_list):
            if line.startswith("IP-CIDR6,"):
                exist_cidr.add(line[9:].lower())
            elif line.startswith("IP-CIDR,"):
                exist_cidr.add(line[8:].lower())
            elif line.startswith("IP-ASN,"):
                exist_asn.add(line[7:])

        # 计算新增
        new_cidr = []
        new_cidr_seen = set()
        for v in ci_ipcidr:
            nv = v.lower()
            if nv not in exist_cidr and nv not in new_cidr_seen:
                new_cidr_seen.add(nv)
                new_cidr.append(v)

        new_asn = []
        new_asn_seen = set()
        for v in ci_asn:
            if v not in exist_asn and v not in new_asn_seen:
                new_asn_seen.add(v)
                new_asn.append(v)

        if not new_cidr and not new_asn:
            print(f"[CLASH-IP] {tag}: no new entries, skip")
            continue

        print(f"[CLASH-IP] {tag}: +{len(new_cidr)} CIDRs  +{len(new_asn)} ASNs")

        dst_yaml = os.path.join(out_geoip, f"{tag}.yaml")
        dst_list = os.path.join(out_geoip, f"{tag}.list")
        dst_json = os.path.join(out_geoip, f"{tag}.json")
        dst_srs  = os.path.join(out_geoip, f"{tag}.srs")
        dst_mrs  = os.path.join(out_geoip, f"{tag}.mrs")
        dst_qx   = os.path.join(out_qx_geoip, f"{tag}.list")

        # 统一排序：IPv4 → IPv6 → ASN
        new_typed = sort_typed_lines(
            [(("IP-CIDR6" if ":" in v else "IP-CIDR"), v) for v in new_cidr] +
            [("IP-ASN", v) for v in new_asn]
        )

        # geoip 侧不加 no-resolve
        # yaml 追加
        yaml_append = []
        if not os.path.isfile(dst_yaml):
            yaml_append.append("payload:")
        for t, v in new_typed:
            yaml_append.append(f"  - {t},{v}")
        with open(dst_yaml, "a", encoding="utf-8") as f:
            for line in yaml_append:
                f.write(line + "\n")

        # list 追加
        with open(dst_list, "a", encoding="utf-8") as f:
            for t, v in new_typed:
                f.write(f"{t},{v}\n")

        # json 重建（从 list，排序后输出）
        all_typed = []
        for line in read_lines(dst_list):
            if line.startswith("IP-CIDR6,"):
                all_typed.append(("IP-CIDR6", line[9:]))
            elif line.startswith("IP-CIDR,"):
                all_typed.append(("IP-CIDR", line[8:]))
            elif line.startswith("IP-ASN,"):
                all_typed.append(("IP-ASN", line[7:]))
        all_typed = sort_typed_lines(all_typed)
        all_cidrs = [v for t, v in all_typed if t in ("IP-CIDR", "IP-CIDR6")]
        rule = {"ip_cidr": all_cidrs} if all_cidrs else {}
        with open(dst_json, "w") as f:
            json.dump({"version": 3, "rules": [rule] if rule else []},
                      f, ensure_ascii=False, separators=(",", ":"))
            f.write("\n")

        srs_tasks.append(f"{dst_json}\t{dst_srs}")

        # mrs（全量重编译）
        all_cidr_list = []
        for line in read_lines(dst_list):
            if line.startswith("IP-CIDR6,"):
                all_cidr_list.append(line[9:])
            elif line.startswith("IP-CIDR,"):
                all_cidr_list.append(line[8:])
        if all_cidr_list:
            mrs_src = os.path.join(workdir, "ci_mrs", f"{tag}.txt")
            os.makedirs(os.path.dirname(mrs_src), exist_ok=True)
            write_lines(mrs_src, all_cidr_list)
            mrs_tasks.append(f"ipcidr\t{mrs_src}\t{dst_mrs}")

        # QX list 追加（跳过 ASN，加 no-resolve）
        qx_append = [(t, v) for t, v in new_typed if t != "IP-ASN"]
        if qx_append:
            with open(dst_qx, "a", encoding="utf-8") as f:
                for t, v in qx_append:
                    f.write(f"{t}, {v}, no-resolve\n")

        ok += 1

    print(f"[INFO] clash-ip: ok={ok}")

    with open(mrs_tasks_file, "a", encoding="utf-8") as f:
        for line in mrs_tasks:
            f.write(line + "\n")
    with open(srs_tasks_file, "a", encoding="utf-8") as f:
        for line in srs_tasks:
            f.write(line + "\n")


# ═══════════════════════════════════════════════════════════════════════════════
# 兼容旧命令（shell 零星调用）
# ═══════════════════════════════════════════════════════════════════════════════

def cmd_parse_clash(yaml_path, out_dir, tag):
    buckets = parse_clash_to_buckets(yaml_path)
    os.makedirs(out_dir, exist_ok=True)
    for bname, items in buckets.items():
        out_path = os.path.join(out_dir, f"{tag}.{bname}.clash.txt")
        write_lines(out_path, items)

def cmd_merge_dedup(geo_file, clash_file, out_file, bucket_type):
    result = merge_dedup_lists(read_lines(geo_file), read_lines(clash_file), bucket_type)
    write_lines(out_file, result)

def cmd_diff_new_entries(exist_file, new_file, out_file, entry_type):
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
    write_lines(out_file, new)

def cmd_rebuild_json_from_list(list_file, json_dst):
    cidrs = []
    for line in read_lines(list_file):
        if line.startswith("IP-CIDR6,"):
            cidrs.append(line[9:])
        elif line.startswith("IP-CIDR,"):
            cidrs.append(line[8:])
    rule = {"ip_cidr": cidrs} if cidrs else {}
    with open(json_dst, "w") as f:
        json.dump({"version": 3, "rules": [rule] if rule else []},
                  f, ensure_ascii=False, separators=(",", ":"))
        f.write("\n")


# ═══════════════════════════════════════════════════════════════════════════════
# 主入口
# ═══════════════════════════════════════════════════════════════════════════════

COMMANDS = {
    "batch_geosite":          lambda a: cmd_batch_geosite(a[0], a[1], a[2], a[3], a[4], a[5], a[6]),
    "batch_geoip":            lambda a: cmd_batch_geoip(a[0], a[1], a[2], a[3], a[4], a[5], a[6], a[7]),
    "batch_clash_ip":         lambda a: cmd_batch_clash_ip(a[0], a[1], a[2], a[3], a[4], a[5]),
    "batch_domain_link":      lambda a: cmd_batch_domain_link(a[0], a[1], a[2], a[3], a[4], a[5]),
    "batch_ip_link":          lambda a: cmd_batch_ip_link(a[0], a[1], a[2], a[3], a[4], a[5]),
    "parse_clash":            lambda a: cmd_parse_clash(a[0], a[1], a[2]),
    "merge_dedup":            lambda a: cmd_merge_dedup(a[0], a[1], a[2], a[3]),
    "diff_new_entries":       lambda a: cmd_diff_new_entries(a[0], a[1], a[2], a[3]),
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
        sys.exit(1)

    COMMANDS[cmd](args)

if __name__ == "__main__":
    main()