#!/usr/bin/env bash
# sync_loy_geo_mrs.sh
# 
# 架构说明：【全能融合 + 智能分发】
# 1. 自动收集所有 Tag (来自 geosite.dat, geoip.dat 以及 clash/*.yaml)
# 2. 对每个 Tag，提取所有维度的规则 (域名、IP、进程等) 并去重合并
# 3. 输出策略：
#    - geo/geosite/<tag>.mrs    -> 仅限域名类规则 (Mihomo behavior: domain)
#    - geo/geoip/<tag>.mrs      -> 仅限 IP 类规则   (Mihomo behavior: ipcidr)
#    - geo/geosite/<tag>.yaml   -> 混合所有规则 (Clash 全家桶直接引用这一个即可)
#    - geo/geosite/<tag>.list   -> 混合所有规则
#    - geo/geosite/<tag>.json   -> 混合所有规则 (Sing-box v3 源文件)
#    - geo/geosite/<tag>.srs    -> 混合所有规则 (Sing-box 编译后)
#    - QX/geosite/<tag>.list    -> 混合支持的规则 (Quantumult X 专用)
# 
# * 彻底废弃 geoip 下的 yaml/list/json/srs，用户配置仅需引用 geosite 目录下的统一文件。

set -euo pipefail

GEOIP_URL='https://cdn.jsdelivr.net/gh/Loyalsoldier/geoip@release/geoip.dat'
GEOSITE_URL='https://cdn.jsdelivr.net/gh/Loyalsoldier/v2ray-rules-dat@release/geosite.dat'

OUT_GEOSITE='geo/geosite'
OUT_GEOIP='geo/geoip'
OUT_QX_GEOSITE='QX/geosite'

CLASH_DIR="${CLASH_DIR:-clash}"

MIHOMO_BIN="${MIHOMO_BIN:-./mihomo}"
SINGBOX_BIN="${SINGBOX_BIN:-./sing-box}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "$REPO_ROOT"

echo "[INFO] repo root: $(pwd)"

command -v v2dat       >/dev/null 2>&1 || { echo "ERROR: v2dat not found";        exit 1; }
[ -x "$MIHOMO_BIN"  ]                  || { echo "ERROR: mihomo not executable";   exit 1; }
[ -x "$SINGBOX_BIN" ]                  || { echo "ERROR: sing-box not executable"; exit 1; }
command -v python3     >/dev/null 2>&1 || { echo "ERROR: python3 not found";       exit 1; }

# ── 工作目录 ──────────────────────────────────────────────────────────────────
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

# ── 1. 下载 & 解包 ────────────────────────────────────────────────────────────
echo "[1/4] Download dat files..."
curl -fsSL --retry 3 --retry-delay 2 "$GEOIP_URL"   -o "$WORKDIR/geoip.dat"
curl -fsSL --retry 3 --retry-delay 2 "$GEOSITE_URL" -o "$WORKDIR/geosite.dat"

echo "[2/4] Unpack dat -> txt..."
mkdir -p "$WORKDIR/geoip_txt" "$WORKDIR/geosite_txt"
v2dat unpack geoip   -o "$WORKDIR/geoip_txt"   "$WORKDIR/geoip.dat"
v2dat unpack geosite -o "$WORKDIR/geosite_txt" "$WORKDIR/geosite.dat"

# ── 3. 清理并创建输出目录 ─────────────────────────────────────────────────────
echo "[3/4] Clean output dirs..."
rm -rf "$OUT_GEOSITE" "$OUT_GEOIP" "$OUT_QX_GEOSITE"
mkdir -p "$OUT_GEOSITE" "$OUT_GEOIP" "$OUT_QX_GEOSITE"

# ── 4. 收集所有的 Tags ────────────────────────────────────────────────────────
declare -A ALL_TAGS=()

for f in "$WORKDIR/geosite_txt"/*.txt; do
  [[ -f "$f" ]] || continue
  base="$(basename "$f")"; tag="${base#geosite_}"; tag="${tag%.txt}"
  ALL_TAGS["$tag"]=1
done

for f in "$WORKDIR/geoip_txt"/*.txt; do
  [[ -f "$f" ]] || continue
  base="$(basename "$f")"; tag="${base#geoip_}"; tag="${tag%.txt}"
  ALL_TAGS["$tag"]=1
done

if [[ -d "$CLASH_DIR" ]]; then
  for f in "$CLASH_DIR"/*.yaml; do
    [[ -f "$f" ]] || continue
    tag="$(basename "$f" .yaml)"
    ALL_TAGS["$tag"]=1
  done
fi

TOTAL_TAGS=${#ALL_TAGS[@]}
echo "[INFO] Found $TOTAL_TAGS unique tags to process."

# ==============================================================================
# 辅助函数：MRS & SRS 编译
# ==============================================================================
compile_mrs() {
  local behavior="$1" src="$2" dst="$3"
  if [[ -s "$src" ]]; then
    local tmp="${dst}.tmp"
    "$MIHOMO_BIN" convert-ruleset "$behavior" text "$src" "$tmp" >/dev/null 2>&1 || true
    if [[ -s "$tmp" ]]; then
      mv -f "$tmp" "$dst"
    else
      rm -f "$tmp"
    fi
  fi
}

compile_srs() {
  local json="$1" srs="$2"
  if [[ -s "$json" ]]; then
    local tmp="${srs}.tmp"
    "$SINGBOX_BIN" rule-set compile --output "$tmp" "$json" >/dev/null 2>&1 || true
    if [[ -s "$tmp" ]]; then
      mv -f "$tmp" "$srs"
    else
      rm -f "$tmp"
    fi
  fi
}

# ==============================================================================
# 核心处理引擎 (Python 驱动)
# ==============================================================================
echo "[4/4] Merging and generating files..."

# 将 Python 处理脚本写入临时文件以提升执行效率
CAT_PY_SCRIPT="$WORKDIR/processor.py"
cat << 'PYEOF' > "$CAT_PY_SCRIPT"
import sys, os, re, json

tag, f_geosite, f_geoip, f_clash, out_geo_dir, out_ip_dir, out_qx_dir = sys.argv[1:8]

buckets = {
    'suffix': set(), 'domain': set(), 'keyword': set(), 'regexp': set(),
    'ipcidr': set(), 'process': set(), 'process_re': set(), 'asn': set()
}

# 1. 解析 geosite txt
if os.path.exists(f_geosite):
    with open(f_geosite, 'r', encoding='utf-8') as f:
        for line in f:
            line = line.strip()
            if not line: continue
            if line.startswith('keyword:'): buckets['keyword'].add(line[8:])
            elif line.startswith('regexp:'): buckets['regexp'].add(line[7:])
            elif line.startswith('full:'): buckets['domain'].add(line[5:])
            else: buckets['suffix'].add(line.lstrip('.'))

# 2. 解析 geoip txt
if os.path.exists(f_geoip):
    with open(f_geoip, 'r', encoding='utf-8') as f:
        for line in f:
            line = line.strip()
            if line: buckets['ipcidr'].add(line.lower())

# 3. 解析 clash yaml (宽松提取)
if os.path.exists(f_clash):
    re_item = re.compile(r'^\s*-\s+(.+)$')
    with open(f_clash, 'r', encoding='utf-8') as f:
        for raw in f:
            m = re_item.match(raw.rstrip())
            if not m: continue
            entry = re.sub(r'\s+#.*$', '', m.group(1).strip())
            if not entry: continue
            parts = [p.strip() for p in entry.split(',')]
            if len(parts) < 2: continue
            rt, rv = parts[0].upper(), parts[1]
            
            if rt == 'DOMAIN-SUFFIX': buckets['suffix'].add(rv.lstrip('.'))
            elif rt == 'DOMAIN': buckets['domain'].add(rv)
            elif rt == 'DOMAIN-KEYWORD': buckets['keyword'].add(rv)
            elif rt == 'DOMAIN-REGEX': buckets['regexp'].add(rv)
            elif rt in ('IP-CIDR', 'IP-CIDR6'): buckets['ipcidr'].add(rv.lower())
            elif rt == 'PROCESS-NAME': buckets['process'].add(rv)
            elif rt == 'PROCESS-NAME-REGEX': buckets['process_re'].add(rv)
            elif rt == 'IP-ASN': buckets['asn'].add(rv)

# 检查是否全空
if all(not v for v in buckets.values()):
    sys.exit(0)

# 转换为排序列表
s_suf = sorted(list(buckets['suffix']))
s_dom = sorted(list(buckets['domain']))
s_kwd = sorted(list(buckets['keyword']))
s_reg = sorted(list(buckets['regexp']))
s_ip  = sorted(list(buckets['ipcidr']))
s_pro = sorted(list(buckets['process']))
s_pre = sorted(list(buckets['process_re']))
s_asn = sorted(list(buckets['asn']))

# === 输出生成 ===

# A. Mihomo MRS 纯文本源文件
if s_suf or s_dom:
    with open(f"{out_geo_dir}/{tag}.mrs.txt", "w") as f:
        f.write("\n".join(s_suf + s_dom) + "\n")

if s_ip:
    with open(f"{out_ip_dir}/{tag}.mrs.txt", "w") as f:
        f.write("\n".join(s_ip) + "\n")

# B. 统一 YAML
with open(f"{out_geo_dir}/{tag}.yaml", "w") as f:
    f.write("payload:\n")
    for x in s_suf: f.write(f"  - DOMAIN-SUFFIX,{x}\n")
    for x in s_dom: f.write(f"  - DOMAIN,{x}\n")
    for x in s_kwd: f.write(f"  - DOMAIN-KEYWORD,{x}\n")
    for x in s_reg: f.write(f"  - DOMAIN-REGEX,{x}\n")
    for x in s_ip:
        if ":" in x: f.write(f"  - IP-CIDR6,{x}\n")
        else: f.write(f"  - IP-CIDR,{x}\n")
    for x in s_pro: f.write(f"  - PROCESS-NAME,{x}\n")
    for x in s_pre: f.write(f"  - PROCESS-NAME-REGEX,{x}\n")
    for x in s_asn: f.write(f"  - IP-ASN,{x}\n")

# C. 统一 LIST (Clash/Surge)
with open(f"{out_geo_dir}/{tag}.list", "w") as f:
    for x in s_suf: f.write(f"DOMAIN-SUFFIX,{x}\n")
    for x in s_dom: f.write(f"DOMAIN,{x}\n")
    for x in s_kwd: f.write(f"DOMAIN-KEYWORD,{x}\n")
    for x in s_reg: f.write(f"DOMAIN-REGEX,{x}\n")
    for x in s_ip:
        if ":" in x: f.write(f"IP-CIDR6,{x}\n")
        else: f.write(f"IP-CIDR,{x}\n")
    for x in s_pro: f.write(f"PROCESS-NAME,{x}\n")
    for x in s_pre: f.write(f"PROCESS-NAME-REGEX,{x}\n")
    for x in s_asn: f.write(f"IP-ASN,{x}\n")

# D. 统一 Quantumult X LIST
with open(f"{out_qx_dir}/{tag}.list", "w") as f:
    for x in s_suf: f.write(f"HOST-SUFFIX, {x}\n")
    for x in s_dom: f.write(f"HOST, {x}\n")
    for x in s_kwd: f.write(f"HOST-KEYWORD, {x}\n")
    for x in s_ip:
        if ":" in x: f.write(f"IP-CIDR6, {x}\n")
        else: f.write(f"IP-CIDR, {x}\n")

# E. 统一 Sing-box JSON (Version 3) 
# 逻辑说明：Sing-box 中同一 rule 字典里的不同字段是 AND 关系。
# 为了实现 OR 关系，需要将域名、IP、进程分别作为独立的字典放入 rules 列表中。
rules_list = []

rule_dom = {}
if s_dom: rule_dom["domain"] = s_dom
if s_suf: rule_dom["domain_suffix"] = s_suf
if s_kwd: rule_dom["domain_keyword"] = s_kwd
if s_reg: rule_dom["domain_regex"] = s_reg
if rule_dom: rules_list.append(rule_dom)

rule_ip = {}
if s_ip: rule_ip["ip_cidr"] = s_ip
if s_asn: rule_ip["source_ip_asn"] = [int(a) if a.isdigit() else a for a in s_asn]
if rule_ip: rules_list.append(rule_ip)

rule_pro = {}
if s_pro: rule_pro["process_name"] = s_pro
if s_pre: rule_pro["process_name_regex"] = s_pre
if rule_pro: rules_list.append(rule_pro)

sb_out = {"version": 3, "rules": rules_list}
with open(f"{out_geo_dir}/{tag}.json", "w", encoding='utf-8') as f:
    json.dump(sb_out, f, ensure_ascii=False, separators=(',', ':'))

PYEOF

# ==============================================================================
# 批量执行
# ==============================================================================
count=0
for tag in "${!ALL_TAGS[@]}"; do
  f_geosite="$WORKDIR/geosite_txt/geosite_${tag}.txt"
  [[ -f "$f_geosite" ]] || f_geosite="$WORKDIR/geosite_txt/${tag}.txt"
  
  f_geoip="$WORKDIR/geoip_txt/geoip_${tag}.txt"
  [[ -f "$f_geoip" ]] || f_geoip="$WORKDIR/geoip_txt/${tag}.txt"
  
  f_clash="${CLASH_DIR}/${tag}.yaml"

  # 调用 Python 进行数据清洗和文件生成
  python3 "$CAT_PY_SCRIPT" "$tag" "$f_geosite" "$f_geoip" "$f_clash" "$OUT_GEOSITE" "$OUT_GEOIP" "$OUT_QX_GEOSITE"

  # 编译生成 MRS 和 SRS 文件
  mrs_domain_src="${OUT_GEOSITE}/${tag}.mrs.txt"
  if [[ -f "$mrs_domain_src" ]]; then
    compile_mrs domain "$mrs_domain_src" "${OUT_GEOSITE}/${tag}.mrs"
    rm -f "$mrs_domain_src"
  fi

  mrs_ip_src="${OUT_GEOIP}/${tag}.mrs.txt"
  if [[ -f "$mrs_ip_src" ]]; then
    compile_mrs ipcidr "$mrs_ip_src" "${OUT_GEOIP}/${tag}.mrs"
    rm -f "$mrs_ip_src"
  fi

  sb_json="${OUT_GEOSITE}/${tag}.json"
  if [[ -f "$sb_json" ]]; then
    compile_srs "$sb_json" "${OUT_GEOSITE}/${tag}.srs"
  fi

  count=$((count+1))
  # 进度条提示（每 100 个打印一次）
  if (( count % 100 == 0 )); then
    echo "  Processed $count / $TOTAL_TAGS tags..."
  fi
done

echo "[INFO] Finished generating files."

echo "[Summary]"
echo "  geo/geosite/        mrs  : $(find "$OUT_GEOSITE"    -name '*.mrs'  | wc -l | tr -d ' ')"
echo "  geo/geosite/        yaml : $(find "$OUT_GEOSITE"    -name '*.yaml' | wc -l | tr -d ' ')"
echo "  geo/geosite/        list : $(find "$OUT_GEOSITE"    -name '*.list' | wc -l | tr -d ' ')"
echo "  geo/geosite/        json : $(find "$OUT_GEOSITE"    -name '*.json' | wc -l | tr -d ' ')"
echo "  geo/geosite/        srs  : $(find "$OUT_GEOSITE"    -name '*.srs'  | wc -l | tr -d ' ')"
echo "  geo/geoip/          mrs  : $(find "$OUT_GEOIP"      -name '*.mrs'  | wc -l | tr -d ' ')"
echo "  QX/geosite/         list : $(find "$OUT_QX_GEOSITE" -name '*.list' | wc -l | tr -d ' ')"
echo "Done."
