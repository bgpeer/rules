# 🌍 Loyalsoldier Geo Rules → Multi-format Rulesets

自动同步 Loyalsoldier 的 `geoip.dat` 和 `geosite.dat`，并转换为多种常用规则格式，适用于 Mihomo / Clash Meta / Sing-box / 小火箭 Shadowrocket / Surge / QuantumultX 等代理工具。

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

## 自定义规则扩展（clash / clash-ip）

除了 Loyalsoldier 的原始数据，你还可以通过 `clash/` 和 `clash-ip/` 目录添加自定义规则，它们会自动融合进对应的输出文件。

### clash/ 目录 — 域名 + IP 混合规则

在 `clash/` 下创建 `<name>.yaml`，支持以下规则类型：

```yaml
payload:
  - DOMAIN,api.example.com
  - DOMAIN-SUFFIX,example.com
  - DOMAIN-KEYWORD,example
  - DOMAIN-WILDCARD,*.example.com
  - IP-CIDR,1.1.1.0/24
  - IP-CIDR6,2606:4700::/32
  - IP-ASN,13335
  - PROCESS-NAME,com.example.app
  - DOMAIN-REGEX,(?i)(^|\.)example\.com$
  - PROCESS-NAME-REGEX,(?i)^com\.example\..*$
```

**融合逻辑：**

- **同名文件存在**（如 `clash/google.yaml` ↔ Loyalsoldier 的 `geosite/google`）→ 自动去重后融合，Loyalsoldier 原有数据不会被修改，只追加新条目
- **无同名文件**（如 `clash/claude.yaml`）→ 从零创建全部格式文件

**clash 插入各格式的规则类型支持情况：**

| 规则类型 | yaml | list | mrs | json/srs | QX list |
|---|:---:|:---:|:---:|:---:|:---:|
| DOMAIN-SUFFIX | ✅ | ✅ | ✅ | ✅ | ✅ |
| DOMAIN | ✅ | ✅ | ✅ | ✅ | ✅ |
| DOMAIN-KEYWORD | ✅ | ✅ | ⚠️ 跳过 | ✅ | ✅ |
| DOMAIN-REGEX | ✅ | ✅ | ⚠️ 跳过 | ✅ | ⚠️ 跳过 |
| DOMAIN-WILDCARD | ✅ | ✅ | ⚠️ 跳过 | ⚠️ 跳过 | ⚠️ 跳过 |
| IP-CIDR / IP-CIDR6 | ✅ | ✅ | ↪️ 转geoip/mrs | ✅ | ✅ |
| IP-ASN | ✅ | ✅ | ⚠️ 跳过 | ⚠️ 跳过 | ⚠️ 跳过 |
| PROCESS-NAME | ✅ | ✅ | ⚠️ 跳过 | ⚠️ 跳过 | ⚠️ 跳过 |
| PROCESS-NAME-REGEX | ✅ | ✅ | ⚠️ 跳过 | ⚠️ 跳过 | ⚠️ 跳过 |

> ⚠️ 跳过不是丢失，是该格式/软件本身不支持该规则类型，自动过滤以确保兼容性。
>
> 💡 clash/ 中的 IP 类条目（IP-CIDR / IP-CIDR6 / IP-ASN）会同时融合进 `geo/geosite/` 和 `geo/geoip/` 对应的同名文件。

### clash-ip/ 目录 — 纯 IP 规则

专门用于向 `geo/geoip/` 追加 IP 规则，只接受 IP 类条目：

```yaml
payload:
  - IP-CIDR,103.21.244.0/22
  - IP-CIDR6,2400:cb00::/32
  - IP-ASN,13335
```

**融合逻辑与 clash/ 相同：** 同名文件存在则去重追加，不存在则新建。

**clash-ip 插入各格式的规则类型支持情况：**

| 规则类型 | yaml | list | mrs | json/srs | QX list |
|---|:---:|:---:|:---:|:---:|:---:|
| IP-CIDR / IP-CIDR6 | ✅ | ✅ | ✅ | ✅ | ✅ |
| IP-ASN | ✅ | ✅ | ⚠️ 跳过 | ⚠️ 跳过 | ⚠️ 跳过 |

> ⚠️ mrs 格式仅支持 IP-CIDR 类型，IP-ASN 会被跳过。
> ⚠️ json/srs（sing-box）和 QX 同样不支持 IP-ASN，自动过滤。

### clash/DOMAIN-Link.json — 远程域名规则订阅

如果你想引入外部链接的域名规则集（如 blackmatrix7、Loyalsoldier 其他仓库等），可以编辑 `clash/DOMAIN-Link.json`，无需手动下载和维护文件。

**文件格式：**

```json
[
  {"name": "microsoft", "url": "https://cdn.jsdelivr.net/gh/blackmatrix7/ios_rule_script@master/rule/Clash/Microsoft/Microsoft.yaml", "format": "yaml"},
  {"name": "icloud",    "url": "https://cdn.jsdelivr.net/gh/Loyalsoldier/clash-rules@release/icloud.txt", "format": "txt"}
]
```

| 字段 | 说明 |
|---|---|
| `name` | 输出文件名（即 `geo/geosite/<name>.*`） |
| `url` | 远程规则文件链接 |
| `format` | `yaml`/`clash`/`json`（Clash 规则格式）、`txt`/`list`（纯域名列表）、`auto`（自动检测，默认） |

**提取规则：** 只提取域名类条目（DOMAIN / DOMAIN-SUFFIX / DOMAIN-KEYWORD / DOMAIN-REGEX / DOMAIN-WILDCARD / PROCESS-NAME），IP 类条目一律忽略。

**去重优先级：Loyalsoldier → clash/\*.yaml → DOMAIN-Link.json**
- 若 `name` 与已有 tag 同名（如 `"name": "google"`）→ 只追加 Loyalsoldier + clash/ 中没有的条目
- 若 `name` 是全新名字 → 直接新建全部格式文件

**各格式支持情况与 clash/ 目录相同（见上表）。**

---

### clash-ip/IP-Link.json — 远程 IP 规则订阅

对应 IP 规则的远程订阅，编辑 `clash-ip/IP-Link.json`。

**文件格式：**

```json
[
  {"name": "cloudflare", "url": "https://raw.githubusercontent.com/blackmatrix7/.../Cloudflare.yaml", "format": "yaml"},
  {"name": "netflix-ip", "url": "https://example.com/netflix-ips.txt", "format": "txt"}
]
```

**提取规则：** 只提取 IP 类条目，域名类条目一律忽略：

| 提取类型 | yaml | list | mrs | json/srs | QX list |
|---|:---:|:---:|:---:|:---:|:---:|
| IP-CIDR（IPv4） | ✅ | ✅ | ✅ | ✅ | ✅ |
| IP-CIDR6（IPv6） | ✅ | ✅ | ✅ | ✅ | ✅ |
| IP-ASN | ✅ | ✅ | ⚠️ 跳过 | ⚠️ 跳过 | ⚠️ 跳过 |

**去重优先级：Loyalsoldier → clash-ip/\*.yaml → IP-Link.json**
- 同名 tag 已存在则只追加新增条目，否则新建。

---

### 使用示例

想给抖音补充自定义 IP 段和进程规则：

1. 创建 `clash/douyin.yaml`，写入自定义条目
2. Push 到仓库（或等每天定时任务）
3. 工作流自动将你的条目融合进 Loyalsoldier 的 `douyin` 规则集
4. 所有格式同步更新，无需手动处理

想订阅第三方 Microsoft 规则集并生成所有格式：

1. 编辑 `clash/DOMAIN-Link.json`，添加一行 `{"name": "microsoft", "url": "...", "format": "yaml"}`
2. Push 后工作流自动拉取、去重、编译
3. 使用 `https://raw.githubusercontent.com/bgpeer/rules/main/geo/geosite/microsoft.mrs` 等链接引用

---

## 文件目录

```
geo/
├── geosite/        # *.mrs  *.yaml  *.list  *.json  *.srs
└── geoip/          # *.mrs  *.yaml  *.list  *.json  *.srs

QX/
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

## GEOSITE 域名样板 [目录](https://github.com/bgpeer/rules/tree/main/geo/geosite)
```
https://raw.githubusercontent.com/bgpeer/rules/main/geo/geosite/cn.list
```

## GEOIP 样板 [目录](https://github.com/bgpeer/rules/tree/main/geo/geoip)
```
https://raw.githubusercontent.com/bgpeer/rules/main/geo/geoip/cn.list
```

---

## 数据来源

- [Loyalsoldier/geoip](https://github.com/Loyalsoldier/geoip)
- [Loyalsoldier/v2ray-rules-dat](https://github.com/Loyalsoldier/v2ray-rules-dat)

---

## 使用方法（Clash Mi）

可以在 Clash Mi → **Geo RuleSet** 中填写以下两个目录链接：

**geosite**
```
https://raw.githubusercontent.com/bgpeer/rules/main/geo/geosite
```

**geoip**
```
https://raw.githubusercontent.com/bgpeer/rules/main/geo/geoip
```

> 说明：这是"目录链接"，Clash Mi 会按需下载其中的 `.mrs` 小文件，例如：
> - `geosite/google.mrs`
> - `geoip/google.mrs`

---

## [可用于 Clash Mi 的样板](https://cdn.gh-proxy.org/https://gist.githubusercontent.com/bgpeer/01f635bc410f3503a218e03e537cb135/raw/ClashMi.yaml)

---

## [可用于 Sing-box 的样板](https://cdn.gh-proxy.org/https://gist.githubusercontent.com/bgpeer/ea81e07938efe1b2e892db7a9bee872e/raw/singbox-v1.12-config.json)

---

## [小火箭(Shadowrocket)懒人配置](https://cdn.gh-proxy.org/https://gist.githubusercontent.com/bgpeer/b0400d50f3fd5a63d77757ec0413d824/raw/Shadowrocket.conf)
```
https://cdn.gh-proxy.org/https://gist.githubusercontent.com/bgpeer/b0400d50f3fd5a63d77757ec0413d824/raw/Shadowrocket.conf
```
`小火箭配置自己没有测试过我不敢保证可用懂得可以自行修改`

---

## 使用方法（QuantumultX）

QuantumultX 使用 `filter_remote` 引用远程规则，需使用 `QX/` 目录下的专用文件，该目录使用 QX 原生的 `HOST` 系格式。

### geosite 域名样板 [目录](https://github.com/bgpeer/rules/tree/main/QX/geosite)
```
https://raw.githubusercontent.com/bgpeer/rules/main/QX/geosite/cn.list
```

### geoip 样板 [目录](https://github.com/bgpeer/rules/tree/main/QX/geoip)
```
https://raw.githubusercontent.com/bgpeer/rules/main/QX/geoip/cn.list
```

### 在 filter_remote 中引用

```ini
[filter_remote]
https://raw.githubusercontent.com/bgpeer/rules/main/QX/geosite/cn.list, tag=CN, force-policy=direct, update-interval=86400, opt-parser=false, enabled=true
https://raw.githubusercontent.com/bgpeer/rules/main/QX/geoip/cn.list, tag=CN-IP, force-policy=direct, update-interval=86400, opt-parser=false, enabled=true
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

## 国内无法直连 GitHub Raw？

`raw.githubusercontent.com` 在国内可能无法直接访问，你可以自建 Cloudflare Worker 做代理转发。

👉 [Cloudflare Worker 部署教程](https://github.com/bgpeer/rules/blob/main/CF-Worker部署教程.md)

部署完成后，将上述链接中的 `https://raw.githubusercontent.com/bgpeer/rules/main/` 替换为 `https://你的域名/rules/` 即可。
