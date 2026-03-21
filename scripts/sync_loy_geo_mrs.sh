#!/usr/bin/env bash
# sync_loy_geo_mrs.sh
# 从 Loyalsoldier 下载 geoip/geosite .dat，拆分并输出五种格式：
#   geo/rules/  ->  .mrs  .yaml  .list
#   geo/sing/   ->  .json  .srs
set -euo pipefail

GEOIP_URL='https://cdn.jsdelivr.net/gh/Loyalsoldier/geoip@release/geoip.dat'
GEOSITE_URL='https://cdn.jsdelivr.net/gh/Loyalsoldier/v2ray-rules-dat@release/geosite.dat'

OUT_RULES_DIR='geo/rules'   # mrs + yaml + list
OUT_SING_DIR='geo/sing'     # json + srs

MIHOMO_BIN="${MIHOMO_BIN:-./mihomo}"
SINGBOX_BIN="${SINGBOX_BIN:-./sing-box}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "$REPO_ROOT"

echo "[INFO] repo root: $(pwd)"

command -v v2dat       >/dev/null 2>&1 || { echo "ERROR: v2dat not found";        exit 1; }
[ -x "$MIHOMO_BIN"  ]                  || { echo "ERROR: mihomo not executable";   exit 1; }
[ -x "$SINGBOX_BIN" ]                  || { echo "ERROR: sing-box not executable"; exit 1; }

echo "[INFO] mihomo version:";   "$MIHOMO_BIN"  -v   || true
echo "[INFO] sing-box version:"; "$SINGBOX_BIN" version || true

# ── 工作目录 ──────────────────────────────────────────────────────────────────
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

# ── 1. 下载 ───────────────────────────────────────────────────────────────────
echo "[1/7] Download dat files..."
curl -fsSL --retry 3 --retry-delay 2 "$GEOIP_URL"   -o "$WORKDIR/geoip.dat"
curl -fsSL --retry 3 --retry-delay 2 "$GEOSITE_URL" -o "$WORKDIR/geosite.dat"

# ── 2. 解包 ───────────────────────────────────────────────────────────────────
echo "[2/7] Unpack dat -> txt..."
mkdir -p "$WORKDIR/geoip_txt" "$WORKDIR/geosite_txt"
v2dat unpack geoip   -o "$WORKDIR/geoip_txt"   "$WORKDIR/geoip.dat"
v2dat unpack geosite -o "$WORKDIR/geosite_txt" "$WORKDIR/geosite.dat"

GEOIP_TXT_COUNT="$(find "$WORKDIR/geoip_txt"   -type f -name '*.txt' | wc -l | tr -d ' ')"
GEOSITE_TXT_COUNT="$(find "$WORKDIR/geosite_txt" -type f -name '*.txt' | wc -l | tr -d ' ')"
echo "[DEBUG] geoip txt=$GEOIP_TXT_COUNT  geosite txt=$GEOSITE_TXT_COUNT"

if [ "$GEOIP_TXT_COUNT" -eq 0 ] || [ "$GEOSITE_TXT_COUNT" -eq 0 ]; then
  echo "ERROR: unpack produced 0 txt files"; exit 1
fi

# ── 3. 清空旧输出 ─────────────────────────────────────────────────────────────
echo "[3/7] Clean output dirs (full sync)..."
rm -rf "$OUT_RULES_DIR" "$OUT_SING_DIR"
mkdir -p "$OUT_RULES_DIR" "$OUT_SING_DIR" geo

# ══════════════════════════════════════════════════════════════════════════════
# 辅助函数
# ══════════════════════════════════════════════════════════════════════════════

# ── mrs (mihomo binary) ──────────────────────────────────────────────────────
convert_mrs() {
  local behavior="$1" src="$2" dst="$3"
  local tmp="${dst}.tmp"
  rm -f "$tmp" 2>/dev/null || true
  "$MIHOMO_BIN" convert-ruleset "$behavior" text "$src" "$tmp"
  if [ ! -s "$tmp" ]; then rm -f "$tmp"; return 1; fi
  mv -f "$tmp" "$dst"
}

# ── yaml (mihomo rule-provider payload) ─────────────────────────────────────
# geosite: behavior=domain
#   DOMAIN-SUFFIX 行 (以 . 开头) -> domain-suffix 原样写入 payload
#   其他 -> domain 写入 payload
# geoip: behavior=ipcidr
#   每行就是一条 CIDR -> 写入 payload
make_yaml_domain() {
  local src="$1" dst="$2"
  {
    echo "payload:"
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      if [[ "$line" == .* ]]; then
        echo "  - '${line}'"          # domain-suffix
      else
        echo "  - '${line}'"          # domain
      fi
    done < "$src"
  } > "$dst"
}

make_yaml_ipcidr() {
  local src="$1" dst="$2"
  {
    echo "payload:"
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      echo "  - '${line}'"
    done < "$src"
  } > "$dst"
}

# ── list (Surge/小火箭) ───────────────────────────────────────────────────────
# geosite:
#   以 . 开头 -> DOMAIN-SUFFIX,example.com（去掉前导点）
#   其他      -> DOMAIN,example.com
# geoip:
#   IPv6 CIDR（含 :） -> IP-CIDR6,
#   IPv4            -> IP-CIDR,
make_list_domain() {
  local src="$1" dst="$2"
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    if [[ "$line" == .* ]]; then
      echo "DOMAIN-SUFFIX,${line#.}"
    else
      echo "DOMAIN,${line}"
    fi
  done < "$src" > "$dst"
}

make_list_ipcidr() {
  local src="$1" dst="$2"
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    if [[ "$line" == *:* ]]; then
      echo "IP-CIDR6,${line}"
    else
      echo "IP-CIDR,${line}"
    fi
  done < "$src" > "$dst"
}

# ── sing-box json (version 3) ────────────────────────────────────────────────
# geosite: 区分 domain (精确) 和 domain_suffix (以 . 开头)
make_singbox_json_domain() {
  local src="$1" dst="$2"
  local domains=() suffixes=()

  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    if [[ "$line" == .* ]]; then
      suffixes+=("${line#.}")
    else
      domains+=("$line")
    fi
  done < "$src"

  # 构造 JSON（用 python3 保证转义正确）
  python3 - "$dst" "${domains[@]+"${domains[@]}"}" <<'PYEOF'
import sys, json

dst = sys.argv[1]
args = sys.argv[2:]

# 分隔 domains / suffixes 靠调用方分开传
# 此处 args 全是 domains（suffixes 单独处理），见外层 wrapper
domains = args

rule = {}
if domains:
    rule["domain"] = domains

out = {"version": 3, "rules": [rule] if rule else []}
with open(dst, "w") as f:
    json.dump(out, f, ensure_ascii=False, separators=(',', ':'))
    f.write('\n')
PYEOF
}

# 更完整的版本：domains + suffixes 一起
make_singbox_json_domain_full() {
  local src="$1" dst="$2"
  python3 - "$src" "$dst" <<'PYEOF'
import sys, json

src, dst = sys.argv[1], sys.argv[2]
domains = []
suffixes = []

with open(src) as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        if line.startswith('.'):
            suffixes.append(line[1:])
        else:
            domains.append(line)

rule = {}
if domains:
    rule["domain"] = domains
if suffixes:
    rule["domain_suffix"] = suffixes

out = {"version": 3, "rules": [rule] if rule else []}
with open(dst, "w") as f:
    json.dump(out, f, ensure_ascii=False, separators=(',', ':'))
    f.write('\n')
PYEOF
}

make_singbox_json_ipcidr() {
  local src="$1" dst="$2"
  python3 - "$src" "$dst" <<'PYEOF'
import sys, json

src, dst = sys.argv[1], sys.argv[2]
cidr4 = []
cidr6 = []

with open(src) as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        if ':' in line:
            cidr6.append(line)
        else:
            cidr4.append(line)

rule = {}
if cidr4:
    rule["ip_cidr"] = cidr4
if cidr6:
    rule["ip_cidr"] = rule.get("ip_cidr", []) + cidr6  # sing-box ip_cidr 支持混合

out = {"version": 3, "rules": [rule] if rule else []}
with open(dst, "w") as f:
    json.dump(out, f, ensure_ascii=False, separators=(',', ':'))
    f.write('\n')
PYEOF
}

# ── srs (sing-box compile) ───────────────────────────────────────────────────
compile_srs() {
  local json="$1" srs="$2"
  local tmp="${srs}.tmp"
  rm -f "$tmp" 2>/dev/null || true
  "$SINGBOX_BIN" rule-set compile --output "$tmp" "$json"
  if [ ! -s "$tmp" ]; then rm -f "$tmp"; return 1; fi
  mv -f "$tmp" "$srs"
}

# ══════════════════════════════════════════════════════════════════════════════
# 4. 处理 geosite
# ══════════════════════════════════════════════════════════════════════════════
echo "[4/7] Process geosite..."
mkdir -p "$WORKDIR/geosite_clean"

geosite_ok=0
geosite_skip=0

while IFS= read -r f; do
  base="$(basename "$f")"
  tag="${base#geosite_}"; tag="${tag%.txt}"
  [[ "$tag" == "$base" ]] && tag="${base%.txt}"

  clean="$WORKDIR/geosite_clean/${tag}.txt"
  : > "$clean"

  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    case "$line" in
      keyword:*|regexp:*) continue ;;
      full:*)
        echo "${line#full:}" >> "$clean"
        ;;
      *)
        # 确保 domain-suffix 以 . 开头
        if [[ "$line" == .* || "$line" == *"*"* ]]; then
          echo "$line" >> "$clean"
        else
          echo ".$line" >> "$clean"
        fi
        ;;
    esac
  done < "$f"

  if [[ ! -s "$clean" ]]; then
    geosite_skip=$((geosite_skip+1)); continue
  fi

  # mrs
  mrs="${OUT_RULES_DIR}/${tag}.mrs"
  convert_mrs domain "$clean" "$mrs" || true

  # yaml
  make_yaml_domain "$clean" "${OUT_RULES_DIR}/${tag}.yaml"

  # list
  make_list_domain "$clean" "${OUT_RULES_DIR}/${tag}.list"

  # json + srs
  json="${OUT_SING_DIR}/${tag}.json"
  make_singbox_json_domain_full "$clean" "$json"
  compile_srs "$json" "${OUT_SING_DIR}/${tag}.srs" || true

  geosite_ok=$((geosite_ok+1))
done < <(find "$WORKDIR/geosite_txt" -type f -name '*.txt' | sort)

echo "[INFO] geosite done: ok=$geosite_ok  skipped_empty=$geosite_skip"

# ══════════════════════════════════════════════════════════════════════════════
# 5. 处理 geoip
# ══════════════════════════════════════════════════════════════════════════════
echo "[5/7] Process geoip..."

geoip_ok=0

while IFS= read -r f; do
  base="$(basename "$f")"
  tag="${base#geoip_}"; tag="${tag%.txt}"
  [[ "$tag" == "$base" ]] && tag="${base%.txt}"

  [[ ! -s "$f" ]] && continue

  # mrs
  convert_mrs ipcidr "$f" "${OUT_RULES_DIR}/${tag}.mrs" || true

  # yaml
  make_yaml_ipcidr "$f" "${OUT_RULES_DIR}/${tag}.yaml"

  # list
  make_list_ipcidr "$f" "${OUT_RULES_DIR}/${tag}.list"

  # json + srs
  json="${OUT_SING_DIR}/${tag}.json"
  make_singbox_json_ipcidr "$f" "$json"
  compile_srs "$json" "${OUT_SING_DIR}/${tag}.srs" || true

  geoip_ok=$((geoip_ok+1))
done < <(find "$WORKDIR/geoip_txt" -type f -name '*.txt' | sort)

echo "[INFO] geoip done: ok=$geoip_ok"

# ══════════════════════════════════════════════════════════════════════════════
# 6. 统计
# ══════════════════════════════════════════════════════════════════════════════
echo "[6/7] Final counts:"
echo "  geo/rules/  mrs  : $(find "$OUT_RULES_DIR" -name '*.mrs'  | wc -l | tr -d ' ')"
echo "  geo/rules/  yaml : $(find "$OUT_RULES_DIR" -name '*.yaml' | wc -l | tr -d ' ')"
echo "  geo/rules/  list : $(find "$OUT_RULES_DIR" -name '*.list' | wc -l | tr -d ' ')"
echo "  geo/sing/   json : $(find "$OUT_SING_DIR"  -name '*.json' | wc -l | tr -d ' ')"
echo "  geo/sing/   srs  : $(find "$OUT_SING_DIR"  -name '*.srs'  | wc -l | tr -d ' ')"

echo "[7/7] Done."
