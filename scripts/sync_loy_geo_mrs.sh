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

CLASH_DIR="${CLASH_DIR:-clash}"
CLASH_IP_DIR="${CLASH_IP_DIR:-clash-ip}"

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

# ── mrs（仅 domain/suffix 或 ipcidr）────────────────────────────────────────
convert_mrs() {
  local behavior="$1" src="$2" dst="$3"
  local tmp="${dst}.tmp"
  rm -f "$tmp" 2>/dev/null || true
  "$MIHOMO_BIN" convert-ruleset "$behavior" text "$src" "$tmp"
  if [ ! -s "$tmp" ]; then rm -f "$tmp"; return 1; fi
  mv -f "$tmp" "$dst"
}

# ── yaml（geosite）───────────────────────────────────────────────────────────
make_yaml_domain() {
  local f_suffix="$1" f_domain="$2" f_keyword="$3" f_regexp="$4" \
        f_process="$5" f_process_re="$6" clash_yaml="$7" dst="$8"
  python3 - "$f_suffix" "$f_domain" "$f_keyword" "$f_regexp" \
            "$f_process" "$f_process_re" "$clash_yaml" "$dst" <<'PYEOF'
import sys, re

f_suffix, f_domain, f_keyword, f_regexp, f_process, f_process_re, clash_yaml, dst = sys.argv[1:]

def read_lines(path):
    try:
        with open(path, encoding="utf-8") as f:
            return [l.rstrip("\n") for l in f if l.strip()]
    except FileNotFoundError:
        return []

def norm_value(t, v):
    if t == "DOMAIN-SUFFIX":
        return v.lstrip(".")
    if t in ("IP-CIDR", "IP-CIDR6"):
        return v.lower()
    return v

geo_lines = []
geo_seen = {}

def add_geo(rule_type, value):
    geo_lines.append(rule_type + "," + value)
    geo_seen.setdefault(rule_type, set()).add(norm_value(rule_type, value))

for line in read_lines(f_suffix):
    add_geo("DOMAIN-SUFFIX", line.lstrip("."))
for line in read_lines(f_domain):
    add_geo("DOMAIN", line)
for line in read_lines(f_keyword):
    add_geo("DOMAIN-KEYWORD", line)
for line in read_lines(f_regexp):
    add_geo("DOMAIN-REGEX", line)
for line in read_lines(f_process):
    add_geo("PROCESS-NAME", line)
for line in read_lines(f_process_re):
    add_geo("PROCESS-NAME-REGEX", line)

clash_extra = []
clash_seen = {}

if clash_yaml:
    re_item = re.compile(r"^\s*-\s+(.+)$")
    try:
        with open(clash_yaml, encoding="utf-8") as f:
            for raw in f:
                m = re_item.match(raw.rstrip())
                if not m:
                    continue
                entry = re.sub(r"\s+#.*$", "", m.group(1).strip())
                if not entry or "," not in entry:
                    continue
                parts = [p.strip() for p in entry.split(",")]
                if len(parts) < 2:
                    continue
                t = parts[0].upper()
                v = parts[1]
                nv = norm_value(t, v)
                if nv in geo_seen.get(t, set()):
                    continue
                if nv in clash_seen.get(t, set()):
                    continue
                clash_seen.setdefault(t, set()).add(nv)
                clash_extra.append(t + "," + v)
    except FileNotFoundError:
        pass

with open(dst, "w", encoding="utf-8") as f:
    f.write("payload:\n")
    for line in geo_lines + clash_extra:
        f.write("  - " + line + "\n")
PYEOF
}

# ── yaml（geoip）─────────────────────────────────────────────────────────────
make_yaml_ipcidr() {
  local f_ipcidr="$1" f_asn="$2" clash_yaml="$3" dst="$4"
  python3 - "$f_ipcidr" "$f_asn" "$clash_yaml" "$dst" <<'PYEOF'
import sys, re

f_ipcidr, f_asn, clash_yaml, dst = sys.argv[1:]

def read_lines(path):
    try:
        with open(path, encoding="utf-8") as f:
            return [l.rstrip("\n") for l in f if l.strip()]
    except FileNotFoundError:
        return []

def norm_cidr(v):
    return v.lower()

geo_lines = []
geo_seen_cidr = set()
geo_seen_asn  = set()

for line in read_lines(f_ipcidr):
    if ":" in line:
        geo_lines.append("IP-CIDR6," + line)
    else:
        geo_lines.append("IP-CIDR," + line)
    geo_seen_cidr.add(norm_cidr(line))

for line in read_lines(f_asn):
    geo_lines.append("IP-ASN," + line)
    geo_seen_asn.add(line)

clash_extra = []
clash_seen_cidr = set()
clash_seen_asn  = set()

if clash_yaml:
    re_item = re.compile(r"^\s*-\s+(.+)$")
    try:
        with open(clash_yaml, encoding="utf-8") as f:
            for raw in f:
                m = re_item.match(raw.rstrip())
                if not m:
                    continue
                entry = re.sub(r"\s+#.*$", "", m.group(1).strip())
                if not entry or "," not in entry:
                    continue
                parts = [p.strip() for p in entry.split(",")]
                if len(parts) < 2:
                    continue
                t = parts[0].upper()
                v = parts[1]
                if t in ("IP-CIDR", "IP-CIDR6"):
                    nv = norm_cidr(v)
                    if nv in geo_seen_cidr or nv in clash_seen_cidr:
                        continue
                    clash_seen_cidr.add(nv)
                    clash_extra.append(t + "," + v)
                elif t == "IP-ASN":
                    if v in geo_seen_asn or v in clash_seen_asn:
                        continue
                    clash_seen_asn.add(v)
                    clash_extra.append("IP-ASN," + v)
    except FileNotFoundError:
        pass

with open(dst, "w", encoding="utf-8") as f:
    f.write("payload:\n")
    for line in geo_lines + clash_extra:
        f.write("  - " + line + "\n")
PYEOF
}

# ── list（geosite）───────────────────────────────────────────────────────────
make_list_domain() {
  local f_suffix="$1" f_domain="$2" f_keyword="$3" f_regexp="$4" \
        f_process="$5" f_process_re="$6" clash_yaml="$7" dst="$8"
  python3 - "$f_suffix" "$f_domain" "$f_keyword" "$f_regexp" \
            "$f_process" "$f_process_re" "$clash_yaml" "$dst" <<'PYEOF'
import sys, re

f_suffix, f_domain, f_keyword, f_regexp, f_process, f_process_re, clash_yaml, dst = sys.argv[1:]

def read_lines(path):
    try:
        with open(path, encoding="utf-8") as f:
            return [l.rstrip("\n") for l in f if l.strip()]
    except FileNotFoundError:
        return []

def norm_value(t, v):
    if t == "DOMAIN-SUFFIX":
        return v.lstrip(".")
    if t in ("IP-CIDR", "IP-CIDR6"):
        return v.lower()
    return v

geo_lines = []
geo_seen = {}

def add_geo(rule_type, value):
    geo_lines.append(rule_type + "," + value)
    geo_seen.setdefault(rule_type, set()).add(norm_value(rule_type, value))

for line in read_lines(f_suffix):
    add_geo("DOMAIN-SUFFIX", line.lstrip("."))
for line in read_lines(f_domain):
    add_geo("DOMAIN", line)
for line in read_lines(f_keyword):
    add_geo("DOMAIN-KEYWORD", line)
for line in read_lines(f_regexp):
    add_geo("DOMAIN-REGEX", line)
for line in read_lines(f_process):
    add_geo("PROCESS-NAME", line)
for line in read_lines(f_process_re):
    add_geo("PROCESS-NAME-REGEX", line)

clash_extra = []
clash_seen = {}

if clash_yaml:
    re_item = re.compile(r"^\s*-\s+(.+)$")
    try:
        with open(clash_yaml, encoding="utf-8") as f:
            for raw in f:
                m = re_item.match(raw.rstrip())
                if not m:
                    continue
                entry = re.sub(r"\s+#.*$", "", m.group(1).strip())
                if not entry or "," not in entry:
                    continue
                parts = [p.strip() for p in entry.split(",")]
                if len(parts) < 2:
                    continue
                t = parts[0].upper()
                v = parts[1]
                nv = norm_value(t, v)
                if nv in geo_seen.get(t, set()):
                    continue
                if nv in clash_seen.get(t, set()):
                    continue
                clash_seen.setdefault(t, set()).add(nv)
                clash_extra.append(t + "," + v)
    except FileNotFoundError:
        pass

with open(dst, "w", encoding="utf-8") as f:
    for line in geo_lines + clash_extra:
        f.write(line + "\n")
PYEOF
}

# ── list（geoip）─────────────────────────────────────────────────────────────
make_list_ipcidr() {
  local f_ipcidr="$1" f_asn="$2" clash_yaml="$3" dst="$4"
  python3 - "$f_ipcidr" "$f_asn" "$clash_yaml" "$dst" <<'PYEOF'
import sys, re

f_ipcidr, f_asn, clash_yaml, dst = sys.argv[1:]

def read_lines(path):
    try:
        with open(path, encoding="utf-8") as f:
            return [l.rstrip("\n") for l in f if l.strip()]
    except FileNotFoundError:
        return []

def norm_cidr(v):
    return v.lower()

geo_lines = []
geo_seen_cidr = set()
geo_seen_asn  = set()

for line in read_lines(f_ipcidr):
    if ":" in line:
        geo_lines.append("IP-CIDR6," + line)
    else:
        geo_lines.append("IP-CIDR," + line)
    geo_seen_cidr.add(norm_cidr(line))

for line in read_lines(f_asn):
    geo_lines.append("IP-ASN," + line)
    geo_seen_asn.add(line)

clash_extra = []
clash_seen_cidr = set()
clash_seen_asn  = set()

if clash_yaml:
    re_item = re.compile(r"^\s*-\s+(.+)$")
    try:
        with open(clash_yaml, encoding="utf-8") as f:
            for raw in f:
                m = re_item.match(raw.rstrip())
                if not m:
                    continue
                entry = re.sub(r"\s+#.*$", "", m.group(1).strip())
                if not entry or "," not in entry:
                    continue
                parts = [p.strip() for p in entry.split(",")]
                if len(parts) < 2:
                    continue
                t = parts[0].upper()
                v = parts[1]
                if t in ("IP-CIDR", "IP-CIDR6"):
                    nv = norm_cidr(v)
                    if nv in geo_seen_cidr or nv in clash_seen_cidr:
                        continue
                    clash_seen_cidr.add(nv)
                    clash_extra.append(t + "," + v)
                elif t == "IP-ASN":
                    if v in geo_seen_asn or v in clash_seen_asn:
                        continue
                    clash_seen_asn.add(v)
                    clash_extra.append("IP-ASN," + v)
    except FileNotFoundError:
        pass

with open(dst, "w", encoding="utf-8") as f:
    for line in geo_lines + clash_extra:
        f.write(line + "\n")
PYEOF
}

# ── list QX（geosite）────────────────────────────────────────────────────────
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

# ── list QX（geoip）──────────────────────────────────────────────────────────
make_qx_list_ipcidr() {
  local f_ipcidr="$1" clash_yaml="$2" dst="$3"
  python3 - "$f_ipcidr" "$clash_yaml" "$dst" <<'PYEOF'
import sys, re

f_ipcidr, clash_yaml, dst = sys.argv[1:]

def read_lines(path):
    try:
        with open(path, encoding="utf-8") as f:
            return [l.rstrip("\n") for l in f if l.strip()]
    except FileNotFoundError:
        return []

geo_lines = []
geo_seen = set()

for line in read_lines(f_ipcidr):
    if ":" in line:
        geo_lines.append("IP-CIDR6, " + line)
    else:
        geo_lines.append("IP-CIDR, " + line)
    geo_seen.add(line.lower())

clash_extra = []
clash_seen = set()

if clash_yaml:
    re_item = re.compile(r"^\s*-\s+(.+)$")
    try:
        with open(clash_yaml, encoding="utf-8") as f:
            for raw in f:
                m = re_item.match(raw.rstrip())
                if not m:
                    continue
                entry = re.sub(r"\s+#.*$", "", m.group(1).strip())
                if not entry or "," not in entry:
                    continue
                parts = [p.strip() for p in entry.split(",")]
                if len(parts) < 2:
                    continue
                t = parts[0].upper()
                v = parts[1]
                if t not in ("IP-CIDR", "IP-CIDR6"):
                    continue
                nv = v.lower()
                if nv in geo_seen or nv in clash_seen:
                    continue
                clash_seen.add(nv)
                if ":" in v:
                    clash_extra.append("IP-CIDR6, " + v)
                else:
                    clash_extra.append("IP-CIDR, " + v)
    except FileNotFoundError:
        pass

with open(dst, "w", encoding="utf-8") as f:
    for line in geo_lines + clash_extra:
        f.write(line + "\n")
PYEOF
}

# ── sing-box json（geosite，version 3）───────────────────────────────────────
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
make_singbox_json_ipcidr() {
  local f_ipcidr="$1" clash_yaml="$2" dst="$3"
  python3 - "$f_ipcidr" "$clash_yaml" "$dst" <<'PYEOF'
import sys, json, re

f_ipcidr, clash_yaml, dst = sys.argv[1:]

def read_lines(path):
    try:
        with open(path, encoding="utf-8") as f:
            return [l.strip() for l in f if l.strip()]
    except FileNotFoundError:
        return []

geo_cidrs = read_lines(f_ipcidr)
geo_seen = set(v.lower() for v in geo_cidrs)

clash_extra = []
clash_seen = set()

if clash_yaml:
    re_item = re.compile(r"^\s*-\s+(.+)$")
    try:
        with open(clash_yaml, encoding="utf-8") as f:
            for raw in f:
                m = re_item.match(raw.rstrip())
                if not m:
                    continue
                entry = re.sub(r"\s+#.*$", "", m.group(1).strip())
                if not entry or "," not in entry:
                    continue
                parts = [p.strip() for p in entry.split(",")]
                if len(parts) < 2:
                    continue
                t = parts[0].upper()
                v = parts[1]
                if t not in ("IP-CIDR", "IP-CIDR6"):
                    continue
                nv = v.lower()
                if nv in geo_seen or nv in clash_seen:
                    continue
                clash_seen.add(nv)
                clash_extra.append(v)
    except FileNotFoundError:
        pass

all_cidrs = geo_cidrs + clash_extra
rule = {}
if all_cidrs:
    rule["ip_cidr"] = all_cidrs
out = {"version": 3, "rules": [rule] if rule else []}
with open(dst, "w") as f:
    json.dump(out, f, ensure_ascii=False, separators=(',', ':'))
    f.write('\n')
PYEOF
}

# ── srs（sing-box compile）───────────────────────────────────────────────────
compile_srs() {
  local json="$1" srs="$2"
  local tmp="${srs}.tmp"
  rm -f "$tmp" 2>/dev/null || true
  "$SINGBOX_BIN" rule-set compile --output "$tmp" "$json"
  if [ ! -s "$tmp" ]; then rm -f "$tmp"; return 1; fi
  mv -f "$tmp" "$srs"
}

# ══════════════════════════════════════════════════════════════════════════════
# clash yaml 解析辅助
# ══════════════════════════════════════════════════════════════════════════════
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
    'ipcidr':     [],
    'process':    [],
    'process_re': [],
    'asn':        [],
}

re_item = re.compile(r'^\s*-\s+(.+)$')

with open(yaml_path, encoding='utf-8') as f:
    for raw in f:
        line = raw.rstrip()
        m = re_item.match(line)
        if not m:
            continue
        entry = m.group(1).strip()
        entry = re.sub(r'\s+#.*$', '', entry)
        if not entry:
            continue
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
            buckets['ipcidr'].append(value)
        elif rule_type == 'PROCESS-NAME':
            buckets['process'].append(value)
        elif rule_type == 'PROCESS-NAME-REGEX':
            buckets['process_re'].append(value)
        elif rule_type == 'IP-ASN':
            buckets['asn'].append(value)

for bname, items in buckets.items():
    out_path = os.path.join(out_dir, f"{tag}.{bname}.clash.txt")
    with open(out_path, 'w', encoding='utf-8') as f:
        for item in items:
            f.write(item + '\n')
PYEOF
}

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
        return val.lower()
    return val

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

apply_clash_geosite() {
  local tag="$1" \
        f_suffix="$2"     f_domain="$3"     f_keyword="$4" \
        f_regexp="$5"     f_process="$6"    f_process_re="$7" \
        f_asn="$8"

  local clash_yaml="${CLASH_DIR}/${tag}.yaml"
  [[ -f "$clash_yaml" ]] || return 0

  echo "[MERGE] geosite/${tag} <- ${clash_yaml}"

  local ctmp="${WORKDIR}/clash_parsed"
  mkdir -p "$ctmp"
  parse_clash_yaml "$clash_yaml" "$ctmp" "$tag"

  local mtmp="${WORKDIR}/merged"
  mkdir -p "$mtmp"

  # ipcidr 桶：来自 clash yaml 的 IP 条目，存入 clash_ip/ 供后续 geoip 使用
  local f_geo_ipcidr="${WORKDIR}/clash_ip/${tag}.ipcidr.txt"
  local f_geo_ip_asn="${WORKDIR}/clash_ip/${tag}.asn.txt"
  mkdir -p "${WORKDIR}/clash_ip"
  : > "$f_geo_ipcidr"
  : > "$f_geo_ip_asn"
  merge_dedup "$f_geo_ipcidr" "${ctmp}/${tag}.ipcidr.clash.txt" "${mtmp}/${tag}.ipcidr.txt" ipcidr \
    && cp -f "${mtmp}/${tag}.ipcidr.txt" "$f_geo_ipcidr" || true
  merge_dedup "$f_geo_ip_asn" "${ctmp}/${tag}.asn.clash.txt"   "${mtmp}/${tag}.ip_asn.txt"  asn \
    && cp -f "${mtmp}/${tag}.ip_asn.txt"  "$f_geo_ip_asn"   || true

  for bucket in suffix domain keyword regexp process process_re; do
    local geo_f clash_f merged_f
    case "$bucket" in
      suffix)     geo_f="$f_suffix"     ;;
      domain)     geo_f="$f_domain"     ;;
      keyword)    geo_f="$f_keyword"    ;;
      regexp)     geo_f="$f_regexp"     ;;
      process)    geo_f="$f_process"    ;;
      process_re) geo_f="$f_process_re" ;;
    esac
    clash_f="${ctmp}/${tag}.${bucket}.clash.txt"
    merged_f="${mtmp}/${tag}.${bucket}.txt"

    merge_dedup "$geo_f" "$clash_f" "$merged_f" "$bucket"
    cp -f "$merged_f" "$geo_f"
  done
}

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

# ── 输出 geoip 全部五种格式（纯 Loyalsoldier 数据，不混入 clash yaml）────────
emit_geoip_all() {
  local tag="$1" f_ipcidr="$2" f_asn="$3"

  # mrs
  if [[ -s "$f_ipcidr" ]]; then
    convert_mrs ipcidr "$f_ipcidr" "${OUT_GEOIP}/${tag}.mrs" || true
  fi

  # yaml（不传 clash_yaml，空字符串）
  make_yaml_ipcidr "$f_ipcidr" "$f_asn" "" "${OUT_GEOIP}/${tag}.yaml"

  # list
  make_list_ipcidr "$f_ipcidr" "$f_asn" "" "${OUT_GEOIP}/${tag}.list"

  # QX list（跳过 ASN）
  make_qx_list_ipcidr "$f_ipcidr" "" "${OUT_QX_GEOIP}/${tag}.list"

  # json + srs
  local json="${OUT_GEOIP}/${tag}.json"
  make_singbox_json_ipcidr "$f_ipcidr" "" "$json"
  compile_srs "$json" "${OUT_GEOIP}/${tag}.srs" || true
}

# ── clash-ip/ 数据合并进 geo/geoip/ 五种格式 + QX/geoip/ ────────────────────
# 参数：tag  f_ipcidr(clash-ip解析结果)  f_asn(clash-ip解析结果)
emit_clash_ip_merge() {
  local tag="$1" f_ci_ipcidr="$2" f_ci_asn="$3"

  local dst_mrs="${OUT_GEOIP}/${tag}.mrs"
  local dst_yaml="${OUT_GEOIP}/${tag}.yaml"
  local dst_list="${OUT_GEOIP}/${tag}.list"
  local dst_json="${OUT_GEOIP}/${tag}.json"
  local dst_srs="${OUT_GEOIP}/${tag}.srs"
  local dst_qx="${OUT_QX_GEOIP}/${tag}.list"

  # 从现有 list 文件提取已有条目作为去重基准
  local f_exist_cidr="${WORKDIR}/ci_exist_${tag}_cidr.txt"
  local f_exist_asn="${WORKDIR}/ci_exist_${tag}_asn.txt"
  : > "$f_exist_cidr"; : > "$f_exist_asn"

  if [[ -f "$dst_list" ]]; then
    grep -E "^IP-CIDR," "$dst_list"  | cut -d, -f2 >> "$f_exist_cidr" || true
    grep -E "^IP-CIDR6," "$dst_list" | cut -d, -f2 >> "$f_exist_cidr" || true
    grep -E "^IP-ASN,"   "$dst_list" | cut -d, -f2 >> "$f_exist_asn"  || true
  fi

  # 计算新增 CIDR（clash-ip 有但现有文件没有的）
  local f_new_cidr="${WORKDIR}/ci_new_${tag}_cidr.txt"
  local f_new_asn="${WORKDIR}/ci_new_${tag}_asn.txt"

  merge_dedup "$f_exist_cidr" "$f_ci_ipcidr" "${WORKDIR}/ci_all_${tag}_cidr.txt" ipcidr
  # 新增 = clash-ip 里 exist 没有的
  python3 -c "
import sys
exist = set(v.strip().lower() for v in open('${f_exist_cidr}') if v.strip())
new = []
seen = set()
for v in open('${f_ci_ipcidr}'):
    v = v.strip()
    if not v: continue
    k = v.lower()
    if k not in exist and k not in seen:
        seen.add(k)
        new.append(v)
open('${f_new_cidr}', 'w').write('\n'.join(new) + ('\n' if new else ''))
"

  merge_dedup "$f_exist_asn" "$f_ci_asn" "${WORKDIR}/ci_all_${tag}_asn.txt" asn
  python3 -c "
import sys
exist = set(v.strip() for v in open('${f_exist_asn}') if v.strip())
new = []
seen = set()
for v in open('${f_ci_asn}'):
    v = v.strip()
    if not v: continue
    if v not in exist and v not in seen:
        seen.add(v)
        new.append(v)
open('${f_new_asn}', 'w').write('\n'.join(new) + ('\n' if new else ''))
"

  if [[ ! -s "$f_new_cidr" ]] && [[ ! -s "$f_new_asn" ]]; then
    echo "[CLASH-IP] ${tag}: no new entries, skip"
    return 0
  fi

  echo "[CLASH-IP] ${tag}: +$(wc -l < "$f_new_cidr" | tr -d ' ') CIDRs  +$(wc -l < "$f_new_asn" | tr -d ' ') ASNs"

  # ── mrs（全量 cidr 重编译）───────────────────────────────────────────────
  local f_all_cidr="${WORKDIR}/ci_all_${tag}_cidr.txt"
  if [[ -s "$f_all_cidr" ]]; then
    convert_mrs ipcidr "$f_all_cidr" "$dst_mrs" || true
  fi

  # ── yaml（追加新增行）───────────────────────────────────────────────────
  [[ -f "$dst_yaml" ]] || echo "payload:" > "$dst_yaml"
  while IFS= read -r line; do [[ -z "$line" ]] && continue
    if [[ "$line" == *:* ]]; then echo "  - IP-CIDR6,${line}"
    else echo "  - IP-CIDR,${line}"; fi
  done < "$f_new_cidr" >> "$dst_yaml"
  while IFS= read -r line; do [[ -z "$line" ]] && continue
    echo "  - IP-ASN,${line}"
  done < "$f_new_asn" >> "$dst_yaml"

  # ── list（追加新增行）───────────────────────────────────────────────────
  while IFS= read -r line; do [[ -z "$line" ]] && continue
    if [[ "$line" == *:* ]]; then echo "IP-CIDR6,${line}"
    else echo "IP-CIDR,${line}"; fi
  done < "$f_new_cidr" >> "$dst_list"
  while IFS= read -r line; do [[ -z "$line" ]] && continue
    echo "IP-ASN,${line}"
  done < "$f_new_asn" >> "$dst_list"

  # ── json + srs（从 list 重新生成）───────────────────────────────────────
  python3 -c "
import json
cidrs = []
for line in open('${dst_list}'):
    line = line.strip()
    if line.startswith('IP-CIDR6,'): cidrs.append(line[9:])
    elif line.startswith('IP-CIDR,'): cidrs.append(line[8:])
rule = {'ip_cidr': cidrs} if cidrs else {}
out = {'version': 3, 'rules': [rule] if rule else []}
open('${dst_json}', 'w').write(json.dumps(out, ensure_ascii=False, separators=(',', ':')) + '\n')
"
  compile_srs "$dst_json" "$dst_srs" || true

  # ── QX list（跳过 ASN，追加新增行）─────────────────────────────────────
  while IFS= read -r line; do [[ -z "$line" ]] && continue
    if [[ "$line" == *:* ]]; then echo "IP-CIDR6, ${line}"
    else echo "IP-CIDR, ${line}"; fi
  done < "$f_new_cidr" >> "$dst_qx"
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

  apply_clash_geosite "$tag" \
    "$f_suffix" "$f_domain" "$f_keyword" "$f_regexp" \
    "$f_process" "$f_process_re" "$f_asn"

  f_ipcidr="${WORKDIR}/clash_ip/${tag}.ipcidr.txt"
  f_ip_asn="${WORKDIR}/clash_ip/${tag}.asn.txt"
  [[ -f "$f_ipcidr" ]] || : > "$f_ipcidr"
  [[ -f "$f_ip_asn" ]] || : > "$f_ip_asn"

  local_empty=true
  for fx in "$f_suffix" "$f_domain" "$f_keyword" "$f_regexp" \
            "$f_process" "$f_process_re" "$f_asn" "$f_ipcidr"; do
    [[ -s "$fx" ]] && { local_empty=false; break; }
  done
  if $local_empty; then geosite_skip=$((geosite_skip+1)); continue; fi

  # mrs（domain行为：suffix + domain）
  f_mrs="${WORKDIR}/gs_mrs/${tag}.txt"
  cat "$f_suffix" "$f_domain" > "$f_mrs"
  if [[ -s "$f_mrs" ]]; then
    convert_mrs domain "$f_mrs" "${OUT_GEOSITE}/${tag}.mrs" || true
  fi

  _clash_yaml="${CLASH_DIR}/${tag}.yaml"
  [[ -f "$_clash_yaml" ]] || _clash_yaml=""

  make_yaml_domain \
    "$f_suffix" "$f_domain" "$f_keyword" "$f_regexp" \
    "$f_process" "$f_process_re" "$_clash_yaml" \
    "${OUT_GEOSITE}/${tag}.yaml"

  make_list_domain \
    "$f_suffix" "$f_domain" "$f_keyword" "$f_regexp" \
    "$f_process" "$f_process_re" "$_clash_yaml" \
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

# ── clash-only geosite ───────────────────────────────────────────────────────
echo "[4b/8] Process clash-only geosite..."
clash_geosite_ok=0

if [[ -d "$CLASH_DIR" ]]; then
  while IFS= read -r cyaml; do
    tag="$(basename "$cyaml" .yaml)"
    [[ -n "${geosite_processed[$tag]+x}" ]] && continue

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

    f_ipcidr="${ctmp}/${tag}.ipcidr.clash.txt"
    f_ip_asn="${ctmp}/${tag}.asn.clash.txt"
    [[ -f "$f_ipcidr" ]] || : > "$f_ipcidr"
    [[ -f "$f_ip_asn" ]] || : > "$f_ip_asn"

    # 同时缓存到 clash_ip/ 供 geoip 流程使用
    mkdir -p "${WORKDIR}/clash_ip"
    cp -f "$f_ipcidr" "${WORKDIR}/clash_ip/${tag}.ipcidr.txt"
    cp -f "$f_ip_asn"  "${WORKDIR}/clash_ip/${tag}.asn.txt"

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
      "$f_process" "$f_process_re" "$cyaml" \
      "${OUT_GEOSITE}/${tag}.yaml"

    make_list_domain \
      "$f_suffix" "$f_domain" "$f_keyword" "$f_regexp" \
      "$f_process" "$f_process_re" "$cyaml" \
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

  f_ipcidr="${WORKDIR}/geoip_cidr_${tag}.txt"
  f_asn="${WORKDIR}/geoip_asn_${tag}.txt"
  cp "$f" "$f_ipcidr"
  : > "$f_asn"

  # 优先从 clash_ip/ 缓存补充（geosite 流程已解析过同名 clash yaml 的 IP 条目）
  if [[ -s "${WORKDIR}/clash_ip/${tag}.ipcidr.txt" ]]; then
    merge_dedup "$f_ipcidr" "${WORKDIR}/clash_ip/${tag}.ipcidr.txt" \
      "${WORKDIR}/merged/${tag}_gi_ipcidr.txt" ipcidr \
      && cp -f "${WORKDIR}/merged/${tag}_gi_ipcidr.txt" "$f_ipcidr" || true
  fi
  if [[ -s "${WORKDIR}/clash_ip/${tag}.asn.txt" ]]; then
    merge_dedup "$f_asn" "${WORKDIR}/clash_ip/${tag}.asn.txt" \
      "${WORKDIR}/merged/${tag}_gi_asn.txt" asn \
      && cp -f "${WORKDIR}/merged/${tag}_gi_asn.txt" "$f_asn" || true
  fi

  # 再跑 apply_clash_geoip（处理 clash yaml 里直接以 geoip tag 命名的情况）
  apply_clash_geoip "$tag" "$f_ipcidr" "$f_asn"

  emit_geoip_all "$tag" "$f_ipcidr" "$f_asn"

  geoip_processed["$tag"]=1
  geoip_ok=$((geoip_ok+1))
done < <(find "$WORKDIR/geoip_txt" -type f -name '*.txt' | sort)

echo "[INFO] geoip geo pass: ok=$geoip_ok"

# ── clash-only geoip ─────────────────────────────────────────────────────────
echo "[5b/8] Process clash-only geoip..."
clash_geoip_ok=0

if [[ -d "$CLASH_DIR" ]]; then
  while IFS= read -r cyaml; do
    tag="$(basename "$cyaml" .yaml)"
    [[ -n "${geoip_processed[$tag]+x}" ]] && continue

    if [[ -f "${WORKDIR}/clash_ip/${tag}.ipcidr.txt" ]]; then
      f_ipcidr="${WORKDIR}/clash_ip/${tag}.ipcidr.txt"
      f_asn="${WORKDIR}/clash_ip/${tag}.asn.txt"
      [[ -f "$f_asn" ]] || : > "$f_asn"
    else
      ctmp="${WORKDIR}/clash_parsed"
      mkdir -p "$ctmp"
      parse_clash_yaml "$cyaml" "$ctmp" "${tag}_geoip2"
      f_ipcidr="${ctmp}/${tag}_geoip2.ipcidr.clash.txt"
      f_asn="${ctmp}/${tag}_geoip2.asn.clash.txt"
      [[ -f "$f_asn" ]] || : > "$f_asn"
    fi

    # 只有确实含 IP 条目才建文件
    [[ -s "$f_ipcidr" ]] || continue

    echo "[CLASH-ONLY] geoip/${tag} <- ${cyaml}"
    emit_geoip_all "$tag" "$f_ipcidr" "$f_asn"

    clash_geoip_ok=$((clash_geoip_ok+1))
  done < <(find "$CLASH_DIR" -maxdepth 1 -name '*.yaml' | sort)
fi

echo "[INFO] geoip clash-only: ok=$clash_geoip_ok"

# ══════════════════════════════════════════════════════════════════════════════
# 6. 处理 clash-ip/（纯 IP 规则，合并进 geo/geoip/ 五格式 + QX/geoip/）
# ══════════════════════════════════════════════════════════════════════════════
echo "[6/8] Process clash-ip/..."
clash_ip_ok=0

if [[ -d "$CLASH_IP_DIR" ]]; then
  while IFS= read -r cyaml; do
    tag="$(basename "$cyaml" .yaml)"
    echo "[CLASH-IP] processing ${tag} <- ${cyaml}"

    # 解析 clash-ip yaml（只取 ipcidr + asn 桶）
    ctmp="${WORKDIR}/clash_ip_parsed"
    mkdir -p "$ctmp"
    parse_clash_yaml "$cyaml" "$ctmp" "ci_${tag}"

    f_ci_ipcidr="${ctmp}/ci_${tag}.ipcidr.clash.txt"
    f_ci_asn="${ctmp}/ci_${tag}.asn.clash.txt"
    [[ -f "$f_ci_ipcidr" ]] || : > "$f_ci_ipcidr"
    [[ -f "$f_ci_asn"    ]] || : > "$f_ci_asn"

    # 无 IP 条目则跳过
    if [[ ! -s "$f_ci_ipcidr" ]] && [[ ! -s "$f_ci_asn" ]]; then
      echo "[CLASH-IP] ${tag}: no IP entries, skip"
      continue
    fi

    # 确保输出目录存在
    mkdir -p "$OUT_GEOIP" "$OUT_QX_GEOIP"

    emit_clash_ip_merge "$tag" "$f_ci_ipcidr" "$f_ci_asn"
    clash_ip_ok=$((clash_ip_ok+1))
  done < <(find "$CLASH_IP_DIR" -maxdepth 1 -name "*.yaml" | sort)
fi

echo "[INFO] clash-ip: ok=$clash_ip_ok"

# ══════════════════════════════════════════════════════════════════════════════
# 7. 统计
# ══════════════════════════════════════════════════════════════════════════════
echo "[7/8] Final counts:"
echo "  geo/geosite/   mrs  : $(find "$OUT_GEOSITE"    -name '*.mrs'  | wc -l | tr -d ' ')"
echo "  geo/geosite/   yaml : $(find "$OUT_GEOSITE"    -name '*.yaml' | wc -l | tr -d ' ')"
echo "  geo/geosite/   list : $(find "$OUT_GEOSITE"    -name '*.list' | wc -l | tr -d ' ')"
echo "  geo/geosite/   json : $(find "$OUT_GEOSITE"    -name '*.json' | wc -l | tr -d ' ')"
echo "  geo/geosite/   srs  : $(find "$OUT_GEOSITE"    -name '*.srs'  | wc -l | tr -d ' ')"
echo "  geo/geoip/     mrs  : $(find "$OUT_GEOIP"      -name '*.mrs'  | wc -l | tr -d ' ')"
echo "  geo/geoip/     yaml : $(find "$OUT_GEOIP"      -name '*.yaml' | wc -l | tr -d ' ')"
echo "  geo/geoip/     list : $(find "$OUT_GEOIP"      -name '*.list' | wc -l | tr -d ' ')"
echo "  geo/geoip/     json : $(find "$OUT_GEOIP"      -name '*.json' | wc -l | tr -d ' ')"
echo "  geo/geoip/     srs  : $(find "$OUT_GEOIP"      -name '*.srs'  | wc -l | tr -d ' ')"
echo "  QX/geosite/    list : $(find "$OUT_QX_GEOSITE" -name '*.list' | wc -l | tr -d ' ')"
echo "  QX/geoip/      list : $(find "$OUT_QX_GEOIP"   -name '*.list' | wc -l | tr -d ' ')"
echo "  clash-ip merged     : $clash_ip_ok"

echo "[8/8] Done."