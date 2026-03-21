#!/usr/bin/env bash
# sync_loy_geo_mrs.sh
# 从 Loyalsoldier 下载 geoip/geosite .dat，拆分并输出五种格式：
#   geo/rules/  ->  .mrs  .yaml  .list
#   geo/sing/   ->  .json  .srs
#
# domain-suffix（以 . 开头）vs domain（精确）区分规则：
#   v2dat 解包后，非 full: 的条目加 . 前缀表示 suffix；full: 条目为精确 domain
#   yaml : DOMAIN-SUFFIX,example.com  /  DOMAIN,api.example.com
#   list : DOMAIN-SUFFIX,example.com  /  DOMAIN,api.example.com
#   json : domain_suffix [".example.com"]  /  domain ["api.example.com"]
#   mrs  : 由 mihomo convert-ruleset 内部处理（输入文本保持 . 前缀约定）
#   srs  : 由 sing-box rule-set compile 内部处理
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

echo "[INFO] mihomo version:";   "$MIHOMO_BIN"  -v       || true
echo "[INFO] sing-box version:"; "$SINGBOX_BIN" version  || true

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

GEOIP_TXT_COUNT="$(find   "$WORKDIR/geoip_txt"   -type f -name '*.txt' | wc -l | tr -d ' ')"
GEOSITE_TXT_COUNT="$(find "$WORKDIR/geosite_txt" -type f -name '*.txt' | wc -l | tr -d ' ')"
echo "[DEBUG] geoip txt=$GEOIP_TXT_COUNT  geosite txt=$GEOSITE_TXT_COUNT"

if [ "$GEOIP_TXT_COUNT" -eq 0 ] || [ "$GEOSITE_TXT_COUNT" -eq 0 ]; then
  echo "ERROR: unpack produced 0 txt files"; exit 1
fi

# ── 3. 清空旧输出（增删同步） ─────────────────────────────────────────────────
echo "[3/7] Clean output dirs (full sync)..."
rm -rf "$OUT_RULES_DIR" "$OUT_SING_DIR"
mkdir -p "$OUT_RULES_DIR" "$OUT_SING_DIR" geo

# ══════════════════════════════════════════════════════════════════════════════
# 辅助函数
# ══════════════════════════════════════════════════════════════════════════════

# ── mrs（mihomo binary ruleset）─────────────────────────────────────────────
# 输入文本：domain-suffix 以 . 开头，domain 不带点，mihomo 自己识别
convert_mrs() {
  local behavior="$1" src="$2" dst="$3"
  local tmp="${dst}.tmp"
  rm -f "$tmp" 2>/dev/null || true
  "$MIHOMO_BIN" convert-ruleset "$behavior" text "$src" "$tmp"
  if [ ! -s "$tmp" ]; then rm -f "$tmp"; return 1; fi
  mv -f "$tmp" "$dst"
}

# ── yaml（mihomo rule-provider payload）──────────────────────────────────────
# domain-suffix（以 . 开头） -> DOMAIN-SUFFIX,example.com
# domain（精确）             -> DOMAIN,api.example.com
make_yaml_domain() {
  local src="$1" dst="$2"
  {
    echo "payload:"
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      if [[ "$line" == .* ]]; then
        echo "  - DOMAIN-SUFFIX,${line#.}"
      else
        echo "  - DOMAIN,${line}"
      fi
    done < "$src"
  } > "$dst"
}

# geoip yaml：自动区分 IPv4 / IPv6
make_yaml_ipcidr() {
  local src="$1" dst="$2"
  {
    echo "payload:"
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      if [[ "$line" == *:* ]]; then
        echo "  - IP-CIDR6,${line}"
      else
        echo "  - IP-CIDR,${line}"
      fi
    done < "$src"
  } > "$dst"
}

# ── list（Surge / 小火箭）────────────────────────────────────────────────────
# domain-suffix（以 . 开头） -> DOMAIN-SUFFIX,example.com
# domain（精确）             -> DOMAIN,api.example.com
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

# geoip list：自动区分 IPv4 / IPv6
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

# ── sing-box json（version 3）────────────────────────────────────────────────
# domain-suffix（以 . 开头） -> domain_suffix 数组，值保留前导点（".example.com"）
# domain（精确）             -> domain 数组，值不带点（"api.example.com"）
make_singbox_json_domain() {
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
            suffixes.append(line)   # 保留前导点，如 ".example.com"
        else:
            domains.append(line)    # 精确域名，如 "api.example.com"

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

# geoip sing-box json：ip_cidr 混合 v4/v6
make_singbox_json_ipcidr() {
  local src="$1" dst="$2"
  python3 - "$src" "$dst" <<'PYEOF'
import sys, json

src, dst = sys.argv[1], sys.argv[2]
cidrs = []

with open(src) as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        cidrs.append(line)

rule = {}
if cidrs:
    rule["ip_cidr"] = cidrs

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
      keyword:*|regexp:*)
        # 跳过，无法转换为 domain/suffix 格式
        continue
        ;;
      full:*)
        # 精确域名，不加点
        echo "${line#full:}" >> "$clean"
        ;;
      *)
        # 普通条目 -> domain-suffix，确保以 . 开头
        if [[ "$line" == .* ]]; then
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
  convert_mrs domain "$clean" "${OUT_RULES_DIR}/${tag}.mrs" || true

  # yaml
  make_yaml_domain "$clean" "${OUT_RULES_DIR}/${tag}.yaml"

  # list
  make_list_domain "$clean" "${OUT_RULES_DIR}/${tag}.list"

  # json
  json="${OUT_SING_DIR}/${tag}.json"
  make_singbox_json_domain "$clean" "$json"

  # srs
  compile_srs "$json" "${OUT_SING_DIR}/${tag}.srs" || true

  geosite_ok=$((geosite_ok+1))
done < <(find "$WORKDIR/geosite_txt" -type f -name '*.txt' | sort)

echo "[INFO] geosite: ok=$geosite_ok  skipped_empty=$geosite_skip"

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

  # json
  json="${OUT_SING_DIR}/${tag}.json"
  make_singbox_json_ipcidr "$f" "$json"

  # srs
  compile_srs "$json" "${OUT_SING_DIR}/${tag}.srs" || true

  geoip_ok=$((geoip_ok+1))
done < <(find "$WORKDIR/geoip_txt" -type f -name '*.txt' | sort)

echo "[INFO] geoip: ok=$geoip_ok"

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
