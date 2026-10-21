/**
 * bgpeer Mihomo 覆写脚本
 * @version 5.12.4
 * @date    2026-10-21
 * @support Mihomo Party / ClashMi / Clash Verge Rev / FlClash / Bettbox
 * @usage   客户端「覆写」处导入链接; ClashMi: 核心设置 → 复写 → 右上 ➕ → 类型选 js
 */

// Bettbox 可视化开关
const Compatible_With_Bettbox = { ruleOptionsEnable: true };

// 开关总表 (由下方 SVC + FN_SWITCHES 填充, Bettbox 界面按此显示)
const ruleOptionsEnable = {};

// 默认关闭的分流组, 例: ["🎬TikTok", "📽️Netflix"]
const GROUP_OFF = [];

// 功能开关 (true 开 / false 关)
const FN_SWITCHES = {
  链式代理: true,
  严格链式: false,         // 落地节点名需含「落地」或 🏠
  广告拦截: true,          // 关掉省内存 (iOS)
  DNS配置: true,
  域名嗅探: true,
  TUN网卡: true,
  Geo数据库: true,
  客户端参数: true,        // 与客户端设置冲突时关
  浏览器面板: true,
  面板局域网访问: false,   // 需开「浏览器面板」; 开 = 局域网可连
  机场订阅: true,
  单节点链接: true,
  自建节点: true,
  动态国家组: true,
  其他随机组: true,
  美国旗规范: true,
  量子加密: true,
  多路复用: false,         // 服务端没开 mux 会连不上
};

// 开关在 main() 内现读: Bettbox 调用 main() 前才注入界面选择

// 分流组开关查表; 未列出的组 (核心组 / 国家组) 视为开启
function groupOn(n) { return ruleOptionsEnable[n] !== false; }

// ---------- 其余参数 (非布尔, 需手动改) ----------
const ICON = "https://cdn.jsdelivr.net/gh/bgpeer/icons@main/color/";
const RULES = "https://cdn.jsdelivr.net/gh/bgpeer/rules@main/";
const GEO_MMDB = "https://cdn.jsdelivr.net/gh/Loyalsoldier/geoip@release/GeoLite2-Country.mmdb";
const GEO_ASN  = "https://cdn.jsdelivr.net/gh/Loyalsoldier/geoip@release/GeoLite2-ASN.mmdb";
const threshold = 2;             // 节点数少于此值不建该国家组
const PANEL_SECRET = "88888888"; // 面板密码 (端口 9092); "random" = 按节点自动生成
const FETCH_VIA = "fallback";    // 规则集下载: "" 直连 | "fallback" 直连优先、失败走代理 | 组名 = 强制走该组
const TUN_STACK = "mips";        // mips (默认, 内核 ≥1.19.31; 旧内核报 invalid tun stack 整份配置起不来, 改 mixed) | mixed | system | gvisor (最兼容)
const TUN_CC = "";               // 仅 mips 栈: "" 默认 | cubic | reno | bbr | bbr3
const CHAIN_EXIT = "落地|🏠";     // 落地节点名关键字 (严格链式用)
// 协议白名单
const FP_OK   = ["vless", "vmess", "trojan"];        // 支持 uTLS 指纹的协议
const SMUX_OK = ["ss", "vmess", "vless", "trojan"];  // 支持 smux 的协议

// 机场订阅: "名称": "链接" 或 "名称": ["链接", "前缀"]; 节点自动加上标 ¹²³
// 前缀勿用国旗 (会被吸进国家组)
const PROVIDER_URLS = {
  "机场1": "#填自己机场订阅",   // 更多机场照此添加
  "机场2": "#填自己机场订阅",
  "机场3": "#填自己机场订阅",
};
const PROVIDER_PROXY = "📥订阅下载"; // "📥订阅下载" 直连优先 | "DIRECT" | "🌍全球加速"
// 订阅节点是客户端之后才拉的, 脚本运行时看不到: 动态国家组只按 config.proxies 里的节点建, 订阅节点进 🎲其他随机

// 单节点分享链接: vless / vmess / ss / trojan / hy2 / tuic / anytls / socks / http
// 名称带国旗或地名才进对应国家组, 否则进 🎲其他随机
const LINK_TAG = "📌";     // 单节点名前缀, 如 📌¹洛杉矶
const LINKS = [
  // 三种写法, 去掉行首 // 填入真实链接:
  // ["🇺🇸洛杉矶家宽", "vless://....."],               // 自定义名 + 链接
  // "http://user:pass@5.6.7.8:8080#🇯🇵东京HTTP家宽",  // 用链接自带名
  // "hysteria2://....",                                // 无名则用协议名
];

// 自建节点: 单行 YAML flow 写法, 删掉示例行首 # 后填入
const PROXY_TAG = "🏠";    // 自建节点名前缀
const PROXIES_YAML = `
# - {name: "🇺🇸 VLESS_TCP/TLS_Vision", type: vless, server: a.com, port: 443, uuid: your-uuid, udp: true, tls: true, network: tcp, client-fingerprint: chrome, flow: xtls-rprx-vision, servername: a.com, skip-cert-verify: false}
# - {name: "🇺🇸美国SOCKS5", type: socks5, server: 1.2.3.4, port: 1080, username: user, password: pass, udp: true}
# - {name: "🇯🇵日本HTTP", type: http, server: 5.6.7.8, port: 8080, username: user, password: pass, tls: false}
`;

// 国家组: [组名, 匹配正则], 顺序即显示顺序; 英文代码带 \b 防误匹配
const COUNTRY = [
  ["🇭🇰香港随机",   /🇭🇰|\bHK\b|Hong|hong|香港|深港|沪港|京港/],
  ["🇹🇼台湾随机",   /🇹🇼|\bTW\b|\bTWN\b|Taiwan|Taipei|台湾|台灣|台北/],
  ["🇯🇵日本随机",   /🇯🇵|\bJP\b|Japan|japan|Tokyo|东京|大阪|日本/],
  ["🇸🇬新加坡随机", /🇸🇬|\bSG\b|Singapore|singapore|新加坡|狮城/],
  ["🇰🇷韩国随机",   /🇰🇷|\bKR\b|Korea|korea|韩国|首尔/],
  ["🇺🇸美国随机",   /🇺🇸|\bUS\b|\bUSA\b|America|美国|洛杉矶|纽约|西雅图|圣何塞|硅谷/],
  ["🇬🇧英国随机",   /🇬🇧|\bUK\b|\bGB\b|England|Britain|London|英国|伦敦/],
  ["🇩🇪德国随机",   /🇩🇪|\bDE\b|Germany|German|Frankfurt|德国|法兰克福/],
  ["🇳🇱荷兰随机",   /🇳🇱|\bNL\b|Netherlands|Holland|Amsterdam|荷兰|阿姆斯特丹/],
  ["🇫🇷法国随机",   /🇫🇷|\bFR\b|France|Paris|法国|巴黎/],
  ["🇨🇦加拿大随机",  /🇨🇦|\bCA\b|Canada|加拿大|多伦多/],
  ["🇦🇺澳洲随机",    /🇦🇺|\bAU\b|Australia|Sydney|澳大利亚|悉尼/],
  ["🇷🇺俄罗斯随机",  /🇷🇺|\bRU\b|Russia|Moscow|俄罗斯|莫斯科/],
  ["🇮🇳印度随机",    /🇮🇳|India|india|Mumbai|Bombay|Delhi|Bangalore|Bengaluru|Chennai|印度|孟买|新德里|班加罗尔/],
  ["🇻🇳越南随机",    /🇻🇳|Vietnam|vietnam|Hanoi|Saigon|越南|河内|胡志明|西贡/],
  ["🇲🇾马来西亚随机", /🇲🇾|Malaysia|malaysia|KualaLumpur|Kuala|马来|吉隆坡/],
  ["🇹🇭泰国随机",    /🇹🇭|\bTH\b|Thailand|thailand|Bangkok|泰国|曼谷/],
  ["🇮🇩印尼随机",    /🇮🇩|Indonesia|indonesia|Jakarta|印尼|印度尼西亚|雅加达/],
  ["🇵🇭菲律宾随机",  /🇵🇭|\bPH\b|Philippines|philippines|Manila|菲律宾|马尼拉/],
  ["🇹🇷土耳其随机",  /🇹🇷|Turkey|turkey|Türkiye|Istanbul|土耳其|伊斯坦布尔/],
  ["🇦🇪阿联酋随机",  /🇦🇪|\bUAE\b|Emirates|Dubai|阿联酋|迪拜|阿布扎比/],
  ["🇧🇷巴西随机",    /🇧🇷|\bBR\b|Brazil|brazil|Brasil|SaoPaulo|巴西|圣保罗/],
  ["🇦🇷阿根廷随机",  /🇦🇷|\bAR\b|Argentina|argentina|阿根廷|布宜诺斯艾利斯/],
];

// 中国节点: 归入 🎯直连 与隐藏的 🇨🇳中国随机, 不进出国组
const CN_GROUP = "🇨🇳中国随机";
const CN_PAT = /🇨🇳|\bCN\b|\bcn\b|中国大陆/;
const CN_TEST_URL = "http://connect.rom.miui.com/generate_204";   // 国内测速地址

// 自定义国家组 (同名替代动态组, 固定建; 机场订阅的地区写在这), 去掉 // 后填写
// 组名在上面 COUNTRY 表里的可只写组名, 自动用表里的正则; 表里没有的必须写正则, 否则跳过
const CUSTOM_RANDOM = [
  // ["🇯🇵日本随机"],                                    // 只写组名: 用 COUNTRY 表里的正则
  // ["🇺🇸美国随机", /\bUS\b|\bUSA\b|🇺🇸|美国|洛杉矶/],   // 同名: 替代动态组
  // ["🇰🇷韩国随机", /\bKR\b|🇰🇷|韩国|首尔/],
  // ["🏠家宽随机",   /家宽|住宅|ISP/],                    // 新名: 新增一组 (必须写正则)
];

// 规则集下载通道 + 本地缓存路径
const FETCH_GROUP = "📥规则下载";   // fallback 模式的下载组
const P = (u) => {
  const o = {};
  if (FETCH_VIA === "fallback") o.proxy = FETCH_GROUP;
  else if (FETCH_VIA) o.proxy = FETCH_VIA;
  o.path = "./bgpeer/" + u.replace(/[\/!]/g, "_");
  return o;
};
const CN_DNS = ["https://223.5.5.5/dns-query#🎯直连", "https://doh.pub/dns-query#🎯直连"];  // DNSPod 无公开 IP, 保留域名
const SYS_DNS = ["system"];   // 内网域名走系统 DNS
// 国外 DoH 一律写 IP (域名形式在国内会被污染)
const G_DNS  = ["https://1.1.1.1/dns-query#🌍全球加速", "https://8.8.8.8/dns-query#🌐Google服务", "https://9.9.9.9/dns-query#🌍全球加速", "tls://1.1.1.1:853#🌍全球加速", "tls://8.8.8.8:853#🌐Google服务"];
// 规则主表: [规则集, 类型, 文件名, 目标组, no-resolve, DNS]
//   类型: d = 域名 mrs | c = 域名 yaml | i = IP mrs
//   no-resolve: IP 规则填 1; DNS: g 国外 | z 国内 | s 系统
const META = { d: ["geosite", "domain", "mrs"], c: ["geosite", "classical", "yaml"], i: ["geoip", "ipcidr", "mrs"] };
const T = [
  ["reject", "d", "category-ads-all", "REJECT"],
  ["TikTok-zj", "d", "tiktok", "🎬TikTok", 0, "g"],
  ["douyin-zj", "d", "bytedance", "🎷抖音", 0, "z"],
  ["OpenAI-zj", "c", "openai", "🧠OpenAI", 0, "g"],
  ["Claude-zj", "c", "anthropic", "🤖Claude", 0, "g"],
  ["PayPal", "d", "paypal", "💳PayPal", 0, "g"],
  ["Cryptocurrency", "d", "category-cryptocurrency", "💰加密货币", 0, "z"],
  ["games-!cn", "c", "category-games-!cn", "🎮国际游戏", 0, "g"],
  ["Telegram-zj", "c", "telegram", "💻Telegram", 0, "g"],
  ["Netflix", "c", "netflix", "📽️Netflix", 0, "g"],
  ["Google-zj", "c", "google", "🌐Google服务", 0, "g"],
  ["google-ip", "i", "google", "🌐Google服务", 1],
  ["Facebook-zj", "d", "meta", "📱Meta", 0, "g"],
  ["GitHub-zj", "d", "github", "😈GitHub", 0, "g"],
  ["Microsoft", "d", "microsoft", "😊微软服务", 0, "g"],
  ["icloud", "d", "icloud", "🍎苹果服务", 0, "g"],
  ["Apple", "c", "apple", "🍎苹果服务", 0, "g"],
  ["twitter", "d", "twitter", "🐦X", 0, "g"],
  ["cloudflare-ip", "i", "cloudflare", "🌍全球加速", 1],
  ["cloudfront-ip", "i", "cloudfront", "🌍全球加速", 1],
  ["fastly-ip", "i", "fastly", "🌍全球加速", 1],
  ["greatfire", "d", "greatfire", "🌍全球加速", 0, "g"],
  ["gfw", "d", "gfw", "🌍全球加速", 0, "g"],
  ["geolocation-!cn", "d", "geolocation-!cn", "🌍全球加速", 0, "g"],
  ["games-cn", "d", "category-games-cn", "🎯直连", 0, "z"],
  ["bilibili", "d", "bilibili", "📺哔哩哔哩", 0, "z"],
  ["xiaohongshu", "d", "xiaohongshu", "📕小红书", 0, "z"],
  ["Alibaba", "d", "alibaba", "⛩️阿里腾讯", 0, "z"],
  ["Tencent", "d", "tencent", "⛩️阿里腾讯", 0, "z"],
  ["private", "d", "private", "🎯直连", 0, "s"],
  ["cn-domain", "d", "cn", "🎯直连", 0, "z"],
  ["private-ip", "i", "private", "🎯直连", 1],
  ["cn-ip", "i", "cn", "🎯直连", 1],
];
// 解析行尾可选项 (位置无关): 1 = no-resolve; g / z / s = DNS 归属
function tailOpts(arr, from) {
  let nr = false, dns = "";
  for (let i = from; i < arr.length; i++) {
    const v = arr[i];
    if (v === "g" || v === "z" || v === "s") dns = v;
    else if (v === 1 || v === true) nr = true;
  }
  return { nr: nr, dns: dns };
}

// 服务组: [组名, 图标, 默认直连]; 图标可省, 默认直连填 1
const SVC = [
  ["🎷抖音", "douyin_1.png", 1], ["🎬TikTok", "tiktok_1.png"], ["🎮国际游戏", "game_2.png"],
  ["💻Telegram", "telegram.png"], ["🧠OpenAI", "chatgpt.png"], ["🤖Claude", "claude_1.png"],
  ["💳PayPal", "paypal_1.png"], ["🌐Google服务", "google_1.png"], ["📱Meta", "meta.png"],
  ["🐦X", "x.png"], ["📽️Netflix", "netflix.png"], ["😈GitHub", "github.png"],
  ["😊微软服务", "microsoft.png", 1], ["🍎苹果服务", "apple.png", 1], ["💰加密货币", "cryptocurrency.png", 1],
  ["📺哔哩哔哩", "bilibili_2.png", 1], ["📕小红书", "xiaohongshu_1.png", 1],
];


// 自定义组图标: [组名, 图标完整 URL], 优先级最高
const ICONS = [
  // ["🎬Emby",       "https://example.com/emby.png"],
  // ["🌐Google服务", "https://example.com/my-google.png"],   // 覆盖 SVC 里给的图标
];

// 填充开关总表: 分流组在前, 功能开关在后
const SWITCH_META = SVC.map((s) => [s[0], typeof s[1] === "string" ? s[1] : null])
  .concat([["⛩️阿里腾讯", "alibaba_tencent.png"]]);        // 不在 SVC 里, 单独补
const SWITCH_GROUPS = SWITCH_META.map((x) => x[0]);
for (const n of SWITCH_GROUPS) ruleOptionsEnable[n] = !GROUP_OFF.includes(n);
Object.assign(ruleOptionsEnable, FN_SWITCHES);

// Bettbox 开关图标 (key 对应开关名)
const serviceConfigs = SWITCH_META.map(function (x) {
  const over = (ICONS || []).find((i) => i && i[0] === x[0]);
  return { key: x[0], name: x[0], icon: over ? over[1] : x[1] ? ICON + x[1] : "" };
});

// 自定义规则: [类型, 值, 目标组, no-resolve, DNS], 排在所有规则集之前
const CUSTOM = [
  ["IP-CIDR", "223.5.5.5/32", "🎯直连", 1],
  // ["DOMAIN-SUFFIX",  "emby.某机场域名.com", "🎬Emby", 0, "g"],   // 走国外 DNS
  // ["DOMAIN-SUFFIX",  "example.com",        "🌍全球加速", "g"],     // 只给 DNS 归属
  // ["DOMAIN-KEYWORD", "emby",               "🎬Emby"],             // 默认 DNS
  // ["IP-CIDR",        "1.2.3.0/24",         "🎷抖音", 1],        // IP 规则填 1
];

function main(config) {

  // 读开关 (须在 main 内读)
  const {
    DNS配置: setDNS, 域名嗅探: setSniffer, TUN网卡: setTun, Geo数据库: setGeo, 客户端参数: setClientOpts,
    机场订阅: useProviders, 单节点链接: useLinks, 自建节点: useProxies,
    动态国家组: autoCountry, 其他随机组: otherGroup, 链式代理: CHAIN, 严格链式: CHAIN_STRICT,
    美国旗规范: fixUSFlag, 量子加密: MLKEM_OK, 多路复用: SMUX_FILL, 广告拦截: ADBLOCK,
  } = ruleOptionsEnable;
  // 面板: 关 | 仅本机 | 局域网
  const setPanel = !ruleOptionsEnable.浏览器面板 ? false : (ruleOptionsEnable.面板局域网访问 ? "lan" : "local");
  // 只保留目标组存在的规则 (组被关或删掉时规则一并跳过, 否则内核报错)
  const LIVE = new Set(SWITCH_GROUPS.filter(groupOn).concat(["🎯直连", "🌍全球加速", "🤡漏网之鱼", "REJECT", "DIRECT"]));
  const T_ON = T.filter(function (r) { return (ADBLOCK || r[0] !== "reject") && LIVE.has(r[3]); });
  // DNS 分流集合 (须基于 T_ON)
  const G_SETS  = T_ON.filter(r => tailOpts(r, 4).dns === "g").map(r => r[0]);
  const CN_SETS = T_ON.filter(r => tailOpts(r, 4).dns === "z").map(r => r[0]);
  const SYS_SETS = T_ON.filter(r => tailOpts(r, 4).dns === "s").map(r => r[0]);

  // 空配置兜底
  if (!config || typeof config !== "object") config = {};
  if (!Array.isArray(config.proxies)) config.proxies = [];
  const proxies = config.proxies;
  // 机场订阅: 与已有 proxy-providers 合并
  const providers = useProviders ? buildProviders() : {};
  const hasProviders = Object.keys(providers).length > 0;    // 真填了链接 (占位不算)
  if (useProviders) config["proxy-providers"] = Object.assign({}, config["proxy-providers"], providers);

  // 单节点链接 (同名自动加序号)
  if (useLinks) {
    const added = parseLinks(LINKS);
    const seen = {};
    for (const p of proxies) if (p && p.name) seen[p.name] = 1;
    for (const p of added) {
      let nm = p.name || p.server, base = nm, k = 2;
      while (seen[nm]) nm = base + " " + (k++);
      p.name = nm; seen[nm] = 1;
      proxies.push(p);
    }
  }

  // 自建节点 (加前缀, 同名自动加序号)
  if (useProxies) {
    const seen = {};
    for (const p of proxies) if (p && p.name) seen[p.name] = 1;
    const selfNodes = parseYamlProxies(PROXIES_YAML);
    for (const raw of selfNodes) {
      if (!raw || typeof raw !== "object" || !raw.server) continue;   // 缺 server 跳过
      const p = Object.assign({}, raw);                               // 拷贝
      const base = (p.name == null ? "" : String(p.name)).trim() || String(p.server);
      let nm = PROXY_TAG + base, root = nm, k = 2;
      while (seen[nm]) nm = root + " " + (k++);
      p.name = nm; seen[nm] = 1;
      proxies.push(p);
    }
  }

  // 1) 美国旗规范
  if (fixUSFlag) {
    for (const p of proxies) {
      if (p && p.name) p.name = p.name.replace(/\u{1F1FA}\u{1F1F2}/gu, "\u{1F1FA}\u{1F1F8}");
    }
  }

  // 1.5) 节点名 YAML 安全化 (先于国家检测)
  for (const p of proxies) if (p && p.name) p.name = safeName(p.name);

  // 2) 自定义国家组: 强制生成, 坏行跳过
  const custom = [];
  for (const c of (CUSTOM_RANDOM || [])) {
    if (!c || !c[0]) continue;
    let re = c[1];
    if (!re) {                                                  // 只写组名: 查 COUNTRY 表
      const hit = COUNTRY.find(function (x) { return x[0] === c[0]; });
      if (!hit) { try { console.log("[CUSTOM_RANDOM] " + c[0] + " 不在 COUNTRY 表里, 要写正则, 已跳过"); } catch (e) {} continue; }
      re = hit[1];
    }
    if (!re.source) { try { re = new RegExp(String(re)); } catch (e) { continue; } }   // 兼容字符串写法
    custom.push([c[0], re]);
  }
  const customNames = custom.map(function (c) { return c[0]; });

  // 2.1) 动态国家组: 节点数 ≥ threshold, 同名让位给自定义组
  const present = !autoCountry ? [] : COUNTRY.filter(function (c) {
    if (customNames.indexOf(c[0]) !== -1) return false;      // 自定义优先
    let n = 0;
    for (const p of proxies) if (p && p.name && c[1].test(p.name)) n++;
    return n >= threshold;
  });
  const countryNames = customNames.concat(present.map(function (c) { return c[0]; }));

  // 2.2) 中国节点: 命中 CN_PAT 且不含其它国家标记
  const OTHER_CC_PAT = COUNTRY.map(function (c) { return c[1].source; }).join("|");
  const OTHER_CC_RE = new RegExp(OTHER_CC_PAT);
  // cnSeen: 扫到中国节点才建 🇨🇳中国随机 (空组会报错)
  // hasCN: 扫到或开了机场订阅 → 🎯直连 收中国节点
  // CN_EXACT: 中国节点名精确正则, 出国组用它排除
  const cnNames = proxies.filter(function (p) { return p && p.name && CN_PAT.test(p.name) && !OTHER_CC_RE.test(p.name); })
    .map(function (p) { return p.name; });
  const CN_EXACT = cnNames.length ? "^(?:" + cnNames.map(reEsc).join("|") + ")$" : "";
  const cnSeen = customNames.indexOf(CN_GROUP) === -1 && cnNames.length > 0;
  const hasCN = cnSeen || useProviders;

  // 2.5) 漏网节点 (不属于任何已建的国家组) → 🎲其他随机
  // 只排除建了组的地区: 没建组的 (节点不够数 / 订阅里的冷门地区) 进 🎲其他随机, 不然哪个国家组都不收
  const ALL_PAT = custom.map(function (c) { return c[1].source; })
    .concat(present.map(function (c) { return c[1].source; }))
    .concat(CN_EXACT ? [CN_EXACT] : [])
    .join("|");
  const ALL_RE = ALL_PAT ? new RegExp(ALL_PAT) : null;       // 无归属正则时全算漏网
  let hasOther = false;
  for (const p of proxies) { if (p && p.name && (!ALL_RE || !ALL_RE.test(p.name))) { hasOther = true; break; } }
  const useOther = otherGroup && (hasOther || hasProviders);   // 订阅节点看不到, 填了订阅就建
  const OTHER = "🎲其他随机";
  const tail = countryNames.concat(useOther ? [OTHER] : []);  // 国家组 + 🎲其他随机

  // 3) 公共片段
  const URLTEST = {
    type: "url-test", lazy: true, icon: ICON + "bypass.png",
    "include-all": true, "exclude-type": "direct",
    url: "https://www.gstatic.com/generate_204", interval: 300, tolerance: 30, timeout: 5000, hidden: true,
  };
  const AUTO = { "include-all": true, "exclude-type": "direct", filter: ".*" };

  // 4) 组成员列表
  const ACCEL   = ["♻️全部随机", "🔗链式出口"].concat(tail);
  const GLOBAL  = ["🌍全球加速", "🔗链式出口", "♻️全部随机"].concat(tail, ["🎯直连"]);
  const GLOBAL_D = ["🎯直连", "🌍全球加速", "🔗链式出口", "♻️全部随机"].concat(tail);

  // 5) select 服务组辅助
  const sel = function (name, icon, list) {
    if (icon == null) return Object.assign({ name: name, type: "select", proxies: list }, AUTO);
    return Object.assign({ name: name, type: "select", icon: ICON + icon, proxies: list }, AUTO);
  };

  // 6) 国家组 + 🎲其他随机 + ♻️全部随机
  const countryGroups = custom.map(function (c) {
    return Object.assign({}, URLTEST, { name: c[0], filter: safeFilter(c[1].source) });
  }).concat(present.map(function (c) {
    return Object.assign({}, URLTEST, { name: c[0], filter: safeFilter(c[1].source) });
  }));
  if (useOther) {
    // 收全部节点, 排除已归类的
    const og = Object.assign({}, URLTEST, { name: OTHER });
    if (ALL_PAT) og["exclude-filter"] = safeFilter(ALL_PAT);
    countryGroups.push(og);
  }
  countryGroups.push(Object.assign({}, URLTEST, { name: "♻️全部随机", filter: ".*" }));
  // 🇨🇳中国随机 (隐藏): 国内地址测速
  if (cnSeen) {
    countryGroups.push(Object.assign({}, URLTEST, {
      name: CN_GROUP, filter: safeFilter(CN_PAT.source),
      "exclude-filter": safeFilter(OTHER_CC_PAT), url: CN_TEST_URL,
    }));
  }

  // 7) 组装 proxy-groups
  config["proxy-groups"] = [
    Object.assign({ name: "🌍全球加速", type: "select", icon: ICON + "global.png", proxies: ACCEL },
                  AUTO, { url: "https://www.gstatic.com/generate_204", interval: 300, timeout: 5000 }),
    ...SVC.map(function (s) {
      const hasIcon = typeof s[1] === "string";   // 字符串 = 图标, 数字 = 直连标志
      return sel(s[0], hasIcon ? s[1] : null, (hasIcon ? s[2] : s[1]) ? GLOBAL_D : GLOBAL);
    }),
    { name: "⛩️阿里腾讯", type: "select", icon: ICON + "alibaba_tencent.png", proxies: ["🎯直连", "🌍全球加速"] },
    // 🎯直连: 有中国节点时一并收入, 可手选
    Object.assign({ name: "🎯直连", type: "select", icon: ICON + "china.png", proxies: ["DIRECT"].concat(cnSeen ? [CN_GROUP] : [], ["🌍全球加速"]), url: CN_TEST_URL },
      // 不能加 exclude-type: direct (会踢掉 DIRECT)
      hasCN ? { "include-all": true, filter: safeFilter(CN_PAT.source), "exclude-filter": safeFilter(OTHER_CC_PAT) } : {}),
    { name: "🤡漏网之鱼", type: "select", icon: ICON + "match_1.png", proxies: ["🌍全球加速", "🎯直连"] },
    // 链式代理: 出口 (落地) 经 dialer-proxy 走中转; 不含 🌍全球加速 防成环
    Object.assign({ name: "🔗链式出口", type: "select", icon: ICON + "chainexport.png",
      override: { "dialer-proxy": "🔗链式中转" },
      proxies: ["♻️全部随机"].concat(tail) }, AUTO),
    // 中转: 前置跳板
    Object.assign({ name: "🔗链式中转", type: "select", icon: ICON + "chaintransfer.png",
      proxies: ["🌍全球加速", "♻️全部随机"].concat(tail) }, AUTO),
  ].concat(
    // 📥规则下载: 直连优先, 失败切 🌍全球加速
    FETCH_VIA === "fallback" ? [{
      name: FETCH_GROUP, type: "fallback", icon: ICON + "bypass.png",
      proxies: ["DIRECT", "🌍全球加速"],
      url: RULES + "geo/geoip/private.mrs",
      interval: 300, lazy: false, hidden: true,
    }] : []
  ).concat(
    // 📥订阅下载: 直连优先, 失败切 🌍全球加速
    (useProviders && PROVIDER_PROXY === "📥订阅下载") ? [{
      name: "📥订阅下载", type: "fallback", icon: ICON + "bypass.png",
      proxies: ["DIRECT", "🌍全球加速"],
      url: "https://www.gstatic.com/generate_204",
      interval: 300, lazy: false, hidden: true,
    }] : []
  ).concat(countryGroups);

  // 8.4) 剔除被关掉的分流组
  config["proxy-groups"] = config["proxy-groups"].filter(function (g) { return g && groupOn(g.name); });

  // 8.5) GLOBAL 组
  const orderedGroups = config["proxy-groups"].filter(g => !g.hidden && g.name !== "GLOBAL").map(g => g.name);
  config["proxy-groups"].push({
    name: "GLOBAL",
    type: "select",
    icon: ICON + "match.png",
    "include-all": true,                          
    proxies: [...new Set(orderedGroups.concat(ACCEL, ["DIRECT"]))],  // 去重
  });

  // 8.55) 关闭链式: 删两组及其引用, 空组补 DIRECT
  if (!CHAIN) {
    const CHAIN_GROUPS = ["🔗链式出口", "🔗链式中转"];
    config["proxy-groups"] = config["proxy-groups"].filter(g => !CHAIN_GROUPS.includes(g.name));
    for (const g of config["proxy-groups"]) {
      if (Array.isArray(g.proxies)) {
        g.proxies = g.proxies.filter(p => !CHAIN_GROUPS.includes(p));
        if (!g.proxies.length) g.proxies = ["DIRECT"];
      }
    }
  }

  // 8.555) 出国组排除中国节点 (保留在 🎯直连 / 国家组 / 链式中转 / GLOBAL)
  if (CN_EXACT) {
    const keep = new Set(["🎯直连", CN_GROUP, "GLOBAL", "🔗链式中转", OTHER].concat(countryNames));   // 🎲其他随机 已排除过
    const cnf = safeFilter(CN_EXACT);
    for (const g of config["proxy-groups"]) {
      if (!g || !g["include-all"] || keep.has(g.name)) continue;
      g["exclude-filter"] = g["exclude-filter"] ? "(?:" + g["exclude-filter"] + ")|(?:" + CN_EXACT + ")" : cnf;
    }
  }

  // 8.56) 严格链式: 落地节点只留在 🔗链式出口, 其余组全部排除; 无落地节点时跳过
  if (CHAIN && CHAIN_STRICT) {
    let exitRe = null;
    try { exitRe = new RegExp(CHAIN_EXIT); } catch (e) { exitRe = null; }
    const hasExit = !!exitRe && (config.proxies || []).some(p => p && p.name && exitRe.test(p.name));
    if (!hasExit) {
      try { console.log("[CHAIN_STRICT] 没有节点名匹配 CHAIN_EXIT=" + CHAIN_EXIT + "，已跳过严格链式(给落地节点名字带上'落地'或🏠再开)"); } catch (e) {}
    } else {
      const exf = safeFilter(CHAIN_EXIT);
      for (const g of config["proxy-groups"]) {
        if (!g || !g["include-all"]) continue;
        if (g.name === "🔗链式出口") {
          g.filter = exf;          // 只收落地节点
          delete g.proxies;        // 只走 🔗链式中转
        } else {
          // 其它组排除落地节点 (防直连落地)
          g["exclude-filter"] = g["exclude-filter"] ? "(?:" + g["exclude-filter"] + ")|(?:" + CHAIN_EXIT + ")" : exf;
        }
      }
    }
  }

  // 8.6) 自定义图标覆盖
  const ICON_MAP = {};
  for (const it of (ICONS || [])) {
    if (!it || !it[0] || !it[1] || String(it[1]).charAt(0) === "#") continue;
    ICON_MAP[it[0]] = it[1];
  }
  for (const g of config["proxy-groups"]) {
    if (g && g.name && ICON_MAP[g.name]) g.icon = ICON_MAP[g.name];
  }

  // 9) rule-providers + rules (顺序 = 匹配优先级)
  config["rule-providers"] = {};
  config.rules = [];
  // 自定义规则排最前
  for (const c of CUSTOM) {
    if (!LIVE.has(c[2])) continue;                 // 目标组不存在则跳过
    config.rules.push(c[0] + "," + c[1] + "," + c[2] + (tailOpts(c, 3).nr ? ",no-resolve" : ""));
  }
  for (const r of T_ON) {
    const [name, t, file, group] = r;
    const [dir, behavior, ext] = META[t];          // [目录, behavior, 格式]
    const u = "geo/" + dir + "/" + file + "." + ext;
    config["rule-providers"][name] = Object.assign(
      { type: "http", behavior: behavior, format: ext, interval: 86400, url: RULES + u }, P(u)
    );
    config.rules.push("RULE-SET," + name + "," + group + (tailOpts(r, 4).nr ? ",no-resolve" : ""));
  }
  config.rules.push("MATCH,🤡漏网之鱼");

  // 10) DNS (可选)
  if (setDNS) {
    // 保留机场订阅自带的 DNS 设置, 稍后合并
    const subDNS    = config.dns || {};
    const subPSN    = [].concat(subDNS["proxy-server-nameserver"] || []);
    const subPolicy = Object.assign({}, subDNS["nameserver-policy"] || {});
    const subFilter = [].concat(subDNS["fake-ip-filter"] || []);
    // 丢弃通吃键 ('+.' / '*') 与指向不存在规则集的键 (否则内核报错)
    const OWN_SETS = new Set(T_ON.map(r => r[0]));
    for (const k of Object.keys(subPolicy)) {
      if (k === "+." || k === "*" || k === "+") { delete subPolicy[k]; continue; }
      if (k.indexOf("rule-set:") === 0 && !OWN_SETS.has(k.slice(9))) delete subPolicy[k];
    }
    // fake-ip-filter 同样去掉悬空的 rule-set
    const subFilterSafe = subFilter.filter(
      v => typeof v !== "string" || v.indexOf("rule-set:") !== 0 || OWN_SETS.has(v.slice(9))
    );

    // nameserver-policy 由规则表的 DNS 归属生成
    const nsPolicy = {};
    for (const s of SYS_SETS) nsPolicy["rule-set:" + s] = SYS_DNS;
    if (ADBLOCK) nsPolicy["rule-set:reject"] = ["https://dns.adguard.com/dns-query"];
    for (const s of G_SETS)  nsPolicy["rule-set:" + s] = G_DNS;
    for (const s of CN_SETS) nsPolicy["rule-set:" + s] = CN_DNS;
    // 自定义规则的 DNS 归属 (仅 DOMAIN / DOMAIN-SUFFIX)
    for (const c of CUSTOM) {
      const dns = tailOpts(c, 3).dns;
      if (dns !== "g" && dns !== "z" && dns !== "s") continue;
      if (!LIVE.has(c[2])) continue;               // 规则已跳过
      let key = null;
      if (c[0] === "DOMAIN") key = c[1];
      else if (c[0] === "DOMAIN-SUFFIX") key = "+." + c[1];
      else continue;
      nsPolicy[key] = dns === "g" ? G_DNS : dns === "s" ? SYS_DNS : CN_DNS;
    }
    config.dns = {
      enable: true, listen: "0.0.0.0:1053", ipv6: true,
      "use-hosts": true, "use-system-hosts": true, "respect-rules": true,
      "enhanced-mode": "fake-ip", "cache-algorithm": "arc",
      "fake-ip-range": "198.18.0.0/16", "fake-ip-range6": "fc00::/18", "prefer-h3": true,
      "fake-ip-filter-mode": "blacklist", "fake-ip-ttl": 60,
      "fake-ip-filter": [...new Set(["localhost", "+.lan", "+.local", "+.arpa", "+.ntp.org", "captive.apple.com", "connectivitycheck.gstatic.com", "msftconnecttest.com", "msftncsi.com", "openai.*", "+.openai.*", "report-v2.samsung.japps.cn", "rule-set:private", ...subFilterSafe])],
      "direct-nameserver": ["system"],
      "default-nameserver": ["223.5.5.5", "119.29.29.29"],
      nameserver: [...CN_DNS, ...G_DNS],
      "proxy-server-nameserver": [...new Set([...subPSN, "https://1.1.1.1/dns-query", "https://8.8.8.8/dns-query", "https://9.9.9.9/dns-query"])],
      "direct-nameserver-follow-policy": true,
      // 本脚本规则集优先, 保留机场独有域名
      "nameserver-policy": Object.assign({}, subPolicy, nsPolicy),
    };
  }

  // 11) 域名嗅探 (可选)
  if (setSniffer) {
    config.sniffer = {
      enable: true, "force-dns-mapping": true, "parse-pure-ip": true, "override-destination": true,
      sniff: { HTTP: { ports: [80, "8080-8880"], "override-destination": true }, TLS: { ports: [443, 8443] }, QUIC: { ports: [443, 8443] } },
      "force-domain": ["+.cloudflare.net", "+.akamaized.net", "+.akamai.net", "+.fastly.net", "+.cloudfront.net", "+.googlevideo.com", "+.ytimg.com", "+.youtube.com", "+.netflix.com", "+.instagram.com", "+.tiktokcdn.com", "+.tiktokv.com", "+.douyin.com", "+.douyincdn.com", "+.telegram.org", "+.t.me", "+.tdesktop.com", "+.cdn-telegram.org", "+.telegram-cdn.org"],
      "skip-domain": ["localhost", "+.lan", "+.local", "+.arpa", "+.invalid", "+.test", "+.push.apple.com", "+.pvp.net", "+.riotgames.com", "+.openai.com", "+.oaistatic.com", "+.oaiusercontent.com", "+.chatgpt.com"],
      "skip-src-address": ["127.0.0.0/8", "::1/128"],
      "skip-dst-address": ["17.0.0.0/8", "149.154.160.0/20", "91.108.0.0/16"],
    };
  }

  // 12) 顶层配置
  Object.assign(config, {
    "mode": "rule",
    "find-process-mode": "strict",   // iOS 不支持 always
    "unified-delay": true,
    "tcp-concurrent": true,
    "ipv6": true,
    ...(setGeo ? {
      // 只下 mmdb + asn (规则全走 rule-provider)
      "geodata-mode": false,
      "geo-auto-update": true,
      "geo-update-interval": 24,
      "geox-url": { "mmdb": GEO_MMDB, "asn": GEO_ASN },
    } : {}),
    ...(setClientOpts ? {
      "port": 7896, "socks-port": 7891, "redir-port": 7892, "tproxy-port": 7894, "mixed-port": 7893,
      "log-level": "warning",
      "etag-support": true,
      "disable-keep-alive": false,
      "inbound-tfo": true,
      "inbound-mptcp": false,
      "allow-lan": true,
      "bind-address": "*",
      "keep-alive-idle": 300,
      "keep-alive-interval": 30,
      // 入站口令按节点派生, 每人不同
      "authentication": ["meta:" + resolveSecret("random", config.proxies)],
      "skip-auth-prefixes": ["127.0.0.1/8", "::1/128"],
      "lan-allowed-ips": ["0.0.0.0/0", "::/0"],
      "lan-disallowed-ips": [],
      "global-ua": "Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Mobile Safari/537.36",
      "ntp": { "enable": true, "server": "time.apple.com", "port": 123, "interval": 30, "dialer-proxy": "", "write-to-system": false },
      "experimental": { "quic-go-disable-ecn": true },
    } : {}),
  });

  // 13) 浏览器面板: false 关 | local 仅本机 | lan 局域网
  let panel = setPanel === true ? "lan" : setPanel;            // 兼容旧写法
  if (panel === "lan" && PANEL_SECRET === "") panel = "local"; // 局域网必须有口令
  if (panel === "local" || panel === "lan") {
    const realSecret = resolveSecret(PANEL_SECRET, config.proxies);
    config["external-controller"] = (panel === "lan" ? "0.0.0.0" : "127.0.0.1") + ":9092";
    config["secret"] = realSecret;
    config["external-controller-cors"] = panel === "lan"
      ? { "allow-origins": ["*"], "allow-private-network": true }  // 局域网
      : { "allow-origins": ["*"] };                                // 仅本机
    config["external-ui"] = "./ui";
    // zashboard 面板包 (codeload 链接, 经 😈GitHub 组下载)
    config["external-ui-url"] = "https://codeload.github.com/Zephyruso/zashboard/zip/refs/heads/gh-pages";
    // 局域网 + random: 用一个假组显示口令
    if (panel === "lan" && PANEL_SECRET === "random") {
      config["proxy-groups"].push({ name: "🔑面板口令:" + realSecret, type: "select", proxies: ["DIRECT"] });
    }
  }
  config.profile = Object.assign({ "store-selected": true, "store-fake-ip": true }, config.profile || {});

  // 14) TUN
  if (setTun) {
    const t = {
      enable: true,
      device: "mihomo",
      stack: TUN_STACK,
      mtu: 1500,
      "inet6-address": ["fdfe:dcba:9876::1/126"],
      "strict-route": true,
      "dns-hijack": ["any:53", "tcp://any:53"],
      "auto-route": true,
      "auto-detect-interface": true,
      "endpoint-independent-nat": true,
      "udp-timeout": 60,
      "disable-icmp-forwarding": true,
      "route-exclude-address-set": ["private-ip"],
      "route-exclude-cidr": ["192.168.0.0/16", "10.0.0.0/8", "172.16.0.0/12", "100.64.0.0/10", "fc00::/7", "fe80::/10"],
    };
    // auto-redirect / gso: 仅 Linux 且非 gvisor 栈
    const isLinux = (function () {
      try { return typeof process !== "undefined" && process.platform === "linux"; } catch (e) { return false; }
    })();
    if (TUN_STACK !== "gvisor" && isLinux) { t["auto-redirect"] = true; t["gso"] = true; t["gso-max-size"] = 65536; }
    // 拥塞控制: 仅 mips 栈, 只放行 cubic / reno / bbr / bbr3
    const cc = String(TUN_CC).toLowerCase();
    if (TUN_STACK === "mips" && ["cubic", "reno", "bbr", "bbr3"].includes(cc)) t["congestion-controller"] = cc;
    config.tun = t;
  }

  // 15) hosts: 加密 DNS 域名直连官方 IP; 原配置 hosts 优先
  config.hosts = Object.assign({
    "doh.pub": ["1.12.12.12", "120.53.53.53"],
    "dns.alidns.com": ["223.5.5.5", "223.6.6.6"],
    "dns.google": ["8.8.8.8", "8.8.4.4"],
    "cloudflare-dns.com": ["1.1.1.1", "1.0.0.1"],
    "dns.adguard.com": ["94.140.14.14", "94.140.15.15"],
  }, config.hosts || {});

  // 16) 补 uTLS 指纹 chrome (仅 TLS 协议, 已有不覆盖)
  (config.proxies || []).forEach(function (p) {
    if (!p || FP_OK.indexOf(p.type) === -1) return;   // 协议不在白名单
    if (p["client-fingerprint"]) return;              // 已有
    var usesTLS = p.type === "trojan" || p.tls === true || p["reality-opts"];
    if (usesTLS) p["client-fingerprint"] = "chrome";  // 仅走 TLS 时
  });

  // 17) 补 smux (排除 XTLS Vision, 已有不覆盖)
  if (SMUX_FILL) {
    (config.proxies || []).forEach(function (p) {
      if (!p || SMUX_OK.indexOf(p.type) === -1) return;   // 协议不支持
      if (p.smux) return;                    // 已有
      if (p.flow) return;                    // XTLS Vision 不加
      p.smux = { enable: true, protocol: "h2mux", "max-connections": 4, "min-streams": 4, padding: true };
    });
  }

  // 18) Reality 节点补 X25519MLKEM768 后量子密钥交换 (已设置不覆盖)
  if (MLKEM_OK) {
    (config.proxies || []).forEach(function (p) {
      if (!p || !p["reality-opts"]) return;                       // 非 Reality
      if ("support-x25519mlkem768" in p["reality-opts"]) return;  // 已设置
      p["reality-opts"]["support-x25519mlkem768"] = true;
    });
  }

  // YAML 安全化
  return makeYamlSafe(config);
}

// 节点名 YAML 安全化 (替换会破坏裸标量的字符)
function safeName(name) {
  let s = String(name)
    .replace(/:/g, "：").replace(/,/g, "，")
    .replace(/\[/g, "【").replace(/\]/g, "】")
    .replace(/\{/g, "｛").replace(/\}/g, "｝");
  // 行首指示符转全角, 行首引号去掉
  s = s.replace(/^\*/, "＊").replace(/^&/, "＆").replace(/^!/, "！")
       .replace(/^\|/, "｜").replace(/^>/, "＞").replace(/^@/, "＠")
       .replace(/^%/, "％").replace(/^#/, "＃").replace(/^\?/, "？")
       .replace(/^["'`]/, "");
  return s;
}

// 节点名 → 正则字面量 (仅转义正则元字符)
function reEsc(s) {
  return String(s).replace(/[\\.+*?()|\[\]{}^$]/g, "\\$&");
}

// filter 以 YAML 指示符开头时包一层 (?:...)
function safeFilter(src) {
  return /^[\[\]{}>|*&!%@`"',#?:-]/.test(src) ? "(?:" + src + ")" : src;
}

// 数字 → 上标 (1 → ¹)
function sup(n) {
  const S = "⁰¹²³⁴⁵⁶⁷⁸⁹";
  return String(n).replace(/\d/g, function (d) { return S[+d]; });
}
// PANEL_SECRET = "random" 时按节点名派生 (djb2), 同批节点结果不变
function resolveSecret(raw, proxies) {
  if (raw !== "random") return raw;
  let h = 5381;
  const basis = (proxies || []).map(function (p) { return p && p.name; }).filter(Boolean).join("|") || "bgpeer";
  for (let i = 0; i < basis.length; i++) h = ((h << 5) + h + basis.charCodeAt(i)) >>> 0;
  return "p" + h.toString(36);
}
// 生成 proxy-providers (自动加上标前缀)
function buildProviders() {
  const out = {}, names = Object.keys(PROVIDER_URLS);
  for (let i = 0; i < names.length; i++) {
    const v = PROVIDER_URLS[names[i]];
    const url = Array.isArray(v) ? v[0] : v;                      // 数组: 第 0 位为链接
    const tag = (Array.isArray(v) && v[1]) ? String(v[1]) : "";   // 第 1 位为前缀
    if (!url || url.charAt(0) === "#") continue;   // 空或占位跳过
    out[names[i]] = {
      type: "http", interval: 3600, proxy: PROVIDER_PROXY,
      "health-check": { enable: true, url: "https://www.gstatic.com/generate_204", interval: 300 },
      url: url, override: { "additional-prefix": tag + sup(i + 1) },  // 前缀 + 上标
    };
  }
  return out;
}

// ===================== 分享链接解析 =====================
// base64 → 字节 (兼容 url-safe / 无填充)
function b64bytes(s) {
  s = String(s).replace(/-/g, "+").replace(/_/g, "/").replace(/\s+/g, "");
  while (s.length % 4) s += "=";
  const T = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
  const out = []; let buf = 0, bits = 0;
  for (let i = 0; i < s.length; i++) {
    const c = s.charAt(i); if (c === "=") break;
    const v = T.indexOf(c); if (v < 0) continue;
    buf = (buf << 6) | v; bits += 6;
    if (bits >= 8) { bits -= 8; out.push((buf >> bits) & 0xff); }
  }
  return out;
}
// 字节 → UTF-8 字符串
function utf8(b) {
  let s = "", i = 0;
  while (i < b.length) {
    let c = b[i++];
    if (c < 0x80) s += String.fromCharCode(c);
    else if (c < 0xE0) s += String.fromCharCode(((c & 0x1f) << 6) | (b[i++] & 0x3f));
    else if (c < 0xF0) s += String.fromCharCode(((c & 0x0f) << 12) | ((b[i++] & 0x3f) << 6) | (b[i++] & 0x3f));
    else { let cp = ((c & 0x07) << 18) | ((b[i++] & 0x3f) << 12) | ((b[i++] & 0x3f) << 6) | (b[i++] & 0x3f); cp -= 0x10000; s += String.fromCharCode(0xD800 + (cp >> 10), 0xDC00 + (cp & 0x3FF)); }
  }
  return s;
}
function b64str(s) { return utf8(b64bytes(s)); }
function dec(s) { try { return decodeURIComponent(s); } catch (e) { return s; } }
function qparse(q) {
  const o = {}; if (!q) return o;
  q.split("&").forEach(function (kv) {
    if (!kv) return; const i = kv.indexOf("=");
    o[dec(i < 0 ? kv : kv.slice(0, i))] = i < 0 ? "" : dec(kv.slice(i + 1));
  });
  return o;
}
// scheme://rest?query#frag
function splitURI(u) {
  const m = /^([a-z0-9]+):\/\/([\s\S]*)$/i.exec(u); if (!m) return null;
  let rest = m[2], frag = "", query = "";
  const h = rest.indexOf("#"); if (h >= 0) { frag = dec(rest.slice(h + 1)); rest = rest.slice(0, h); }
  const q = rest.indexOf("?"); if (q >= 0) { query = rest.slice(q + 1); rest = rest.slice(0, q); }
  return { scheme: m[1].toLowerCase(), rest: rest, query: query, frag: frag };
}
// userinfo@host:port[/path] (支持 IPv6)
function splitAuthority(rest) {
  let path = ""; const sl = rest.indexOf("/"); if (sl >= 0) { path = rest.slice(sl); rest = rest.slice(0, sl); }
  let userinfo = "", hp = rest; const at = rest.lastIndexOf("@");
  if (at >= 0) { userinfo = rest.slice(0, at); hp = rest.slice(at + 1); }
  let host = hp, port = "";
  if (hp.charAt(0) === "[") { const e = hp.indexOf("]"); host = hp.slice(1, e); const c = hp.indexOf(":", e); if (c >= 0) port = hp.slice(c + 1); }
  else { const c = hp.lastIndexOf(":"); if (c >= 0) { host = hp.slice(0, c); port = hp.slice(c + 1); } }
  return { userinfo: userinfo, host: host, port: port, path: path };
}
function wsOpts(q) { return { path: q.path || "/", headers: q.host ? { Host: q.host } : {} }; }
function grpcOpts(q) { return { "grpc-service-name": q.serviceName || q.path || "" }; }
function insec(q) { return q.insecure === "1" || q.allowInsecure === "1" || q.allow_insecure === "1"; }

function pVmess(s) {
  const j = JSON.parse(b64str(s.rest)); const net = j.net || "tcp";
  const p = { name: j.ps || "", type: "vmess", server: j.add, port: +j.port, uuid: j.id, alterId: +(j.aid || 0), cipher: j.scy || j.security || "auto", udp: true, network: net === "h2" ? "h2" : net };
  if (j.tls === "tls" || j.tls === true) { p.tls = true; if (j.sni || j.host) p.servername = j.sni || j.host; }
  if (j.fp) p["client-fingerprint"] = j.fp;
  if (j.alpn) p.alpn = String(j.alpn).split(",");
  if (net === "ws") p["ws-opts"] = { path: j.path || "/", headers: j.host ? { Host: j.host } : {} };
  else if (net === "grpc") p["grpc-opts"] = { "grpc-service-name": j.path || "" };
  else if (net === "h2") p["h2-opts"] = { host: j.host ? [j.host] : [], path: j.path || "/" };
  return p;
}
function pVless(s) {
  const a = splitAuthority(s.rest), q = qparse(s.query), net = q.type || "tcp", sec = q.security || "none";
  const p = { name: s.frag || "", type: "vless", server: a.host, port: +a.port, uuid: dec(a.userinfo), udp: true, network: net };
  if (q.flow) p.flow = q.flow;
  if (sec === "tls" || sec === "reality") { p.tls = true; if (q.sni) p.servername = q.sni; if (q.alpn) p.alpn = q.alpn.split(","); if (q.fp) p["client-fingerprint"] = q.fp; }
  if (sec === "reality") p["reality-opts"] = { "public-key": q.pbk || "", "short-id": q.sid || "" };
  if (insec(q)) p["skip-cert-verify"] = true;
  if (net === "ws") p["ws-opts"] = wsOpts(q);
  else if (net === "grpc") p["grpc-opts"] = grpcOpts(q);
  return p;
}
function pTrojan(s) {
  const a = splitAuthority(s.rest), q = qparse(s.query), net = q.type || "tcp";
  const p = { name: s.frag || "", type: "trojan", server: a.host, port: +a.port, password: dec(a.userinfo), udp: true };
  if (q.sni) p.sni = q.sni;
  if (q.alpn) p.alpn = q.alpn.split(",");
  if (q.fp) p["client-fingerprint"] = q.fp;
  if (insec(q)) p["skip-cert-verify"] = true;
  if (net === "ws") { p.network = "ws"; p["ws-opts"] = wsOpts(q); }
  else if (net === "grpc") { p.network = "grpc"; p["grpc-opts"] = grpcOpts(q); }
  return p;
}
function ssObj(name, host, port, cipher, password, q) {
  const p = { name: name, type: "ss", server: host, port: +port, cipher: cipher, password: password, udp: true };
  if (q && q.plugin) {
    const parts = q.plugin.split(";"), pl = parts[0], opts = {};
    for (let i = 1; i < parts.length; i++) { const kv = parts[i].split("="); opts[kv[0]] = kv[1] === undefined ? true : kv[1]; }
    if (pl === "obfs-local" || pl === "simple-obfs") { p.plugin = "obfs"; p["plugin-opts"] = { mode: opts.obfs || "http", host: opts["obfs-host"] }; }
    else if (pl.indexOf("v2ray") >= 0) { p.plugin = "v2ray-plugin"; p["plugin-opts"] = { mode: "websocket", host: opts.host, path: opts.path, tls: !!opts.tls }; }
  }
  return p;
}
function pSS(s) {
  if (s.rest.indexOf("@") >= 0) {
    const a = splitAuthority(s.rest); let mp = a.userinfo;
    if (mp.indexOf(":") < 0) mp = b64str(mp);          // base64(method:pass)
    const ci = mp.indexOf(":");
    return ssObj(s.frag || "", a.host, a.port, mp.slice(0, ci), mp.slice(ci + 1), qparse(s.query));
  }
  const d = b64str(s.rest), at = d.lastIndexOf("@"), mp = d.slice(0, at), hp = d.slice(at + 1);
  const ci = mp.indexOf(":"), cp = hp.lastIndexOf(":");
  return ssObj(s.frag || "", hp.slice(0, cp), hp.slice(cp + 1), mp.slice(0, ci), mp.slice(ci + 1), {});
}
function pHy2(s) {
  const a = splitAuthority(s.rest), q = qparse(s.query);
  const p = { name: s.frag || "", type: "hysteria2", server: a.host, port: +a.port, password: dec(a.userinfo) };
  if (q.sni) p.sni = q.sni;
  if (insec(q)) p["skip-cert-verify"] = true;
  if (q.obfs && q.obfs !== "none") { p.obfs = q.obfs; if (q["obfs-password"]) p["obfs-password"] = q["obfs-password"]; }
  if (q.alpn) p.alpn = q.alpn.split(",");
  if (q.mport) p.ports = q.mport;                       // 端口跳跃
  return p;
}
function pTuic(s) {
  const a = splitAuthority(s.rest), q = qparse(s.query);
  let uuid = dec(a.userinfo), password = ""; const ci = a.userinfo.indexOf(":");
  if (ci >= 0) { uuid = dec(a.userinfo.slice(0, ci)); password = dec(a.userinfo.slice(ci + 1)); }
  const p = { name: s.frag || "", type: "tuic", server: a.host, port: +a.port, uuid: uuid, password: password };
  if (q.sni) p.sni = q.sni;
  if (q.alpn) p.alpn = q.alpn.split(",");
  if (q.congestion_control) p["congestion-controller"] = q.congestion_control;
  if (q.udp_relay_mode) p["udp-relay-mode"] = q.udp_relay_mode;
  if (insec(q)) p["skip-cert-verify"] = true;
  return p;
}
function pAnytls(s) {
  const a = splitAuthority(s.rest), q = qparse(s.query);
  const p = { name: s.frag || "", type: "anytls", server: a.host, port: +a.port, password: dec(a.userinfo), udp: true };
  if (q.sni) p.sni = q.sni;
  if (insec(q)) p["skip-cert-verify"] = true;
  if (q.fp) p["client-fingerprint"] = q.fp;
  if (q.alpn) p.alpn = q.alpn.split(",");
  return p;
}
// userinfo → 用户名 / 密码 (base64 或明文)
function authCreds(userinfo, p) {
  if (!userinfo) return;
  let ui = userinfo;
  if (ui.indexOf(":") < 0) { try { ui = b64str(ui); } catch (e) {} }  // base64
  const ci = ui.indexOf(":");
  if (ci < 0) { p.username = dec(ui); return; }                       // 仅用户名
  p.username = dec(ui.slice(0, ci));
  p.password = dec(ui.slice(ci + 1));
}
// socks://(socks5://) [base64(user:pass)|user:pass@]host:port[?tls=1&...]#name
function pSocks(s) {
  const a = splitAuthority(s.rest), q = qparse(s.query);
  const p = { name: s.frag || "", type: "socks5", server: a.host, port: +a.port, udp: true };
  authCreds(a.userinfo, p);
  if (q.tls === "1" || q.tls === "true") p.tls = true;
  if (insec(q)) p["skip-cert-verify"] = true;
  return p;
}
// http(s)://[user:pass@]host:port[?sni=]#name
function pHttp(s) {
  const a = splitAuthority(s.rest), q = qparse(s.query);
  const p = { name: s.frag || "", type: "http", server: a.host, port: +a.port };
  authCreds(a.userinfo, p);
  if (s.scheme === "https" || q.tls === "1" || q.tls === "true") { p.tls = true; if (q.sni) p.sni = q.sni; }
  if (insec(q)) p["skip-cert-verify"] = true;
  return p;
}
function parseOne(u) {
  const s = splitURI(u); if (!s) return null;
  switch (s.scheme) {
    case "vmess": return pVmess(s);
    case "vless": return pVless(s);
    case "trojan": return pTrojan(s);
    case "ss": return pSS(s);
    case "hysteria2": case "hy2": return pHy2(s);
    case "tuic": return pTuic(s);
    case "anytls": return pAnytls(s);
    case "socks": case "socks5": return pSocks(s);
    case "http": case "https": return pHttp(s);
    default: return null;
  }
}
// 链接列表 → 节点; 写法: "链接" 或 ["名称", "链接"]; 坏链接跳过不占序号
function parseLinks(list) {
  const out = [];
  let n = 0;
  for (let item of (list || [])) {
    let nm = "", link = "";
    if (Array.isArray(item)) {                                   // [名称, 链接]
      nm = String(item[0] == null ? "" : item[0]).trim();
      link = String(item[1] == null ? "" : item[1]).trim();
    } else {                                                     // 链接
      link = String(item == null ? "" : item).trim();
    }
    if (!link || link.charAt(0) === "#") continue;               // 空或占位
    let p = null;
    try { p = parseOne(link); } catch (e) { p = null; }
    if (!p || !p.server || !p.port) continue;                    // 解析失败
    n++;
    const base = nm || p.name || p.type;                         // 自定义名 > #备注 > 协议名
    p.name = LINK_TAG + sup(n) + base;                           // 如 📌¹洛杉矶
    out.push(p);
  }
  return out;
}

// 解析单行 YAML flow 节点 ({...}, 行首 "- " 可省); 坏行跳过
function parseYamlProxies(text) {
  const out = [];
  if (!text) return out;
  for (let line of String(text).split(/\r?\n/)) {
    line = line.trim();
    if (!line || line.charAt(0) === "#") continue;            // 空行 / 注释
    if (line.charAt(0) === "-") line = line.slice(1).trim();  // 去掉 "- "
    if (line.charAt(0) !== "{") continue;                     // 只收 {...}
    let obj = null;
    try { obj = yflow(line); } catch (e) { obj = null; }
    if (obj && typeof obj === "object" && obj.server) out.push(obj);
  }
  return out;
}
// 极简 YAML flow 解析器 (仅覆盖节点配置所需)
function yflow(s) {
  let i = 0;
  const ws = function () { while (i < s.length && /\s/.test(s[i])) i++; };
  function parseValue() {
    ws();
    const ch = s[i];
    if (ch === "{") return parseMap();
    if (ch === "[") return parseSeq();
    return parseScalar();
  }
  function parseMap() {
    const o = {}; i++; ws();                       // 跳过 {
    if (s[i] === "}") { i++; return o; }
    while (i < s.length) {
      ws();
      let key;
      if (s[i] === '"' || s[i] === "'") key = parseQuoted();
      else { let j = i; while (i < s.length && s[i] !== ":") i++; key = s.slice(j, i).trim(); }
      ws(); if (s[i] === ":") i++;                  // 跳过 :
      o[key] = parseValue(); ws();
      if (s[i] === ",") { i++; continue; }
      if (s[i] === "}") { i++; break; }
      break;
    }
    return o;
  }
  function parseSeq() {
    const a = []; i++; ws();                        // 跳过 [
    if (s[i] === "]") { i++; return a; }
    while (i < s.length) {
      a.push(parseValue()); ws();
      if (s[i] === ",") { i++; continue; }
      if (s[i] === "]") { i++; break; }
      break;
    }
    return a;
  }
  function parseScalar() {
    ws();
    if (s[i] === '"' || s[i] === "'") return parseQuoted();
    let j = i;
    while (i < s.length && ",}]".indexOf(s[i]) === -1) i++;   // 裸标量读到结构符为止
    const raw = s.slice(j, i).trim();
    if (raw === "true") return true;
    if (raw === "false") return false;
    if (raw === "null" || raw === "~" || raw === "") return null;
    if (/^-?\d+$/.test(raw)) return parseInt(raw, 10);        // 整数
    if (/^-?\d+\.\d+$/.test(raw)) return parseFloat(raw);     // 小数
    return raw;                                                // 其余为字符串
  }
  function parseQuoted() {
    const q = s[i]; i++;
    let buf = "";
    while (i < s.length && s[i] !== q) {
      if (s[i] === "\\" && i + 1 < s.length) { buf += s[i + 1]; i += 2; continue; }
      buf += s[i]; i++;
    }
    i++;                                            // 结束引号
    return buf;
  }
  return parseValue();
}

// 整份配置 YAML 安全化 (ClashMi 序列化兼容)
function makeYamlSafe(config) {
  if (config["bind-address"] === "*") delete config["bind-address"];      // 默认即全部

  const cors = config["external-controller-cors"];
  if (cors && Array.isArray(cors["allow-origins"]) && cors["allow-origins"].indexOf("*") !== -1) {
    delete cors["allow-origins"];                                          // 去掉裸 '*'
  }

  if (config.hosts && typeof config.hosts === "object") {                  // '*.x' → '.x'
    const h = {};
    for (const k of Object.keys(config.hosts)) h[k.indexOf("*.") === 0 ? k.slice(1) : k] = config.hosts[k];
    config.hosts = h;
  }
  return config;
}

// CommonJS 导出 (部分客户端需要)
if (typeof module !== "undefined") { module.exports = main; module.exports.main = main; }