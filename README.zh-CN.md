# playwright-cdp-selkies

**单个 Docker 容器,同时提供 Playwright 管理的 Chromium、可实时观看的远程桌面、以及对外暴露的 CDP 端点。**

[![ci](https://github.com/chendefine/playwright-cdp-selkies/actions/workflows/ci.yaml/badge.svg)](https://github.com/chendefine/playwright-cdp-selkies/actions/workflows/ci.yaml)
[![license: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![docker image size](https://img.shields.io/docker/image-size/chendefine/playwright-cdp-selkies)](https://hub.docker.com/r/chendefine/playwright-cdp-selkies)
[![docker pulls](https://img.shields.io/docker/pulls/chendefine/playwright-cdp-selkies)](https://hub.docker.com/r/chendefine/playwright-cdp-selkies)

[English](README.md) | [简体中文](README.zh-CN.md)

容器在一个入口脚本里拉起全部服务,并作为 PID 1 监管它们:

```
docker run ─┬─ Xvfb        虚拟显示(Selkies 采集的画面)
            ├─ PulseAudio  虚拟音频
            ├─ Selkies     HTML5 远程桌面        ─┐
            ├─ Chromium   Playwright 构建,CDP ──┼─ nginx 统一门面
            └─ nginx      一个进程,3 个端口     ─┘
```

* **带公开 CDP 端点的 Chromium** — 在容器*外部*用 `connectOverCDP("http://localhost:9222")` 接入 [Playwright](https://playwright.dev) / Puppeteer / Selenium。
* **可实时观看的桌面** — 浏览器默认以**有头模式**运行在虚拟 X11 显示器上,[Selkies](https://github.com/selkies-project/selkies) 把画面(含音频)串流到任意浏览器(WebRTC/WebCodecs)。自动化过程实时可见、可交互。
* **持久化配置目录** — 通过 bind mount,cookies、登录态、扩展在容器重建后依然保留。
* **支持 HTTPS** — 默认自动生成自签证书,也可挂载自己的证书;已存在的有效证书永远优先复用。
* **合理的默认值** — UTC 时区、`en-US` 浏览器语言;两者都是一行环境变量即可覆盖。

## 目录

- [镜像里有什么](#镜像里有什么)
- [快速开始](#快速开始)
  - [Docker Compose](#docker-compose-1)
  - [纯 docker run](#纯-docker-run)
- [端口](#端口)
- [通过 CDP 接入 Playwright](#通过-cdp-接入-playwright)
- [观看桌面](#观看桌面)
- [配置](#配置)
  - [构建参数](#构建参数)
  - [环境变量](#环境变量)
  - [时区与语言](#时区与语言)
- [HTTPS](#https-1)
- [持久化](#持久化)
- [服务开关、健康检查与重启](#服务开关健康检查与重启)
- [从源码构建](#从源码构建)
- [版本联动脚本](#版本联动脚本)
- [CI/CD 与发布的镜像](#cicd-与发布的镜像)
- [安全注意事项](#安全注意事项)
- [故障排查](#故障排查)
- [参与贡献](#参与贡献)
- [许可证](#许可证)

## 镜像里有什么

| 组件 | 版本 | 作用 |
| --- | --- | --- |
| Ubuntu | 24.04 | 基础镜像 |
| Node.js | 24(当前 LTS) | 与 Playwright 支持范围一致 |
| Playwright Chromium | 1.62.1 | 被自动化的浏览器(`chromium`、`chromium-headless-shell`、`ffmpeg`) |
| Selkies | [钉住的 commit](Dockerfile) | HTML5 远程桌面(Web 客户端、信令、串流) |
| nginx | Ubuntu 软件包 | 统一门面:Web UI(HTTP/HTTPS)+ CDP 网关,支持 WebSocket |
| Xvfb / PulseAudio | Ubuntu 软件包 | 虚拟显示器 + 音频,供串流 |

容器内部所有服务只监听回环地址;nginx 是唯一的对外门面,且每个代理都支持 WebSocket(CDP 和 Selkies 信令都需要)。

## 快速开始

### Docker Compose

```bash
git clone https://github.com/chendefine/playwright-cdp-selkies.git
cd playwright-cdp-selkies

cp .env.example .env        # 可选 —— 默认值即可直接跑
docker compose up -d --build
```

然后:

* **桌面串流**:<http://localhost:8080> —— Chromium 窗口实时画面。
* **CDP 端点**:<http://localhost:9222/json/version> —— 供 Playwright 等客户端连接。

常用命令:

```bash
docker compose logs -f      # 跟随日志
docker compose exec playwright-cdp-selkies bash   # 进入容器 shell
docker compose down         # 停止(加 -v 同时删除网络)
```

### 纯 docker run

```bash
docker build -t chendefine/playwright-cdp-selkies .

docker run -d --name playwright-cdp-selkies \
  --restart always \
  --shm-size 1g \
  -p 8080:80 \
  -p 9222:9222 \
  -v "$PWD/chrome-user-data:/chrome-user-data" \
  chendefine/playwright-cdp-selkies
```

传给容器的首参数若不是隐式的 `start`,会被直接 exec,例如 `docker run -it chendefine/playwright-cdp-selkies bash` 进入 shell。

## 端口

容器端口**固定,设计如此**;各变量只决定 docker 发布到的**宿主机侧**端口。

| 容器端口 | 服务 | 宿主端口(默认) | 修改方式 |
| --- | --- | --- | --- |
| 80 | Web UI(HTTP) | 8080 | `.env` 里的 `NGINX_HTTP_PORT` |
| 443 | Web UI(HTTPS,可选) | 8443 | `NGINX_HTTPS_PORT` + [HTTPS](#https-1) |
| 9222 | Chromium CDP | 9222 | `.env` 里的 `CDP_PORT` |

## 通过 CDP 接入 Playwright

镜像把 Chromium 的 DevTools 协议经 nginx 对外暴露,宿主机(或任何可达网络)上的 CDP 客户端都能驱动这个浏览器,本地**无需**安装 Playwright 浏览器。

```bash
npm init -y && npm i playwright
node examples/connect-playwright.mjs https://example.com
```

<details>
<summary>examples/connect-playwright.mjs(核心逻辑)</summary>

```js
import { chromium } from "playwright";

const browser = await chromium.connectOverCDP("http://localhost:9222");
const context = browser.contexts()[0];            // 复用默认 context
const page = context.pages()[0] ?? await context.newPage();

await page.goto("https://example.com");
console.log(await page.title());
await browser.close();  // 只关闭 CDP 会话,不关浏览器
```

</details>

说明:

* 默认 context 使用**持久化配置目录**,登录态和 cookies 在多次运行间保留。
* `curl http://localhost:9222/json/version` 是最快速的健康检查。
* Puppeteer 同样适用:`puppeteer.connect({ browserURL: "http://localhost:9222" })`。

## 观看桌面

打开 <http://localhost:8080>。Selkies 把 Xvfb 画面(含音频)直接串流到浏览器标签页 —— 键盘鼠标输入会送进容器。Chromium 默认有头运行(`CHROMIUM_HEADLESS=0`),每一步自动化都能在串流里看到。可用 `CHROMIUM_LANG` / `CHROMIUM_START_URL` 控制浏览器初始状态。

设置密码(`SELKIES_BASIC_AUTH_PASSWORD`,用户名默认 `ubuntu`,见[环境变量](#环境变量))即可为串流启用登录页。

## 配置

全部通过环境变量配置;使用 Compose 时写入 `.env`(模板见 [.env.example](.env.example))。未在 `compose.yaml` 里显式列出的变量也会经 `env_file` 直通进容器 —— 包括 Selkies 原生设置,如 `SELKIES_FRAMERATE=30`、`SELKIES_TURN_URL=...`。

### 构建参数

| 参数 | 默认值 | 说明 |
| --- | --- | --- |
| `PLAYWRIGHT_VERSION` | `1.62.1` | npm 上的 playwright-core 版本(必须存在于 registry.npmjs.org) |
| `NODE_VERSION` | `24` | Node.js 主版本(由 [`update-playwright-node.mjs`](#版本联动脚本) 保持同步) |
| `SELKIES_REF` | 钉住的 SHA | 构建 Selkies wheel 所用的 git ref(sha/分支/标签) |
| `TZ` | `UTC` | 容器时区,以 `ENV TZ` 暴露(运行时可覆盖) |
| `DOCKER_IMAGE_NAME_TEMPLATE` | `chendefine/playwright-cdp-selkies` | 传给 `playwright-core mark-docker-image` 的值 |

```bash
docker compose build --build-arg PLAYWRIGHT_VERSION=1.62.1
```

### 环境变量

**服务开关**

| 变量 | 默认值 | 说明 |
| --- | --- | --- |
| `ENABLE_SELKIES` | `true` | `false` = 跳过 Web UI + 显示器 + 音频(纯 CDP 容器) |
| `ENABLE_CDP` | `true` | `false` = 跳过 Chromium + CDP 网关(纯远程桌面容器) |

**Web UI / TLS**

| 变量 | 默认值 | 说明 |
| --- | --- | --- |
| `ENABLE_HTTPS` | `false` | `true` = nginx 在容器 443 端口同时提供 TLS 的 Web UI |
| `TLS_CERT_DIR` | `/etc/nginx/tls` | 证书查找 / 生成目录 |
| `TLS_CERT_FILE` / `TLS_KEY_FILE` | `$TLS_CERT_DIR/fullchain.pem` / `privkey.pem` | 显式证书/私钥路径 |
| `TLS_SELF_SIGNED_CN` | `localhost` | 生成的自签证书 CN |

**Selkies**

| 变量 | 默认值 | 说明 |
| --- | --- | --- |
| `SELKIES_BASIC_AUTH_PASSWORD` | *(空)* | 设置即启用登录页;空 = 无登录 |
| `SELKIES_BASIC_AUTH_USER` | `ubuntu` | 登录用户名 |
| `SELKIES_ENCODER` | `h264enc` | `h264enc` \| `h264enc-striped` \| `openh264enc` \| `jpeg` |
| `SELKIES_EXTRA_ARGS` | *(空)* | 追加到 `selkies` 的额外 CLI 参数 |
| `SELKIES_INTERNAL_PORT` | `8081` | Selkies 绑定的回环端口(nginx 后面) |

**Chromium / CDP**

| 变量 | 默认值 | 说明 |
| --- | --- | --- |
| `CHROMIUM_HEADLESS` | `0` | `0` = 有头,显示在 Xvfb 桌面(串流可见);`1` = 无头 |
| `CHROMIUM_LANG` | `en-US` | 浏览器 UI 语言 + `Accept-Language`(如 `zh-CN`) |
| `CHROMIUM_START_URL` | `about:blank` | 启动时打开的页面 |
| `CHROMIUM_EXTRA_ARGS` | *(空)* | 额外 chromium 参数,如 `--proxy-server=http://host:3128` |
| `CHROMIUM_USER_DATA_DIR` | `/tmp/chrome-profile`(compose:`/chrome-user-data`) | 浏览器配置目录 |
| `CDP_INTERNAL_PORT` | `9221` | Chromium 回环 DevTools 端口(nginx 后面) |

**桌面 / 容器**

| 变量 | 默认值 | 说明 |
| --- | --- | --- |
| `TZ` | `UTC` | 容器时区(任意 IANA 时区,如 `Asia/Shanghai`) |
| `SCREEN_GEOMETRY` | `1920x1080x24` | Xvfb 屏幕尺寸 `宽x高x深`;同时决定 Selkies 串流分辨率 |
| `SHM_SIZE`(compose) | `1gb` | `/dev/shm` 大小 —— Chromium 需要比 docker 默认 64 MB 更多的空间 |

### 时区与语言

默认值是对容器友好的 **UTC** 时区与**系统默认英语**(`en-US`)浏览器语言。两者都是普通环境变量覆盖,无需重新构建:

```bash
# docker run
docker run -e TZ=Asia/Shanghai -e CHROMIUM_LANG=zh-CN ...

# compose(.env)
TZ=Asia/Shanghai
CHROMIUM_LANG=zh-CN
```

`CHROMIUM_LANG` 同时决定浏览器 UI 语言和 `navigator.language` / `Accept-Language`;入口脚本会对持久化配置目录做预置,即使目录最初是用其他语言创建的也能生效(细节见 `docker-entrypoint.sh`)。

## HTTPS

TLS 在 nginx 终止。只要存在**有效**证书对(自签也算有效;"有效" = 证书与私钥可解析且互相匹配)就会**原样复用**;只有找不到可用证书对时才会生成自签证书 —— 生成到 `./tls` 挂载目录里,因此会持久化并在后续启动中复用。

**方式 A —— 快速(自签):** 在 `.env` 取消一行注释:

```bash
COMPOSE_FILE=compose.yaml:compose.https.yaml
```

一条配置同时发布 `https://localhost:8443` 并开启 HTTPS。

**方式 B —— 使用自己的证书:** 把 `fullchain.pem` + `privkey.pem` 放进宿主机 `./tls` 目录,再用上面的 overlay(或设 `ENABLE_HTTPS=true`)。已存在的有效证书对永远原样复用;损坏的证书对会让容器带明确错误直接退出,而不是被悄悄替换。

`ENABLE_HTTPS=true` 但*不*用 overlay = HTTPS 只在 docker 网络内可用(例如挂在另一个反向代理后面)—— 宿主端口不发布。

## 持久化

| 宿主路径(compose) | 容器路径 | 内容 |
| --- | --- | --- |
| `./chrome-user-data` | `/chrome-user-data` | Chromium 配置:cookies、登录态、扩展、`navigator.language` 偏好 |
| `./tls` | `/etc/nginx/tls` | TLS 证书(你自己的,或生成的自签对) |

两个目录都已 git-ignore。配置目录就是浏览器的 `--user-data-dir`,本次运行登录的账号在 `docker compose down && up` 之后依然有效。上一容器遗留的 `Singleton*` 锁文件(Chromium 的运行时产物)会在启动时自动清理。

### Docker 网络(compose)

默认情况下 compose 把容器接入自建的 `<project>_default` 网络。`.env` 里两个变量可以改变这一行为:

```bash
NETWORK_NAME=my-net NETWORK_EXTERNAL=false   # 由 compose 创建并管理 my-net
NETWORK_NAME=existing NETWORK_EXTERNAL=true  # 接入已存在的网络,
                                             # 例如与反向代理栈共享
```

对已存在的网络请使用 `NETWORK_EXTERNAL=true`(旧版 compose 否则会报 incorrect label 错误)。

## 服务开关、健康检查与重启

* 容器启动 == 服务启动:入口脚本是一个极简 PID 1 监管器,**任一服务退出即退出**,配合 `--restart always` / `restart: always` 即为自动恢复。
* compose 健康检查每 30 秒轮询 `http://127.0.0.1:80/`(nginx 代理 Selkies)。
* 同时设置 `ENABLE_SELKIES=false` 和 `ENABLE_CDP=false` 是配置错误,会立即失败。
* 日志在容器内 `/tmp/*.log`(`xvfb.log`、`pulseaudio.log`、`chromium.log`、`nginx/*.log`);`docker compose logs` 显示入口脚本自身输出。

## 从源码构建

```bash
docker compose build            # 或:docker build -t chendefine/playwright-cdp-selkies .
```

这是一个多阶段 Dockerfile:

1. `selkies-build`(node:24-bookworm-slim)从钉住的上游 commit 构建 Selkies wheel(其中打包了 HTML5 Web 客户端,普通源码 checkout 里没有),
2. 最终 Ubuntu 24.04 阶段安装 Node.js、Playwright Chromium 及其系统依赖、nginx、Xvfb/PulseAudio 和 Selkies wheel —— 各自成层。

`docker build --check .` 通过,无警告。

## 版本联动脚本

[`update-playwright-node.mjs`](update-playwright-node.mjs) 基于实时元数据(npm 的 `engines.node` + Node.js 发布索引;选择满足 Playwright 下限的最新 LTS 主版本)统一重钉 `Dockerfile`、`compose.yaml`、`.env.example` 中的 Playwright 与 Node 版本:

```bash
node update-playwright-node.mjs            # 钉到最新 playwright-core
node update-playwright-node.mjs 1.62.1     # 钉到指定版本
node update-playwright-node.mjs --check    # CI 模式:有偏差则退出码 1
```

## CI/CD 与发布的镜像

[![ci](https://github.com/chendefine/playwright-cdp-selkies/actions/workflows/ci.yaml/badge.svg)](https://github.com/chendefine/playwright-cdp-selkies/actions/workflows/ci.yaml)

每次 push 与 pull request 运行 [`ci.yaml`](.github/workflows/ci.yaml):hadolint + shellcheck、完整镜像构建、运行时冒烟测试(CDP 端点与 Web UI)。推送 `v*` 标签时构建并发布:

* **GHCR**:`ghcr.io/chendefine/playwright-cdp-selkies`(使用内置 `GITHUB_TOKEN`)
* **Docker Hub**:`chendefine/playwright-cdp-selkies`(需要仓库 secrets `DOCKERHUB_USERNAME` / `DOCKERHUB_TOKEN`;未配置则跳过)

标签规则:`v1.4.0` → `1.4.0`、`1.4`、`sha-<短哈希>`、`latest`。

### 上游版本自动更新

[`playwright-update.yaml`](.github/workflows/playwright-update.yaml) 每天定时(也支持手动触发)监视 npm 上的 `playwright-core` 新版本,并驱动整个闭环:

1. `update-playwright-node.mjs` 重新钉住仓库中的 Playwright + Node 版本;
2. 自动开启一个包含变更 diff 的 bump PR;
3. `ci.yaml` 在该 PR 上运行(lint + 完整构建 + 冒烟测试);
4. CI 全绿后 PR 以 squash 方式自动合并;
5. `ci.yaml` 中的 `release-tag` job 推送标签 `v<playwright 版本>`;
6. 标签事件触发 `publish` job → 镜像发布到 GHCR / Docker Hub。

若 `v1.63.0` 已被占用(同一 Playwright 版本重新发布),标签自动递增为 `v1.63.0-r2`、`-r3`、……

要实现全自动,需一次性配置:

* **仓库 secret `PLAYWRIGHT_UPDATE_TOKEN`** —— 经典 PAT(需 `repo` 权限)或 fine-grained PAT(需 *Contents* + *Pull requests* 读写)。它在两处不可或缺:GitHub 对用内置 `GITHUB_TOKEN` 创建的 PR 绝不触发 `on: pull_request`(bump PR 将没有 CI 检查);且 `GITHUB_TOKEN` 产生的事件不会触发任何 workflow(用它推送的发布标签永远不会启动 publish job)。不配置该 secret 时 bump PR 照常开启、等待人工合并(关闭再重开该 PR 可强制触发 CI),但推送的标签不会自动发布 —— 需在本机重推标签或手动运行 workflow。
* **Settings → General → Pull Requests → "Allow auto-merge"** 打开,PR 才能在检查通过后自行合并。

不配置 secret 时流程仍然完整,只是加了人工闸门:PR 照常开启,你验证后手动合并,打标签与发布随后自动完成。手动 `v*` 标签的发布方式完全不变;手动改 Playwright 版本合入 main 也会同样被自动打标签并发布。

## 安全注意事项

* **CDP 端点没有认证。** 一次 TCP 连接即获得完整的浏览器控制权 —— `9222` 只发布到 localhost 或可信网络,绝不要暴露公网 IP。
* **Web UI 默认无认证。** 只要串流可能被不信任的人访问,就设置 `SELKIES_BASIC_AUTH_PASSWORD`;同时配合 HTTPS(纯 HTTP + basic auth 会泄露密码)。
* Chromium 以 `--no-sandbox` 运行(容器化 Chrome 在没有允许 userns 的 seccomp 配置时的标准做法);请把容器当作"暴露一个浏览器"来对待,放在专用的用户/VM 里。
* 生成的 TLS 密钥是自签的 —— 浏览器会告警,属预期;对公网服务请换用正式证书。
* 容器以 **root** 运行(入口脚本是 PID 1,且需绑定 80/443 特权端口)。若威胁模型允许,可加 `--cap-drop=ALL --security-opt=no-new-privileges`,或让反向代理监听非特权端口。

## 故障排查

| 现象 | 处理 |
| --- | --- |
| `curl :9222/json/version` 失败 | `docker compose logs`;查看容器内 `/tmp/chromium.log`。端口被占?改 `CDP_PORT`。 |
| Web UI 打不开 | 是否设了 `ENABLE_SELKIES=false`?查看 `/tmp/nginx/error.log` 及 Selkies 是否起来(`/tmp` 下日志)。 |
| 串流里看不到浏览器窗口 | 是否设了 `CHROMIUM_HEADLESS=1`?默认 `0` 有头并显示在串流桌面。 |
| 标签页高负载下崩溃 | 调大 `SHM_SIZE`(compose 已是 1 GB;`docker run` 用 `--shm-size`)。 |
| 重启后提示 profile "in use by another process" | 正常情况会自动清理;仍出现就 `rm chrome-user-data/Singleton*`。 |
| 旧配置目录语言未生效 | 入口脚本启动时会预置偏好;确认 `CHROMIUM_LANG` 设在*容器*上,而不是单个页面上。 |
| HTTPS 报错 | 证书对损坏时会快速失败 —— 修复或删除 `tls/fullchain.pem` + `tls/privkey.pem`(删掉后重新生成自签对)。 |

## 参与贡献

见 [CONTRIBUTING.md](CONTRIBUTING.md)。欢迎提 issue 和 PR —— 修 bug、完善文档、以及论证充分的特性新增都欢迎。

## 许可证

[MIT](LICENSE) —— 镜像中另行打包了 Chromium、Selkies、nginx 等第三方软件,它们遵循各自的许可证。
