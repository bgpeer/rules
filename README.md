🌍 Loyalsoldier Geo Rules → Multi-format Rulesets

自动同步 Loyalsoldier 的 "geoip.dat" 和 "geosite.dat"，并转换为多种常用规则格式，适用于 Mihomo / Clash Meta / Sing-box 等代理工具。

---

✨ 特性

# rules

自动将 [Loyalsoldier](https://github.com/Loyalsoldier) 的 `geoip.dat` / `geosite.dat` 拆分转换为多种格式规则集，每天北京时间 02:00 自动更新。

## geosite.dat 规则转换情况

| 原始类型 | 转换类型 | mrs | yaml | list | json/srs |
|---|---|:---:|:---:|:---:|:---:|
| 普通条目 | domain-suffix | ✅ | ✅ | ✅ | ✅ |
| `full:` | domain 精确 | ✅ | ✅ | ✅ | ✅ |
| `keyword:` | domain-keyword | ⚠️ 跳过 | ✅ | ✅ | ✅ |
| `regexp:` | domain-regex | ⚠️ 跳过 | ✅ | ✅ | ✅ |

## geoip.dat 规则转换情况

| 原始类型 | 转换类型 | mrs | yaml | list | json/srs |
|---|---|:---:|:---:|:---:|:---:|
| IPv4 CIDR | IP-CIDR | ✅ | ✅ | ✅ | ✅ |
| IPv6 CIDR | IP-CIDR6 | ✅ | ✅ | ✅ | ✅ |

> ⚠️ mrs 格式由 mihomo `convert-ruleset` 编译，天生不支持 keyword / regexp 类型，跳过为正常行为。

## 文件目录

```
geo/
├── geosite/   # *.mrs  *.yaml  *.list  *.json  *.srs
└── geoip/     # *.mrs  *.yaml  *.list  *.json  *.srs
```

## 格式说明

| 格式 | 适用客户端 |
|---|---|
| `.mrs` | mihomo（二进制规则集） |
| `.yaml` | mihomo rule-provider |
| `.list` | Surge / 小火箭 |
| `.json` | sing-box rule-set source |
| `.srs` | sing-box（二进制规则集） |

---

## 规则集目录有五种格式，yaml，list，mrs，json，srs，改后缀对应软件就行了

**geosite域名样板**
`https://cdn.jsdelivr.net/gh/bgpeer/rules@main/geo/geosite/cn.list`

**geoip样板**
`https://cdn.jsdelivr.net/gh/bgpeer/rules@main/geo/geoip/cn.list`

## 数据来源

- [Loyalsoldier/geoip](https://github.com/Loyalsoldier/geoip)
- [Loyalsoldier/v2ray-rules-dat](https://github.com/Loyalsoldier/v2ray-rules-dat)


---

## 使用方法（ClashMi）

在 ClashMi → **Geo RuleSet** 中填写以下两个目录链接（推荐使用 CDN）：

### [GEOSITE数据库](https://github.com/bgpeer/rules/tree/main/geo/geosite)
```
https://cdn.jsdelivr.net/gh/bgpeer/rules@main/geo/geosite
```

### [GEOIP数据库](https://github.com/bgpeer/rules/tree/main/geo/geoip)
```
https://cdn.jsdelivr.net/gh/bgpeer/rules@main/geo/geoip
```


> 说明：这是“目录链接”，ClashMi 会按需下载其中的 `.mrs` 小文件（例如 
- `geosite/google.mrs`
- `geoip/google.mrs`

---
## [可用于Clash Mi的样板](https://cdn.gh-proxy.org/https://gist.github.com/bgpeer/01f635bc410f3503a218e03e537cb135/raw/ClashMi.yaml)
---

## [可用于Sing-box的样板](https://cdn.gh-proxy.org/https://gist.github.com/bgpeer/ea81e07938efe1b2e892db7a9bee872e/raw/singbox-v1.12-config.json)
