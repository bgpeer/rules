#!/usr/bin/env bash
# sync_loy_geo_mrs.sh
# 从 Loyalsoldier 下载 geoip/geosite .dat，拆分并输出五种格式：
#   geo/geosite/        ->  .mrs  .yaml  .list  .json  .srs
#   geo/geoip/          ->  .mrs  .yaml  .list  .json  .srs
#   QX/geosite          ->  .list
#   QX/geoip            ->  .list
#
# 并将 clash/<n>.yaml 中的规则融合进同名输出（宽松去重）：
#   支持规则类型：DOMAIN-SUFFIX / DOMAIN / DOMAIN-KEYWORD / DOMAIN-REGEX
#                IP-CIDR / IP-CIDR6
#                PROCESS-NAME / PROCESS-NAME-REGEX / IP-ASN
#   融合策略：
#     yaml / list           -> 保留所有规则类型
#     mrs                   -> 仅 domain/suffix 和 IP-CIDR/IP-CIDR6，其余跳过
#     json / srs            -> 跳过 PROCESS-NAME / PROCESS-NAME-REGEX / IP-ASN
#     QX list               -> 跳过 DOMAIN-REGEX / PROCESS-NAME / PROCESS-NAME-REGEX / IP-ASN
#   若 clash/<n>.yaml 存在但 geo 无同名文件，则纯从 clash 数据建档。
#
# 性能优化：
#   - Python 批处理：一次 python3 调用处理所有 tag 的全部文本格式（消除 6000+ 次进程启动）
#   - 并行编译：mrs/srs 用 xargs -P 多核并行
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

PARALLEL="${PARALLEL:-$(nproc 2>/dev/null || echo 2)}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
HELPERS="${SCRIPT_DIR}/helpers.py"
cd "$REPO_ROOT"

echo "[INFO] repo root: $(pwd)"
echo "[INFO] parallel jobs: $PARALLEL"

# ── 前置检查 ──────────────────────────────────────────────────────────────────
command -v v2dat       >/dev/null 2>&1 || { echo "ERROR: v2dat not found";        exit 1; }
[ -x "$MIHOMO_BIN"  ]                  || { echo "ERROR: mihomo not executable";   exit 1; }
[ -x "$SINGBOX_BIN" ]                  || { echo "ERROR: sing-box not executable"; exit 1; }
command -v python3     >/dev/null 2>&1 || { echo "ERROR: python3 not found";       exit 1; }
[ -f "$HELPERS"      ]                 || { echo "ERROR: helpers.py not found at $HELPERS"; exit 1; }

echo "[INFO] mihomo version:";   "$MIHOMO_BIN"  -v       || true
echo "[INFO] sing-box version:"; "$SINGBOX_BIN" version  || true

# ── 工作目录 ──────────────────────────────────────────────────────────────────
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

MRS_TASKS="${WORKDIR}/mrs_tasks.txt"
SRS_TASKS="${WORKDIR}/srs_tasks.txt"
: > "$MRS_TASKS"
: > "$SRS_TASKS"

# ══════════════════════════════════════════════════════════════════════════════
# 1. 下载
# ══════════════════════════════════════════════════════════════════════════════
echo "[1/7] Download dat files (parallel)..."
curl -fsSL --retry 3 --retry-delay 2 "$GEOIP_URL"   -o "$WORKDIR/geoip.dat" &
pid_dl_geoip=$!
curl -fsSL --retry 3 --retry-delay 2 "$GEOSITE_URL" -o "$WORKDIR/geosite.dat" &
pid_dl_geosite=$!
wait "$pid_dl_geoip"
wait "$pid_dl_geosite"

# ══════════════════════════════════════════════════════════════════════════════
# 2. 解包
# ══════════════════════════════════════════════════════════════════════════════
echo "[2/7] Unpack dat -> txt (parallel)..."
mkdir -p "$WORKDIR/geoip_txt" "$WORKDIR/geosite_txt"
v2dat unpack geoip   -o "$WORKDIR/geoip_txt"   "$WORKDIR/geoip.dat" &
pid_up_geoip=$!
v2dat unpack geosite -o "$WORKDIR/geosite_txt" "$WORKDIR/geosite.dat" &
pid_up_geosite=$!
wait "$pid_up_geoip"
wait "$pid_up_geosite"

GEOIP_TXT_COUNT="$(find   "$WORKDIR/geoip_txt"   -type f -name '*.txt' | wc -l | tr -d ' ')"
GEOSITE_TXT_COUNT="$(find "$WORKDIR/geosite_txt" -type f -name '*.txt' | wc -l | tr -d ' ')"
echo "[DEBUG] geoip txt=$GEOIP_TXT_COUNT  geosite txt=$GEOSITE_TXT_COUNT"

if [ "$GEOIP_TXT_COUNT" -eq 0 ] || [ "$GEOSITE_TXT_COUNT" -eq 0 ]; then
  echo "ERROR: unpack produced 0 txt files"; exit 1
fi

# ══════════════════════════════════════════════════════════════════════════════
# 3. 清空旧输出（增删同步）
# ══════════════════════════════════════════════════════════════════════════════
echo "[3/7] Clean output dirs (full sync)..."
rm -rf "$OUT_GEOSITE" "$OUT_GEOIP" "$OUT_QX_GEOSITE" "$OUT_QX_GEOIP"
mkdir -p "$OUT_GEOSITE" "$OUT_GEOIP" "$OUT_QX_GEOSITE" "$OUT_QX_GEOIP"

# ══════════════════════════════════════════════════════════════════════════════
# 4. Python 批处理 geosite（一次调用处理所有 tag，输出 yaml/list/json/QX）
# ══════════════════════════════════════════════════════════════════════════════
echo "[4/7] Batch process geosite (Python)..."
python3 "$HELPERS" batch_geosite \
  "$WORKDIR/geosite_txt" \
  "$CLASH_DIR" \
  "$OUT_GEOSITE" \
  "$OUT_QX_GEOSITE" \
  "$MRS_TASKS" \
  "$SRS_TASKS" \
  "$WORKDIR"

# ── DOMAIN-Link（远程域名规则集，输出到 geo/geosite/）────────────────────────
echo "[4b/7] Batch process DOMAIN-Link..."
python3 "$HELPERS" batch_domain_link \
  "${CLASH_DIR}/DOMAIN-Link.json" \
  "$OUT_GEOSITE" \
  "$OUT_QX_GEOSITE" \
  "$MRS_TASKS" \
  "$SRS_TASKS" \
  "$WORKDIR"

# ══════════════════════════════════════════════════════════════════════════════
# 5. Python 批处理 geoip（一次调用处理所有 tag）
# ══════════════════════════════════════════════════════════════════════════════
echo "[5/7] Batch process geoip (Python)..."
python3 "$HELPERS" batch_geoip \
  "$WORKDIR/geoip_txt" \
  "$CLASH_DIR" \
  "$WORKDIR/clash_ip" \
  "$OUT_GEOIP" \
  "$OUT_QX_GEOIP" \
  "$MRS_TASKS" \
  "$SRS_TASKS" \
  "$WORKDIR"

# ── Python 批处理 clash-ip/ ──────────────────────────────────────────────────
echo "[5b/7] Batch process clash-ip (Python)..."
python3 "$HELPERS" batch_clash_ip \
  "$CLASH_IP_DIR" \
  "$OUT_GEOIP" \
  "$OUT_QX_GEOIP" \
  "$MRS_TASKS" \
  "$SRS_TASKS" \
  "$WORKDIR"

# ── IP-Link（远程 IP 规则集，输出到 geo/geoip/）────────────────────────────
echo "[5c/7] Batch process IP-Link..."
python3 "$HELPERS" batch_ip_link \
  "${CLASH_IP_DIR}/IP-Link.json" \
  "$OUT_GEOIP" \
  "$OUT_QX_GEOIP" \
  "$MRS_TASKS" \
  "$SRS_TASKS" \
  "$WORKDIR"

# ══════════════════════════════════════════════════════════════════════════════
# 6. 并行编译 mrs + srs
# ══════════════════════════════════════════════════════════════════════════════
echo "[6/7] Parallel compile mrs + srs (jobs=$PARALLEL)..."

# mrs 去重（同一 dst 只保留最后一条）
MRS_DEDUP="${WORKDIR}/mrs_tasks_dedup.txt"
if [[ -s "$MRS_TASKS" ]]; then
  awk -F'\t' '{ last[$3] = $0 } END { for (k in last) print last[k] }' \
    "$MRS_TASKS" > "$MRS_DEDUP"
else
  : > "$MRS_DEDUP"
fi

# srs 去重（同一 dst 只保留最后一条，防止并行 race condition）
SRS_DEDUP="${WORKDIR}/srs_tasks_dedup.txt"
if [[ -s "$SRS_TASKS" ]]; then
  awk -F'\t' '{ last[$2] = $0 } END { for (k in last) print last[k] }' \
    "$SRS_TASKS" > "$SRS_DEDUP"
else
  : > "$SRS_DEDUP"
fi

mrs_total="$(wc -l < "$MRS_DEDUP" | tr -d ' ')"
srs_total="$(wc -l < "$SRS_DEDUP" | tr -d ' ')"
echo "[INFO] mrs tasks: $mrs_total   srs tasks: $srs_total"

# ── 并行编译 mrs ─────────────────────────────────────────────────────────────
mrs_fail_log="${WORKDIR}/mrs_failures.log"
: > "$mrs_fail_log"

if [[ "$mrs_total" -gt 0 ]]; then
  export MIHOMO_BIN mrs_fail_log
  compile_one_mrs() {
    local line="$1"
    local behavior src dst tmp errf
    behavior="$(printf '%s' "$line" | cut -f1)"
    src="$(printf '%s' "$line" | cut -f2)"
    dst="$(printf '%s' "$line" | cut -f3)"
    tmp="${dst}.${BASHPID}.tmp"
    errf="${tmp}.err"
    rm -f "$tmp" "$errf" 2>/dev/null || true
    if "$MIHOMO_BIN" convert-ruleset "$behavior" text "$src" "$tmp" 2>"$errf" \
       && [ -s "$tmp" ]; then
      mv -f "$tmp" "$dst"
    else
      # 连工具自己的报错一起记：只记一行 "FAIL: 路径" 的话，下次排查还得靠猜
      printf 'FAIL: %s\t%s\n' "$dst" \
        "$(tr '\n' ' ' < "$errf" 2>/dev/null | cut -c1-300)" >> "$mrs_fail_log"
      rm -f "$tmp" 2>/dev/null || true
    fi
    rm -f "$errf" 2>/dev/null || true
  }
  export -f compile_one_mrs
  cat "$MRS_DEDUP" | xargs -P "$PARALLEL" -I{} bash -c 'compile_one_mrs "$@"' _ {}
  echo "[INFO] mrs compile done"
fi

# ── 并行编译 srs ─────────────────────────────────────────────────────────────
srs_fail_log="${WORKDIR}/srs_failures.log"
: > "$srs_fail_log"

if [[ "$srs_total" -gt 0 ]]; then
  export SINGBOX_BIN srs_fail_log
  compile_one_srs() {
    local line="$1"
    local json_file srs tmp errf
    json_file="$(printf '%s' "$line" | cut -f1)"
    srs="$(printf '%s' "$line" | cut -f2)"
    tmp="${srs}.${BASHPID}.tmp"
    errf="${tmp}.err"
    rm -f "$tmp" "$errf" 2>/dev/null || true
    if "$SINGBOX_BIN" rule-set compile --output "$tmp" "$json_file" 2>"$errf" \
       && [ -s "$tmp" ]; then
      mv -f "$tmp" "$srs"
    else
      printf 'FAIL: %s\t%s\n' "$srs" \
        "$(tr '\n' ' ' < "$errf" 2>/dev/null | cut -c1-300)" >> "$srs_fail_log"
      rm -f "$tmp" 2>/dev/null || true
    fi
    rm -f "$errf" 2>/dev/null || true
  }
  export -f compile_one_srs
  cat "$SRS_DEDUP" | xargs -P "$PARALLEL" -I{} bash -c 'compile_one_srs "$@"' _ {}
  echo "[INFO] srs compile done"
fi

# ⚠ 别用 `grep -c ... || echo 0`：grep 没匹配时【会打印 0 而且退出码是 1】，
#   `|| echo 0` 于是也执行，变量拿到的是两行 "0\n0"，下面 [[ $mrs_fail -gt 0 ]]
#   直接报 "syntax error in expression"、整个判断块被跳过。也就是说这个守卫
#   【从来没生效过】：每次运行日志末尾那两行语法错误就是它，真出编译失败也不会报。
#   wc -l 不依赖退出码，日志文件在上面已用 `: >` 建好，必然存在。
mrs_fail="$(wc -l < "$mrs_fail_log" | tr -d ' ')"
srs_fail="$(wc -l < "$srs_fail_log" | tr -d ' ')"

# ══════════════════════════════════════════════════════════════════════════════
# 7. 统计
# ══════════════════════════════════════════════════════════════════════════════
echo "[7/7] Final counts:"
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

total_fail=$(( mrs_fail + srs_fail ))
if [[ "$total_fail" -gt 0 ]]; then
  echo "[WARN] compilation failures: mrs=$mrs_fail  srs=$srs_fail"
  # 用 ::error:: 而不是普通 echo：GitHub 把它挂成红色注解贴在运行页顶部，
  # 不会淹没在几千行日志里。产物照常提交（编译失败只是沿用上一版文件，
  # 是【旧】不是【坏】），但运行结果会由最后一步置为失败，避免连续失败无人察觉。
  while IFS=$'\t' read -r target reason; do
    [[ -z "$target" ]] && continue
    echo "::error::规则集编译失败 ${target#FAIL: } ${reason}"
  done < <(cat "$mrs_fail_log" "$srs_fail_log")
  if [[ -n "${GITHUB_ENV:-}" ]]; then
    echo "COMPILE_FAILURES=$total_fail" >> "$GITHUB_ENV"
  fi
  if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    {
      echo "### ⚠ 规则集编译失败 ${total_fail} 个（mrs=${mrs_fail} srs=${srs_fail}）"
      echo
      echo "这些目标沿用了上一版文件——内容是旧的，不是坏的。"
      echo
      echo '```'
      cat "$mrs_fail_log" "$srs_fail_log"
      echo '```'
    } >> "$GITHUB_STEP_SUMMARY"
  fi
fi

echo "Done."
