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
# 转换是无损的：源文件 100% 是 DOMAIN-SUFFIX，而
#   DOMAIN-SUFFIX,foo.com  ≡  ||foo.com^      （都是「该域名 + 所有子域」）
# 语义严格对等，不是近似。
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

total=$(grep -cve '^\s*$' -e '^\s*#' "$SRC" || true)
suffix=$(grep -c '^DOMAIN-SUFFIX,' "$SRC" || true)
echo "源文件 $SRC: 有效行 ${total}，其中 DOMAIN-SUFFIX ${suffix}"

# ── 2 上游格式若变了要吵出来，不能悄悄丢规则 ────────────────────────────────
if [ "$total" -ne "$suffix" ]; then
  echo "⚠ 上游出现了非 DOMAIN-SUFFIX 的规则类型，这些行不会被转换："
  grep -v '^DOMAIN-SUFFIX,' "$SRC" | grep -ve '^\s*$' -e '^\s*#' | head -20 >&2
  die "格式与预期不符（期望全部是 DOMAIN-SUFFIX），请先确认转换规则是否还成立"
fi

# ── 3 转换 ─────────────────────────────────────────────────────────────────
mkdir -p "$OUT_DIR"
{
  echo '! Title: bgpeer ads (category-ads-all)'
  echo '! Description: DNS 层去广告名单，由 geo/geosite/category-ads-all.list 转换而来'
  echo '! Homepage: https://github.com/bgpeer/rules'
  echo '! Upstream: https://github.com/Loyalsoldier/v2ray-rules-dat'
  echo '! Syntax: AdGuard/adblock —— ||domain^ 表示该域名及其所有子域'
  echo '!'
  awk -F, '/^DOMAIN-SUFFIX,/ { print "||" $2 "^" }' "$SRC"
} > "$OUT"

# ── 4 产出校验：空名单是最阴的失败方式（不报错、但等于没拦截）────────────────
rules=$(grep -c '^||' "$OUT" || true)
echo "产出 $OUT: 规则 ${rules} 条，$(du -h "$OUT" | cut -f1)"

[ "$rules" -eq "$suffix" ] || die "规则数不符：源 ${suffix}，产出 ${rules}（转换有丢失）"
[ "$rules" -ge "$MIN_RULES" ] || die "规则数 ${rules} 低于下限 ${MIN_RULES}，疑似上游异常"

# ── 5 抽查几个必然存在的广告域，防止内容整体跑偏 ────────────────────────────
for d in doubleclick.net googlesyndication.com google-analytics.com; do
  grep -qx "||${d}^" "$OUT" || die "抽查失败：${d} 不在产出里，内容异常"
done

echo "✓ $OUT 生成并校验通过（${rules} 条）"
