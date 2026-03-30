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

GEOIP_URL='https://raw.githubusercontent.com/Loyalsoldier/geoip/release/geoip.dat'
GEOSITE_URL='https://raw.githubusercontent.com/Loyalsoldier/v2ray-rules-dat/release/geosite.dat'

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
HELPERS="${SCRIPT_DIR}/helpers.py"
cd "$REPO_ROOT"

echo "[INFO] repo root: $(pwd)"

# ── 前置检查 ──────────────────────────────────────────────────────────────────
command -v v2dat       >/dev/null 2>&1 || { echo "ERROR: v2dat not found";        exit 1; }
[ -x "$MIHOMO_BIN"  ]                  || { echo "ERROR: mihomo not executable";   exit 1; }
[ -x "$SINGBOX_BIN" ]                  || { echo "ERROR: sing-box not executable"; exit 1; }
command -v python3     >/dev/null 2>&1 || { echo "ERROR: python3 not found";       exit 1; }
[ -f "$HELPERS"      ]                 || { echo "ERROR: helpers.py not found at $HELPERS"; exit 1; }

echo "[INFO] mihomo version:";   "$MIHOMO_BIN"  -v       || true
echo "[INFO] sing-box version:"; "$SINGBOX_BIN" version  || true

# ── helpers.py 快捷调用 ──────────────────────────────────────────────────────
py() { python3 "$HELPERS" "$@"; }

# ── 失败计数 ──────────────────────────────────────────────────────────────────
mrs_fail=0
srs_fail=0

# ── 工作目录 ──────────────────────────────────────────────────────────────────
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

# ══════════════════════════════════════════════════════════════════════════════
# 1. 下载
# ══════════════════════════════════════════════════════════════════════════════
echo "[1/8] Download dat files..."
curl -fsSL --retry 3 --retry-delay 2 "$GEOIP_URL"   -o "$WORKDIR/geoip.dat"
curl -fsSL --retry 3 --retry-delay 2 "$GEOSITE_URL" -o "$WORKDIR/geosite.dat"

# ══════════════════════════════════════════════════════════════════════════════
# 2. 解包
# ══════════════════════════════════════════════════════════════════════════════
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

# ══════════════════════════════════════════════════════════════════════════════
# 3. 清空旧输出（增删同步）
# ══════════════════════════════════════════════════════════════════════════════
echo "[3/8] Clean output dirs (full sync)..."
rm -rf "$OUT_GEOSITE" "$OUT_GEOIP" "$OUT_QX_GEOSITE" "$OUT_QX_GEOIP"
mkdir -p "$OUT_GEOSITE" "$OUT_GEOIP" "$OUT_QX_GEOSITE" "$OUT_QX_GEOIP"

# ══════════════════════════════════════════════════════════════════════════════
# 辅助函数（仅 bash 部分，Python 逻辑全在 helpers.py）
# ══════════════════════════════════════════════════════════════════════════════

# ── mrs（仅 domain/suffix 或 ipcidr）────────────────────────────────────────
convert_mrs() {
  local behavior="$1" src="$2" dst="$3"
  local tmp="${dst}.tmp"
  rm -f "$tmp" 2>/dev/null || true
  if ! "$MIHOMO_BIN" convert-ruleset "$behavior" text "$src" "$tmp"; then
    mrs_fail=$((mrs_fail+1)); return 1
  fi
  if [ ! -s "$tmp" ]; then rm -f "$tmp"; mrs_fail=$((mrs_fail+1)); return 1; fi
  mv -f "$tmp" "$dst"
}

# ── srs（sing-box compile）───────────────────────────────────────────────────
compile_srs() {
  local json_file="$1" srs="$2"
  local tmp="${srs}.tmp"
  rm -f "$tmp" 2>/dev/null || true
  if ! "$SINGBOX_BIN" rule-set compile --output "$tmp" "$json_file"; then
    srs_fail=$((srs_fail+1)); return 1
  fi
  if [ ! -s "$tmp" ]; then rm -f "$tmp"; srs_fail=$((srs_fail+1)); return 1; fi
  mv -f "$tmp" "$srs"
}

# ── clash yaml 解析（带缓存，同一 yaml 只解析一次）──────────────────────────
declare -A clash_parsed_cache=()
CLASH_CACHE_DIR="${WORKDIR}/clash_parsed"
mkdir -p "$CLASH_CACHE_DIR"

ensure_clash_parsed() {
  local yaml_path="$1" tag="$2"
  if [[ -n "${clash_parsed_cache[${tag}]+x}" ]]; then return 0; fi
  py parse_clash "$yaml_path" "$CLASH_CACHE_DIR" "$tag"
  clash_parsed_cache["$tag"]=1
}

# ── 从 clash 缓存获取桶文件路径 ──────────────────────────────────────────────
clash_bucket_file() {
  local tag="$1" bucket="$2"
  echo "${CLASH_CACHE_DIR}/${tag}.${bucket}.clash.txt"
}

# ── apply_clash_geosite：融合 clash/ 进 geosite 分桶 ─────────────────────────
apply_clash_geosite() {
  local tag="$1" \
        f_suffix="$2"     f_domain="$3"     f_keyword="$4" \
        f_regexp="$5"     f_process="$6"    f_process_re="$7" \
        f_asn="$8"

  local clash_yaml="${CLASH_DIR}/${tag}.yaml"
  [[ -f "$clash_yaml" ]] || return 0

  echo "[MERGE] geosite/${tag} <- ${clash_yaml}"
  ensure_clash_parsed "$clash_yaml" "$tag"

  local mtmp="${WORKDIR}/merged"
  mkdir -p "$mtmp"

  # ipcidr + asn 桶：来自 clash yaml 的 IP 条目，缓存供后续 geoip 使用
  mkdir -p "${WORKDIR}/clash_ip"
  local f_geo_ipcidr="${WORKDIR}/clash_ip/${tag}.ipcidr.txt"
  local f_geo_ip_asn="${WORKDIR}/clash_ip/${tag}.asn.txt"
  : > "$f_geo_ipcidr"; : > "$f_geo_ip_asn"

  py merge_dedup "$f_geo_ipcidr" "$(clash_bucket_file "$tag" ipcidr)" \
    "${mtmp}/${tag}.ipcidr.txt" ipcidr \
    && cp -f "${mtmp}/${tag}.ipcidr.txt" "$f_geo_ipcidr" || true
  py merge_dedup "$f_geo_ip_asn" "$(clash_bucket_file "$tag" asn)" \
    "${mtmp}/${tag}.ip_asn.txt" asn \
    && cp -f "${mtmp}/${tag}.ip_asn.txt" "$f_geo_ip_asn" || true

  for bucket in suffix domain keyword regexp process process_re; do
    local geo_f
    case "$bucket" in
      suffix)     geo_f="$f_suffix"     ;;
      domain)     geo_f="$f_domain"     ;;
      keyword)    geo_f="$f_keyword"    ;;
      regexp)     geo_f="$f_regexp"     ;;
      process)    geo_f="$f_process"    ;;
      process_re) geo_f="$f_process_re" ;;
    esac
    py merge_dedup "$geo_f" "$(clash_bucket_file "$tag" "$bucket")" \
      "${mtmp}/${tag}.${bucket}.txt" "$bucket"
    cp -f "${mtmp}/${tag}.${bucket}.txt" "$geo_f"
  done
}

# ── apply_clash_geoip：融合 clash/ 进 geoip 分桶 ────────────────────────────
apply_clash_geoip() {
  local tag="$1" f_ipcidr="$2" f_asn="$3"

  local clash_yaml="${CLASH_DIR}/${tag}.yaml"
  [[ -f "$clash_yaml" ]] || return 0

  echo "[MERGE] geoip/${tag} <- ${clash_yaml}"
  ensure_clash_parsed "$clash_yaml" "${tag}_geoip"

  local mtmp="${WORKDIR}/merged"
  mkdir -p "$mtmp"

  for bucket in ipcidr asn; do
    local geo_f
    case "$bucket" in
      ipcidr) geo_f="$f_ipcidr" ;;
      asn)    geo_f="$f_asn"    ;;
    esac
    py merge_dedup "$geo_f" "$(clash_bucket_file "${tag}_geoip" "$bucket")" \
      "${mtmp}/${tag}_geoip.${bucket}.txt" "$bucket"
    cp -f "${mtmp}/${tag}_geoip.${bucket}.txt" "$geo_f"
  done
}

# ── emit_geosite_all：为一个 geosite tag 输出全部格式 ────────────────────────
emit_geosite_all() {
  local tag="$1" \
        f_suffix="$2" f_domain="$3" f_keyword="$4" f_regexp="$5" \
        f_process="$6" f_process_re="$7" f_ipcidr="$8" clash_yaml="$9"

  # mrs（domain 行为：suffix + domain）
  local f_mrs="${WORKDIR}/gs_mrs/${tag}.txt"
  cat "$f_suffix" "$f_domain" > "$f_mrs"
  if [[ -s "$f_mrs" ]]; then
    convert_mrs domain "$f_mrs" "${OUT_GEOSITE}/${tag}.mrs" || true
  fi

  # yaml
  py make_yaml_domain \
    "$f_suffix" "$f_domain" "$f_keyword" "$f_regexp" \
    "$f_process" "$f_process_re" "$clash_yaml" \
    "${OUT_GEOSITE}/${tag}.yaml"

  # list
  py make_list_domain \
    "$f_suffix" "$f_domain" "$f_keyword" "$f_regexp" \
    "$f_process" "$f_process_re" "$clash_yaml" \
    "${OUT_GEOSITE}/${tag}.list"

  # QX list
  py make_qx_domain "$f_suffix" "$f_domain" "$f_keyword" "$f_ipcidr" \
    "$clash_yaml" "${OUT_QX_GEOSITE}/${tag}.list"

  # json + srs
  local json="${OUT_GEOSITE}/${tag}.json"
  py make_json_domain "$f_suffix" "$f_domain" "$f_keyword" "$f_regexp" "$f_ipcidr" \
    "$clash_yaml" "$json"
  compile_srs "$json" "${OUT_GEOSITE}/${tag}.srs" || true
}

# ── emit_geoip_all：为一个 geoip tag 输出全部格式 ────────────────────────────
emit_geoip_all() {
  local tag="$1" f_ipcidr="$2" f_asn="$3"

  # mrs
  if [[ -s "$f_ipcidr" ]]; then
    convert_mrs ipcidr "$f_ipcidr" "${OUT_GEOIP}/${tag}.mrs" || true
  fi

  # yaml
  py make_yaml_ipcidr "$f_ipcidr" "$f_asn" "" "${OUT_GEOIP}/${tag}.yaml"

  # list
  py make_list_ipcidr "$f_ipcidr" "$f_asn" "" "${OUT_GEOIP}/${tag}.list"

  # QX list（跳过 ASN）
  py make_qx_ipcidr "$f_ipcidr" "" "${OUT_QX_GEOIP}/${tag}.list"

  # json + srs
  local json="${OUT_GEOIP}/${tag}.json"
  py make_json_ipcidr "$f_ipcidr" "" "$json"
  compile_srs "$json" "${OUT_GEOIP}/${tag}.srs" || true
}

# ── emit_clash_ip_merge：clash-ip/ 数据合并进 geo/geoip/ 全格式 ──────────────
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
    grep -E "^IP-CIDR6?," "$dst_list" | cut -d, -f2 >> "$f_exist_cidr" || true
    grep -E "^IP-ASN,"    "$dst_list" | cut -d, -f2 >> "$f_exist_asn"  || true
  fi

  # 计算新增条目
  local f_new_cidr="${WORKDIR}/ci_new_${tag}_cidr.txt"
  local f_new_asn="${WORKDIR}/ci_new_${tag}_asn.txt"
  py diff_new_entries "$f_exist_cidr" "$f_ci_ipcidr" "$f_new_cidr" cidr
  py diff_new_entries "$f_exist_asn"  "$f_ci_asn"    "$f_new_asn"  asn

  if [[ ! -s "$f_new_cidr" ]] && [[ ! -s "$f_new_asn" ]]; then
    echo "[CLASH-IP] ${tag}: no new entries, skip"
    return 0
  fi

  echo "[CLASH-IP] ${tag}: +$(wc -l < "$f_new_cidr" | tr -d ' ') CIDRs  +$(wc -l < "$f_new_asn" | tr -d ' ') ASNs"

  # mrs（全量 cidr 重编译）
  local f_all_cidr="${WORKDIR}/ci_all_${tag}_cidr.txt"
  py merge_dedup "$f_exist_cidr" "$f_ci_ipcidr" "$f_all_cidr" ipcidr
  if [[ -s "$f_all_cidr" ]]; then
    convert_mrs ipcidr "$f_all_cidr" "$dst_mrs" || true
  fi

  # yaml（追加新增行）
  [[ -f "$dst_yaml" ]] || echo "payload:" > "$dst_yaml"
  while IFS= read -r line; do [[ -z "$line" ]] && continue
    if [[ "$line" == *:* ]]; then echo "  - IP-CIDR6,${line}"
    else echo "  - IP-CIDR,${line}"; fi
  done < "$f_new_cidr" >> "$dst_yaml"
  while IFS= read -r line; do [[ -z "$line" ]] && continue
    echo "  - IP-ASN,${line}"
  done < "$f_new_asn" >> "$dst_yaml"

  # list（追加新增行）
  while IFS= read -r line; do [[ -z "$line" ]] && continue
    if [[ "$line" == *:* ]]; then echo "IP-CIDR6,${line}"
    else echo "IP-CIDR,${line}"; fi
  done < "$f_new_cidr" >> "$dst_list"
  while IFS= read -r line; do [[ -z "$line" ]] && continue
    echo "IP-ASN,${line}"
  done < "$f_new_asn" >> "$dst_list"

  # json + srs（从 list 重新生成）
  py rebuild_json_from_list "$dst_list" "$dst_json"
  compile_srs "$dst_json" "$dst_srs" || true

  # QX list（跳过 ASN，追加新增 CIDR）
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

  _clash_yaml="${CLASH_DIR}/${tag}.yaml"
  [[ -f "$_clash_yaml" ]] || _clash_yaml=""

  emit_geosite_all "$tag" \
    "$f_suffix" "$f_domain" "$f_keyword" "$f_regexp" \
    "$f_process" "$f_process_re" "$f_ipcidr" "$_clash_yaml"

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

    ensure_clash_parsed "$cyaml" "$tag"

    for bucket in suffix domain keyword regexp process process_re asn; do
      clash_f="$(clash_bucket_file "$tag" "$bucket")"
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

    f_ipcidr="$(clash_bucket_file "$tag" ipcidr)"
    f_ip_asn="$(clash_bucket_file "$tag" asn)"
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

    emit_geosite_all "$tag" \
      "$f_suffix" "$f_domain" "$f_keyword" "$f_regexp" \
      "$f_process" "$f_process_re" "$f_ipcidr" "$cyaml"

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

  # 纯 Loyalsoldier 数据
  f_ipcidr="${WORKDIR}/geoip_cidr_${tag}.txt"
  f_asn="${WORKDIR}/geoip_asn_${tag}.txt"
  cp "$f" "$f_ipcidr"
  : > "$f_asn"

  # 五种格式 + QX 只用纯 Loyalsoldier 数据
  emit_geoip_all "$tag" "$f_ipcidr" "$f_asn"

  # clash/ 的 IP 条目：merge 后只重编译 mrs
  f_clash_ipcidr="${WORKDIR}/geoip_clash_cidr_${tag}.txt"
  f_clash_asn="${WORKDIR}/geoip_clash_asn_${tag}.txt"
  cp "$f_ipcidr" "$f_clash_ipcidr"
  : > "$f_clash_asn"

  # 从 clash_ip/ 缓存补充（geosite 流程已解析过同名 clash yaml 的 IP 条目）
  if [[ -s "${WORKDIR}/clash_ip/${tag}.ipcidr.txt" ]]; then
    mtmp="${WORKDIR}/merged"
    mkdir -p "$mtmp"
    py merge_dedup "$f_clash_ipcidr" "${WORKDIR}/clash_ip/${tag}.ipcidr.txt" \
      "${mtmp}/${tag}_gi_ipcidr.txt" ipcidr \
      && cp -f "${mtmp}/${tag}_gi_ipcidr.txt" "$f_clash_ipcidr" || true
  fi

  # apply_clash_geoip（clash yaml 直接以 geoip tag 命名的情况）
  apply_clash_geoip "$tag" "$f_clash_ipcidr" "$f_clash_asn"

  # 只有 clash 带来新条目时才重编译 mrs
  if [[ -s "$f_clash_ipcidr" ]]; then
    convert_mrs ipcidr "$f_clash_ipcidr" "${OUT_GEOIP}/${tag}.mrs" || true
  fi

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
      ensure_clash_parsed "$cyaml" "${tag}_geoip2"
      f_ipcidr="$(clash_bucket_file "${tag}_geoip2" ipcidr)"
      f_asn="$(clash_bucket_file "${tag}_geoip2" asn)"
      [[ -f "$f_asn" ]] || : > "$f_asn"
    fi

    [[ -s "$f_ipcidr" ]] || continue

    echo "[CLASH-ONLY] geoip/${tag} <- ${cyaml} (mrs only)"
    convert_mrs ipcidr "$f_ipcidr" "${OUT_GEOIP}/${tag}.mrs" || true

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

    ensure_clash_parsed "$cyaml" "ci_${tag}"

    f_ci_ipcidr="$(clash_bucket_file "ci_${tag}" ipcidr)"
    f_ci_asn="$(clash_bucket_file "ci_${tag}" asn)"
    [[ -f "$f_ci_ipcidr" ]] || : > "$f_ci_ipcidr"
    [[ -f "$f_ci_asn"    ]] || : > "$f_ci_asn"

    if [[ ! -s "$f_ci_ipcidr" ]] && [[ ! -s "$f_ci_asn" ]]; then
      echo "[CLASH-IP] ${tag}: no IP entries, skip"
      continue
    fi

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

if [[ $mrs_fail -gt 0 ]] || [[ $srs_fail -gt 0 ]]; then
  echo "[WARN] compilation failures: mrs=$mrs_fail  srs=$srs_fail"
fi

echo "[8/8] Done."