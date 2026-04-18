# 🌍 Loyalsoldier Geo Rules → 多格式规则集

自动同步 Loyalsoldier 的 `geoip.dat` 与
`geosite.dat`，并转换为多种主流代理工具可用的规则格式。

支持：Mihomo / Clash Meta / Sing-box / Shadowrocket / Surge / Quantumult
X

------------------------------------------------------------------------

## ✨ 核心特性

-   ⏱ 自动更新：每天北京时间 02:00 同步最新数据\
-   🔄 多格式输出：一次生成，适配所有主流客户端\
-   🧩 可扩展规则：支持本地 + 远程规则融合\
-   🧠 智能解析：自动识别多种规则格式并转换\
-   🧹 自动去重：确保规则干净高效

------------------------------------------------------------------------

## 📦 支持格式

  格式       适用客户端
  ---------- -------------------------------
  .mrs       Mihomo（二进制规则集）
  .yaml      Clash Rule Provider
  .list      Surge / Shadowrocket / Mihomo
  .json      Sing-box（source）
  .srs       Sing-box（二进制）
  QX .list   Quantumult X

------------------------------------------------------------------------

## 🚀 使用方法（Clash / Mihomo）

geosite: https://raw.githubusercontent.com/bgpeer/rules/main/geo/geosite

geoip: https://raw.githubusercontent.com/bgpeer/rules/main/geo/geoip

------------------------------------------------------------------------

## 📡 示例规则

https://raw.githubusercontent.com/bgpeer/rules/main/geo/geosite/cn.list
https://raw.githubusercontent.com/bgpeer/rules/main/geo/geoip/cn.list

------------------------------------------------------------------------

## 💡 总结

一次同步 → 自动转换 → 全平台通用
