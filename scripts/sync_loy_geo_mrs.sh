#!/usr/bin/env bash
# sync_loy_geo_mrs.sh
# 修正版：完美处理 Sing-box 后缀点号 + 强制 IP 融合进 Geosite 
set -euo pipefail

GEOIP_URL='https://cdn.jsdelivr.net/gh/Loyalsoldier/geoip@release/geoip.dat'
GEOSITE_URL='https://cdn.jsdelivr.net/gh/Loyalsoldier/v2ray-rules-dat@release/geosite.dat'

OUT_GEOSITE='geo/geosite'
OUT_GEOIP='geo/geoip'
OUT_QX_GEOSITE='QX/geosite'
CLASH_DIR="${CLASH_DIR:-clash}"
MIHOMO_BIN="${MIHOMO_BIN:-./mihomo}"
SINGBOX_BIN="${SINGBOX_BIN:-./sing-box}"

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

echo "[1/4] Downloading..."
curl -fsSL "$GEOIP_URL" -o "$WORKDIR/geoip.dat"
curl -fsSL "$GEOSITE_URL" -o "$WORKDIR/geosite.dat"

echo "[2/4] Unpacking..."
mkdir -p "$WORKDIR/geoip_txt" "$WORKDIR/geosite_txt"
v2dat unpack geoip -o "$WORKDIR/geoip_txt" "$WORKDIR/geoip.dat"
v2dat unpack geosite -o "$WORKDIR/geosite_txt" "$WORKDIR/geosite.dat"

rm -rf "$OUT_GEOSITE" "$OUT_GEOIP" "$OUT_QX_GEOSITE"
mkdir -p "$OUT_GEOSITE" "$OUT_GEOIP" "$OUT_QX_GEOSITE"

# 收集 Tags
declare -A ALL_TAGS=()
for f in "$WORKDIR/geosite_txt"/*.txt "$WORKDIR/geoip_txt"/*.txt; do
  [[ -f "$f" ]] || continue
  base="$(basename "$f")"; tag="${base#geosite_}"; tag="${tag#geoip_}"; tag="${tag%.txt}"
  ALL_TAGS["$tag"]=1
done
if [[ -d "$CLASH_DIR" ]]; then
  for f in "$CLASH_DIR"/*.yaml; do
    [[ -f "$f" ]] && ALL_TAGS["$(basename "$f" .yaml)"]=1
  done
fi

# 核心 Python 处理器
CAT_PY_SCRIPT="$WORKDIR/processor.py"
cat << 'PYEOF' > "$CAT_PY_SCRIPT"
import sys, os, re, json

tag, f_geosite, f_geoip, f_clash, out_geo_dir, out_ip_dir, out_qx_dir = sys.argv[1:8]
buckets = {k: set() for k in ['suffix', 'domain', 'keyword', 'regexp', 'ipcidr', 'process', 'process_re', 'asn']}

# 解析函数：处理后缀点号规范
def add_suffix(val):
    val = val.strip().lower()
    return f".{val.lstrip('.')}" if val else ""

def add_domain(val):
    return val.strip().lstrip('.').lower()

# 1. Geosite TXT
if os.path.exists(f_geosite):
    with open(f_geosite, 'r') as f:
        for line in f:
            line = line.strip()
            if not line: continue
            if line.startswith('keyword:'): buckets['keyword'].add(line[8:])
            elif line.startswith('regexp:'): buckets['regexp'].add(line[7:])
            elif line.startswith('full:'): buckets['domain'].add(add_domain(line[5:]))
            else: buckets['suffix'].add(add_suffix(line))

# 2. GeoIP TXT
if os.path.exists(f_geoip):
    with open(f_geoip, 'r') as f:
        for line in f:
            if line.strip(): buckets['ipcidr'].add(line.strip().lower())

# 3. Clash YAML (提取所有类型)
if os.path.exists(f_clash):
    re_item = re.compile(r'^\s*-\s+(.+)$')
    with open(f_clash, 'r') as f:
        for raw in f:
            m = re_item.match(raw.rstrip())
            if not m: continue
            entry = re.sub(r'\s+#.*$', '', m.group(1).strip())
            parts = [p.strip() for p in entry.split(',')]
            if len(parts) < 2: continue
            rt, rv = parts[0].upper(), parts[1]
            if rt == 'DOMAIN-SUFFIX': buckets['suffix'].add(add_suffix(rv))
            elif rt == 'DOMAIN': buckets['domain'].add(add_domain(rv))
            elif rt == 'DOMAIN-KEYWORD': buckets['keyword'].add(rv)
            elif rt == 'DOMAIN-REGEX': buckets['regexp'].add(rv)
            elif rt in ('IP-CIDR', 'IP-CIDR6'): buckets['ipcidr'].add(rv.lower())
            elif rt == 'PROCESS-NAME': buckets['process'].add(rv)
            elif rt == 'PROCESS-NAME-REGEX': buckets['process_re'].add(rv)
            elif rt == 'IP-ASN': buckets['asn'].add(rv)

if all(not v for v in buckets.values()): sys.exit(0)

# 排序
s_suf, s_dom, s_kwd, s_reg = sorted(list(buckets['suffix'])), sorted(list(buckets['domain'])), sorted(list(buckets['keyword'])), sorted(list(buckets['regexp']))
s_ip, s_pro, s_pre, s_asn = sorted(list(buckets['ipcidr'])), sorted(list(buckets['process'])), sorted(list(buckets['process_re'])), sorted(list(buckets['asn']))

# A. MRS 源文件 (严格区分 Domain 和 IP)
if s_suf or s_dom:
    with open(f"{out_geo_dir}/{tag}.mrs.txt", "w") as f:
        # MRS 格式不强制要求点号，但为了兼容性通常保留 lstrip
        f.write("\n".join([x.lstrip('.') for x in s_suf] + s_dom) + "\n")
if s_ip:
    with open(f"{out_ip_dir}/{tag}.mrs.txt", "w") as f:
        f.write("\n".join(s_ip) + "\n")

# B. 统一 YAML (融合所有规则)
with open(f"{out_geo_dir}/{tag}.yaml", "w") as f:
    f.write("payload:\n")
    for x in s_suf: f.write(f"  - DOMAIN-SUFFIX,{x.lstrip('.')}\n")
    for x in s_dom: f.write(f"  - DOMAIN,{x}\n")
    for x in s_kwd: f.write(f"  - DOMAIN-KEYWORD,{x}\n")
    for x in s_reg: f.write(f"  - DOMAIN-REGEX,{x}\n")
    for x in s_ip: f.write(f"  - {'IP-CIDR6' if ':' in x else 'IP-CIDR'},{x}\n")
    for x in s_pro: f.write(f"  - PROCESS-NAME,{x}\n")
    for x in s_pre: f.write(f"  - PROCESS-NAME-REGEX,{x}\n")
    for x in s_asn: f.write(f"  - IP-ASN,{x}\n")

# C. Sing-box JSON (严格点号规范)
rules_list = []
rule_dom = {}
if s_dom: rule_dom["domain"] = s_dom
if s_suf: rule_dom["domain_suffix"] = s_suf # 此时 s_suf 已全部带点
if s_kwd: rule_dom["domain_keyword"] = s_kwd
if s_reg: rule_dom["domain_regex"] = s_reg
if rule_dom: rules_list.append(rule_dom)
rule_ip = {}
if s_ip: rule_ip["ip_cidr"] = s_ip
if s_asn: rule_ip["source_ip_asn"] = [int(a) if a.isdigit() else a for a in s_asn]
if rule_ip: rules_list.append(rule_ip)
if s_pro or s_pre:
    rule_pro = {}
    if s_pro: rule_pro["process_name"] = s_pro
    if s_pre: rule_pro["process_name_regex"] = s_pre
    rules_list.append(rule_pro)

with open(f"{out_geo_dir}/{tag}.json", "w") as f:
    json.dump({"version": 3, "rules": rules_list}, f, ensure_ascii=False, separators=(',', ':'))

# D. QX (HOST-SUFFIX 不需要前导点)
with open(f"{out_qx_dir}/{tag}.list", "w") as f:
    for x in s_suf: f.write(f"HOST-SUFFIX, {x.lstrip('.')}\n")
    for x in s_dom: f.write(f"HOST, {x}\n")
    for x in s_kwd: f.write(f"HOST-KEYWORD, {x}\n")
    for x in s_ip: f.write(f"IP-CIDR{6 if ':' in x else ''}, {x}\n")
PYEOF

echo "[4/4] Processing Tags..."
for tag in "${!ALL_TAGS[@]}"; do
  f_gs="$WORKDIR/geosite_txt/geosite_${tag}.txt"; [[ -f "$f_gs" ]] || f_gs="$WORKDIR/geosite_txt/${tag}.txt"
  f_gp="$WORKDIR/geoip_txt/geoip_${tag}.txt";   [[ -f "$f_gp" ]] || f_gp="$WORKDIR/geoip_txt/${tag}.txt"
  f_cl="${CLASH_DIR}/${tag}.yaml"

  python3 "$CAT_PY_SCRIPT" "$tag" "$f_gs" "$f_gp" "$f_cl" "$OUT_GEOSITE" "$OUT_GEOIP" "$OUT_QX_GEOSITE"

  [[ -f "${OUT_GEOSITE}/${tag}.mrs.txt" ]] && "$MIHOMO_BIN" convert-ruleset domain "${OUT_GEOSITE}/${tag}.mrs.txt" "${OUT_GEOSITE}/${tag}.mrs" >/dev/null 2>&1 && rm -f "${OUT_GEOSITE}/${tag}.mrs.txt"
  [[ -f "${OUT_GEOIP}/${tag}.mrs.txt" ]] && "$MIHOMO_BIN" convert-ruleset ipcidr "${OUT_GEOIP}/${tag}.mrs.txt" "${OUT_GEOIP}/${tag}.mrs" >/dev/null 2>&1 && rm -f "${OUT_GEOIP}/${tag}.mrs.txt"
  [[ -f "${OUT_GEOSITE}/${tag}.json" ]] && "$SINGBOX_BIN" rule-set compile --output "${OUT_GEOSITE}/${tag}.srs" "${OUT_GEOSITE}/${tag}.json" >/dev/null 2>&1
done

echo "Done. All unified rules are in $OUT_GEOSITE"
