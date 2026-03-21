🌍 Loyalsoldier Geo Rules → Multi-format Rulesets

自动同步 Loyalsoldier 的 "geoip.dat" 和 "geosite.dat"，并转换为多种常用规则格式，适用于 Mihomo / Clash Meta / Sing-box 等代理工具。

---

✨ 特性

- 🔄 每日自动同步（GitHub Actions）
- 📦 多格式输出
  - Mihomo / Clash：
    - ".mrs"
    - ".yaml"
    - ".list"
  - Sing-box：
    - ".json"
    - ".srs"
- 🧠 语义严格区分
  - "DOMAIN"（精确匹配）
  - "DOMAIN-SUFFIX"（后缀匹配）
- 🧹 全量同步
  - 自动删除过期规则
- ⚙️ 完全自动化构建

---

📁 目录结构

geo/
├── rules/
│   ├── geosite/
│   │   ├── google.yaml
│   │   ├── google.list
│   │   └── google.mrs
│   └── geoip/
│       ├── cn.yaml
│       ├── cn.list
│       └── cn.mrs
└── sing/
    ├── geosite/
    │   ├── google.json
    │   └── google.srs
    └── geoip/
        ├── cn.json
        └── cn.srs

---

## 使用方法（ClashMi）

在 ClashMi → **Geo RuleSet** 中填写以下两个目录链接（推荐使用 CDN）：

### Loy_GeoSite:[域名规则集目录](https://github.com/SHICHUNHUI88/rules/tree/main/geo/rules/geosite)
```
https://cdn.jsdelivr.net/gh/SHICHUNHUI88@main/rules/geo/rules/geosite
```

### Loy_GeoIP:[ip规则集目录](https://github.com/SHICHUNHUI88/tree/main/rules/geo/rules/geoip)
```
https://cdn.jsdelivr.net/gh/SHICHUNHUI88@main/rules/geo/rules/geoip
```


> 说明：这是“目录链接”，ClashMi 会按需下载其中的 `.mrs` 小文件（例如 
- `geosite/google.mrs`
- `geoip/google.mrs`

---
## [可用于Clash Mi的样板](https://cdn.gh-proxy.org/https://gist.github.com/SHICHUNHUI88/01f635bc410f3503a218e03e537cb135/raw/ClashMi.yaml)
---

## 同步机制

- 上游来源：Loyalsoldier / MetaCubeX 相关 Geo 规则体系（拆分 `.mrs`）
- 同步频率：每日自动同步（北京时间凌晨更新）
- 同步策略：**增删同步**（上游新增/删除/更新都会同步到本仓库）

---

## 目录结构（Loyalsoldier）

singbox/
  Loy-geosite/   # 域名类规则集（.srs）
  Loy-geoip/     # IP 类规则集（.srs）

---

## CDN 目录链接（推荐）

### Loy-GeoSite:[sing-box目录](https://github.com/SHICHUNHUI88/tree/main/rules/geo/sing/geosite)
```
https://cdn.jsdelivr.net/gh/SHICHUNHUI88@main/rules/geo/sing/geosite
```

### Loy-GeoIP:[sing-box目录](https://github.com/SHICHUNHUI88/tree/main/rules/geo/sing/geoip)
```
https://cdn.jsdelivr.net/gh/SHICHUNHUI88@main/rules/geo/sing/geoip
```

> 说明：这是“目录链接”，singbox 会按需下载其中的 `.srs` 小文件（例如
- `geosite/google.srs`
- `geoip/google.srs`
