#### [可用于 Clash Mi 的样板](https://cdn.gh-proxy.org/https://gist.githubusercontent.com/bgpeer/01f635bc410f3503a218e03e537cb135/raw/ClashMi.yaml)

#### ClashMi 配置核心复写

```yaml
https://cdn.gh-proxy.org/https://gist.github.com/bgpeer/cfd6fcf7bc40c166984b87ecf4fbf920/raw/Clashmi-fx.yaml
```

`打开Clashmi→核心设置→复写→点击右上角➕→添加配置链接`

**[Mihomo通用的JS复写](https://cdn.gh-proxy.org/https://gist.github.com/bgpeer/e9f0dcf4601f8350ab0b08506c069b4a/raw/Mihomo-fx.js)**

```js
https://cdn.gh-proxy.org/https://gist.github.com/bgpeer/e9f0dcf4601f8350ab0b08506c069b4a/raw/Mihomo-fx.js
```

---

### Sing-box

[可用于 Sing-box 的样板](https://cdn.gh-proxy.org/https://gist.github.com/bgpeer/ea81e07938efe1b2e892db7a9bee872e/raw/singbox-config.json)

---
> ⚠️ 下面是苹果系列配置自己没有测试过，不敢保证可用，懂得可以自行修改。

### Shadowrocket（小火箭）

[小火箭（Shadowrocket）懒人配置](https://cdn.gh-proxy.org/https://gist.githubusercontent.com/bgpeer/b0400d50f3fd5a63d77757ec0413d824/raw/Shadowrocket.conf)

```
https://cdn.gh-proxy.org/https://gist.githubusercontent.com/bgpeer/b0400d50f3fd5a63d77757ec0413d824/raw/Shadowrocket.conf
```

[Surge样板](https://cdn.gh-proxy.org/https://gist.githubusercontent.com/bgpeer/9e5b1e02fd8f69af7dc57da2aa59510b/raw/Surge.conf)

[QuantumultX样板](https://cdn.gh-proxy.org/https://gist.githubusercontent.com/bgpeer/8c4b2b9685791f097ad183da3d29e4d0/raw/QX.conf)

---

Mihomo / Clash Meta / Sing-box / 小火箭 Shadowrocket / Surge / 规则集文件
https://github.com/bgpeer/rules/tree/main/geo

QuantumultX / 规则集文件
https://github.com/bgpeer/rules/tree/main/QX

---

# 🌍 Loyalsoldier Geo Rules → Multi-format Rulesets

自动同步上游 **Loyalsoldier** 的 [geoip.dat](https://github.com/Loyalsoldier/geoip) 和 [geosite.dat](https://github.com/Loyalsoldier/v2ray-rules-dat)，并转换为多种常用规则格式，适用于 Mihomo / Clash Meta / Sing-box / 小火箭 Shadowrocket / Surge / QuantumultX 等代理工具。

---

## ✨ 特性

自动将 [Loyalsoldier](https://github.com/Loyalsoldier) 的 `geoip.dat` / `geosite.dat` 拆分转换为多种格式规则集，每天北京时间 02:10 自动更新。

---

## 📦 规则转换对照表

### geosite.dat 规则转换情况

| 原始类型 | 转换类型 | mrs | yaml | list | json/srs | QX list |
| --- | --- | :---: | :---: | :---: | :---: | :---: |
| 普通条目 | domain-suffix | ✅ | ✅ | ✅ | ✅ | ✅ |
| `full:` | domain 精确 | ✅ | ✅ | ✅ | ✅ | ✅ |
| `keyword:` | domain-keyword | ⚠️ 跳过 | ✅ | ✅ | ✅ | ✅ |
| `regexp:` | domain-regex | ⚠️ 跳过 | ✅ | ✅ | ✅ | ⚠️ 跳过 |

### geoip.dat 规则转换情况

| 原始类型 | 转换类型 | mrs | yaml | list | json/srs | QX list |
| --- | --- | :---: | :---: | :---: | :---: | :---: |
| IPv4 CIDR | IP-CIDR | ✅ | ✅ | ✅ | ✅ | ✅ |
| IPv6 CIDR | IP-CIDR6 | ✅ | ✅ | ✅ | ✅ | ✅ |

> ⚠️ mrs 格式由 mihomo `convert-ruleset` 编译，天生不支持 keyword / regexp 类型，跳过为正常行为。
>
> ⚠️ QuantumultX 不支持 regexp 类型，相关条目已在转换时自动跳过。

---

## 🛡️ ads.txt — DNS 层去广告名单（AdGuard Home / Pi-hole）

给**装不了代理客户端的设备**用：智能电视、盒子、IoT、路由器，或安卓「私人 DNS」全系统去广告。
挂着代理的设备本来就靠规则集里的 `category-ads-all` 拦广告，这份补的是「不挂代理」的场景。

**订阅地址：**

**[📄 点此查看名单内容](https://github.com/bgpeer/rules/blob/adguard/ads.txt)**（文件较大，网页只展示开头一段，完整内容点页面里的 `Raw`）

```
https://raw.githubusercontent.com/bgpeer/rules/adguard/ads.txt
```

AdGuard Home 后台 → 过滤器 → DNS 拦截列表 → 添加黑名单，粘贴上面的地址即可。随主流水线每天 02:10 更新。

> 📌 这份名单托管在**独立的 `adguard` 分支**，不在 `main` 的目录树里。它有 17 万行 / 4MB，
> 每天变动约 250 行：提交进 `main` 会让历史每天沉淀一个大 blob、push 越来越慢；发 Release
> 又会占据仓库首页最显眼的位置，与本仓库「分流规则集」的定位不符。独立分支每次强推一个
> 全新的无父提交，历史零累积，上面这个地址固定指向最新版，更新频率和用法都不变。

**为什么要单独出这一份**：AdGuard Home / Pi-hole 只认 adblock(`||domain^`) 或 hosts 语法，
本仓库现有的三种格式它**一种都读不了**——`.mrs` 是 zstd 压缩的二进制，`.yaml` / `.list` 是
Clash 的 `DOMAIN-SUFFIX,x` 语法。

**为什么只转 `category-ads-all` 一个**：其余 1500+ 个 geosite 是**分流**名单（`cn`、`google`、
`netflix`…），回答的是「走哪个代理组」；AdGuard 没有这个概念，只能拦或放。把 `google.list`
转进去等于**把 Google 全拦了**，与本意相反。只有拦截类转过去才有意义，而它们当中
`category-ads-all` 占了 99%。

**包含自建同名文件与远程同名链接的插入**：本文件的输入是**合并后的最终产物**。
`sync_loy_geo_mrs.sh` 先在 `[4/7]` 融合 `clash/category-ads-all.yaml`（自建同名）、
在 `[4b/7]` 融合 `DOMAIN-Link.json` 里 `name` 为 `category-ads-all` 的远程链接，
转换步骤在其之后运行——所以你插入的规则都会进 `ads.txt`。

**规则类型映射**（`.list` 保留全部类型，故按类型分别处理）：

| 源类型 | 转换结果 | 说明 |
| --- | --- | --- |
| `DOMAIN-SUFFIX,foo.com` | `\|\|foo.com^` | 语义**严格对等**（该域名 + 所有子域） |
| `DOMAIN,foo.com` | `\|\|foo.com^` | 略宽：adblock 无「仅精确域名」的干净写法，会连子域一起拦 |
| `DOMAIN-KEYWORD,foo` | `foo` | adblock 无锚点即子串匹配，与 KEYWORD 语义一致 |
| `DOMAIN-REGEX` | ⚠️ 跳过 | Go RE2 与 AdGuard 正则方言不同，错译比不译更糟（mrs / QX 同样跳过） |
| `IP-CIDR` / `IP-ASN` / `PROCESS-NAME` 等 | ⚠️ 跳过 | DNS 层拦截没有 IP / 进程的概念 |

产出会按首次出现顺序去重，`DOMAIN` 与 `DOMAIN-SUFFIX` 指向同一域名不会产生重复行。

**上游与自己任意增删都不会让产出出问题**——`scripts/build_adguard_ads.sh` 按这几条设计：

1. **先写临时文件，全部校验通过才替换正式产物**——绝不会写出半成品或空名单
2. **校验不过就保留上一版并告警，然后正常退出**——绝不因为本步骤失败而拖垮
   `mrs`/`srs`/`QX` 等其余格式的当日更新。宁可 `ads.txt` 停在上一版，也不能让整条流水线红掉、
   或者产出一份坏名单
3. **条目数看「相对上一版的跌幅」（阈值 50%），不用写死的绝对下限**——上游正常增删不误报，
   真出事（名单被清空、结构大改）才拦下
4. **抽查知名广告域只告警不拦截**——上游有权删掉任何一条，不该因此中断
5. **逐条校验域名合法性**，空值、带空格、引号残留、以 `.` 开头等非法值一律跳过并列出，
   保证输出的每一行 AdGuard 都认
6. **未知规则类型只告警不失败**，上游将来加新类型不会中断构建

主动大幅精简名单时用 `ADGUARD_FORCE=1 scripts/build_adguard_ads.sh` 跳过跌幅检查。

> ⚠️ 非 ASCII 域名（如中文域名）目前会被跳过并在日志中列出——未做 punycode 转换。

> 💡 这份仍以欧美广告为主，**国内广告拦不住**。要补这块，在 AdGuard 后台
> 「添加黑名单 → 从列表中选择」里勾 `CHN: anti-AD` 或 `CHN: AdRules DNS List`，两者选其一即可
> （互相重叠严重，且 AdGuard 是把规则全量读进内存的，小内存机器别堆太多）。

---

## 🔗 远程规则订阅

### clash/DOMAIN-Link.json — 远程规则订阅（全类型）

如果你想引入外部链接的规则集（如 blackmatrix7、Loyalsoldier 其他仓库等），可以编辑 `clash/DOMAIN-Link.json`，无需手动下载和维护文件。

**文件格式：**

```json
[
  {"name": "microsoft", "url": "https://cdn.jsdelivr.net/gh/blackmatrix7/ios_rule_script@master/rule/Clash/Microsoft/Microsoft.yaml", "format": "yaml"},
  {"name": "cn",    "url": "https://raw.githubusercontent.com/blackmatrix7/ios_rule_script/master/rule/Clash/ChinaMax/ChinaMax_IP.txt", "format": "txt"}
]
```

| 字段 | 说明 |
| --- | --- |
| `name` | 输出文件名（即 `geo/geosite/<name>.*` / `geo/geoip/<name>.*`） |
| `url` | 远程规则文件链接 |
| `format` | 格式提示（见下表，默认 `auto`） |

**`format` 可选值：**

| 填写值 | 实际解析方式 |
| --- | --- |
| `yaml` / `json` / `clash` | Clash 规则格式（解析 `payload:` 块或 `DOMAIN,x` 行） |
| `list` / `txt` | 纯域名列表，一行一个 |
| `auto` 或不填 | 根据内容自动判断（推荐，默认） |

**自动识别支持的输入格式：**

| 来源格式 | 示例 | 识别结果 |
| --- | --- | --- |
| Clash list | `DOMAIN-SUFFIX,example.com` | DOMAIN-SUFFIX |
| Clash YAML | `payload:` + `- DOMAIN,x` | DOMAIN / DOMAIN-SUFFIX |
| QuantumultX | `HOST-SUFFIX,example.com,policy` | DOMAIN-SUFFIX |
| sing-box JSON | `{"rules":[{"domain_suffix":["..."]}]}` | DOMAIN-SUFFIX |
| 引号 YAML | `- 'example.com'` / `- '+.example.com'` | DOMAIN / DOMAIN-SUFFIX |
| 纯文本（无前缀） | `api.example.com` | DOMAIN（精确） |
| 纯文本（`.` 前缀） | `.example.com` | DOMAIN-SUFFIX |
| 纯文本（`+.` 前缀） | `+.example.com` | DOMAIN-SUFFIX |

**提取规则：** 域名类 + IP 类条目全部提取：

- 域名类条目（DOMAIN / DOMAIN-SUFFIX / DOMAIN-KEYWORD / DOMAIN-REGEX 等）→ 融合进 `geo/geosite/`（全格式）
- IP 类条目（IP-CIDR / IP-CIDR6 / IP-ASN）→ 融合进 `geo/geosite/`（加 `no-resolve`）+ 额外编译进 `geoip/<name>.mrs`
- `geoip/` 其他格式（yaml / list / json / srs / QX）不受影响，`geosite/mrs` 不含 IP

**去重优先级：** `Loyalsoldier` → `clash/*.yaml` → `DOMAIN-Link.json`

- 若 `name` 与已有 tag 同名（如 `"name": "google"`）→ 只追加前两者中没有的条目
- 若 `name` 是全新名字 → 直接新建全部格式文件

各格式支持情况与 `clash/` 目录相同。

---

## 🛠 自定义规则扩展（clash / clash-ip）

除了 Loyalsoldier 的原始数据，你还可以通过 `clash/` 和 `clash-ip/` 目录添加自定义规则，它们会自动融合进对应的输出文件。

### clash/ 目录 — 域名 + IP 混合规则

在 `clash/` 下创建 `<name>.yaml`，支持以下规则类型：

```yaml
payload:
  - DOMAIN,api.example.com
  - DOMAIN-SUFFIX,example.com
  - DOMAIN-WILDCARD,*.example.com
  - IP-CIDR,1.1.1.0/24
  - IP-CIDR6,2606:4700::/32
  - IP-ASN,13335
  - DOMAIN-KEYWORD,example
  - PROCESS-NAME,com.example.app
  - DOMAIN-REGEX,(?i)(^|\.)example\.com$
  - PROCESS-NAME-REGEX,(?i)^com\.example\..*$
```

**融合逻辑：**

- **同名文件存在**（如 `clash/google.yaml` ↔ Loyalsoldier 的 `geosite/google`）→ 自动去重后融合，Loyalsoldier 原有数据不会被修改，只追加新条目
- **无同名文件**（如 `clash/claude.yaml`）→ 从零创建全部格式文件

**clash 插入各格式的规则类型支持情况：**

| 规则类型 | yaml | list | mrs | json/srs | QX list |
| --- | :---: | :---: | :---: | :---: | :---: |
| DOMAIN-SUFFIX | ✅ | ✅ | ✅ | ✅ | ✅ |
| DOMAIN | ✅ | ✅ | ✅ | ✅ | ✅ |
| DOMAIN-KEYWORD | ✅ | ✅ | ⚠️ 跳过 | ✅ | ✅ |
| DOMAIN-REGEX | ✅ | ✅ | ⚠️ 跳过 | ✅ | ⚠️ 跳过 |
| DOMAIN-WILDCARD | ✅ | ✅ | ⚠️ 跳过 | ⚠️ 跳过 | ⚠️ 跳过 |
| IP-CIDR / IP-CIDR6 | ✅ | ✅ | ↪️ 转 geoip/mrs | ✅ | ✅ |
| IP-ASN | ✅ | ✅ | ⚠️ 跳过 | ⚠️ 跳过 | ⚠️ 跳过 |
| PROCESS-NAME | ✅ | ✅ | ⚠️ 跳过 | ⚠️ 跳过 | ⚠️ 跳过 |
| PROCESS-NAME-REGEX | ✅ | ✅ | ⚠️ 跳过 | ⚠️ 跳过 | ⚠️ 跳过 |

> ⚠️ 跳过不是丢失，是该格式/软件本身不支持该规则类型，自动过滤以确保兼容性。
>
> 💡 `clash/` 中的 IP 类条目（IP-CIDR / IP-CIDR6 / IP-ASN）会同时融合进 `geo/geosite/` 和 `geo/geoip/` 对应的同名文件。

### clash-ip/ 目录 — 纯 IP 规则

专门用于向 `geo/geoip/` 追加 IP 规则，只接受 IP 类条目：

```yaml
payload:
  - IP-CIDR,103.21.244.0/22
  - IP-CIDR6,2400:cb00::/32
  - IP-ASN,13335
```

**融合逻辑与 `clash/` 相同：** 同名文件存在则去重追加，不存在则新建。

**clash-ip 插入各格式的规则类型支持情况：**

| 规则类型 | yaml | list | mrs | json/srs | QX list |
| --- | :---: | :---: | :---: | :---: | :---: |
| IP-CIDR / IP-CIDR6 | ✅ | ✅ | ✅ | ✅ | ✅ |
| IP-ASN | ✅ | ✅ | ⚠️ 跳过 | ⚠️ 跳过 | ⚠️ 跳过 |

> ⚠️ mrs 格式仅支持 IP-CIDR 类型，IP-ASN 会被跳过。
>
> ⚠️ json/srs（sing-box）和 QX 同样不支持 IP-ASN，自动过滤。

### clash-ip/IP-Link.json — 远程 IP 规则订阅

对应 IP 规则的远程订阅，编辑 `clash-ip/IP-Link.json`。

**文件格式：**

```json
[
  {"name": "cloudflare", "url": "https://raw.githubusercontent.com/blackmatrix7/.../Cloudflare.yaml", "format": "yaml"},
  {"name": "netflix-ip", "url": "https://example.com/netflix-ips.txt", "format": "txt"}
]
```

**`format` 可选值：**

| 填写值 | 实际解析方式 |
| --- | --- |
| `yaml` / `json` / `clash` | Clash 规则格式（解析 `IP-CIDR,x` / `IP-CIDR6,x` 行） |
| `list` / `txt` / `ip-text` | 纯 CIDR 列表，一行一个 |
| `auto` 或不填 | 根据内容自动判断（推荐，默认） |

**自动识别支持的输入格式：**

| 来源格式 | 示例 |
| --- | --- |
| Clash list（含 no-resolve） | `IP-CIDR,1.2.3.0/24,no-resolve` |
| Clash YAML（引号包裹） | `- '1.2.3.0/24'` |
| 纯 CIDR 文本 | `1.2.3.0/24` / `2001:db8::/32` |
| sing-box JSON | `{"rules":[{"ip_cidr":["1.2.3.0/24"]}]}` |

**去重优先级：** `Loyalsoldier` → `clash-ip/*.yaml` → `IP-Link.json`

- 同名 tag 已存在则只追加新增条目，否则新建。

---

## 💡 使用示例

**想给抖音补充自定义 IP 段和进程规则：**

1. 创建 `clash/douyin.yaml`，写入自定义条目
2. Push 到仓库（或等每天定时任务）
3. 工作流自动将你的条目融合进 Loyalsoldier 的 `douyin` 规则集
4. 所有格式同步更新，无需手动处理

**想订阅第三方 Microsoft 规则集并生成所有格式：**

1. 编辑 `clash/DOMAIN-Link.json`，添加一行 `{"name": "microsoft", "url": "...", "format": "yaml"}`
2. Push 后工作流自动拉取、去重、编译
3. 使用 `https://raw.githubusercontent.com/bgpeer/rules/main/geo/geosite/microsoft.mrs` 等链接引用

---

## 📁 文件目录

```
geo/
├── geosite/        # *.mrs  *.yaml  *.list  *.json  *.srs
└── geoip/          # *.mrs  *.yaml  *.list  *.json  *.srs

QX/
├── geosite/        # *.list(HOST-SUFFIX / HOST / HOST-KEYWORD)
└── geoip/          # *.list(IP-CIDR / IP-CIDR6)
```

---

## 📄 格式说明

| 格式 | 适用客户端 |
| --- | --- |
| `.mrs` | mihomo（二进制规则集） |
| `.yaml` | mihomo rule-provider |
| `.list` | Surge / 小火箭 Shadowrocket / mihomo |
| `.list`（QX） | QuantumultX |
| `.json` | sing-box rule-set source |
| `.srs` | sing-box（二进制规则集） |

> 规则集目录有五种格式：`yaml`、`list`、`mrs`、`json`、`srs`，改后缀对应软件就行了。

### GEOSITE 域名样板 [目录](https://github.com/bgpeer/rules/tree/main/geo/geosite)

```
https://raw.githubusercontent.com/bgpeer/rules/main/geo/geosite/cn.list
```

### GEOIP 样板 [目录](https://github.com/bgpeer/rules/tree/main/geo/geoip)

```
https://raw.githubusercontent.com/bgpeer/rules/main/geo/geoip/cn.list
```

---

## 🚀 使用方法

### Clash Mi

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
>
> - `geosite/google.mrs`
> - `geoip/google.mrs`

---

### QuantumultX

QuantumultX 使用 `filter_remote` 引用远程规则，需使用 `QX/` 目录下的专用文件，该目录使用 QX 原生的 `HOST` 系格式。

#### geosite 域名样板 [目录](https://github.com/bgpeer/rules/tree/main/QX/geosite)

```
https://raw.githubusercontent.com/bgpeer/rules/main/QX/geosite/cn.list
```

#### geoip 样板 [目录](https://github.com/bgpeer/rules/tree/main/QX/geoip)

```
https://raw.githubusercontent.com/bgpeer/rules/main/QX/geoip/cn.list
```

#### 在 filter_remote 中引用

```ini
[filter_remote]
https://raw.githubusercontent.com/bgpeer/rules/main/QX/geosite/cn.list, tag=CN, force-policy=direct, update-interval=86400, opt-parser=false, enabled=true
https://raw.githubusercontent.com/bgpeer/rules/main/QX/geoip/cn.list, tag=CN-IP, force-policy=direct, update-interval=86400, opt-parser=false, enabled=true
```

> 说明：文件内不含策略名，必须通过 `force-policy` 指定走哪个策略组，否则 QX 解析失败。将 `direct` 替换为你实际的策略组名称即可。

#### QuantumultX 格式说明

| 规则类型 | 示例 |
| --- | --- |
| 域名后缀 | `HOST-SUFFIX, example.com` |
| 域名精确 | `HOST, api.example.com` |
| 域名关键字 | `HOST-KEYWORD, openai` |
| IPv4 | `IP-CIDR, 1.1.1.1/32` |
| IPv6 | `IP-CIDR6, 2606::/32` |

---

## 🌐 国内无法直连 GitHub Raw？

`raw.githubusercontent.com` 在国内可能无法直接访问，你可以自建 Cloudflare Worker 做代理转发。

👉 [Cloudflare Worker 部署教程](https://github.com/bgpeer/rules/blob/main/CF-Worker部署教程.md)

部署完成后，将上述链接中的 `https://raw.githubusercontent.com/bgpeer/rules/main/` 替换为 `https://你的域名/rules/` 即可。

---

## 📜 来源与免责声明

- 本仓库的 GeoIP / GeoSite 规则数据部分来自上游开源项目(如 [Loyalsoldier/geoip](https://github.com/Loyalsoldier/geoip)、[Loyalsoldier/v2ray-rules-dat](https://github.com/Loyalsoldier/v2ray-rules-dat) 等)整理、转换而来,相关数据版权归各自作者所有,在此致谢。
- 本仓库仅提供**分流规则文件与配置模板**,不提供任何代理服务、节点或订阅。规则仅供**学习、研究与个人自用**。
- 请在遵守你所在地区**法律法规**的前提下使用;因使用本仓库内容产生的任何后果由使用者自行承担,作者不承担任何责任。

## 📄 License

本项目以 [MIT License](./LICENSE) 开源;上游数据与第三方组件版权归其各自作者所有。
