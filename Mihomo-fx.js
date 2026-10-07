// ============================================================================
// bgpeer 覆写脚本，版本5.11 (Mihomo 系通用: Mihomo Party / ClashMi / Clash Verge Rev / FlClash / Bettbox)
// 用法: 在客户端"覆写"处粘贴链接导入,或复制导入，或做文件名称__复写.js 导入
//       ClashMi把链接添加到➜核心设置➜复写➜右上➕里面去，类型选js，然后选择这个复写。
// 入口约定: 客户端会调用 main(config), config 为订阅解析后的对象, 返回修改后的 config。

// 适配 Bettbox 可视化开关 (v1.18.8+): 有了这行声明, 下面 ruleOptionsEnable 里的开关会直接出现在
// 软件界面上, 点一下即改, 不用再进来改脚本。其它客户端(ClashMi/Verge/Party/FlClash)忽略此行, 不受影响。
const Compatible_With_Bettbox = { ruleOptionsEnable: true };

// 开关总表。内容在下面 SVC 之后统一填充, 界面顺序 = 分流策略组在前、功能开关在后。
// 已实测: Bettbox 读的是这个对象运行时的键, 不是源码文本, 所以键可以由代码生成。
const ruleOptionsEnable = {};

// 想让某个分流组默认关闭: 把组名填进来, 例如 ["🎬TikTok", "📽️Netflix"]。留空 = 全部默认开启。
const GROUP_OFF = [];

/**
 * 功能开关   true = 启用 | false = 禁用
 * 分流策略组的开关不在这里, 由下面 SVC 表自动生成(见「自动生成」段), 增删组只改 SVC 一处。
 * 端口/正则/链接/各种表这类非布尔参数做不成开关, 都在下面「其余可调参数」里, 仍需手动改。
 */
const FN_SWITCHES = {
  链式代理: true,
  严格链式: false,         // 落地节点名字要带"落地"或🏠, 否则自动跳过
  广告拦截: true,          // 关掉可少加载 18 万行广告规则(iOS 内存吃紧时)
  DNS配置: true,
  域名嗅探: true,
  TUN网卡: true,
  Geo数据库: true,
  客户端参数: true,        // 入站端口/局域网/认证; 与客户端自身设置冲突(GUI连不上内核)时关掉
  浏览器面板: true,
  面板局域网访问: false,   // 需先开「浏览器面板」; 开=0.0.0.0局域网可连(需口令), 关=仅本机
  机场订阅: true,
  单节点链接: true,
  自建节点: true,
  动态国家组: true,
  其他随机组: true,
  美国旗规范: true,
  量子加密: true,
  多路复用: false,         // 服务端没开 mux 会连不上 -> 保持关闭
};

// 注意: 开关的值一律在 main() 里现读(见下方「读开关」段), 不在这里存成顶层常量。
// 原因: Bettbox 是在脚本求值完、调用 main() 之前才把界面上的选择注入 ruleOptionsEnable 对象,
// 顶层常量拿到的是注入前的旧值 -> 界面上关了开关却不生效, 甚至组删了规则还在导致内核报错。

// 策略组开关查表: 键就是完整组名("🎷抖音"), 直接查, 不用做任何名字加工。
// 表里没有的键一律视为开启 —— 核心组(🌍全球加速/🎯直连/🤡漏网之鱼)、国家组照常生成, 不会被误删。
function groupOn(n) { return ruleOptionsEnable[n] !== false; }

// ------------------- 其余可调参数 (非布尔, 做不成开关, 需要时进来改) -------------------
const ICON = "https://cdn.jsdelivr.net/gh/bgpeer/icons@main/color/";
const RULES = "https://cdn.jsdelivr.net/gh/bgpeer/rules@main/";
const GEO_MMDB = "https://cdn.jsdelivr.net/gh/Loyalsoldier/geoip@release/GeoLite2-Country.mmdb";
const GEO_ASN  = "https://cdn.jsdelivr.net/gh/Loyalsoldier/geoip@release/GeoLite2-ASN.mmdb";
const threshold = 2;             // 某国节点数 < 该值则不生成该组 (1=有就生成, 2=至少2个才显示)
const PANEL_SECRET = "88888888"; // 面板密码: 可自行修改 | "random"=随机密码 | 端口：9092，一般会被软件覆盖端口=9090
const FETCH_VIA = "fallback";    // 规则集下载通道: ""=DIRECT直连; "fallback"=DIRECT优先,连不上自动切代理; "🌍全球加速"=强制走代理。path 缓存始终保留
const TUN_STACK = "mixed";       // TUN栈: mixed=均衡(默认,手机推荐) | system=最快但挑环境 | gvisor=最稳最兼容(UDP不通时用) | mips=mihomo自研新栈(内核需≥1.19.31,旧内核填了直接报错起不来)
const TUN_CC = "";               // 仅 mips 栈生效的 TCP 拥塞控制: ""=内核默认(cubic) | cubic | reno | bbr | bbr3
const CHAIN_EXIT = "落地|🏠";     // 哪些算"落地节点"：名字含"落地"或🏠的就是(「严格链式」开关用它认人)
// 协议白名单(将来有新协议要纳入, 只需在这里加协议名; 不在名单的一律不碰, 保持订阅原样)
const FP_OK   = ["vless", "vmess", "trojan"];        // 吃 uTLS 指纹(client-fingerprint)的协议
const SMUX_OK = ["ss", "vmess", "vless", "trojan"];  // 支持 smux 多路复用的协议

// 机场订阅 (proxy-providers)。节点由订阅或机场提供, 经各组 include-all 自动并入, 无需改组。
// 两种写法可混用: "机场1": "链接", 只有上标(¹东京); "机场1": ["链接", "⚡"], 会自定义前缀+上标(⚡¹东京)。前缀随意换 🅰️/超/★ 等
// 注意: 别拿国家旗帜当前缀(如 🇺🇸), 否则该机场全部节点会被吸进对应国家组
// 开关「机场订阅」在顶部 ruleOptionsEnable 里。常开稳定: 没填/占位的槽位自动跳过, 且与软件已有 provider 合并
const PROVIDER_URLS = {              // 机场名: 链接。上标 ¹²³… 按顺序自动加且不可去除, 加多少个都行; 保留两边引号
  "机场1": "#填自己机场订阅",   // 添加更多机场链接，此处链接节点不会被收集到动态国家随机分组，原因：有软件壁垒
  "机场2": "#填自己机场订阅",
  "机场3": "#填自己机场订阅",
};
const PROVIDER_PROXY = "📥订阅下载"; // 拉机场订阅的通道: 默认 DIRECT优先, 直连不通自动切🌍全球加速。也可直接填 "DIRECT" 或 "🌍全球加速"

// 单节点分享链接添加(非机场订阅链接)，支持: vless:// vmess:// ss:// trojan:// hysteria2://(hy2://) tuic:// anytls:// socks://(socks5://) http://(https://)
// 想进某国家组, 名称里要带旗子/关键词(自定义名写 🇺🇸 或保留链接原本的 #🇺🇸xxx); 不带的进 🎲其他随机。
// 开关「单节点链接」在顶部 FN_SWITCHES 里。关掉就完全不解析; LINKS 为空时本就是空操作
const LINK_TAG = "📌";     // 单链接节点名前缀, 用来和机场订阅的 ¹²³ 区分。效果: 📌¹洛杉矶。想换成 🏷️/📎/⚡ 等随意; 留空 "" 则只剩序号
const LINKS = [
  // 用法: 去掉行首 // 换成你的真链接即可。三种写法(可混用):括号引号和后面的逗号不可删除
  // ["🇺🇸洛杉矶家宽", "vless://....."],   // 自定义名 + 链接
  // "http://user:pass@5.6.7.8:8080#🇯🇵东京HTTP家宽",         // 只填链接(用链接自带 #备注)
  // "hysteria2://....",               // 只填链接(无备注 → 用协议名)
];

// 自建节点 YAML写法(proxies 口子): 直接粘订阅/客户端里 proxies: 下那种 YAML 节点(单行 flow 写法, 行首 "- " 可有可无)。
// 同样加 PROXY_TAG 前缀; 留空就是空操作。注: 仅支持单行 {k: v,...} flow 式, 不支持缩进多行块式。
// 下面带#号是单行yaml写法样本可供参考，自己写的时候要把前面的#和例子都删掉，只支持用压缩yaml写法
// 开关「自建节点」在顶部 ruleOptionsEnable 里。关掉就完全不并入; PROXIES_YAML 为空时本就是空操作
const PROXY_TAG = "🏠";    // 自建节点名前缀, 区分自建与机场(¹²³)/链接(📌)。效果: 🏠洛杉矶自建。可改 🛠️/⭐/🏡 等; 留空 "" 则用原名。不带上标序号
const PROXIES_YAML = `
# - {name: "🇺🇸 VLESS_TCP/TLS_Vision", type: vless, server: a.com, port: 443, uuid: your-uuid, udp: true, tls: true, network: tcp, client-fingerprint: chrome, flow: xtls-rprx-vision, servername: a.com, skip-cert-verify: false}
# - {name: "🇺🇸美国SOCKS5", type: socks5, server: 1.2.3.4, port: 1080, username: user, password: pass, udp: true}
# - {name: "🇯🇵日本HTTP", type: http, server: 5.6.7.8, port: 8080, username: user, password: pass, tls: false}
`;

// 国家组: [组名, 匹配正则]。顺序即面板展示顺序; 只输出命中的。美国旗一律 🇺🇸。
// ["🏠自建美国随机", /^🏠.*(🇺🇸|美国|洛杉矶|自建)/],也可以像这样锚定前缀写法来识别自建
// 英文短代码一律带 \b 词边界: 防 US 误吸 RUSSIA、TH 误吸 SOUTH、AR 误吸 WARP/STAR、CA 误吸 AFRICA 之类
// 开关「动态国家组」在顶部 ruleOptionsEnable 里: 开=扫描节点自动创建(受 threshold 约束) | 关=整段不扫不建(下面 CUSTOM_RANDOM 自定义组不受影响, 恒生成)
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

// 中国节点(回国/国内BGP/自建国内机): 直接扫进 🎯直连(单节点可手选) + 隐藏的 🇨🇳中国随机(自动测速), 只挂在 🎯直连 下;
// 不进 🌍全球加速/♻️全部随机/🎲其他随机/服务组。不受「动态国家组」开关和 threshold 约束: 有 1 个就生效。
const CN_GROUP = "🇨🇳中国随机";
const CN_PAT = /🇨🇳|\bCN\b|\bcn\b|中国大陆/;
const CN_TEST_URL = "http://connect.rom.miui.com/generate_204";   // 国内测速地址: 国内机连不上 gstatic, 不能用它测

// 自定义显式国家随机分组 (脚本里的机场订阅可在这里国家随机分组扫到)，自己写的时候删掉前面两个斜杠和样品
const CUSTOM_RANDOM = [
  // ["🇺🇸美国随机", /\bUS\b|\bUSA\b|🇺🇸|美国|洛杉矶/],   // 占名示例: 上面动态的 🇺🇸美国随机 让位不再生成
  // ["🇰🇷韩国随机", /\bKR\b|🇰🇷|韩国|首尔/],
  // ["🏠家宽随机",   /家宽|住宅|ISP/],                    // 不占名示例: 纯新增组, 与动态组并存
];

// 规则集锚点。FETCH_VIA 决定下载通道(见上); path: 下成功后本地缓存, 之后冷启动直接读缓存
const FETCH_GROUP = "📥规则下载";   // FETCH_VIA="fallback" 时, 规则集走这个"DIRECT优先回落"组下载
const P = (u) => {
  const o = {};
  if (FETCH_VIA === "fallback") o.proxy = FETCH_GROUP;
  else if (FETCH_VIA) o.proxy = FETCH_VIA;
  o.path = "./bgpeer/" + u.replace(/[\/!]/g, "_");
  return o;
};
const CN_DNS = ["https://223.5.5.5/dns-query#🎯直连", "https://doh.pub/dns-query#🎯直连"];  // 阿里用 IP 形式免一次解析; DNSPod 2024-09 起不再公开 IP 接入, 保留域名
const SYS_DNS = ["system"];   // 私有/内网域名交给系统(路由器/运营商)DNS 解析
// 全部 IP 形式: dns.google / cloudflare-dns.com / dns.quad9.net 这些域名在国内被污染,
// 用域名形式会先被 default-nameserver 解析到假 IP, TLS 握手失败 -> 该条目静默失效。
const G_DNS  = ["https://1.1.1.1/dns-query#🌍全球加速", "https://8.8.8.8/dns-query#🌐Google服务", "https://9.9.9.9/dns-query#🌍全球加速", "tls://1.1.1.1:853#🌍全球加速", "tls://8.8.8.8:853#🌐Google服务"];
// 主表: [规则集名, 类型, 文件基名, 目标组, no-resolve?, DNS归属?] —— providers / rules / DNS分流 全从这里生成
//   类型: d=域名mrs/geosite  c=域名yaml/geosite  i=IP mrs/geoip
//   no-resolve: IP规则(i)填1, 其余填0或直接省略;  DNS归属: g=走国外DNS, z=走国内DNS, 不写=默认DNS (位置无关)
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
// 尾部可选项解析(位置无关): 值===1 -> no-resolve; 值==="g"/"z"/"s" -> DNS归属(国外/国内/系统); 其余(0/""/省略)忽略=默认DNS
// T 表从第5位(idx4)起扫, CUSTOM 从第4位(idx3)起扫。故 no-resolve 与 g/z 都可省略, 不报错。
function tailOpts(arr, from) {
  let nr = false, dns = "";
  for (let i = from; i < arr.length; i++) {
    const v = arr[i];
    if (v === "g" || v === "z" || v === "s") dns = v;
    else if (v === 1 || v === true) nr = true;
  }
  return { nr: nr, dns: dns };
}
// 生效规则表 T_ON 与 G_SETS / CN_SETS 都依赖开关, 因此在 main() 里现算(见「读开关」段), 这里不预先算。

// 服务组表: [组名, 图标, 默认直连?]  —— 图标可省略; 默认直连填1(🎯直连开头), 省略=🌍全球加速开头
//   四种写法: ["组名","图标.png"] / ["组名","图标.png",1] / ["组名"](无图标) / ["组名",1](无图标,直连)
//   规则: 第2位是字符串=图标; 是数字=直连标志(此时无图标)。图标想换/想给无图标组配图 -> 用下面 ICONS 口子
const SVC = [
  ["🎷抖音", "douyin_1.png", 1], ["🎬TikTok", "tiktok_1.png"], ["🎮国际游戏", "game_2.png"],
  ["💻Telegram", "telegram.png"], ["🧠OpenAI", "chatgpt.png"], ["🤖Claude", "claude_1.png"],
  ["💳PayPal", "paypal_1.png"], ["🌐Google服务", "google_1.png"], ["📱Meta", "meta.png"],
  ["🐦X", "x.png"], ["📽️Netflix", "netflix.png"], ["😈GitHub", "github.png"],
  ["😊微软服务", "microsoft.png", 1], ["🍎苹果服务", "apple.png", 1], ["💰加密货币", "cryptocurrency.png", 1],
  ["📺哔哩哔哩", "bilibili_2.png", 1], ["📕小红书", "xiaohongshu_1.png", 1],
];


// 可以在上面SVC组创建一个策略组例如["🎬Emby"],然后自定义图标 (优先级高于 SVC 及默认图标; 给任意组换图标) 
// [组名, 图标完整URL]。组名匹配到则覆盖其图标; 这里填的是完整链接(不走 ICON 前缀, 想用啥源都行)。
// 此组只可以自定义图标没有其他功能; 组若本就没图标也不会凭空报错。留空 [] = no-op。
const ICONS = [
  // ["🎬Emby",       "https://gh.669588.xyz/bgpeer/icons/main/color/emby.png"],
  // ["🌐Google服务", "https://example.com/my-google.png"],   // 覆盖 SVC 里给的图标
];

// ── 填充开关总表 ── 插入顺序 = 界面显示顺序: 先分流策略组, 后功能开关。
// 分流组的键 = 完整组名, 默认全开(GROUP_OFF 里列出的除外)。增删策略组只改上面 SVC 一处, 不会漏改。
const SWITCH_META = SVC.map((s) => [s[0], typeof s[1] === "string" ? s[1] : null])
  .concat([["⛩️阿里腾讯", "alibaba_tencent.png"]]);        // 阿里腾讯不在 SVC 里, 单独补上
const SWITCH_GROUPS = SWITCH_META.map((x) => x[0]);
for (const n of SWITCH_GROUPS) ruleOptionsEnable[n] = !GROUP_OFF.includes(n);
Object.assign(ruleOptionsEnable, FN_SWITCHES);

// ── Bettbox 开关图标 ── 据作者说明: 图标要在 serviceConfigs 里显式给出, 按 key 与开关键对应。
// 这里直接从 SVC 生成, 图标沿用该组自己的图标(ICONS 里有覆盖则用覆盖的), 所以不用二次维护。
// 其它客户端不认识这个变量, 只是多一个没人用的常量, 不影响任何功能。
const serviceConfigs = SWITCH_META.map(function (x) {
  const over = (ICONS || []).find((i) => i && i[0] === x[0]);
  return { key: x[0], name: x[0], icon: over ? over[1] : x[1] ? ICON + x[1] : "" };
});

// 自定义添加单条分流规则: [规则类型, 值, 目标组,]  —— 表内顺序=匹配优先级(谁在前谁先命中)，不可SET规则集
const CUSTOM = [
  ["IP-CIDR", "223.5.5.5/32", "🎯直连", 1],
  // ["DOMAIN-SUFFIX",  "emby.某机场域名.com", "🎬Emby", 0, "g"],   // 机场 Emby 域名, 走国外DNS
  // ["DOMAIN-SUFFIX",  "example.com",        "🌍全球加速", "g"],     // 省 no-resolve, 只给 DNS 归属
  // ["DOMAIN-KEYWORD", "emby",               "🎬Emby"],             // 啥都不写=默认DNS(关键词本就不做DNS分流)
  // ["IP-CIDR",        "1.2.3.0/24",         "🎷抖音", 1],        // IP类: 填1=no-resolve, 不写 g/z
];

function main(config) {

  // ── 读开关(必须在 main 里读, 不能提到顶层): Bettbox 在调用 main() 之前才把界面上的选择注入
  //    ruleOptionsEnable, 提到顶层会拿到注入前的旧值。其它客户端没有注入, 读到的就是脚本里写的值。──
  const {
    DNS配置: setDNS, 域名嗅探: setSniffer, TUN网卡: setTun, Geo数据库: setGeo, 客户端参数: setClientOpts,
    机场订阅: useProviders, 单节点链接: useLinks, 自建节点: useProxies,
    动态国家组: autoCountry, 其他随机组: otherGroup, 链式代理: CHAIN, 严格链式: CHAIN_STRICT,
    美国旗规范: fixUSFlag, 量子加密: MLKEM_OK, 多路复用: SMUX_FILL, 广告拦截: ADBLOCK,
  } = ruleOptionsEnable;
  // 面板三档由两个布尔合成: 关=false | 开=仅本机(local) | 开+局域网访问=全开(lan)
  const setPanel = !ruleOptionsEnable.浏览器面板 ? false : (ruleOptionsEnable.面板局域网访问 ? "lan" : "local");
  // 生效规则表: 只保留"目标组确实会被生成"的规则行 —— 规则指向不存在的策略组内核会直接报错
  // ("proxy [xxx] not found")。两种情况都能兜住: ①界面上把某个分流组关了; ②你直接从 SVC 里删了一行
  // (删组不用再回来删规则)。关广告同理: reject 规则集与规则一起跳过。摘掉后流量回落到后面的兜底行。
  const LIVE = new Set(SWITCH_GROUPS.filter(groupOn).concat(["🎯直连", "🌍全球加速", "🤡漏网之鱼", "REJECT", "DIRECT"]));
  const T_ON = T.filter(function (r) { return (ADBLOCK || r[0] !== "reject") && LIVE.has(r[3]); });
  // G_SETS / CN_SETS / SYS_SETS 从 T_ON 的 DNS归属自动分出 (位置无关, 见 tailOpts; 增减只在 T 行尾改 g/z/s)
  // 必须用 T_ON 而不是 T: 否则 nameserver-policy 会引用到已被摘掉的 rule-set, 内核报错
  const G_SETS  = T_ON.filter(r => tailOpts(r, 4).dns === "g").map(r => r[0]);
  const CN_SETS = T_ON.filter(r => tailOpts(r, 4).dns === "z").map(r => r[0]);
  const SYS_SETS = T_ON.filter(r => tailOpts(r, 4).dns === "s").map(r => r[0]);

  // 空 config / 没传 config 兜底: 即使客户端给空壳(proxies: [])甚至什么都不给, 也能输出完整配置。
  // 注: 这只保证 js 自身不崩; 客户端是否允许"无订阅启动"由客户端决定, 多数仍需一个空壳订阅当载体。
  if (!config || typeof config !== "object") config = {};
  if (!Array.isArray(config.proxies)) config.proxies = [];
  const proxies = config.proxies;
  // 合并而非覆盖: 保留软件 yaml 里已有的 proxy-providers; 机场节点经 include-all 自动并入各组
  if (useProviders) config["proxy-providers"] = Object.assign({}, config["proxy-providers"], buildProviders());

  // 单节点分享链接 -> 解析成节点对象并入 proxies (去重: 同名自动加后缀, 不丢节点)。单条解析失败只跳过该条。
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

  // 自建节点 -> 直接并入 proxies (加 PROXY_TAG 前缀, 不加上标; 去重同上)。来源: PROXIES_YAML(YAML文本)。缺 server 跳过。
  if (useProxies) {
    const seen = {};
    for (const p of proxies) if (p && p.name) seen[p.name] = 1;
    const selfNodes = parseYamlProxies(PROXIES_YAML);
    for (const raw of selfNodes) {
      if (!raw || typeof raw !== "object" || !raw.server) continue;   // 没 server 的当占位/写错 -> 跳过, 不丢其他
      const p = Object.assign({}, raw);                               // 拷贝, 不改动源对象
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

  // 1.5) 节点名 YAML 安全化前移(原在 makeYamlSafe 里最后才做): 让国家检测/漏网检测/运行期 filter
  //      全部作用于同一份"最终名字", 消除 ^锚定 等写法的编译期/运行期分裂
  for (const p of proxies) if (p && p.name) p.name = safeName(p.name);

  // 2) 自定义随机分组: 无视 threshold/autoCountry 强制生成(显示卡片)。坏行(缺名/坏正则)跳过, 不影响其他行
  const custom = [];
  for (const c of (CUSTOM_RANDOM || [])) {
    if (!c || !c[0] || !c[1]) continue;
    let re = c[1];
    if (!re.source) { try { re = new RegExp(String(re)); } catch (e) { continue; } }   // 兼容手滑写成字符串
    custom.push([c[0], re]);
  }
  const customNames = custom.map(function (c) { return c[0]; });

  // 2.1) 动态检测国家 (autoCountry=false 时整段不扫不建): 节点数 >= threshold; 已被自定义占名的让位, 不重复建
  const present = !autoCountry ? [] : COUNTRY.filter(function (c) {
    if (customNames.indexOf(c[0]) !== -1) return false;      // 同名压制: 自定义优先
    let n = 0;
    for (const p of proxies) if (p && p.name && c[1].test(p.name)) n++;
    return n >= threshold;
  });
  const countryNames = customNames.concat(present.map(function (c) { return c[0]; }));

  // 2.2) 中国节点检测: 命中 CN_PAT 且不命中任何其它国家正则才算 (🇨🇳台湾/深港中转 不算)。有 1 个就生效; 开了机场订阅也生效。
  const OTHER_CC_PAT = COUNTRY.map(function (c) { return c[1].source; }).join("|");
  const OTHER_CC_RE = new RegExp(OTHER_CC_PAT);
  //      cnSeen = 真的扫到了中国节点 -> 才建 🇨🇳中国随机 (空组=COMPATIBLE 连不上, 绝不能建空的)
  //      hasCN  = 扫到了 或 开了机场订阅(provider 节点脚本看不到) -> 🎯直连 用 include-all 把中国节点扫进来; 没有就什么都不多
  //      CN_EXACT = 看得到的中国节点名拼成的精确正则, 出国组/🎲其他随机 用它排除(见 CN_PAT 处说明)
  const cnNames = proxies.filter(function (p) { return p && p.name && CN_PAT.test(p.name) && !OTHER_CC_RE.test(p.name); })
    .map(function (p) { return p.name; });
  const CN_EXACT = cnNames.length ? "^(?:" + cnNames.map(reEsc).join("|") + ")$" : "";
  const cnSeen = customNames.indexOf(CN_GROUP) === -1 && cnNames.length > 0;
  const hasCN = cnSeen || useProviders;

  // 2.5) 检测是否有"未归入任何组"的漏网节点 (归属判定 = 自定义组 + 启用中的动态表 + 大陆组; autoCountry 关了动态表不算)
  const ALL_PAT = custom.map(function (c) { return c[1].source; })
    .concat(autoCountry ? COUNTRY.map(function (c) { return c[1].source; }) : [])
    .concat(CN_EXACT ? [CN_EXACT] : [])
    .join("|");
  const ALL_RE = ALL_PAT ? new RegExp(ALL_PAT) : null;       // 两表皆空 -> 无归属正则, 所有节点都算漏网
  let hasOther = false;
  for (const p of proxies) { if (p && p.name && (!ALL_RE || !ALL_RE.test(p.name))) { hasOther = true; break; } }
  const useOther = otherGroup && hasOther;
  const OTHER = "🎲其他随机";
  const tail = countryNames.concat(useOther ? [OTHER] : []);  // 国家组 + (可选)其他随机

  // 3) 公共片段
  const URLTEST = {
    type: "url-test", lazy: true, icon: ICON + "bypass.png",
    "include-all": true, "exclude-type": "direct",
    url: "https://www.gstatic.com/generate_204", interval: 300, tolerance: 30, timeout: 5000, hidden: true,
  };
  const AUTO = { "include-all": true, "exclude-type": "direct", filter: ".*" };

  // 4) 三处列表 (随国家动态变化)
  const ACCEL   = ["♻️全部随机", "🔗链式出口"].concat(tail);
  const GLOBAL  = ["🌍全球加速", "🔗链式出口", "♻️全部随机"].concat(tail, ["🎯直连"]);
  const GLOBAL_D = ["🎯直连", "🌍全球加速", "🔗链式出口", "♻️全部随机"].concat(tail);

  // 5) select 服务组辅助
  const sel = function (name, icon, list) {
    if (icon == null) return Object.assign({ name: name, type: "select", proxies: list }, AUTO);
    return Object.assign({ name: name, type: "select", icon: ICON + icon, proxies: list }, AUTO);
  };

  // 6) 自定义随机组(显示卡片)在前 + 动态国家组(只含命中的)在后 + (可选)其他随机 + 全部随机兜底
  const countryGroups = custom.map(function (c) {
    return Object.assign({}, URLTEST, { name: c[0], filter: safeFilter(c[1].source) });
  }).concat(present.map(function (c) {
    return Object.assign({}, URLTEST, { name: c[0], filter: safeFilter(c[1].source) });
  }));
  if (useOther) {
    // include-all 收全部, 再用 exclude-filter 排除所有已归类关键字 = 只剩没归类的; 无任何归类正则时=直接收全部
    const og = Object.assign({}, URLTEST, { name: OTHER });
    if (ALL_PAT) og["exclude-filter"] = safeFilter(ALL_PAT);
    countryGroups.push(og);
  }
  countryGroups.push(Object.assign({}, URLTEST, { name: "♻️全部随机", filter: ".*" }));
  // 🇨🇳中国随机(隐藏): 只收中国节点(exclude-filter 踢掉同时带其它国家标记的), 用国内地址测速
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
      const hasIcon = typeof s[1] === "string";   // 第2位: 字符串=图标; 数字=直连标志(此时无图标)
      return sel(s[0], hasIcon ? s[1] : null, (hasIcon ? s[2] : s[1]) ? GLOBAL_D : GLOBAL);
    }),
    { name: "⛩️阿里腾讯", type: "select", icon: ICON + "alibaba_tencent.png", proxies: ["🎯直连", "🌍全球加速"] },
    // 🎯直连: 有中国节点时 include-all 把中国单节点直接扫进来(排在 DIRECT/🇨🇳中国随机/🌍全球加速 之后), 可手选
    Object.assign({ name: "🎯直连", type: "select", icon: ICON + "china.png", proxies: ["DIRECT"].concat(cnSeen ? [CN_GROUP] : [], ["🌍全球加速"]), url: CN_TEST_URL },
      // 注意: 这里绝不能加 exclude-type: direct —— 它会把 proxies 里的 DIRECT(本地直连)一起踢掉
      hasCN ? { "include-all": true, filter: safeFilter(CN_PAT.source), "exclude-filter": safeFilter(OTHER_CC_PAT) } : {}),
    { name: "🤡漏网之鱼", type: "select", icon: ICON + "match_1.png", proxies: ["🌍全球加速", "🎯直连"] },
    // ── 链式 出口/中转 (可见卡片, 放漏网之鱼后面; 直接点卡片进组选节点) ──
    // 出口(落地): override.dialer-proxy 给 include-all 单节点注入前置=中转; 选"单节点"才成链, 不含🌍全球加速(否则成环)
    Object.assign({ name: "🔗链式出口", type: "select", icon: ICON + "chainexport.png",
      override: { "dialer-proxy": "🔗链式中转" },
      proxies: ["♻️全部随机"].concat(tail) }, AUTO),
    // 中转(前置跳板): 🌍全球加速 + 国家动态组 + ♻️全部随机 + 单节点
    Object.assign({ name: "🔗链式中转", type: "select", icon: ICON + "chaintransfer.png",
      proxies: ["🌍全球加速", "♻️全部随机"].concat(tail) }, AUTO),
  ].concat(
    // FETCH_VIA="fallback": 规则集下载走 DIRECT优先, 健康检查指向真实下载源(jsDelivr),
    // 直连连得上就用直连, 连不上才自动切到 🌍全球加速。冷启动默认用列表第一个(DIRECT)。
    FETCH_VIA === "fallback" ? [{
      name: FETCH_GROUP, type: "fallback", icon: ICON + "bypass.png",
      proxies: ["DIRECT", "🌍全球加速"],
      url: RULES + "geo/geoip/private.mrs",
      interval: 300, lazy: false, hidden: true,
    }] : []
  ).concat(
    // 📥订阅下载: 机场订阅下载通道。DIRECT优先(健康检查直连能过就用直连), 不通自动切🌍全球加速。
    // 也解决纯机场冷启动: 首启组里还没节点时, 先用 DIRECT 拉订阅把节点引导起来。
    (useProviders && PROVIDER_PROXY === "📥订阅下载") ? [{
      name: "📥订阅下载", type: "fallback", icon: ICON + "bypass.png",
      proxies: ["DIRECT", "🌍全球加速"],
      url: "https://www.gstatic.com/generate_204",
      interval: 300, lazy: false, hidden: true,
    }] : []
  ).concat(countryGroups);

  // 8.4) 分流策略组开关: 把被关掉的组直接剔除。核心组(🌍全球加速/🎯直连/🤡漏网之鱼)、国家组、♻️全部随机
  //       在开关表里没有对应键, groupOn 一律返回 true, 不会被误删。放在 GLOBAL 之前, 让 GLOBAL 只收活着的组。
  config["proxy-groups"] = config["proxy-groups"].filter(function (g) { return g && groupOn(g.name); });

  // 8.5) 自定义内置 GLOBAL 组。
  const orderedGroups = config["proxy-groups"].filter(g => !g.hidden && g.name !== "GLOBAL").map(g => g.name);
  config["proxy-groups"].push({
    name: "GLOBAL",
    type: "select",
    icon: ICON + "match.png",
    "include-all": true,                          
    proxies: [...new Set(orderedGroups.concat(ACCEL, ["DIRECT"]))],  // 去重: 🔗链式出口在orderedGroups和ACCEL里各一次
  });

  // 8.55) 链式开关: CHAIN=false 时删除 🔗链式出口/🔗链式中转 两组, 并清掉其它组(含 GLOBAL)对它们的引用
  //       所有组建完后统一处理, 一次搞定; 引用被删后若某组 proxies 空了, 用 DIRECT 兜底防止内核报错。
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

  // 8.555) 大陆节点隔离: 从所有"出国"用途的 include-all 组(🌍全球加速/♻️全部随机/服务组/🔗链式出口…)剔除大陆节点,
  //        防止被手选或 url-test 选中后国外流量走国内机。保留在: 🎯直连、🇨🇳中国随机、国家组(自带精确 filter)、
  //        🔗链式中转(国内BGP机做前置跳板是正经用法)、GLOBAL(全局模式什么都能选)。放在 8.56 前, 让严格链式合并 exclude-filter。
  if (CN_EXACT) {
    const keep = new Set(["🎯直连", CN_GROUP, "GLOBAL", "🔗链式中转", OTHER].concat(countryNames));   // OTHER 已经靠 ALL_PAT 排除过大陆, 不重复加
    const cnf = safeFilter(CN_EXACT);
    for (const g of config["proxy-groups"]) {
      if (!g || !g["include-all"] || keep.has(g.name)) continue;
      g["exclude-filter"] = g["exclude-filter"] ? "(?:" + g["exclude-filter"] + ")|(?:" + CN_EXACT + ")" : cnf;
    }
  }

  // 8.56) 严格链式(CHAIN_STRICT): 把 CHAIN_EXIT 认定的"落地/出口"节点【只】留在🔗链式出口组、
  //        从其它所有 include-all 组剔除(含 url-test 健康检查会直拨的 ♻️全部随机/国家组)。
  //        效果: 家宽永远只经🔗链式中转到达落地, 绝不直连落地(连探测都不会)。
  //        没有节点匹配 CHAIN_EXIT 时跳过——避免把🔗链式出口变成空组导致内核报错。
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
          g.filter = exf;          // 出口组只收落地节点(include-all + filter)
          delete g.proxies;        // 去掉 ♻️全部随机/国家组 等引用, 只留落地节点; 每次拨号都走 override.dialer-proxy=🔗链式中转
        } else {
          // 其它所有 include-all 组(国家组/♻️全部随机/全球加速/GLOBAL/🔗链式中转…)剔除落地节点:
          // 既不会被误选直连, 也不会被 url-test 直接探测(家宽直连落地的根源)
          g["exclude-filter"] = g["exclude-filter"] ? "(?:" + g["exclude-filter"] + ")|(?:" + CHAIN_EXIT + ")" : exf;
        }
      }
    }
  }

  // 8.6) 图标覆盖: 优先级高于 SVC 及默认图标。所有组建好后统一覆盖, ICONS 里有同名组则换图(完整URL)。
  //      没写 URL / 占位(#) / 空表 -> 跳过, 不动任何组(也不报错)。
  const ICON_MAP = {};
  for (const it of (ICONS || [])) {
    if (!it || !it[0] || !it[1] || String(it[1]).charAt(0) === "#") continue;
    ICON_MAP[it[0]] = it[1];
  }
  for (const g of config["proxy-groups"]) {
    if (g && g.name && ICON_MAP[g.name]) g.icon = ICON_MAP[g.name];
  }

  // 8+9) rule-providers 与 rules 由主表 T 一次生成
  //      provider 是 map (顺序无所谓); rules 是数组 (顺序=T 的顺序, 即匹配优先级)
  config["rule-providers"] = {};
  config.rules = [];
  // 自定义内联规则: 按表内顺序, 整批排在所有 RULE-SET 之前 = 最高优先级。no-resolve 由 tailOpts 识别(位置无关)
  for (const c of CUSTOM) {
    if (!LIVE.has(c[2])) continue;                 // 目标组不存在(被关掉或已从 SVC 删除) -> 这条一起跳过
    config.rules.push(c[0] + "," + c[1] + "," + c[2] + (tailOpts(c, 3).nr ? ",no-resolve" : ""));
  }
  for (const r of T_ON) {
    const [name, t, file, group] = r;
    const [dir, behavior, ext] = META[t];          // d/c/i -> [目录, behavior, 扩展名(也是format)]
    const u = "geo/" + dir + "/" + file + "." + ext;
    config["rule-providers"][name] = Object.assign(
      { type: "http", behavior: behavior, format: ext, interval: 86400, url: RULES + u }, P(u)
    );
    config.rules.push("RULE-SET," + name + "," + group + (tailOpts(r, 4).nr ? ",no-resolve" : ""));
  }
  config.rules.push("MATCH,🤡漏网之鱼");

  // 10) DNS (可选)
  if (setDNS) {
    // —— 机场订阅自带的私有 DNS: 先接住, 后面合并回去 (不接的话整段会被下面的赋值抹掉) ——
    // 有些机场把只有自家 DNS 才解析得出的内网域名写在 proxy-server-nameserver / nameserver-policy 里,
    // 抹掉之后他们的节点就连不上了。fake-ip-filter 同理。
    const subDNS    = config.dns || {};
    const subPSN    = [].concat(subDNS["proxy-server-nameserver"] || []);
    const subPolicy = Object.assign({}, subDNS["nameserver-policy"] || {});
    const subFilter = [].concat(subDNS["fake-ip-filter"] || []);
    // 防御1: 机场若写了 '+.' / '*' 这种通吃键, 会把下面所有分流策略架空 -> 丢弃
    // 防御2: rule-providers 已被本脚本清空重建, 订阅里指向旧 provider 的 rule-set: 键会变成悬空引用,
    //        内核直接报 "not found rule-set: xxx" 并拒绝启动(startService failed) -> 一并丢弃。
    //        例: 订阅写 rule-set:cn, 而本脚本生成的是 cn-domain / cn-ip。
    const OWN_SETS = new Set(T_ON.map(r => r[0]));
    for (const k of Object.keys(subPolicy)) {
      if (k === "+." || k === "*" || k === "+") { delete subPolicy[k]; continue; }
      if (k.indexOf("rule-set:") === 0 && !OWN_SETS.has(k.slice(9))) delete subPolicy[k];
    }
    // fake-ip-filter 同理: 订阅里的 rule-set: 项也可能悬空
    const subFilterSafe = subFilter.filter(
      v => typeof v !== "string" || v.indexOf("rule-set:") !== 0 || OWN_SETS.has(v.slice(9))
    );

    // 由 G_SETS/CN_SETS 自动生成 nameserver-policy (增减只改顶部那两个数组)
    const nsPolicy = {};
    for (const s of SYS_SETS) nsPolicy["rule-set:" + s] = SYS_DNS;
    if (ADBLOCK) nsPolicy["rule-set:reject"] = ["https://dns.adguard.com/dns-query"];
    for (const s of G_SETS)  nsPolicy["rule-set:" + s] = G_DNS;
    for (const s of CN_SETS) nsPolicy["rule-set:" + s] = CN_DNS;
    // 追加: CUSTOM 内联域名的 DNS 归属。仅 DOMAIN(精确) / DOMAIN-SUFFIX(+.) 可转 policy key;
    //       关键词/正则/IP 无法按域名做 DNS 分流 -> 跳过(规则本身照常生效, 只是不进 DNS 分流)
    for (const c of CUSTOM) {
      const dns = tailOpts(c, 3).dns;
      if (dns !== "g" && dns !== "z" && dns !== "s") continue;
      if (!LIVE.has(c[2])) continue;               // 规则本身已被跳过, DNS 分流也不必留
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
      // 本脚本的 rule-set: 键优先, 机场独有的域名键(如 +.某机场.com)原样保留
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

  // —— 顶层配置 (与 Clashmi-fx 一致; setClientOpts 见顶部参数区) ——
  Object.assign(config, {
    "mode": "rule",
    "find-process-mode": "strict",   // 内核默认档: always 桌面端每连接查进程有开销, iOS 不支持
    "unified-delay": true,
    "tcp-concurrent": true,
    "ipv6": true,
    ...(setGeo ? {
      // 分流全走 rule-provider(.mrs/.yaml), 无内置 GEOSITE/GEOIP 规则, 故不下 geoip.dat/geosite.dat;
      // 只要 mmdb(连接信息/国旗)+asn(IP-ASN 规则). 走 jsDelivr 拉, 与本脚本其他外部资源一致.
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
      // 入站认证口令按节点确定性派生(复用 resolveSecret): 每人不同, 避免公开脚本全网同一口令被蹭代理
      "authentication": ["meta:" + resolveSecret("random", config.proxies)],
      "skip-auth-prefixes": ["127.0.0.1/8", "::1/128"],
      "lan-allowed-ips": ["0.0.0.0/0", "::/0"],
      "lan-disallowed-ips": [],
      "global-ua": "Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Mobile Safari/537.36",
      "ntp": { "enable": true, "server": "time.apple.com", "port": 123, "interval": 30, "dialer-proxy": "", "write-to-system": false },
      "experimental": { "quic-go-disable-ecn": true },
    } : {}),
  });

  // —— 浏览器面板 (控制器 API) —— 三档: false=关 | "local"=仅本机(默认) | "lan"=局域网。与 setClientOpts 解耦
  // secret 由 PANEL_SECRET 决定; "random" 走 resolveSecret 按节点确定性派生(覆写脚本无持久存储,故同批节点恒定同值)
  let panel = setPanel === true ? "lan" : setPanel;            // 兼容老写法: 旧配置里的 setPanel=true 视作全开
  if (panel === "lan" && PANEL_SECRET === "") panel = "local"; // 全开必须有口令, 留空则自动降回本机, 杜绝无口令裸奔
  if (panel === "local" || panel === "lan") {
    const realSecret = resolveSecret(PANEL_SECRET, config.proxies);
    config["external-controller"] = (panel === "lan" ? "0.0.0.0" : "127.0.0.1") + ":9092";
    config["secret"] = realSecret;
    config["external-controller-cors"] = panel === "lan"
      ? { "allow-origins": ["*"], "allow-private-network": true }  // 全开: 允许站外/跨私网面板访问
      : { "allow-origins": ["*"] };                                // 本机: 无需私网放行
    config["external-ui"] = "./ui";
    // zashboard 面板包: jsDelivr 发不了 zip, 只能写 GitHub 的 codeload 链接(与 Clashmi-fx 一致)。
    // 内核拉面板走的是自己的出站, 会按规则分流, GitHub 域名命中 😈GitHub 组走代理, 大陆也拉得下来。
    config["external-ui-url"] = "https://codeload.github.com/Zephyruso/zashboard/zip/refs/heads/gh-pages";
    // 全开 + random: 把派生口令显示成一个 display-only 假组, 开 App 在组列表一眼可见, 抄进外部浏览器登录即可
    // (自己填了固定串的不显示——你本就知道; local 档不暴露端口, 也无需显示)
    if (panel === "lan" && PANEL_SECRET === "random") {
      config["proxy-groups"].push({ name: "🔑面板口令:" + realSecret, type: "select", proxies: ["DIRECT"] });
    }
  }
  config.profile = Object.assign({ "store-selected": true, "store-fake-ip": true }, config.profile || {});

  // —— TUN (裸订阅必须有, 否则抓不到系统流量; 已补全到与 Clashmi-fx 一致; TUN_STACK 见顶部参数区) ——
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
    // auto-redirect / gso 只在 system/mixed/mips 栈下有意义(mips 自带 Linux GSO 收发), gvisor 下加了可能报错, 故按栈区分
    // auto-redirect/gso 为 Linux 内核专属优化, 其他平台注入会崩(iOS NE 实测)。
    // 仅在 JS 环境能确认 Linux 时(如 Mihomo Party@Linux 有 process.platform)才注入; 检测不到=不加, 安全兜底。
    const isLinux = (function () {
      try { return typeof process !== "undefined" && process.platform === "linux"; } catch (e) { return false; }
    })();
    if (TUN_STACK !== "gvisor" && isLinux) { t["auto-redirect"] = true; t["gso"] = true; t["gso-max-size"] = 65536; }
    // congestion-controller 只对 mips 有效; 内核只认 cubic/reno/bbr/bbr3, 填错整个 TUN 起不来, 所以只放行这四个
    // (≥1.19.31 但还没这个字段的内核会直接忽略, 不报错)
    const cc = String(TUN_CC).toLowerCase();
    if (TUN_STACK === "mips" && ["cubic", "reno", "bbr", "bbr3"].includes(cc)) t["congestion-controller"] = cc;
    config.tun = t;
  }

  // —— hosts (与 Clashmi-fx 一致) —— 值都是 127.0.0.1, 只列域名
  config.hosts = Object.assign(
    ["*.backloop.dev", "*.localtest.me", "*.lvh.me", "*.vcap.me", "*.traefik.me", "*.readymade.dev"]
      .reduce((h, d) => (h[d] = "127.0.0.1", h), {}),
    config.hosts || {}
  );

  // —— tunnels (端口转发, 与 Clashmi-fx 一致) —— [本地端口, 目标, 走哪个组]; network 都是 tcp+udp
  const TUN = [
    [7788, "jp1.wildrift.riotgames.com:443", "🎮国际游戏"],
    [7789, "jp1.pvp.net:443", "🎮国际游戏"],
    [9000, "149.154.167.91:443", "💻Telegram"],
    [9001, "149.154.167.92:443", "💻Telegram"],
    [9002, "149.154.175.100:443", "💻Telegram"],
    [7999, "api.openai.com:443", "🧠OpenAI"],
    [7443, "chat.openai.com:443", "🧠OpenAI"],
    [7700, "www.google.com:443", "🌐Google服务"],
    [7701, "accounts.google.com:443", "🌐Google服务"],
    [7702, "www.googleapis.com:443", "🌐Google服务"],
  ];
  config.tunnels = TUN.filter(([, , proxy]) => LIVE.has(proxy)).map(([port, target, proxy]) => ({
    network: ["tcp", "udp"], address: "127.0.0.1:" + port, target, proxy,
  }));

  // —— 给"吃 uTLS 指纹"的节点补 client-fingerprint=chrome(替代已废弃的 global-client-fingerprint)——
  // 只处理走标准 TLS 的协议(FP_OK 白名单); QUIC系(hysteria/hysteria2/tuic)、wireguard、ssh、
  // 纯 ss/ssr、anytls 等不在名单内一律跳过(它们不吃 uTLS, 强加可能告警/握手失败)。已自带指纹的也不动。
  (config.proxies || []).forEach(function (p) {
    if (!p || FP_OK.indexOf(p.type) === -1) return;   // 协议不在白名单 -> 跳过
    if (p["client-fingerprint"]) return;              // 已自带(含 REALITY 自带) -> 不覆盖
    var usesTLS = p.type === "trojan" || p.tls === true || p["reality-opts"];
    if (usesTLS) p["client-fingerprint"] = "chrome";  // 仅确实走 TLS 时才补
  });
  // 注: 不再给 proxy-providers 统一加 override.client-fingerprint —— 那是"整份订阅强制套用",
  // 会把订阅里的 hy2/tuic 等也一起套, 反而可能出问题。订阅模式请在订阅/机场侧配置指纹。

  // —— 给支持 smux 的节点补 smux h2mux(SMUX_FILL 开关; 服务端没开 mux 会连不上 -> 关掉)——
  // 仅 SMUX_OK 白名单内的协议; 且排除 XTLS Vision(有 flow 字段, 叠 smux 会破坏 XTLS);
  // hy2/tuic/wireguard/ssh/anytls 不在名单 -> 不碰(QUIC/自带mux/不支持)。已自带 smux 的不覆盖。
  if (SMUX_FILL) {
    (config.proxies || []).forEach(function (p) {
      if (!p || SMUX_OK.indexOf(p.type) === -1) return;   // 协议不支持 -> 跳过
      if (p.smux) return;                    // 已自带 -> 不动
      if (p.flow) return;                    // XTLS Vision(flow非空) -> 绝不加
      p.smux = { enable: true, protocol: "h2mux", "max-connections": 4, "min-streams": 4, padding: true };
    });
  }

  // —— 给 Reality 节点补 support-x25519mlkem768(MLKEM_OK 开关; 后量子混合密钥交换)——
  // 只碰带 reality-opts 的节点; 已显式设置过该字段(含 false)的不覆盖。
  // 覆盖范围: 订阅主 proxies + LINKS + PROXIES_YAML; PROVIDER_URLS 机场节点运行时才下载, JS 摸不到。
  if (MLKEM_OK) {
    (config.proxies || []).forEach(function (p) {
      if (!p || !p["reality-opts"]) return;                       // 非 Reality -> 跳过
      if ("support-x25519mlkem768" in p["reality-opts"]) return;  // 已显式设置 -> 不覆盖
      p["reality-opts"]["support-x25519mlkem768"] = true;
    });
  }

  // —— YAML 安全化: 无条件执行(都是功能等价改写) ——
  return makeYamlSafe(config);
}

// 把单个节点名改成 YAML 安全。只动会破坏裸标量的字符; 国家匹配正则不含这些字符, 匹配不受影响。
function safeName(name) {
  let s = String(name)
    .replace(/:/g, "：").replace(/,/g, "，")
    .replace(/\[/g, "【").replace(/\]/g, "】")
    .replace(/\{/g, "｛").replace(/\}/g, "｝");
  // 行首保留字符(* & ! | > @ % # ?)会被当成指示符 -> 替成全角; 行首引号/反引号直接去掉
  s = s.replace(/^\*/, "＊").replace(/^&/, "＆").replace(/^!/, "！")
       .replace(/^\|/, "｜").replace(/^>/, "＞").replace(/^@/, "＠")
       .replace(/^%/, "％").replace(/^#/, "＃").replace(/^\?/, "？")
       .replace(/^["'`]/, "");
  return s;
}

// 组 filter/exclude-filter 的正则源若以 YAML 指示符开头(如 [ { & ! > | * 等, 裸标量序列化后非法),
// 包一层 (?:...) 等价规避——(?: 以 "(" 开头, 天然 YAML 安全, 且不改变正则语义。emoji/普通字母开头原样返回。
// 节点名 -> 正则字面量。只转义正则元字符: Go 正则不认 "\ " 这类对非标点的转义, 不能用通用写法。
function reEsc(s) {
  return String(s).replace(/[\\.+*?()|\[\]{}^$]/g, "\\$&");
}

function safeFilter(src) {
  return /^[\[\]{}>|*&!%@`"',#?:-]/.test(src) ? "(?:" + src + ")" : src;
}

// 数字 -> 上标 (1->¹, 10->¹⁰, 100->¹⁰⁰)。任意位数, 不设上限。
function sup(n) {
  const S = "⁰¹²³⁴⁵⁶⁷⁸⁹";  // ⁰¹²³⁴⁵⁶⁷⁸⁹
  return String(n).replace(/\d/g, function (d) { return S[+d]; });
}
// 解析 PANEL_SECRET: 非 "random" 直接返回原串; "random" 按节点名做 djb2 确定性派生。
// 覆写脚本无持久存储、每次重载重跑 main(), 无法"生成一次永久记住", 故用派生: 同批节点恒定同值, 换节点才变, 且每人不同。
// 注: 纯机场(proxies 为空)时 basis 回落 "bgpeer", 此时各用户派生值相同——介意可在 lan 档手填固定串代替 random。
function resolveSecret(raw, proxies) {
  if (raw !== "random") return raw;
  let h = 5381;
  const basis = (proxies || []).map(function (p) { return p && p.name; }).filter(Boolean).join("|") || "bgpeer";
  for (let i = 0; i < basis.length; i++) h = ((h << 5) + h + basis.charCodeAt(i)) >>> 0;
  return "p" + h.toString(36);
}
// 生成 proxy-providers: 展开原锚点 *p, 按顺序自动加上标前缀。节点靠各组 include-all 自动收入。
function buildProviders() {
  const out = {}, names = Object.keys(PROVIDER_URLS);
  for (let i = 0; i < names.length; i++) {
    const v = PROVIDER_URLS[names[i]];
    const url = Array.isArray(v) ? v[0] : v;                      // 数组写法取第0位=链接
    const tag = (Array.isArray(v) && v[1]) ? String(v[1]) : "";   // 第1位=自定义前缀, 没填=空
    if (!url || url.charAt(0) === "#") continue;   // 空 / 占位符(#机场订阅) -> 跳过, 上标序号不占用
    out[names[i]] = {
      type: "http", interval: 3600, proxy: PROVIDER_PROXY,
      "health-check": { enable: true, url: "https://www.gstatic.com/generate_204", interval: 300 },
      url: url, override: { "additional-prefix": tag + sup(i + 1) },  // 前缀在前, 上标恒定保留不可去除
    };
  }
  return out;
}

// ===================== 分享链接解析器 (自带, 不依赖 atob/URL/Buffer) =====================
// base64 -> 字节数组 (兼容 url-safe 与缺省填充)
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
// 字节数组 -> UTF-8 字符串 (支持中文/emoji 节点名)
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
// userinfo@host:port[/path] -> 各字段 (支持 IPv6 [..])
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
    if (mp.indexOf(":") < 0) mp = b64str(mp);          // userinfo 是 base64(method:pass)
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
  if (q.mport) p.ports = q.mport;                       // 端口跳跃 30000-31000
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
// userinfo 取用户名/密码: 先试 base64(user:pass), 再试明文 user:pass。塞进目标对象。
function authCreds(userinfo, p) {
  if (!userinfo) return;
  let ui = userinfo;
  if (ui.indexOf(":") < 0) { try { ui = b64str(ui); } catch (e) {} }  // 无冒号 -> 当 base64(user:pass)
  const ci = ui.indexOf(":");
  if (ci < 0) { p.username = dec(ui); return; }                       // 只有用户名
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
// http://(https://) [user:pass@]host:port[?sni=...]#name  (https:// 或 ?tls=1 -> 走 TLS)
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
// 遍历链接列表 -> 节点对象数组。
// 元素两种写法: "链接"  或  ["自定义名","链接"]。空行/注释(#开头)/坏链接跳过, 且不占序号。
// 名称优先级: 自定义名 > 链接自带#备注(parseOne 存进 p.name) > 协议名; 最终统一加上标序号前缀 ¹²³…
function parseLinks(list) {
  const out = [];
  let n = 0;
  for (let item of (list || [])) {
    let nm = "", link = "";
    if (Array.isArray(item)) {                                   // ["名称","链接"]
      nm = String(item[0] == null ? "" : item[0]).trim();
      link = String(item[1] == null ? "" : item[1]).trim();
    } else {                                                     // "链接"
      link = String(item == null ? "" : item).trim();
    }
    if (!link || link.charAt(0) === "#") continue;               // 空/占位 -> 跳过, 不占序号
    let p = null;
    try { p = parseOne(link); } catch (e) { p = null; }
    if (!p || !p.server || !p.port) continue;                    // 解析失败 -> 跳过, 不占序号
    n++;
    const base = nm || p.name || p.type;                         // 自定义名 > 链接#备注 > 协议名
    p.name = LINK_TAG + sup(n) + base;                           // 前缀: 区分标记 + 上标序号, 如 📌¹洛杉矶
    out.push(p);
  }
  return out;
}

// 解析"订阅 proxies: 下的 YAML 节点"(flow 写法子集): 每行一个 {k: v, ...} 映射, 行首 "- " 可有可无。
// 支持: 双引号/裸标量, 整数/小数/布尔, 嵌套 {} 与 []; 端口段(30000-31000)、uuid、域名等带"-"或"."的串原样保留为字符串。
// 不支持: 缩进多行块式写法(必须单行 flow)。解析失败的行整条跳过, 不影响其他行。
function parseYamlProxies(text) {
  const out = [];
  if (!text) return out;
  for (let line of String(text).split(/\r?\n/)) {
    line = line.trim();
    if (!line || line.charAt(0) === "#") continue;            // 空行 / 注释
    if (line.charAt(0) === "-") line = line.slice(1).trim();  // 去掉块序列标记 "- "
    if (line.charAt(0) !== "{") continue;                     // 只收 flow 映射
    let obj = null;
    try { obj = yflow(line); } catch (e) { obj = null; }
    if (obj && typeof obj === "object" && obj.server) out.push(obj);
  }
  return out;
}
// 极简 flow 解析器: 解析单个 {map} / [seq] / 标量。仅覆盖节点配置所需子集, 不是完整 YAML。
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
    while (i < s.length && ",}]".indexOf(s[i]) === -1) i++;   // 裸标量到结构符为止(冒号不算, 故 URL 可保留)
    const raw = s.slice(j, i).trim();
    if (raw === "true") return true;
    if (raw === "false") return false;
    if (raw === "null" || raw === "~" || raw === "") return null;
    if (/^-?\d+$/.test(raw)) return parseInt(raw, 10);        // 纯整数 -> 数字 (端口段含"-"不在此列, 保持字符串)
    if (/^-?\d+\.\d+$/.test(raw)) return parseFloat(raw);     // 小数 -> 数字
    return raw;                                                // 其余(uuid/域名/端口段/密钥…) -> 字符串
  }
  function parseQuoted() {
    const q = s[i]; i++;
    let buf = "";
    while (i < s.length && s[i] !== q) {
      if (s[i] === "\\" && i + 1 < s.length) { buf += s[i + 1]; i += 2; continue; }
      buf += s[i]; i++;
    }
    i++;                                            // 跳过结束引号
    return buf;
  }
  return parseValue();
}

// 把整份配置改成 YAML 安全(无条件执行)。逐项功能等价, 不删任何"功能", 只换 ClashMi 内核
// 序列化时不会加引号、会导致启动报错的写法。对 FlClash/Verge/Party 也无副作用。
// 注: 节点名 safeName 已前移到 main() 第 1.5 步(国家检测之前), 此处不再重复处理。
function makeYamlSafe(config) {
  if (config["bind-address"] === "*") delete config["bind-address"];      // = 默认监听全部

  const cors = config["external-controller-cors"];
  if (cors && Array.isArray(cors["allow-origins"]) && cors["allow-origins"].indexOf("*") !== -1) {
    delete cors["allow-origins"];                                          // 裸 '*' 无安全等价, 仅去此项
  }

  if (config.hosts && typeof config.hosts === "object") {                  // '*.x' -> '.x'
    const h = {};
    for (const k of Object.keys(config.hosts)) h[k.indexOf("*.") === 0 ? k.slice(1) : k] = config.hosts[k];
    config.hosts = h;
  }
  return config;
}

// 兼容部分客户端的导出习惯; 浏览器/纯脚本环境忽略即可
if (typeof module !== "undefined") { module.exports = main; module.exports.main = main; }