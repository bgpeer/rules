# 🌍 Loyalsoldier Geo Rules → Multi-format Rulesets

自动同步 Loyalsoldier 的 `geoip.dat` 和 `geosite.dat`，并转换为多种常用规则格式，适用于 Mihomo / Clash Meta / Sing-box / 小火箭 Shadowrocket / Surge/ QuantumultX 等代理工具。

---

## ✨ 特性

自动将 [Loyalsoldier](https://github.com/Loyalsoldier) 的 `geoip.dat` / `geosite.dat` 拆分转换为多种格式规则集，每天北京时间 02:00 自动更新。

---

## geosite.dat 规则转换情况

| 原始类型 | 转换类型 | mrs | yaml | list | json/srs | QX list |
|---|---|:---:|:---:|:---:|:---:|:---:|
| 普通条目 | domain-suffix | ✅ | ✅ | ✅ | ✅ | ✅ |
| `full:` | domain 精确 | ✅ | ✅ | ✅ | ✅ | ✅ |
| `keyword:` | domain-keyword | ⚠️ 跳过 | ✅ | ✅ | ✅ | ✅ |
| `regexp:` | domain-regex | ⚠️ 跳过 | ✅ | ✅ | ✅ | ⚠️ 跳过 |

## geoip.dat 规则转换情况

| 原始类型 | 转换类型 | mrs | yaml | list | json/srs | QX list |
|---|---|:---:|:---:|:---:|:---:|:---:|
| IPv4 CIDR | IP-CIDR | ✅ | ✅ | ✅ | ✅ | ✅ |
| IPv6 CIDR | IP-CIDR6 | ✅ | ✅ | ✅ | ✅ | ✅ |

> ⚠️ mrs 格式由 mihomo `convert-ruleset` 编译，天生不支持 keyword / regexp 类型，跳过为正常行为。
> ⚠️ QuantumultX 不支持 regexp 类型，相关条目已在转换时自动跳过。

---

## 文件目录

```
geo/
├── geosite/        # *.mrs  *.yaml  *.list  *.json  *.srs
└── geoip/          # *.mrs  *.yaml  *.list  *.json  *.srs

QuantumultX/
├── geosite/        # *.list（HOST-SUFFIX / HOST / HOST-KEYWORD）
└── geoip/          # *.list（IP-CIDR / IP-CIDR6）
```

---

## 格式说明

| 格式 | 适用客户端 |
|---|---|
| `.mrs` | mihomo（二进制规则集） |
| `.yaml` | mihomo rule-provider |
| `.list` | Surge / 小火箭 Shadowrocket / mihomo |
| `.list`（QX） | QuantumultX |
| `.json` | sing-box rule-set source |
| `.srs` | sing-box（二进制规则集） |

---

## 规则集目录有五种格式，yaml，list，mrs，json，srs，改后缀对应软件就行了

**geosite 域名样板**
```
https://cdn.jsdelivr.net/gh/SHICHUNHUI88/rules@main/geo/geosite/cn.list
```

**geoip 样板**
```
https://cdn.jsdelivr.net/gh/SHICHUNHUI88/rules@main/geo/geoip/cn.list
```

---

## 数据来源

- [Loyalsoldier/geoip](https://github.com/Loyalsoldier/geoip)
- [Loyalsoldier/v2ray-rules-dat](https://github.com/Loyalsoldier/v2ray-rules-dat)

---

## 使用方法（Clash Mi）

在 Clash Mi → **Geo RuleSet** 中填写以下两个目录链接（推荐使用 CDN）：

### [GEOSITE 数据库](https://github.com/SHICHUNHUI88/rules/tree/main/geo/geosite)
```
https://cdn.jsdelivr.net/gh/SHICHUNHUI88/rules@main/geo/geosite
```

### [GEOIP 数据库](https://github.com/SHICHUNHUI88/rules/tree/main/geo/geoip)
```
https://cdn.jsdelivr.net/gh/SHICHUNHUI88/rules@main/geo/geoip
```

> 说明：这是"目录链接"，Clash Mi 会按需下载其中的 `.mrs` 小文件，例如：
> - `geosite/google.mrs`
> - `geoip/google.mrs`

---

## [可用于 Clash Mi 的样板](https://cdn.gh-proxy.org/https://gist.github.com/SHICHUNHUI88/01f635bc410f3503a218e03e537cb135/raw/ClashMi.yaml)

---

## 使用方法（Sing-box）

## [可用于 Sing-box 的样板](https://cdn.gh-proxy.org/https://gist.github.com/SHICHUNHUI88/ea81e07938efe1b2e892db7a9bee872e/raw/singbox-v1.12-config.json)

---

## 使用方法（QuantumultX）

QuantumultX 使用 `filter_remote` 引用远程规则，需使用 `QuantumultX/` 目录下的专用文件，该目录使用 QX 原生的 `HOST` 系格式。

### geosite 域名样板 [目录](https://github.com/SHICHUNHUI88/rules/tree/main/QuantumultX/geosite)
```
https://cdn.jsdelivr.net/gh/SHICHUNHUI88/rules@main/QuantumultX/geosite/cn.list
```

### geoip 样板 [目录](https://github.com/SHICHUNHUI88/rules/tree/main/QuantumultX/geoip)
```
https://cdn.jsdelivr.net/gh/SHICHUNHUI88/rules@main/QuantumultX/geoip/cn.list
```

### 在 filter_remote 中引用

```ini
[filter_remote]
https://cdn.jsdelivr.net/gh/SHICHUNHUI88/rules@main/QuantumultX/geosite/cn.list, tag=CN, force-policy=direct, update-interval=86400, opt-parser=false, enabled=true
https://cdn.jsdelivr.net/gh/SHICHUNHUI88/rules@main/QuantumultX/geoip/cn.list, tag=CN-IP, force-policy=direct, update-interval=86400, opt-parser=false, enabled=true
```

> 说明：文件内不含策略名，必须通过 `force-policy` 指定走哪个策略组，否则 QX 解析失败。将 `direct` 替换为你实际的策略组名称即可。

### QuantumultX 格式说明

| 规则类型 | 示例 |
|---|---|
| 域名后缀 | `HOST-SUFFIX, example.com` |
| 域名精确 | `HOST, api.example.com` |
| 域名关键字 | `HOST-KEYWORD, openai` |
| IPv4 | `IP-CIDR, 1.1.1.1/32` |
| IPv6 | `IP-CIDR6, 2606::/32` |

---


