#!/usr/bin/env bash
# sync_loy_geo_mrs.sh
# 从 Loyalsoldier 下载 geoip/geosite .dat，拆分并输出五种格式：
#   geo/geosite/        ->  .mrs  .yaml  .list  .json  .srs
#   geo/geoip/          ->  .mrs  .yaml  .list  .json  .srs
#   QX/geosite          ->  .list
#   QX/geoip            ->  .list
#
# geosite 支持四种规则类型：
#   普通条目  -> domain-suffix  (.example.com)
#   full:     -> domain 精确    (api.example.com)
#   keyword:  -> domain-keyword (写入 yaml/list/json/srs，mrs 不支持跳过)
#   regexp:   -> domain-regex   (写入 yaml/list/json/srs，mrs 不支持跳过；QX 不支持跳过)
#
# geoip 支持：
#   IPv4 CIDR -> IP-CIDR
#   IPv6 CIDR -> IP-CIDR6（自动区分）
set -euo pipefail

GEOIP_URL='https://cdn.jsdelivr.net/gh/Loyalsoldier/geoip@release/geoip.dat'
GEOSITE_URL='https://cdn.jsdelivr.net/gh/Loyalsoldier/v2ray-rules-dat@release/geosite.dat'

OUT_GEOSITE='geo/geosite'
OUT_GEOIP='geo/geoip'
OUT_QX_GEOSITE='QX/geosite'
OUT_QX_GEOIP='QX/geoip'

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
make_yaml_domain() {
  local f_suffix="$1" f_domain="$2" f_keyword="$3" f_regexp="$4" dst="$5"
  {
    echo "payload:"
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      echo "  - DOMAIN-SUFFIX,${line#.}"
    done < "$f_suffix"
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      echo "  - DOMAIN,${line}"
    done < "$f_domain"
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      echo "  - DOMAIN-KEYWORD,${line}"
    done < "$f_keyword"
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

# ── list（geosite，mihomo/Surge/小火箭）──────────────────────────────────────
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

# ── list（geoip，mihomo/Surge/小火箭）────────────────────────────────────────
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

# ── list QX（geosite，QuantumultX）───────────────────────────────────────────
make_qx_list_domain() {
  local f_suffix="$1" f_domain="$2" f_keyword="$3" dst="$4"
  # regexp: QX 不支持，跳过
  {
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      echo "HOST-SUFFIX, ${line#.}"
    done < "$f_suffix"
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      echo "HOST, ${line}"
    done < "$f_domain"
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      echo "HOST-KEYWORD, ${line}"
    done < "$f_keyword"
  } > "$dst"
}

# ── list QX（geoip，QuantumultX）─────────────────────────────────────────────
make_qx_list_ipcidr() {
  local src="$1" dst="$2"
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    if [[ "$line" == *:* ]]; then
      echo "IP-CIDR6, ${line}"
    else
      echo "IP-CIDR, ${line}"
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

suffixes = read_lines(f_suffix)
domains  = read_lines(f_domain)
keywords = read_lines(f_keyword)
regexps  = read_lines(f_regexp)

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
  "$WORKDIR/gs_mrs"

geosite_ok=0
geosite_skip=0

while IFS= read -r f; do
  base="$(basename "$f")"
  tag="${base#geosite_}"; tag="${tag%.txt}"
  [[ "$tag" == "$base" ]] && tag="${base%.txt}"

  f_suffix="${WORKDIR}/gs_suffix/${tag}.txt"
  f_domain="${WORKDIR}/gs_domain/${tag}.txt"
  f_keyword="${WORKDIR}/gs_keyword/${tag}.txt"
  f_regexp="${WORKDIR}/gs_regexp/${tag}.txt"
  : > "$f_suffix"; : > "$f_domain"; : > "$f_keyword"; : > "$f_regexp"

  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    case "$line" in
      keyword:*) echo "${line#keyword:}" >> "$f_keyword" ;;
      regexp:*)  echo "${line#regexp:}"  >> "$f_regexp"  ;;
      full:*)    echo "${line#full:}"    >> "$f_domain"  ;;
      *)
        if [[ "$line" == .* ]]; then
          echo "$line"  >> "$f_suffix"
        else
          echo ".$line" >> "$f_suffix"
        fi
        ;;
    esac
  done < "$f"

  if [[ ! -s "$f_suffix" && ! -s "$f_domain" && ! -s "$f_keyword" && ! -s "$f_regexp" ]]; then
    geosite_skip=$((geosite_skip+1)); continue
  fi

  # mrs：只用 suffix+domain
  f_mrs="${WORKDIR}/gs_mrs/${tag}.txt"
  cat "$f_suffix" "$f_domain" > "$f_mrs"
  if [[ -s "$f_mrs" ]]; then
    convert_mrs domain "$f_mrs" "${OUT_GEOSITE}/${tag}.mrs" || true
  fi

  make_yaml_domain "$f_suffix" "$f_domain" "$f_keyword" "$f_regexp" \
    "${OUT_GEOSITE}/${tag}.yaml"

  make_list_domain "$f_suffix" "$f_domain" "$f_keyword" "$f_regexp" \
    "${OUT_GEOSITE}/${tag}.list"

  make_qx_list_domain "$f_suffix" "$f_domain" "$f_keyword" \
    "${OUT_QX_GEOSITE}/${tag}.list"

  json="${OUT_GEOSITE}/${tag}.json"
  make_singbox_json_domain "$f_suffix" "$f_domain" "$f_keyword" "$f_regexp" "$json"
  compile_srs "$json" "${OUT_GEOSITE}/${tag}.srs" || true

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

  convert_mrs ipcidr "$f" "${OUT_GEOIP}/${tag}.mrs"    || true
  make_yaml_ipcidr   "$f"  "${OUT_GEOIP}/${tag}.yaml"
  make_list_ipcidr   "$f"  "${OUT_GEOIP}/${tag}.list"
  make_qx_list_ipcidr "$f" "${OUT_QX_GEOIP}/${tag}.list"

  json="${OUT_GEOIP}/${tag}.json"
  make_singbox_json_ipcidr "$f" "$json"
  compile_srs "$json" "${OUT_GEOIP}/${tag}.srs"        || true

  geoip_ok=$((geoip_ok+1))
done < <(find "$WORKDIR/geoip_txt" -type f -name '*.txt' | sort)

echo "[INFO] geoip: ok=$geoip_ok"

# ══════════════════════════════════════════════════════════════════════════════
# 6. 统计
# ══════════════════════════════════════════════════════════════════════════════
echo "[6/7] Final counts:"
echo "  geo/geosite/        mrs  : $(find "$OUT_GEOSITE"    -name '*.mrs'  | wc -l | tr -d ' ')"
echo "  geo/geosite/        yaml : $(find "$OUT_GEOSITE"    -name '*.yaml' | wc -l | tr -d ' ')"
echo "  geo/geosite/        list : $(find "$OUT_GEOSITE"    -name '*.list' | wc -l | tr -d ' ')"
echo "  geo/geosite/        json : $(find "$OUT_GEOSITE"    -name '*.json' | wc -l | tr -d ' ')"
echo "  geo/geosite/        srs  : $(find "$OUT_GEOSITE"    -name '*.srs'  | wc -l | tr -d ' ')"
echo "  geo/geoip/          mrs  : $(find "$OUT_GEOIP"      -name '*.mrs'  | wc -l | tr -d ' ')"
echo "  geo/geoip/          yaml : $(find "$OUT_GEOIP"      -name '*.yaml' | wc -l | tr -d ' ')"
echo "  geo/geoip/          list : $(find "$OUT_GEOIP"      -name '*.list' | wc -l | tr -d ' ')"
echo "  geo/geoip/          json : $(find "$OUT_GEOIP"      -name '*.json' | wc -l | tr -d ' ')"
echo "  geo/geoip/          srs  : $(find "$OUT_GEOIP"      -name '*.srs'  | wc -l | tr -d ' ')"
echo "  QX/geosite/         list : $(find "$OUT_QX_GEOSITE" -name '*.list' | wc -l | tr -d ' ')"
echo "  QX/geoip/           list : $(find "$OUT_QX_GEOIP"   -name '*.list' | wc -l | tr -d ' ')"

echo "[7/7] Done."
