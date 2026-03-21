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

🚀 使用方法

1️⃣ Mihomo / Clash Meta

YAML

rule-providers:
  google:
    type: http
    behavior: domain
    url: https://raw.githubusercontent.com/<你的用户名>/<仓库名>/main/geo/rules/geosite/google.yaml
    path: ./ruleset/google.yaml
    interval: 86400

MRS（推荐）

rule-providers:
  google:
    type: http
    behavior: domain
    format: mrs
    url: https://raw.githubusercontent.com/<你的用户名>/<仓库名>/main/geo/rules/geosite/google.mrs

---

2️⃣ Sing-box

JSON

{
  "rule_set": [
    {
      "type": "remote",
      "tag": "google",
      "format": "json",
      "url": "https://raw.githubusercontent.com/<你的用户名>/<仓库名>/main/geo/sing/geosite/google.json"
    }
  ]
}

SRS（推荐）

{
  "rule_set": [
    {
      "type": "remote",
      "tag": "google",
      "format": "binary",
      "url": "https://raw.githubusercontent.com/<你的用户名>/<仓库名>/main/geo/sing/geosite/google.srs"
    }
  ]
}

---

🔄 自动更新

- 每天自动同步（北京时间 02:00）
- 同步源：
  - https://github.com/Loyalsoldier/geoip
  - https://github.com/Loyalsoldier/v2ray-rules-dat

---

⚙️ 本地运行

依赖

- "v2dat"
- "mihomo"
- "sing-box"
- "python3"

执行

chmod +x scripts/sync_loy_geo_mrs.sh
./scripts/sync_loy_geo_mrs.sh

---

🧠 规则转换说明

原始规则| 输出
"full:api.example.com"| DOMAIN
"example.com"| DOMAIN-SUFFIX
".example.com"| DOMAIN-SUFFIX

---

⚠️ 注意

- "keyword:" / "regexp:" 规则默认忽略（避免不兼容问题）
- 所有规则均来自上游项目，不保证 100% 可用性
- 建议优先使用 ".mrs" 或 ".srs"（性能更好）

---

🙏 致谢

- Loyalsoldier
- v2ray-rules-dat
- MetaCubeX / Mihomo
- SagerNet / Sing-box

---

📜 License

MIT
