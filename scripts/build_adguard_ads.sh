#!/usr/bin/env bash
# build_adguard_ads.sh —— 由 category-ads-all.list 生成 AdGuard/Pi-hole 能读的拦截名单
#
# 为什么要单独生成：AdGuard Home / Pi-hole 只认 adblock(||domain^) 或 hosts 语法，
# 仓库现有的三种格式它一种都读不了——.mrs 是 zstd 二进制、.yaml/.list 是 Clash 的
# DOMAIN-SUFFIX 语法。所以给「不挂代理的设备」(电视/盒子/IoT) 单独产一份。
#
# 为什么只转这一个：其余 1500+ 个 geosite 是【分流】名单(cn/google/netflix…)，回答的是
# 「走哪个代理组」；AdGuard 没有这个概念，只能拦或放。把 google.list 转进去等于把
# Google 全拦了，与本意相反。
#
# 输入是【合并后】的最终产物：sync_loy_geo_mrs.sh 已在 [4/7]、[4b/7] 把 clash/<n>.yaml
# 的自建同名规则和 DOMAIN-Link.json 的远程同名链接融合进来了，本脚本在其之后运行。
#
# ── 设计原则：无论上游或自己怎么增删，产出都不能出问题 ──────────────────────
#   1) 先写临时文件，全部校验通过才替换正式产物 —— 绝不会写出半成品或空名单
#   2) 校验不过就【保留上一版】并告警，然后 exit 0 —— 绝不因为本步骤失败而
#      拖垮 mrs/srs/QX 等其余格式的当日更新（宁可 ads.txt 停在上一版，也不能
#      让整条流水线红掉、或者产出一份坏名单）
#   3) 条目数用【相对上一版的跌幅】判断，不用写死的绝对下限 —— 上游正常增删
#      不会误报；真出事（比如上游把名单清空/换结构）才会拦下
#   4) 抽查知名广告域只【告警不拦截】—— 上游有权删任何一条，不该因此中断
#   5) 逐条校验域名合法性，非法值跳过并列出 —— 保证输出的每一行 AdGuard 都认
#
# 转换映射：
#   DOMAIN-SUFFIX,foo.com  ->  ||foo.com^   语义严格对等（该域名 + 所有子域）
#   DOMAIN,foo.com         ->  ||foo.com^   略宽：adblock 无「仅精确域名」的干净写法
#   DOMAIN-KEYWORD,foo     ->  foo          adblock 无锚点即子串匹配，语义一致
#   DOMAIN-REGEX           ->  跳过         Go RE2 与 AdGuard 正则方言不同，错译比不译更糟
#   DOMAIN-WILDCARD        ->  跳过         与 adblock 的通配语义不完全对应，宁可不转
#   IP-CIDR / IP-ASN /
#   PROCESS-NAME 等        ->  跳过         DNS 层拦截没有 IP / 进程的概念
#
# 输出头部【故意不写生成时间】：带时间戳会导致规则没变文件也天天变，而本仓库每日
# 全量重生成、git 历史只增不减，无谓的 churn 要避免。
#
# 想强行接受一次大幅缩减（比如你主动精简了名单）：ADGUARD_FORCE=1 scripts/build_adguard_ads.sh
set -uo pipefail        # 不用 -e：本脚本要自己掌控失败路径，不能中途退出

SRC="geo/geosite/category-ads-all.list"
OUT_DIR="adguard"
OUT="${OUT_DIR}/ads.txt"
MIN_ABS=1000            # 绝对下限：低于这个数一定是坏了，不可能是正常增删
DROP_PCT=50             # 相对上一版跌幅超过这个百分比就判为可疑
FORCE="${ADGUARD_FORCE:-0}"

TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT

note() { echo "  $*"; }
warn() { echo "::warning::$*"; echo "  ⚠ $*"; }
# 关键：告警 + 保留上一版 + exit 0。绝不让本步骤中断整条流水线。
keep_old() {
  echo "::error::adguard/ads.txt 未更新：$*"
  echo "  ❌ $*"
  if [ -s "$OUT" ]; then
    echo "  → 保留上一版 $OUT（$(grep -cve '^!' -e '^$' "$OUT" 2>/dev/null || echo 0) 条）不动，其余格式不受影响。"
  else
    echo "  → 尚无可用的上一版，本次不产出。其余格式不受影响。"
  fi
  exit 0
}

# ── 1 源文件 ────────────────────────────────────────────────────────────────
[ -f "$SRC" ] || keep_old "找不到源文件 $SRC（上游可能改了名或没生成）"
[ -s "$SRC" ] || keep_old "源文件 $SRC 是空的"

# ── 2 统计各规则类型（含 clash/ 与 DOMAIN-Link 插入进来的）──────────────────
ct() { grep -c "^$1," "$SRC" 2>/dev/null || true; }
n_suffix=$(ct 'DOMAIN-SUFFIX'); n_domain=$(ct 'DOMAIN'); n_keyword=$(ct 'DOMAIN-KEYWORD')
n_total=$(grep -cve '^[[:space:]]*$' -e '^[[:space:]]*#' "$SRC" 2>/dev/null || true)
n_conv=$((n_suffix + n_domain + n_keyword))

note "源文件 $SRC（合并后产物）：有效行 ${n_total}"
note "  可转换 ${n_conv} = SUFFIX ${n_suffix} + DOMAIN ${n_domain} + KEYWORD ${n_keyword}；其余 $((n_total-n_conv)) 行按映射表跳过"

# 出现完全没见过的类型 → 只告警。上游加新类型不该中断构建。
UNKNOWN=$(grep -v -e '^[[:space:]]*$' -e '^[[:space:]]*#' \
  -e '^DOMAIN-SUFFIX,' -e '^DOMAIN,' -e '^DOMAIN-KEYWORD,' -e '^DOMAIN-REGEX,' \
  -e '^DOMAIN-WILDCARD,' -e '^IP-CIDR,' -e '^IP-CIDR6,' -e '^IP-ASN,' \
  -e '^PROCESS-NAME,' -e '^PROCESS-NAME-REGEX,' "$SRC" 2>/dev/null | head -5)
[ -n "$UNKNOWN" ] && { warn "出现未知规则类型（已跳过，如需支持请更新本脚本映射表）："; echo "$UNKNOWN" | sed 's/^/      /'; }

# ── 3 转换到临时文件；逐条校验合法性，非法值一律不写出 ──────────────────────
# 域名只接受 ASCII 字母数字 . - _，不以 . - 开头结尾，长度 ≤253。
# 这样无论上游/自己塞进来什么（空值、带空格、中文、引号残留），输出都保持合法。
awk -F, -v badf="$TMP.bad" '
  function ok_domain(v) {
    return (v ~ /^[A-Za-z0-9_]([A-Za-z0-9._-]*[A-Za-z0-9_])?$/) && length(v) <= 253 && v ~ /\./
  }
  function ok_keyword(v) { return (v ~ /^[A-Za-z0-9._-]+$/) && length(v) <= 253 }
  /^DOMAIN-SUFFIX,/ || /^DOMAIN,/ {
    v = $2
    if (ok_domain(v)) r = "||" v "^"; else { print $0 > badf; r = "" }
  }
  /^DOMAIN-KEYWORD,/ {
    v = $2
    if (ok_keyword(v)) r = v; else { print $0 > badf; r = "" }
  }
  r != "" && !seen[r]++ { print r }
  { r = "" }
' "$SRC" > "$TMP.rules"

if [ -s "$TMP.bad" ]; then
  warn "跳过 $(wc -l < "$TMP.bad") 条非法值（域名格式不合规，AdGuard 会拒绝）："
  head -5 "$TMP.bad" | sed 's/^/      /'
fi

rules=$(wc -l < "$TMP.rules")
note "转换产出：${rules} 条"

# ── 4 硬性校验：产出本身必须是有效的 ────────────────────────────────────────
[ "$rules" -ge "$MIN_ABS" ] || keep_old "产出仅 ${rules} 条，低于绝对下限 ${MIN_ABS}，判定为异常"
[ "$rules" -le "$n_conv" ] || keep_old "产出 ${rules} 条 > 可转换 ${n_conv} 条，转换逻辑有误"

# 每一行都必须是合法 adblock 语法，否则整份不要
BADLINE=$(grep -vE '^(\|\|[A-Za-z0-9._-]+\^|[A-Za-z0-9._-]+)$' "$TMP.rules" | head -3)
[ -z "$BADLINE" ] || { echo "$BADLINE" | sed 's/^/      /'; keep_old "产出中存在非法 adblock 行（见上）"; }

# ── 5 相对上一版的跌幅：上游/自己正常增删不误报，真出事才拦 ──────────────────
if [ -s "$OUT" ] && [ "$FORCE" != "1" ]; then
  old=$(grep -cve '^!' -e '^$' "$OUT" 2>/dev/null || echo 0)
  if [ "$old" -ge "$MIN_ABS" ]; then
    floor=$(( old * (100 - DROP_PCT) / 100 ))
    delta=$(( rules - old ))
    pct=$(( old > 0 ? delta * 100 / old : 0 ))
    note "对比上一版：${old} -> ${rules} 条（${pct}%）"
    [ "$rules" -ge "$floor" ] || keep_old "较上一版骤减 $(( -pct ))%（${old} -> ${rules}），超过 ${DROP_PCT}% 阈值，疑似上游异常。确属主动精简请用 ADGUARD_FORCE=1 重跑"
  fi
fi

# ── 6 抽查知名广告域：只告警不拦截（上游有权删任何一条）──────────────────────
miss=""
for d in doubleclick.net googlesyndication.com google-analytics.com; do
  grep -qxF "||${d}^" "$TMP.rules" || miss="${miss} ${d}"
done
[ -n "$miss" ] && warn "抽查未命中：${miss}（上游可能已移除；不影响本次产出）"

# ── 7 全部通过，才替换正式产物 ──────────────────────────────────────────────
mkdir -p "$OUT_DIR"
{
  echo '! Title: bgpeer ads (category-ads-all)'
  echo '! Description: DNS 层去广告名单，由 geo/geosite/category-ads-all.list 转换而来'
  echo '! Homepage: https://github.com/bgpeer/rules'
  echo '! Upstream: https://github.com/Loyalsoldier/v2ray-rules-dat'
  echo '! Syntax: AdGuard/adblock —— ||domain^ 表示该域名及其所有子域'
  echo '!'
  cat "$TMP.rules"
} > "$TMP.out" && mv "$TMP.out" "$OUT"
rm -f "$TMP.rules" "$TMP.bad" "$TMP.out" 2>/dev/null || true

echo "  ✓ $OUT 已更新（${rules} 条，$(du -h "$OUT" | cut -f1)）"
