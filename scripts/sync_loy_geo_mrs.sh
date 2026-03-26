#!/usr/bin/env bash
# sync_loy_geo_mrs.sh
# 从 Loyalsoldier 下载 geoip/geosite .dat，拆分并输出五种格式：
#   geo/geosite/        ->  .mrs  .yaml  .list  .json  .srs
#   geo/geoip/          ->  .mrs  .yaml  .list  .json  .srs
#   QX/geosite          ->  .list
#   QX/geoip            ->  .list
#
# 并将 clash/<name>.yaml 中的规则融合进同名输出（宽松去重）：
#   支持规则类型：DOMAIN-SUFFIX / DOMAIN / DOMAIN-KEYWORD / DOMAIN-REGEX
#                IP-CIDR / IP-CIDR6
#                PROCESS-NAME / PROCESS-NAME-REGEX / IP-ASN
#   融合策略：
#     yaml / list           -> 保留所有规则类型
#     mrs                   -> 仅 domain/suffix 和 IP-CIDR/IP-CIDR6，其余跳过
#     json / srs            -> 跳过 PROCESS-NAME / PROCESS-NAME-REGEX / IP-ASN
#     QX list               -> 跳过 DOMAIN-REGEX / PROCESS-NAME / PROCESS-NAME-REGEX / IP-ASN
#   若 clash/<name>.yaml 存在但 geo 无同名文件，则纯从 clash 数据建档。
set -euo pipefail

GEOIP_URL='https://cdn.jsdelivr.net/gh/Loyalsoldier/geoip@release/geoip.dat'
GEOSITE_URL='https://cdn.jsdelivr.net/gh/Loyalsoldier/v2ray-rules-dat@release/geosite.dat'

OUT_GEOSITE='geo/geosite'
OUT_GEOIP='geo/geoip'
OUT_QX_GEOSITE='QX/geosite'
OUT_QX_GEOIP='QX/geoip'

CLASH_DIR="${CLASH_DIR:-clash}"     # clash yaml 源目录，可由环境变量覆盖

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

echo "[INFO] mihomo version:";   "$MIHOMO_BIN"  -v       || true
echo "[INFO] sing-box version:"; "$SINGBOX_BIN" version  || true

# ── 工作目录 ──────────────────────────────────────────────────────────────────
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

# ── 1. 下载 ───────────────────────────────────────────────────────────────────
echo "[1/8] Download dat files..."
curl -fsSL --retry 3 --retry-delay 2 "$GEOIP_URL"   -o "$WORKDIR/geoip.dat"
curl -fsSL --retry 3 --retry-delay 2 "$GEOSITE_URL" -o "$WORKDIR/geosite.dat"

# ── 2. 解包 ───────────────────────────────────────────────────────────────────
echo "[2/8] Unpack dat -> txt..."
mkdir -p "$WORKDIR/geoip_txt" "$WORKDIR/geosite_txt"
v2dat unpack geoip   -o "$WORKDIR/geoip_txt"   "$WORKDIR/geoip.dat"
v2dat unpack geosite -o "$WORKDIR/geosite_txt" "$WORKDIR/geosite.dat"

GEOIP_TXT_COUNT="$(find   "$WORKDIR/geoip_txt"   -type f -name '*.txt' | wc -l | tr -d ' ')"
GEOSITE_TXT_COUNT="$(find "$WORKDIR/geosite_txt" -type f -name '*.txt' | wc -l | tr -d ' ')"
echo "[DEBUG] geoip txt=$GEOIP_TXT_COUNT  geosite txt=$GEOSITE_TXT_COUNT"

if [ "$GEOIP_TXT_COUNT" -eq 0 ] || [ "$GEOSITE_TXT_COUNT" -eq 0 ]; then
  echo "ERROR: unpack produced 0 txt files"; exit 1
fi

# ── 3. 清空旧输出（增删同步） ─────────────────────────────────────────────────
echo "[3/8] Clean output dirs (full sync)..."
rm -rf "$OUT_GEOSITE" "$OUT_GEOIP" "$OUT_QX_GEOSITE" "$OUT_QX_GEOIP"
mkdir -p "$OUT_GEOSITE" "$OUT_GEOIP" "$OUT_QX_GEOSITE" "$OUT_QX_GEOIP"

# ══════════════════════════════════════════════════════════════════════════════
# 辅助函数
# ══════════════════════════════════════════════════════════════════════════════

# ── mrs（仅 domain/suffix，keyword/regexp 不支持）────────────────────────────
convert_mrs() {
  local behavior="$1" src="$2" dst="$3"
  local tmp="${dst}.tmp"
  rm -f "$tmp" 2>/dev/null || true
  "$MIHOMO_BIN" convert-ruleset "$behavior" text "$src" "$tmp"
  if [ ! -s "$tmp" ]; then rm -f "$tmp"; return 1; fi
  mv -f "$tmp" "$dst"
}

# ── yaml（geosite）───────────────────────────────────────────────────────────
# 参数：f_suffix f_domain f_keyword f_regexp f_process f_process_re f_asn dst
make_yaml_domain() {
  local f_suffix="$1" f_domain="$2" f_keyword="$3" f_regexp="$4" \
        f_process="$5" f_process_re="$6" f_ipcidr="$7" f_asn="$8" dst="$9"
  {
    echo "payload:"
    while IFS= read -r line; do [[ -z "$line" ]] && continue
      echo "  - DOMAIN-SUFFIX,${line#.}"; done < "$f_suffix"
    while IFS= read -r line; do [[ -z "$line" ]] && continue
      echo "  - DOMAIN,${line}"; done < "$f_domain"
    while IFS= read -r line; do [[ -z "$line" ]] && continue
      echo "  - DOMAIN-KEYWORD,${line}"; done < "$f_keyword"
    while IFS= read -r line; do [[ -z "$line" ]] && continue
      echo "  - DOMAIN-REGEX,${line}"; done < "$f_regexp"
    while IFS= read -r line; do [[ -z "$line" ]] && continue
      echo "  - PROCESS-NAME,${line}"; done < "$f_process"
    while IFS= read -r line; do [[ -z "$line" ]] && continue
      echo "  - PROCESS-NAME-REGEX,${line}"; done < "$f_process_re"
    while IFS= read -r line; do [[ -z "$line" ]] && continue
      if [[ "$line" == *:* ]]; then echo "  - IP-CIDR6,${line}"
      else echo "  - IP-CIDR,${line}"; fi; done < "$f_ipcidr"
    while IFS= read -r line; do [[ -z "$line" ]] && continue
      echo "  - IP-ASN,${line}"; done < "$f_asn"
  } > "$dst"
}

# ── yaml（geoip）─────────────────────────────────────────────────────────────
# 参数：f_ipcidr f_asn dst
make_yaml_ipcidr() {
  local f_ipcidr="$1" f_asn="$2" dst="$3"
  {
    echo "payload:"
    while IFS= read -r line; do [[ -z "$line" ]] && continue
      if [[ "$line" == *:* ]]; then echo "  - IP-CIDR6,${line}"
      else echo "  - IP-CIDR,${line}"; fi; done < "$f_ipcidr"
    while IFS= read -r line; do [[ -z "$line" ]] && continue
      echo "  - IP-ASN,${line}"; done < "$f_asn"
  } > "$dst"
}

# ── list（geosite，mihomo/Surge/小火箭）──────────────────────────────────────
make_list_domain() {
  local f_suffix="$1" f_domain="$2" f_keyword="$3" f_regexp="$4" \
        f_process="$5" f_process_re="$6" f_ipcidr="$7" f_asn="$8" dst="$9"
  {
    while IFS= read -r line; do [[ -z "$line" ]] && continue
      echo "DOMAIN-SUFFIX,${line#.}"; done < "$f_suffix"
    while IFS= read -r line; do [[ -z "$line" ]] && continue
      echo "DOMAIN,${line}"; done < "$f_domain"
    while IFS= read -r line; do [[ -z "$line" ]] && continue
      echo "DOMAIN-KEYWORD,${line}"; done < "$f_keyword"
    while IFS= read -r line; do [[ -z "$line" ]] && continue
      echo "DOMAIN-REGEX,${line}"; done < "$f_regexp"
    while IFS= read -r line; do [[ -z "$line" ]] && continue
      echo "PROCESS-NAME,${line}"; done < "$f_process"
    while IFS= read -r line; do [[ -z "$line" ]] && continue
      echo "PROCESS-NAME-REGEX,${line}"; done < "$f_process_re"
    while IFS= read -r line; do [[ -z "$line" ]] && continue
      if [[ "$line" == *:* ]]; then echo "IP-CIDR6,${line}"
      else echo "IP-CIDR,${line}"; fi; done < "$f_ipcidr"
    while IFS= read -r line; do [[ -z "$line" ]] && continue
      echo "IP-ASN,${line}"; done < "$f_asn"
  } > "$dst"
}

# ── list（geoip，mihomo/Surge/小火箭）────────────────────────────────────────
# 参数：f_ipcidr f_asn dst
make_list_ipcidr() {
  local f_ipcidr="$1" f_asn="$2" dst="$3"
  {
    while IFS= read -r line; do [[ -z "$line" ]] && continue
      if [[ "$line" == *:* ]]; then echo "IP-CIDR6,${line}"
      else echo "IP-CIDR,${line}"; fi; done < "$f_ipcidr"
    while IFS= read -r line; do [[ -z "$line" ]] && continue
      echo "IP-ASN,${line}"; done < "$f_asn"
  } > "$dst"
}

# ── list QX（geosite，QuantumultX）───────────────────────────────────────────
# 跳过：DOMAIN-REGEX / PROCESS-NAME / PROCESS-NAME-REGEX / IP-ASN
make_qx_list_domain() {
  local f_suffix="$1" f_domain="$2" f_keyword="$3" f_ipcidr="$4" dst="$5"
  {
    while IFS= read -r line; do [[ -z "$line" ]] && continue
      echo "HOST-SUFFIX, ${line#.}"; done < "$f_suffix"
    while IFS= read -r line; do [[ -z "$line" ]] && continue
      echo "HOST, ${line}"; done < "$f_domain"
    while IFS= read -r line; do [[ -z "$line" ]] && continue
      echo "HOST-KEYWORD, ${line}"; done < "$f_keyword"
    while IFS= read -r line; do [[ -z "$line" ]] && continue
      if [[ "$line" == *:* ]]; then echo "IP-CIDR6, ${line}"
      else echo "IP-CIDR, ${line}"; fi; done < "$f_ipcidr"
  } > "$dst"
}

# ── list QX（geoip，QuantumultX）─────────────────────────────────────────────
# 跳过：IP-ASN
make_qx_list_ipcidr() {
  local f_ipcidr="$1" dst="$2"
  while IFS= read -r line; do [[ -z "$line" ]] && continue
    if [[ "$line" == *:* ]]; then echo "IP-CIDR6, ${line}"
    else echo "IP-CIDR, ${line}"; fi
  done < "$f_ipcidr" > "$dst"
}

# ── sing-box json（geosite，version 3）───────────────────────────────────────
# 跳过：PROCESS-NAME / PROCESS-NAME-REGEX / IP-ASN
make_singbox_json_domain() {
  local f_suffix="$1" f_domain="$2" f_keyword="$3" f_regexp="$4" f_ipcidr="$5" dst="$6"
  python3 - "$f_suffix" "$f_domain" "$f_keyword" "$f_regexp" "$f_ipcidr" "$dst" <<'PYEOF'
import sys, json
f_suffix, f_domain, f_keyword, f_regexp, f_ipcidr, dst = sys.argv[1:]
def read_lines(path):
    with open(path) as f:
        return [l.strip() for l in f if l.strip()]
suffixes = read_lines(f_suffix)
domains  = read_lines(f_domain)
keywords = read_lines(f_keyword)
regexps  = read_lines(f_regexp)
cidrs    = read_lines(f_ipcidr)
rule = {}
if domains:   rule["domain"]         = domains
if suffixes:  rule["domain_suffix"]  = suffixes
if keywords:  rule["domain_keyword"] = keywords
if regexps:   rule["domain_regex"]   = regexps
if cidrs:     rule["ip_cidr"]        = cidrs
out = {"version": 3, "rules": [rule] if rule else []}
with open(dst, "w") as f:
    json.dump(out, f, ensure_ascii=False, separators=(',', ':'))
    f.write('\n')
PYEOF
}

# ── sing-box json（geoip，version 3）─────────────────────────────────────────
# 跳过：IP-ASN
make_singbox_json_ipcidr() {
  local f_ipcidr="$1" dst="$2"
  python3 - "$f_ipcidr" "$dst" <<'PYEOF'
import sys, json
src, dst = sys.argv[1], sys.argv[2]
cidrs = [l.strip() for l in open(src) if l.strip()]
rule = {}
if cidrs: rule["ip_cidr"] = cidrs
out = {"version": 3, "rules": [rule] if rule else []}
with open(dst, "w") as f:
    json.dump(out, f, ensure_ascii=False, separators=(',', ':'))
    f.write('\n')
PYEOF
}

# ── srs（sing-box compile）───────────────────────────────────────────────────
compile_srs() {
  json="$1" srs="$2"
  local tmp="${srs}.tmp"
  rm -f "$tmp" 2>/dev/null || true
  "$SINGBOX_BIN" rule-set compile --output "$tmp" "$json"
  if [ ! -s "$tmp" ]; then rm -f "$tmp"; return 1; fi
  mv -f "$tmp" "$srs"
}

# ══════════════════════════════════════════════════════════════════════════════
# clash yaml 解析与合并辅助（Python）
# ══════════════════════════════════════════════════════════════════════════════
#
# parse_clash_yaml <yaml_path> <out_dir> <tag>
#   解析 clash/<tag>.yaml，将各规则类型写到 <out_dir>/<tag>.<type>.clash.txt
#   输出文件（均为纯值列表，不含规则类型前缀）：
#     suffix.clash.txt  domain.clash.txt  keyword.clash.txt  regexp.clash.txt
#     ipcidr.clash.txt  process.clash.txt  process_re.clash.txt  asn.clash.txt
#
parse_clash_yaml() {
  local yaml_path="$1" out_dir="$2" tag="$3"
  python3 - "$yaml_path" "$out_dir" "$tag" <<'PYEOF'
import sys, re, os

yaml_path, out_dir, tag = sys.argv[1], sys.argv[2], sys.argv[3]

buckets = {
    'suffix':     [],
    'domain':     [],
    'keyword':    [],
    'regexp':     [],
    'ipcidr':     [],   # IPv4 + IPv6 合一
    'process':    [],
    'process_re': [],
    'asn':        [],
}

# 提取 payload 列表中每一条规则
re_item = re.compile(r'^\s*-\s+(.+)$')

with open(yaml_path, encoding='utf-8') as f:
    for raw in f:
        line = raw.rstrip()
        m = re_item.match(line)
        if not m:
            continue
        entry = m.group(1).strip()
        # 去掉行内注释（# 之前若有空格则为注释）
        entry = re.sub(r'\s+#.*$', '', entry)
        if not entry:
            continue

        # 拆分类型与值（最多拆两段，第三段如 no-resolve 丢弃）
        parts = [p.strip() for p in entry.split(',')]
        if len(parts) < 2:
            continue
        rule_type = parts[0].upper()
        value     = parts[1]

        if rule_type == 'DOMAIN-SUFFIX':
            buckets['suffix'].append(value.lstrip('.'))
        elif rule_type == 'DOMAIN':
            buckets['domain'].append(value)
        elif rule_type == 'DOMAIN-KEYWORD':
            buckets['keyword'].append(value)
        elif rule_type == 'DOMAIN-REGEX':
            buckets['regexp'].append(value)
        elif rule_type in ('IP-CIDR', 'IP-CIDR6'):
            # 保留原始 CIDR，no-resolve 已被丢弃
            buckets['ipcidr'].append(value)
        elif rule_type == 'PROCESS-NAME':
            buckets['process'].append(value)
        elif rule_type == 'PROCESS-NAME-REGEX':
            buckets['process_re'].append(value)
        elif rule_type == 'IP-ASN':
            buckets['asn'].append(value)
        # 其余类型忽略

for bname, items in buckets.items():
    out_path = os.path.join(out_dir, f"{tag}.{bname}.clash.txt")
    with open(out_path, 'w', encoding='utf-8') as f:
        for item in items:
            f.write(item + '\n')
PYEOF
}

# ── 宽松去重合并：将 clash txt 合并进 geo txt，normalize 后去重 ───────────────
#
# merge_dedup <geo_file> <clash_file> <out_file> <bucket_type>
#   bucket_type: suffix | domain | keyword | regexp | ipcidr | process | process_re | asn
#
#   normalize 规则：
#     suffix  : 统一去掉前导 "."
#     ipcidr  : 统一小写；掩码位统一（不做，保留原值）
#     其余    : 原样比较（大小写敏感）
#
merge_dedup() {
  local geo_file="$1" clash_file="$2" out_file="$3" bucket_type="$4"
  python3 - "$geo_file" "$clash_file" "$out_file" "$bucket_type" <<'PYEOF'
import sys

geo_file, clash_file, out_file, btype = sys.argv[1:]

def read_lines(path):
    try:
        with open(path, encoding='utf-8') as f:
            return [l.rstrip('\n') for l in f if l.strip()]
    except FileNotFoundError:
        return []

def normalize(val, btype):
    if btype == 'suffix':
        return val.lstrip('.')
    if btype == 'ipcidr':
        # 仅小写（IPv6 地址可能有大写）
        return val.lower()
    return val   # domain / keyword / regexp / process / process_re / asn

geo_lines   = read_lines(geo_file)
clash_lines = read_lines(clash_file)

seen  = set()
order = []

for val in geo_lines + clash_lines:
    key = normalize(val, btype)
    if key not in seen:
        seen.add(key)
        order.append(val)

with open(out_file, 'w', encoding='utf-8') as f:
    for item in order:
        f.write(item + '\n')
PYEOF
}

# ── 一键合并所有分桶：从 clash yaml 解析后与 geo 分桶合并，写回 geo 分桶文件 ──
#
# apply_clash_geosite <tag> <f_suffix> <f_domain> <f_keyword> <f_regexp>
#                           <f_process> <f_process_re> <f_asn>
#
apply_clash_geosite() {
  local tag="$1" \
        f_suffix="$2"     f_domain="$3"     f_keyword="$4" \
        f_regexp="$5"     f_process="$6"    f_process_re="$7" \
        f_asn="$8"

  local clash_yaml="${CLASH_DIR}/${tag}.yaml"
  [[ -f "$clash_yaml" ]] || return 0   # 无同名 clash yaml，跳过

  echo "[MERGE] geosite/${tag} <- ${clash_yaml}"

  # 解析 clash yaml 到临时子目录
  local ctmp="${WORKDIR}/clash_parsed"
  mkdir -p "$ctmp"
  parse_clash_yaml "$clash_yaml" "$ctmp" "$tag"

  # ipcidr/asn 桶额外存到 clash_ip/，供 geoip 流程直接取用，无需重复解析
  mkdir -p "${WORKDIR}/clash_ip"
  cp -f "${ctmp}/${tag}.ipcidr.clash.txt" "${WORKDIR}/clash_ip/${tag}.ipcidr.txt" \
    2>/dev/null || : > "${WORKDIR}/clash_ip/${tag}.ipcidr.txt"
  cp -f "${ctmp}/${tag}.asn.clash.txt" "${WORKDIR}/clash_ip/${tag}.asn.txt" \
    2>/dev/null || : > "${WORKDIR}/clash_ip/${tag}.asn.txt"

  local mtmp="${WORKDIR}/merged"
  mkdir -p "$mtmp"

  for bucket in suffix domain keyword regexp process process_re asn; do
    local geo_f clash_f merged_f
    case "$bucket" in
      suffix)     geo_f="$f_suffix"     ;;
      domain)     geo_f="$f_domain"     ;;
      keyword)    geo_f="$f_keyword"    ;;
      regexp)     geo_f="$f_regexp"     ;;
      process)    geo_f="$f_process"    ;;
      process_re) geo_f="$f_process_re" ;;
      asn)        geo_f="$f_asn"        ;;
    esac
    clash_f="${ctmp}/${tag}.${bucket}.clash.txt"
    merged_f="${mtmp}/${tag}.${bucket}.txt"

    merge_dedup "$geo_f" "$clash_f" "$merged_f" "$bucket"
    cp -f "$merged_f" "$geo_f"
  done
}

# ── geoip 版合并（只有 ipcidr + asn 两个桶） ─────────────────────────────────
#
# apply_clash_geoip <tag> <f_ipcidr> <f_asn>
#
apply_clash_geoip() {
  local tag="$1" f_ipcidr="$2" f_asn="$3"

  local clash_yaml="${CLASH_DIR}/${tag}.yaml"
  [[ -f "$clash_yaml" ]] || return 0

  echo "[MERGE] geoip/${tag} <- ${clash_yaml}"

  local ctmp="${WORKDIR}/clash_parsed"
  mkdir -p "$ctmp"
  parse_clash_yaml "$clash_yaml" "$ctmp" "${tag}_geoip"

  local mtmp="${WORKDIR}/merged"
  mkdir -p "$mtmp"

  for bucket in ipcidr asn; do
    local geo_f clash_f merged_f
    case "$bucket" in
      ipcidr) geo_f="$f_ipcidr" ;;
      asn)    geo_f="$f_asn"    ;;
    esac
    clash_f="${ctmp}/${tag}_geoip.${bucket}.clash.txt"
    merged_f="${mtmp}/${tag}_geoip.${bucket}.txt"

    merge_dedup "$geo_f" "$clash_f" "$merged_f" "$bucket"
    cp -f "$merged_f" "$geo_f"
  done
}

# ══════════════════════════════════════════════════════════════════════════════
# 4. 处理 geosite
# ══════════════════════════════════════════════════════════════════════════════
echo "[4/8] Process geosite..."
mkdir -p \
  "$WORKDIR/gs_suffix"  "$WORKDIR/gs_domain"  "$WORKDIR/gs_keyword" \
  "$WORKDIR/gs_regexp"  "$WORKDIR/gs_process" "$WORKDIR/gs_process_re" \
  "$WORKDIR/gs_asn"     "$WORKDIR/gs_mrs"     "$WORKDIR/clash_ip"

geosite_ok=0
geosite_skip=0

# 收集已处理的 tag（避免 clash-only 文件重复处理）
declare -A geosite_processed=()

while IFS= read -r f; do
  base="$(basename "$f")"
  tag="${base#geosite_}"; tag="${tag%.txt}"
  [[ "$tag" == "$base" ]] && tag="${base%.txt}"

  f_suffix="${WORKDIR}/gs_suffix/${tag}.txt"
  f_domain="${WORKDIR}/gs_domain/${tag}.txt"
  f_keyword="${WORKDIR}/gs_keyword/${tag}.txt"
  f_regexp="${WORKDIR}/gs_regexp/${tag}.txt"
  f_process="${WORKDIR}/gs_process/${tag}.txt"
  f_process_re="${WORKDIR}/gs_process_re/${tag}.txt"
  f_asn="${WORKDIR}/gs_asn/${tag}.txt"
  for fx in "$f_suffix" "$f_domain" "$f_keyword" "$f_regexp" \
            "$f_process" "$f_process_re" "$f_asn"; do
    : > "$fx"
  done

  # 解包 geo txt -> 分桶
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    case "$line" in
      keyword:*) echo "${line#keyword:}" >> "$f_keyword" ;;
      regexp:*)  echo "${line#regexp:}"  >> "$f_regexp"  ;;
      full:*)    echo "${line#full:}"    >> "$f_domain"  ;;
      *)
        if [[ "$line" == .* ]]; then echo "$line"   >> "$f_suffix"
        else                         echo ".$line"  >> "$f_suffix"
        fi ;;
    esac
  done < "$f"

  # 合并 clash yaml（若存在）
  apply_clash_geosite "$tag" \
    "$f_suffix" "$f_domain" "$f_keyword" "$f_regexp" \
    "$f_process" "$f_process_re" "$f_asn"

  # clash_ip 缓存（apply_clash_geosite 已写入；若无 clash yaml 则为空文件）
  f_ipcidr="${WORKDIR}/clash_ip/${tag}.ipcidr.txt"
  f_ip_asn="${WORKDIR}/clash_ip/${tag}.asn.txt"
  [[ -f "$f_ipcidr" ]] || : > "$f_ipcidr"
  [[ -f "$f_ip_asn" ]] || : > "$f_ip_asn"

  # 所有桶均空则跳过（含 ipcidr）
  local_empty=true
  for fx in "$f_suffix" "$f_domain" "$f_keyword" "$f_regexp" \
            "$f_process" "$f_process_re" "$f_asn" "$f_ipcidr"; do
    [[ -s "$fx" ]] && { local_empty=false; break; }
  done
  if $local_empty; then geosite_skip=$((geosite_skip+1)); continue; fi

  # mrs：suffix + domain（不含 keyword/regexp/process/ip）
  f_mrs="${WORKDIR}/gs_mrs/${tag}.txt"
  cat "$f_suffix" "$f_domain" > "$f_mrs"
  if [[ -s "$f_mrs" ]]; then
    convert_mrs domain "$f_mrs" "${OUT_GEOSITE}/${tag}.mrs" || true
  fi

  make_yaml_domain \
    "$f_suffix" "$f_domain" "$f_keyword" "$f_regexp" \
    "$f_process" "$f_process_re" "$f_ipcidr" "$f_ip_asn" \
    "${OUT_GEOSITE}/${tag}.yaml"

  make_list_domain \
    "$f_suffix" "$f_domain" "$f_keyword" "$f_regexp" \
    "$f_process" "$f_process_re" "$f_ipcidr" "$f_ip_asn" \
    "${OUT_GEOSITE}/${tag}.list"

  make_qx_list_domain "$f_suffix" "$f_domain" "$f_keyword" "$f_ipcidr" \
    "${OUT_QX_GEOSITE}/${tag}.list"

  json="${OUT_GEOSITE}/${tag}.json"
  make_singbox_json_domain "$f_suffix" "$f_domain" "$f_keyword" "$f_regexp" "$f_ipcidr" "$json"
  compile_srs "$json" "${OUT_GEOSITE}/${tag}.srs" || true

  geosite_processed["$tag"]=1
  geosite_ok=$((geosite_ok+1))
done < <(find "$WORKDIR/geosite_txt" -type f -name '*.txt' | sort)

echo "[INFO] geosite geo pass: ok=$geosite_ok  skipped_empty=$geosite_skip"

# ── clash-only geosite（geo 无同名但 clash/ 有）─────────────────────────────
echo "[4b/8] Process clash-only geosite..."
clash_geosite_ok=0

if [[ -d "$CLASH_DIR" ]]; then
  while IFS= read -r cyaml; do
    tag="$(basename "$cyaml" .yaml)"
    # 已由 geo 流程处理过的跳过
    [[ -n "${geosite_processed[$tag]+x}" ]] && continue
    # 该 tag 是否看起来像 geoip（名字上无法区分，按 clash yaml 内容判断）
    # 策略：clash-only 文件同时可能含 domain 又含 ip；
    #       这里按 geosite 路径处理（含 ip 的条目也会被 domain 输出忽略，ip 条目写 yaml/list）。

    echo "[CLASH-ONLY] geosite/${tag} <- ${cyaml}"

    f_suffix="${WORKDIR}/gs_suffix/${tag}.txt"
    f_domain="${WORKDIR}/gs_domain/${tag}.txt"
    f_keyword="${WORKDIR}/gs_keyword/${tag}.txt"
    f_regexp="${WORKDIR}/gs_regexp/${tag}.txt"
    f_process="${WORKDIR}/gs_process/${tag}.txt"
    f_process_re="${WORKDIR}/gs_process_re/${tag}.txt"
    f_asn="${WORKDIR}/gs_asn/${tag}.txt"
    for fx in "$f_suffix" "$f_domain" "$f_keyword" "$f_regexp" \
              "$f_process" "$f_process_re" "$f_asn"; do
      : > "$fx"
    done

    # 直接解析 clash yaml
    ctmp="${WORKDIR}/clash_parsed"
    mkdir -p "$ctmp"
    parse_clash_yaml "$cyaml" "$ctmp" "$tag"

    for bucket in suffix domain keyword regexp process process_re asn; do
      clash_f="${ctmp}/${tag}.${bucket}.clash.txt"
      case "$bucket" in
        suffix)     cp -f "$clash_f" "$f_suffix"     ;;
        domain)     cp -f "$clash_f" "$f_domain"     ;;
        keyword)    cp -f "$clash_f" "$f_keyword"    ;;
        regexp)     cp -f "$clash_f" "$f_regexp"     ;;
        process)    cp -f "$clash_f" "$f_process"    ;;
        process_re) cp -f "$clash_f" "$f_process_re" ;;
        asn)        cp -f "$clash_f" "$f_asn"        ;;
      esac
    done

    # clash_ip 缓存（parse_clash_yaml 已写入）
    f_ipcidr="${ctmp}/${tag}.ipcidr.clash.txt"
    f_ip_asn="${ctmp}/${tag}.asn.clash.txt"
    [[ -f "$f_ipcidr" ]] || : > "$f_ipcidr"
    [[ -f "$f_ip_asn" ]] || : > "$f_ip_asn"

    local_empty=true
    for fx in "$f_suffix" "$f_domain" "$f_keyword" "$f_regexp" \
              "$f_process" "$f_process_re" "$f_asn" "$f_ipcidr"; do
      [[ -s "$fx" ]] && { local_empty=false; break; }
    done
    $local_empty && continue

    f_mrs="${WORKDIR}/gs_mrs/${tag}.txt"
    cat "$f_suffix" "$f_domain" > "$f_mrs"
    if [[ -s "$f_mrs" ]]; then
      convert_mrs domain "$f_mrs" "${OUT_GEOSITE}/${tag}.mrs" || true
    fi

    make_yaml_domain \
      "$f_suffix" "$f_domain" "$f_keyword" "$f_regexp" \
      "$f_process" "$f_process_re" "$f_ipcidr" "$f_ip_asn" \
      "${OUT_GEOSITE}/${tag}.yaml"

    make_list_domain \
      "$f_suffix" "$f_domain" "$f_keyword" "$f_regexp" \
      "$f_process" "$f_process_re" "$f_ipcidr" "$f_ip_asn" \
      "${OUT_GEOSITE}/${tag}.list"

    make_qx_list_domain "$f_suffix" "$f_domain" "$f_keyword" "$f_ipcidr" \
      "${OUT_QX_GEOSITE}/${tag}.list"

    json="${OUT_GEOSITE}/${tag}.json"
    make_singbox_json_domain "$f_suffix" "$f_domain" "$f_keyword" "$f_regexp" "$f_ipcidr" "$json"
    compile_srs "$json" "${OUT_GEOSITE}/${tag}.srs" || true

    geosite_processed["$tag"]=1
    clash_geosite_ok=$((clash_geosite_ok+1))
  done < <(find "$CLASH_DIR" -maxdepth 1 -name '*.yaml' | sort)
fi

echo "[INFO] geosite clash-only: ok=$clash_geosite_ok"

# ══════════════════════════════════════════════════════════════════════════════
# 5. 处理 geoip
# ══════════════════════════════════════════════════════════════════════════════
echo "[5/8] Process geoip..."

geoip_ok=0
declare -A geoip_processed=()

while IFS= read -r f; do
  base="$(basename "$f")"
  tag="${base#geoip_}"; tag="${tag%.txt}"
  [[ "$tag" == "$base" ]] && tag="${base%.txt}"

  [[ ! -s "$f" ]] && continue

  # geo txt 只含 CIDR，asn 桶初始为空
  f_ipcidr="${WORKDIR}/geoip_cidr_${tag}.txt"
  f_asn="${WORKDIR}/geoip_asn_${tag}.txt"
  cp "$f" "$f_ipcidr"
  : > "$f_asn"

  # 合并 clash yaml（若存在）—— 只取 ipcidr + asn 桶
  apply_clash_geoip "$tag" "$f_ipcidr" "$f_asn"

  # geoip 只需 mrs（yaml/list/json/srs 已融入 geosite 同名文件）
  convert_mrs ipcidr "$f_ipcidr" "${OUT_GEOIP}/${tag}.mrs"    || true

  geoip_processed["$tag"]=1
  geoip_ok=$((geoip_ok+1))
done < <(find "$WORKDIR/geoip_txt" -type f -name '*.txt' | sort)

echo "[INFO] geoip geo pass: ok=$geoip_ok"

# ── clash-only geoip ─────────────────────────────────────────────────────────
# 对于 clash yaml 里含有 IP-CIDR/IP-ASN 但 geo 无同名的情况：
# 条件：clash yaml 存在 + geoip 未处理 + geosite 也未处理（避免重复）
echo "[5b/8] Process clash-only geoip..."
clash_geoip_ok=0

if [[ -d "$CLASH_DIR" ]]; then
  while IFS= read -r cyaml; do
    tag="$(basename "$cyaml" .yaml)"
    [[ -n "${geoip_processed[$tag]+x}" ]] && continue   # geo geoip already processed

    # Use cached parse from geosite flow if available, else parse now
    if [[ -f "${WORKDIR}/clash_ip/${tag}.ipcidr.txt" ]]; then
      f_ipcidr="${WORKDIR}/clash_ip/${tag}.ipcidr.txt"
      f_asn="${WORKDIR}/clash_ip/${tag}.asn.txt"
    else
      ctmp="${WORKDIR}/clash_parsed"
      mkdir -p "$ctmp"
      parse_clash_yaml "$cyaml" "$ctmp" "${tag}_geoip2"
      f_ipcidr="${ctmp}/${tag}_geoip2.ipcidr.clash.txt"
      f_asn="${ctmp}/${tag}_geoip2.asn.clash.txt"
    fi


    echo "[CLASH-ONLY] geoip/${tag} <- ${cyaml} (mrs only)"
    convert_mrs ipcidr "$f_ipcidr" "${OUT_GEOIP}/${tag}.mrs"    || true

    clash_geoip_ok=$((clash_geoip_ok+1))
  done < <(find "$CLASH_DIR" -maxdepth 1 -name '*.yaml' | sort)
fi

echo "[INFO] geoip clash-only: ok=$clash_geoip_ok"

# ══════════════════════════════════════════════════════════════════════════════
# 6. 统计
# ══════════════════════════════════════════════════════════════════════════════
echo "[6/8] Final counts:"
echo "  geo/geosite/        mrs  : $(find "$OUT_GEOSITE"    -name '*.mrs'  | wc -l | tr -d ' ')"
echo "  geo/geosite/        yaml : $(find "$OUT_GEOSITE"    -name '*.yaml' | wc -l | tr -d ' ')"
echo "  geo/geosite/        list : $(find "$OUT_GEOSITE"    -name '*.list' | wc -l | tr -d ' ')"
echo "  geo/geosite/        json : $(find "$OUT_GEOSITE"    -name '*.json' | wc -l | tr -d ' ')"
echo "  geo/geosite/        srs  : $(find "$OUT_GEOSITE"    -name '*.srs'  | wc -l | tr -d ' ')"
echo "  geo/geoip/          mrs  : $(find "$OUT_GEOIP"      -name '*.mrs'  | wc -l | tr -d ' ')"
echo "  QX/geosite/         list : $(find "$OUT_QX_GEOSITE" -name '*.list' | wc -l | tr -d ' ')"

echo "[7/8] Done."