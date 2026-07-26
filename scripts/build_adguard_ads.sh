#!/usr/bin/env bash
# build_adguard_ads.sh —— 由 category-ads-all.list 生成 AdGuard/Pi-hole 能读的拦截名单
#
# 为什么要单独生成：AdGuard Home / Pi-hole 只认 adblock(||domain^) 或 hosts 语法，
# 仓库现有的三种格式它一种都读不了——.mrs 是 zstd 二进制、.yaml/.list 是 Clash 的
# DOMAIN-SUFFIX 语法。所以给「不挂代理的设备」(电视/盒子/IoT) 单独产一份。
#
# 为什么只转这一个：其余 1500+ 个 geosite 是【分流】名单(cn/google/netflix…)，回答的是
# 「走哪个代理组」；AdGuard 没有这个概念，只能拦或放。把 google.list 转进去等于把
# Google 全拦了，与本意相反。只有【拦截类】转过去才有意义，而它们里 category-ads-all
# 占了 99%。
#
# 输入是【合并后】的最终产物：sync_loy_geo_mrs.sh 已在 [4/7]、[4b/7] 把
# clash/<n>.yaml 的自建同名规则和 DOMAIN-Link.json 的远程同名链接融合进来了，
# 本脚本在其之后运行，所以那些插入的规则都会进 ads.txt。
#
# ⚠ 也正因为如此，源文件【不能假定只有 DOMAIN-SUFFIX】——.list 格式保留全部规则类型。
#   所以下面按类型分别处理，不认识的类型跳过并报数，绝不因为出现新类型就让整条
#   每日流水线失败（那会连累 mrs/srs/QX 等所有格式的更新）。
#
# 转换映射：
#   DOMAIN-SUFFIX,foo.com  ->  ||foo.com^   语义严格对等（该域名 + 所有子域）
#   DOMAIN,foo.com         ->  ||foo.com^   略宽：adblock 无「仅精确域名」的干净写法，
#                                           会连子域一起拦。对广告名单是可接受且通常更可取的
#   DOMAIN-KEYWORD,foo     ->  foo          adblock 无锚点即子串匹配，与 KEYWORD 语义一致
#   DOMAIN-REGEX           ->  跳过         Go RE2 与 AdGuard 正则方言不同，错译比不译更糟
#                                           （mrs / QX 同样跳过 regex）
#   IP-CIDR / IP-ASN /
#   PROCESS-NAME 等        ->  跳过         DNS 层拦截没有 IP / 进程的概念
#
# 注意：输出头部【故意不写生成时间】。带时间戳会导致规则没变文件也天天变，
# 而本仓库每日全量重生成、git 历史只增不减（已 1GB+），无谓的 churn 要避免。
set -euo pipefail

SRC="geo/geosite/category-ads-all.list"
OUT_DIR="adguard"
OUT="${OUT_DIR}/ads.txt"
MIN_RULES=100000          # 合理下限：正常 16 万+，低于这个说明上游出问题了

die() { echo "❌ $*" >&2; exit 1; }

# ── 1 源文件必须存在且不为空 ────────────────────────────────────────────────
[ -f "$SRC" ] || die "找不到源文件 $SRC"
[ -s "$SRC" ] || die "源文件 $SRC 是空的"

# ── 2 统计各规则类型（含 clash/ 与 DOMAIN-Link 插入进来的）──────────────────
count_type() { grep -c "^$1," "$SRC" || true; }
n_suffix=$(count_type 'DOMAIN-SUFFIX')
n_domain=$(count_type 'DOMAIN')
n_keyword=$(count_type 'DOMAIN-KEYWORD')
n_regex=$(count_type 'DOMAIN-REGEX')
# grep '^DOMAIN,' 不会误吃 DOMAIN-SUFFIX/KEYWORD/REGEX（逗号锚住了），无需再减

n_total=$(grep -cve '^\s*$' -e '^\s*#' "$SRC" || true)
n_conv=$((n_suffix + n_domain + n_keyword))
n_skip=$((n_total - n_conv))

echo "源文件 $SRC（合并后产物）：有效行 ${n_total}"
echo "  可转换 ${n_conv}  = DOMAIN-SUFFIX ${n_suffix} + DOMAIN ${n_domain} + DOMAIN-KEYWORD ${n_keyword}"
echo "  跳过   ${n_skip}  （DOMAIN-REGEX ${n_regex}，及 IP-CIDR / IP-ASN / PROCESS-NAME 等）"

# 出现了完全没见过的类型就吵一声（不致命，但要看得见）
UNKNOWN=$(grep -v -e '^\s*$' -e '^\s*#' \
  -e '^DOMAIN-SUFFIX,' -e '^DOMAIN,' -e '^DOMAIN-KEYWORD,' -e '^DOMAIN-REGEX,' \
  -e '^IP-CIDR,' -e '^IP-CIDR6,' -e '^IP-ASN,' \
  -e '^PROCESS-NAME,' -e '^PROCESS-NAME-REGEX,' "$SRC" | head -5 || true)
if [ -n "$UNKNOWN" ]; then
  echo "⚠ 出现未知规则类型（已跳过，如需支持请更新本脚本的映射表）："
  echo "$UNKNOWN" | sed 's/^/    /'
fi

# ── 3 转换（awk 单遍；!seen 去重且保持首次出现顺序，输出才稳定不产生无谓 churn）──
mkdir -p "$OUT_DIR"
{
  echo '! Title: bgpeer ads (category-ads-all)'
  echo '! Description: DNS 层去广告名单，由 geo/geosite/category-ads-all.list 转换而来'
  echo '! Homepage: https://github.com/bgpeer/rules'
  echo '! Upstream: https://github.com/Loyalsoldier/v2ray-rules-dat'
  echo '! Syntax: AdGuard/adblock —— ||domain^ 表示该域名及其所有子域'
  echo '!'
  awk -F, '
    /^DOMAIN-SUFFIX,/  { r = "||" $2 "^" }
    /^DOMAIN,/         { r = "||" $2 "^" }
    /^DOMAIN-KEYWORD,/ { r = $2         }
    r != "" && !seen[r]++ { print r }
    { r = "" }
  ' "$SRC"
} > "$OUT"

# ── 4 产出校验：空名单是最阴的失败方式（不报错、但等于没拦截）────────────────
rules=$(grep -cve '^!' -e '^\s*$' "$OUT" || true)
echo "产出 $OUT：规则 ${rules} 条，$(du -h "$OUT" | cut -f1)"

[ "$rules" -le "$n_conv" ] || die "产出 ${rules} 条 > 可转换 ${n_conv} 条，转换逻辑有误"
[ "$rules" -ge "$MIN_RULES" ] || die "规则数 ${rules} 低于下限 ${MIN_RULES}，疑似上游异常"

# ── 5 抽查几个必然存在的广告域，防止内容整体跑偏 ────────────────────────────
for d in doubleclick.net googlesyndication.com google-analytics.com; do
  grep -qx "||${d}^" "$OUT" || die "抽查失败：${d} 不在产出里，内容异常"
done

echo "✓ $OUT 生成并校验通过（${rules} 条）"
