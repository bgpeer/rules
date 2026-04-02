# Cloudflare Worker 部署教程（gh-raw）

## 一、注册账号

前往 [Cloudflare](https://dash.cloudflare.com) 注册账号（免费）。

## 二、添加域名

1. 进入 Cloudflare 主页，点击 **添加站点**
2. 输入你的域名，选择 **Free** 计划
3. 按提示去域名注册商修改 NS 记录，指向 Cloudflare 提供的两个 nameserver
4. 等待 DNS 生效（通常几分钟到几小时）

> ⚠️ 必须先添加域名，因为 `workers.dev` 默认域名在国内无法访问。

## 三、创建 Worker

1. 左侧菜单进入 **Workers 和 Pages**
2. 点击 **创建应用程序** → **创建 Worker**
3. 名称填 `gh-raw`，点击 **部署**
4. 部署完成后点击 **编辑代码**
5. 删除全部默认代码，粘贴以下代码：

```javascript
export default {
  async fetch(request) {
    const url = new URL(request.url);
    const path = url.pathname;
    let target = "";

    if (path.startsWith("/rules/")) {
      target = "https://raw.githubusercontent.com/SHICHUNHUI88/rules/main" + path.replace("/rules", "");
    } else {
      return new Response("404", { status: 404 });
    }

    const cacheKey = new Request(url.toString(), request);
    const cache = caches.default;

    let response = await cache.match(cacheKey);
    if (response) {
      return response;
    }

    const resp = await fetch(target, {
      headers: { "User-Agent": "cloudflare-worker" },
    });

    if (!resp.ok) {
      return new Response("not found", { status: resp.status });
    }

    const ttl = getSecondsUntilNextBeijing0230();

    response = new Response(resp.body, resp);
    response.headers.set("Access-Control-Allow-Origin", "*");
    response.headers.set("Cache-Control", `public, max-age=${ttl}`);
    response.headers.set("CDN-Cache-Control", `max-age=${ttl}`);

    await cache.put(cacheKey, response.clone());

    return response;
  },
};

function getSecondsUntilNextBeijing0230() {
  const now = new Date();
  const target = new Date(now);
  target.setUTCHours(18, 30, 0, 0);

  if (now >= target) {
    target.setUTCDate(target.getUTCDate() + 1);
  }

  const diff = Math.floor((target - now) / 1000);
  return Math.max(diff, 60);
}
```

6. 点击 **保存并部署**

## 四、绑定自定义域名

1. 回到 `gh-raw` Worker 概述页
2. 进入 **设置** → **域和路由**
3. 点击 **添加** → **自定义域**
4. 输入你想要的子域名，例如 `gh.你的域名.com`
5. Cloudflare 会自动添加 DNS 记录，等待生效即可

## 五、使用方式

部署完成后，将配置中的地址替换为你的域名：

- 规则文件：`https://gh.你的域名/rules/路径`
- 配置文件：`https://gh.你的域名/vps/路径`

## 举例
GEOSITE
```
https://gh.你的域名/rules/geo/geosite/cn.list
```
GEOIP
```
https://gh.你的域名/rules/geo/geoip/cn.list
```

## 说明

- 免费额度：每天 100,000 次请求，个人使用完全够用
- 缓存策略：文件会自动缓存，每天北京时间 02:30 过期刷新（与规则更新时间对齐）
