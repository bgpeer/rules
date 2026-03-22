#!/usr/bin/env bash
# sync_loy_geo_mrs.sh
# 从 Loyalsoldier 下载 geoip/geosite .dat，拆分并输出五种格式：
#   geo/rules/geosite/  ->  .mrs  .yaml  .list
#   geo/rules/geoip/    ->  .mrs  .yaml  .list
#   geo/sing/geosite/   ->  .json  .srs
#   geo/sing/geoip/     ->  .json  .srs
#
# geosite 支持五种规则类型：
#   普通条目  -> domain-suffix  (.example.com)
#   full:     -> domain 精确    (api.example.com)
#   keyword:  -> domain-keyword (保留，写入 yaml/list/json/srs，mrs 不支持跳过)
#   regexp:   -> domain-regex   (保留，写入 yaml/list/json/srs，mrs 不支持跳过)
#
# geoip 支持：
#   IPv4 CIDR -> IP-CIDR
#   IPv6 CIDR -> IP-CIDR6（自动区分）
set -euo pipefail

GEOIP_URL='https://cdn.jsdelivr.net/gh/Loyalsoldier/geoip@release/geoip.dat'
GEOSITE_URL='https://cdn.jsdelivr.net/gh/Loyalsoldier/v2ray-rules-dat@release/geosite.dat'

OUT_RULES_GEOSITE='geo/rules/geosite'
OUT_RULES_GEOIP='geo/rules/geoip'
OUT_SING_GEOSITE='geo/sing/geosite'
OUT_SING_GEOIP='geo/sing/geoip'

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
rm -rf geo/rules geo/sing
mkdir -p \
  "$OUT_RULES_GEOSITE" "$OUT_RULES_GEOIP" \
  "$OUT_SING_GEOSITE"  "$OUT_SING_GEOIP"

# ══════════════════════════════════════════════════════════════════════════════
# 辅助函数
# ══════════════════════════════════════════════════════════════════════════════

# ── mrs（仅 domain/suffix，keyword/regexp 不写入）────────────────────────────
convert_mrs() {
  local behavior="$1" src="$2" dst="$3"
  local tmp="${dst}.tmp"
  rm -f "$tmp" 2>/dev/null || true
  "$MIHOMO_BIN" convert-ruleset "$behavior" text "$src" "$tmp"
  if [ ! -s "$tmp" ]; then rm -f "$tmp"; return 1; fi
  mv -f "$tmp" "$dst"
}

# ── yaml（geosite）───────────────────────────────────────────────────────────
# 接收四个"已分类"的临时文件：suffix / domain / keyword / regexp
make_yaml_domain() {
  local f_suffix="$1" f_domain="$2" f_keyword="$3" f_regexp="$4" dst="$5"
  {
    echo "payload:"
    # domain-suffix
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      echo "  - DOMAIN-SUFFIX,${line#.}"
    done < "$f_suffix"
    # domain 精确
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      echo "  - DOMAIN,${line}"
    done < "$f_domain"
    # keyword
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      echo "  - DOMAIN-KEYWORD,${line}"
    done < "$f_keyword"
    # regexp
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      echo "  - DOMAIN-REGEX,${line}"
    done < "$f_regexp"
  } > "$dst"
}

# ── yaml（geoip）─────────────────────────────────────────────────────────────
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

# ── list（geosite）───────────────────────────────────────────────────────────
make_list_domain() {
  local f_suffix="$1" f_domain="$2" f_keyword="$3" f_regexp="$4" dst="$5"
  {
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      echo "DOMAIN-SUFFIX,${line#.}"
    done < "$f_suffix"
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      echo "DOMAIN,${line}"
    done < "$f_domain"
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      echo "DOMAIN-KEYWORD,${line}"
    done < "$f_keyword"
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      echo "DOMAIN-REGEX,${line}"
    done < "$f_regexp"
  } > "$dst"
}

# ── list（geoip）─────────────────────────────────────────────────────────────
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

# ── sing-box json（geosite，version 3）───────────────────────────────────────
make_singbox_json_domain() {
  local f_suffix="$1" f_domain="$2" f_keyword="$3" f_regexp="$4" dst="$5"
  python3 - "$f_suffix" "$f_domain" "$f_keyword" "$f_regexp" "$dst" <<'PYEOF'
import sys, json

f_suffix, f_domain, f_keyword, f_regexp, dst = sys.argv[1:]

def read_lines(path):
    with open(path) as f:
        return [l.strip() for l in f if l.strip()]

suffixes = read_lines(f_suffix)   # 保留前导点，如 ".example.com"
domains  = read_lines(f_domain)   # 精确，如 "api.example.com"
keywords = read_lines(f_keyword)  # 如 "pay"
regexps  = read_lines(f_regexp)   # 如 "^pay"

rule = {}
if domains:
    rule["domain"] = domains
if suffixes:
    rule["domain_suffix"] = suffixes
if keywords:
    rule["domain_keyword"] = keywords
if regexps:
    rule["domain_regex"] = regexps

out = {"version": 3, "rules": [rule] if rule else []}
with open(dst, "w") as f:
    json.dump(out, f, ensure_ascii=False, separators=(',', ':'))
    f.write('\n')
PYEOF
}

# ── sing-box json（geoip，version 3）─────────────────────────────────────────
make_singbox_json_ipcidr() {
  local src="$1" dst="$2"
  python3 - "$src" "$dst" <<'PYEOF'
import sys, json

src, dst = sys.argv[1], sys.argv[2]
cidrs = [l.strip() for l in open(src) if l.strip()]

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
mkdir -p \
  "$WORKDIR/gs_suffix" \
  "$WORKDIR/gs_domain" \
  "$WORKDIR/gs_keyword" \
  "$WORKDIR/gs_regexp" \
  "$WORKDIR/gs_mrs"   # mrs 只用 suffix+domain 合并文件

geosite_ok=0
geosite_skip=0

while IFS= read -r f; do
  base="$(basename "$f")"
  tag="${base#geosite_}"; tag="${tag%.txt}"
  [[ "$tag" == "$base" ]] && tag="${base%.txt}"

  # 四个分类文件
  f_suffix="${WORKDIR}/gs_suffix/${tag}.txt"
  f_domain="${WORKDIR}/gs_domain/${tag}.txt"
  f_keyword="${WORKDIR}/gs_keyword/${tag}.txt"
  f_regexp="${WORKDIR}/gs_regexp/${tag}.txt"
  : > "$f_suffix"; : > "$f_domain"; : > "$f_keyword"; : > "$f_regexp"

  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    case "$line" in
      keyword:*)
        echo "${line#keyword:}" >> "$f_keyword"
        ;;
      regexp:*)
        echo "${line#regexp:}" >> "$f_regexp"
        ;;
      full:*)
        # 精确域名，不加点
        echo "${line#full:}" >> "$f_domain"
        ;;
      *)
        # domain-suffix，确保以 . 开头
        if [[ "$line" == .* ]]; then
          echo "$line" >> "$f_suffix"
        else
          echo ".$line" >> "$f_suffix"
        fi
        ;;
    esac
  done < "$f"

  # 判断是否完全为空（四个文件都空）
  if [[ ! -s "$f_suffix" && ! -s "$f_domain" && ! -s "$f_keyword" && ! -s "$f_regexp" ]]; then
    geosite_skip=$((geosite_skip+1)); continue
  fi

  # mrs：只用 suffix+domain 合并文件（mihomo convert-ruleset 不支持 keyword/regexp）
  f_mrs="${WORKDIR}/gs_mrs/${tag}.txt"
  cat "$f_suffix" "$f_domain" > "$f_mrs"
  if [[ -s "$f_mrs" ]]; then
    convert_mrs domain "$f_mrs" "${OUT_RULES_GEOSITE}/${tag}.mrs" || true
  fi

  # yaml
  make_yaml_domain "$f_suffix" "$f_domain" "$f_keyword" "$f_regexp" \
    "${OUT_RULES_GEOSITE}/${tag}.yaml"

  # list
  make_list_domain "$f_suffix" "$f_domain" "$f_keyword" "$f_regexp" \
    "${OUT_RULES_GEOSITE}/${tag}.list"

  # json
  json="${OUT_SING_GEOSITE}/${tag}.json"
  make_singbox_json_domain "$f_suffix" "$f_domain" "$f_keyword" "$f_regexp" "$json"

  # srs
  compile_srs "$json" "${OUT_SING_GEOSITE}/${tag}.srs" || true

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

  convert_mrs ipcidr "$f" "${OUT_RULES_GEOIP}/${tag}.mrs"    || true
  make_yaml_ipcidr   "$f"  "${OUT_RULES_GEOIP}/${tag}.yaml"
  make_list_ipcidr   "$f"  "${OUT_RULES_GEOIP}/${tag}.list"

  json="${OUT_SING_GEOIP}/${tag}.json"
  make_singbox_json_ipcidr "$f" "$json"
  compile_srs "$json" "${OUT_SING_GEOIP}/${tag}.srs"         || true

  geoip_ok=$((geoip_ok+1))
done < <(find "$WORKDIR/geoip_txt" -type f -name '*.txt' | sort)

echo "[INFO] geoip: ok=$geoip_ok"

# ══════════════════════════════════════════════════════════════════════════════
# 6. 统计
# ══════════════════════════════════════════════════════════════════════════════
echo "[6/7] Final counts:"
echo "  geo/rules/geosite/  mrs  : $(find "$OUT_RULES_GEOSITE" -name '*.mrs'  | wc -l | tr -d ' ')"
echo "  geo/rules/geosite/  yaml : $(find "$OUT_RULES_GEOSITE" -name '*.yaml' | wc -l | tr -d ' ')"
echo "  geo/rules/geosite/  list : $(find "$OUT_RULES_GEOSITE" -name '*.list' | wc -l | tr -d ' ')"
echo "  geo/rules/geoip/    mrs  : $(find "$OUT_RULES_GEOIP"   -name '*.mrs'  | wc -l | tr -d ' ')"
echo "  geo/rules/geoip/    yaml : $(find "$OUT_RULES_GEOIP"   -name '*.yaml' | wc -l | tr -d ' ')"
echo "  geo/rules/geoip/    list : $(find "$OUT_RULES_GEOIP"   -name '*.list' | wc -l | tr -d ' ')"
echo "  geo/sing/geosite/   json : $(find "$OUT_SING_GEOSITE"  -name '*.json' | wc -l | tr -d ' ')"
echo "  geo/sing/geosite/   srs  : $(find "$OUT_SING_GEOSITE"  -name '*.srs'  | wc -l | tr -d ' ')"
echo "  geo/sing/geoip/     json : $(find "$OUT_SING_GEOIP"    -name '*.json' | wc -l | tr -d ' ')"
echo "  geo/sing/geoip/     srs  : $(find "$OUT_SING_GEOIP"    -name '*.srs'  | wc -l | tr -d ' ')"

echo "[7/7] Done."
