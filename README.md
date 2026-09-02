# playwright-cdp-selkies

**A single Docker container that bundles a Playwright-managed Chromium with a live-viewable remote desktop and a public CDP endpoint.**

[![ci](https://github.com/chendefine/playwright-cdp-selkies/actions/workflows/ci.yaml/badge.svg)](https://github.com/chendefine/playwright-cdp-selkies/actions/workflows/ci.yaml)
[![license: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![docker image size](https://img.shields.io/docker/image-size/chendefine/playwright-cdp-selkies)](https://hub.docker.com/r/chendefine/playwright-cdp-selkies)
[![docker pulls](https://img.shields.io/docker/pulls/chendefine/playwright-cdp-selkies)](https://hub.docker.com/r/chendefine/playwright-cdp-selkies)

[English](README.md) | [简体中文](README.zh-CN.md)

The container starts everything it needs in one place and supervises it as PID 1:

```
docker run ─┬─ Xvfb        virtual display (what Selkies streams)
            ├─ PulseAudio  virtual audio
            ├─ Selkies     HTML5 remote desktop  ─┐
            ├─ Chromium   Playwright build, CDP ──┼─ nginx front door
            └─ nginx      one process, 3 ports  ─┘
```

* **Chromium with a public CDP endpoint** — connect [Playwright](https://playwright.dev) / Puppeteer / Selenium from *outside* the container via `connectOverCDP("http://localhost:9222")`.
* **Live-viewable desktop** — the browser runs **headed** on a virtual X11 display by default, and [Selkies](https://github.com/selkies-project/selkies) streams it to any browser (WebRTC/WebCodecs, audio included). Watch and interact with your automation as it runs.
* **Persistent profile** — cookies, logins and extensions survive container recreation via a bind mount.
* **HTTPS support** — self-signed by default, or bring your own certificate; existing valid pairs are always reused.
* **Sane defaults** — UTC timezone, `en-US` browser locale; both are one-line overrides.

## Table of contents

- [What's inside](#whats-inside)
- [Quick start](#quick-start)
  - [Docker Compose](#docker-compose)
  - [Plain docker run](#plain-docker-run)
- [Ports](#ports)
- [Connecting Playwright over CDP](#connecting-playwright-over-cdp)
- [Watching the desktop](#watching-the-desktop)
- [Configuration](#configuration)
  - [Build arguments](#build-arguments)
  - [Environment variables](#environment-variables)
  - [Timezone and language](#timezone-and-language)
- [HTTPS](#https)
- [Persistence](#persistence)
- [Service toggles, health and restarts](#service-toggles-health-and-restarts)
- [Building from source](#building-from-source)
- [Keeping versions in sync](#keeping-versions-in-sync)
- [CI/CD and published images](#cicd-and-published-images)
- [Security considerations](#security-considerations)
- [Troubleshooting](#troubleshooting)
- [Contributing](#contributing)
- [License](#license)

## What's inside

| Component | Version | Role |
| --- | --- | --- |
| Ubuntu | 24.04 | base image |
| Node.js | 24 (current LTS) | matches Playwright's supported range |
| Playwright Chromium | 1.62.1 | the automated browser (`chromium`, `chromium-headless-shell`, `ffmpeg`) |
| Selkies | [pinned commit](Dockerfile) | HTML5 remote desktop (web client, signaling, streaming) |
| nginx | Ubuntu package | front door: web UI (HTTP/HTTPS) + CDP gateway, WebSocket-capable |
| Xvfb / PulseAudio | Ubuntu packages | virtual display + audio for the stream |

All services are loopback-only inside the container; nginx is the single public front door and every proxy speaks WebSocket (required by both CDP and Selkies signaling).

## Quick start

### Docker Compose

```bash
git clone https://github.com/chendefine/playwright-cdp-selkies.git
cd playwright-cdp-selkies

cp .env.example .env        # optional — defaults work out of the box
docker compose up -d --build
```

Then:

* **Desktop stream**: <http://localhost:8080> — the Chromium window, live.
* **CDP endpoint**: <http://localhost:9222/json/version> — for Playwright et al.

Useful commands:

```bash
docker compose logs -f      # follow logs
docker compose exec playwright-cdp-selkies bash   # shell in the container
docker compose down         # stop (add -v to also drop the network)
```

### Plain docker run

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

Any argument other than the implicit `start` is exec'd instead of the supervisor, e.g. `docker run -it chendefine/playwright-cdp-selkies bash` drops to a shell.

## Ports

Container ports are **fixed by design**; the variables pick only the **host-side** ports docker publishes.

| Container port | Service | Host port (default) | How to change |
| --- | --- | --- | --- |
| 80 | Web UI (HTTP) | 8080 | `NGINX_HTTP_PORT` in `.env` |
| 443 | Web UI (HTTPS, opt-in) | 8443 | `NGINX_HTTPS_PORT` + [HTTPS](#https) |
| 9222 | Chromium CDP | 9222 | `CDP_PORT` in `.env` |

## Connecting Playwright over CDP

The image exposes Chromium's DevTools protocol through nginx, so any CDP client on your host (or anywhere reachable) can drive the browser. You do **not** need Playwright browsers installed locally.

```bash
npm init -y && npm i playwright
node examples/connect-playwright.mjs https://example.com
```

<details>
<summary>examples/connect-playwright.mjs (essence)</summary>

```js
import { chromium } from "playwright";

const browser = await chromium.connectOverCDP("http://localhost:9222");
const context = browser.contexts()[0];            // reuse default context
const page = context.pages()[0] ?? await context.newPage();

await page.goto("https://example.com");
console.log(await page.title());
await browser.close();  // closes the CDP session, not the browser
```

</details>

Notes:

* The default context uses the **persisted profile**, so logins and cookies carry over between runs.
* `curl http://localhost:9222/json/version` is the quickest health check.
* Puppeteer works the same way: `puppeteer.connect({ browserURL: "http://localhost:9222" })`.

## Watching the desktop

Open <http://localhost:8080>. Selkies streams the Xvfb display (with audio) straight into the browser tab — keyboard and mouse input go to the container. Since Chromium runs headed by default (`CHROMIUM_HEADLESS=0`), every automation step is visible in the stream. Set `CHROMIUM_LANG`/`CHROMIUM_START_URL` to control the initial browser state.

Protect the stream with a login screen by setting a password (`SELKIES_BASIC_AUTH_PASSWORD`, username defaults to `ubuntu` — see [Environment variables](#environment-variables)).

## Configuration

Everything is configured via environment variables; with Compose, put them in `.env` (see [.env.example](.env.example)). Variables not explicitly listed in `compose.yaml` still reach the container through the `env_file` pass-through — that includes native Selkies settings such as `SELKIES_FRAMERATE=30` or `SELKIES_TURN_URL=...`.

### Build arguments

| Arg | Default | Description |
| --- | --- | --- |
| `PLAYWRIGHT_VERSION` | `1.62.1` | playwright-core version from npm (must exist on registry.npmjs.org) |
| `NODE_VERSION` | `24` | Node.js major (kept in sync by [`update-playwright-node.mjs`](#keeping-versions-in-sync)) |
| `SELKIES_REF` | pinned SHA | git ref (sha/branch/tag) the Selkies wheel is built from |
| `TZ` | `UTC` | container timezone, exposed as `ENV TZ` (runtime-overridable) |
| `DOCKER_IMAGE_NAME_TEMPLATE` | `chendefine/playwright-cdp-selkies` | value passed to `playwright-core mark-docker-image` |

```bash
docker compose build --build-arg PLAYWRIGHT_VERSION=1.62.1
```

### Environment variables

**Service toggles**

| Variable | Default | Description |
| --- | --- | --- |
| `ENABLE_SELKIES` | `true` | `false` = skip web UI + display + audio (CDP-only container) |
| `ENABLE_CDP` | `true` | `false` = skip Chromium + CDP gateway (remote-desktop-only container) |

**Web UI / TLS**

| Variable | Default | Description |
| --- | --- | --- |
| `ENABLE_HTTPS` | `false` | `true` = nginx also serves the web UI over TLS on container port 443 |
| `TLS_CERT_DIR` | `/etc/nginx/tls` | where certificates are looked up / generated |
| `TLS_CERT_FILE` / `TLS_KEY_FILE` | `$TLS_CERT_DIR/fullchain.pem` / `privkey.pem` | explicit cert/key paths |
| `TLS_SELF_SIGNED_CN` | `localhost` | CN of the generated self-signed certificate |

**Selkies**

| Variable | Default | Description |
| --- | --- | --- |
| `SELKIES_BASIC_AUTH_PASSWORD` | *(empty)* | set to enable the login screen; empty = no login |
| `SELKIES_BASIC_AUTH_USER` | `ubuntu` | login username |
| `SELKIES_ENCODER` | `h264enc` | `h264enc` \| `h264enc-striped` \| `openh264enc` \| `jpeg` |
| `SELKIES_EXTRA_ARGS` | *(empty)* | extra CLI flags appended to `selkies` |
| `SELKIES_INTERNAL_PORT` | `8081` | loopback port Selkies binds to (behind nginx) |

**Chromium / CDP**

| Variable | Default | Description |
| --- | --- | --- |
| `CHROMIUM_HEADLESS` | `0` | `0` = headed on the Xvfb desktop (visible in the stream); `1` = headless |
| `CHROMIUM_LANG` | `en-US` | browser UI locale + `Accept-Language` (e.g. `zh-CN`) |
| `CHROMIUM_START_URL` | `about:blank` | page opened at startup |
| `CHROMIUM_EXTRA_ARGS` | *(empty)* | extra chromium flags, e.g. `--proxy-server=http://host:3128` |
| `CHROMIUM_GPU` | `auto` | `auto` = render on a passed-through GPU when one is visible ([GPU passthrough](#gpu-passthrough-optional)), else SwiftShader software — WebGL always works; `off` = force software; `strict` = never allow SwiftShader (WebGL then requires the GPU) |
| `CHROMIUM_DISABLE_FEATURES` | `HttpsFirstBalancedModeAutoEnable,HttpsUpgrades,HttpsFirstModeV2` (compose; empty without compose) | comma-separated features passed as `--disable-features=` — turns off the HTTPS-First / HTTPS-Upgrade experiments; set empty in `.env` to drop the flag |
| `CHROMIUM_USER_DATA_DIR` | `/tmp/chrome-profile` (compose: `/chrome-user-data`) | browser profile directory |
| `CDP_INTERNAL_PORT` | `9221` | chromium loopback DevTools port (behind nginx) |

**Desktop / container**

| Variable | Default | Description |
| --- | --- | --- |
| `TZ` | `UTC` | container timezone (any IANA zone, e.g. `Asia/Shanghai`) |
| `SCREEN_GEOMETRY` | `1920x1080x24` | Xvfb screen size `WxHxD`; also sizes the Selkies stream |
| `SHM_SIZE` (compose) | `1gb` | `/dev/shm` size — Chromium needs more than the 64 MB docker default |

### Timezone and language

Defaults are the container-friendly **UTC** timezone and **system-default English** (`en-US`) browser locale. Both are plain environment overrides — no rebuild needed:

```bash
# with docker run
docker run -e TZ=Asia/Shanghai -e CHROMIUM_LANG=zh-CN ...

# with compose (.env)
TZ=Asia/Shanghai
CHROMIUM_LANG=zh-CN
```

`CHROMIUM_LANG` sets both the browser UI language and `navigator.language`/`Accept-Language`; the entrypoint seeds the persisted profile so the locale applies even to profiles created with a different language (see `docker-entrypoint.sh` for the gory details).

## HTTPS

TLS terminates at nginx. The certificate pair is **reused whenever a valid one exists** (self-signed counts as valid; "valid" = parseable cert + matching key) and a self-signed pair is generated **only** when no usable pair is found — into the `./tls` bind mount, so it persists and is reused across restarts.

**Option A — quick (self-signed):** uncomment one line in `.env`:

```bash
COMPOSE_FILE=compose.yaml:compose.https.yaml
```

This publishes `https://localhost:8443` and turns HTTPS on in one go.

**Option B — bring your own certificate:** drop `fullchain.pem` + `privkey.pem` into `./tls` on the host and use the overlay above (or set `ENABLE_HTTPS=true`). Existing valid pairs are always reused as-is; a broken pair stops the container with a clear error instead of being silently replaced.

`ENABLE_HTTPS=true` *without* the overlay means HTTPS works only inside the docker network (e.g. behind another reverse proxy) — the host port stays unpublished.

## GPU passthrough (optional)

By default everything renders in software (SwiftShader): the container runs anywhere, no GPU required. To render on the host's real GPU instead, add one of the opt-in overlays in `.env`:

```bash
# Intel / AMD — passes /dev/dri through:
COMPOSE_FILE=compose.yaml:compose.gpu.yaml

# NVIDIA — host needs the proprietary driver + nvidia-container-toolkit:
COMPOSE_FILE=compose.yaml:compose.gpu-nvidia.yaml
```

The entrypoint auto-detects the device at start (`CHROMIUM_GPU=auto`, the default) and switches Chromium to the Vulkan/ANGLE backend (`--use-angle=vulkan --enable-features=Vulkan`): WebGL/WebGPU contexts render via Vulkan — the native-GL path cannot work on Xvfb at all — and the display compositor runs on Vulkan too (without the compositing flag chrome://gpu reports WebGL as "Hardware accelerated but at reduced performance": GPU frames read back into a CPU compositor). Verified results: NVIDIA passthrough → `ANGLE (NVIDIA, Vulkan … GeForce RTX …)`, AMD iGPU → `ANGLE (AMD, Vulkan … RADV)` with `webgl/webgpu: enabled` (no readback). `--disable-gpu` is then no longer added in headless mode, and SwiftShader stays allowed as a runtime fallback so WebGL survives a flaky device. `CHROMIUM_GPU=strict` never allows SwiftShader (anti-fingerprinting: the browser must not report a software renderer — WebGL is then unavailable without a GPU); `off` forces the software path even with a GPU attached.

The image bakes in the Mesa/VA-API userland for Intel/AMD; NVIDIA GL libraries cannot be baked in (they must match the host driver) — the nvidia container toolkit injects them at container start. Verify with `docker compose exec playwright-cdp-selkies glxinfo -B` / `vainfo` (Intel/AMD) or `nvidia-smi` (NVIDIA), and with `chrome://gpu` in the streamed browser: WebGL should report the hardware renderer.

## Persistence

| Host path (compose) | Container path | Content |
| --- | --- | --- |
| `./chrome-user-data` | `/chrome-user-data` | Chromium profile: cookies, logins, extensions, `navigator.language` prefs |
| `./tls` | `/etc/nginx/tls` | TLS certificates (yours or the generated self-signed pair) |

Both directories are git-ignored. The profile is the browser's `--user-data-dir`, so a login made in one run is still there after `docker compose down && up`. Stale `Singleton*` lock files (a Chromium artifact of the previous container) are cleaned automatically at startup.

### Docker network (compose)

By default compose attaches the container to its own `<project>_default` network. Two `.env` knobs change that:

```bash
NETWORK_NAME=my-net NETWORK_EXTERNAL=false   # compose creates & manages my-net
NETWORK_NAME=existing NETWORK_EXTERNAL=true  # attach to an existing network,
                                             # e.g. shared with a reverse-proxy stack
```

Prefer `NETWORK_EXTERNAL=true` for networks that already exist (older compose versions refuse to adopt them otherwise).

## Service toggles, health and restarts

* Container start == service start: the entrypoint is a minimal PID-1 supervisor that **exits when any service dies**, so `--restart always` / `restart: always` turns that into automatic recovery.
* The compose healthcheck polls `http://127.0.0.1:80/` (nginx fronting Selkies) every 30 s.
* Both `ENABLE_SELKIES=false` and `ENABLE_CDP=false` at once is a configuration error and fails fast.
* Logs live in `/tmp/*.log` inside the container (`xvfb.log`, `pulseaudio.log`, `chromium.log`, `nginx/*.log`) — `docker compose logs` shows the entrypoint's own output.

## Building from source

```bash
docker compose build            # or: docker build -t chendefine/playwright-cdp-selkies .
```

The build is a multi-stage Dockerfile:

1. `selkies-build` (node:24-bookworm-slim) builds the Selkies wheel from a pinned upstream commit (it bundles the HTML5 web client, which a plain source checkout lacks),
2. the final Ubuntu 24.04 stage installs Node.js, Playwright Chromium + its system deps, nginx, Xvfb/PulseAudio and the Selkies wheel — each in its own layer.

`docker build --check .` passes with no warnings.

## Keeping versions in sync

[`update-playwright-node.mjs`](update-playwright-node.mjs) re-pins Playwright and Node across `Dockerfile`, `compose.yaml` and `.env.example` from live metadata (npm `engines.node` + the Node.js release index; newest LTS major that satisfies Playwright's floor):

```bash
node update-playwright-node.mjs            # pin the latest playwright-core
node update-playwright-node.mjs 1.62.1     # pin a specific version
node update-playwright-node.mjs --check    # CI mode: exit 1 on drift
```

## CI/CD and published images

[![ci](https://github.com/chendefine/playwright-cdp-selkies/actions/workflows/ci.yaml/badge.svg)](https://github.com/chendefine/playwright-cdp-selkies/actions/workflows/ci.yaml)

Every push and pull request runs [`ci.yaml`](.github/workflows/ci.yaml): hadolint + shellcheck, a full image build, and runtime smoke tests (CDP endpoint and web UI). Pushing a `v*` tag builds and publishes:

* **GHCR**: `ghcr.io/chendefine/playwright-cdp-selkies` (uses the built-in `GITHUB_TOKEN`)
* **Docker Hub**: `chendefine/playwright-cdp-selkies` (needs the `DOCKERHUB_USERNAME` / `DOCKERHUB_TOKEN` repo secrets; skipped otherwise)

Tag scheme: `v1.4.0` → `1.4.0`, `1.4`, `sha-<short>` and `latest`.

### Automatic upstream updates

[`playwright-update.yaml`](.github/workflows/playwright-update.yaml) watches npm for new `playwright-core` releases on a daily cron (also runnable manually) and drives the whole loop:

1. `update-playwright-node.mjs` re-pins Playwright + Node across the repo,
2. a bump PR is opened with the diff,
3. `ci.yaml` runs on the PR (lint + full build + smoke tests),
4. the PR squashes via auto-merge once CI is green,
5. the `release-tag` job in `ci.yaml` pushes tag `v<playwright-version>`,
6. the tag event runs the `publish` job → the image lands on GHCR / Docker Hub.

If `v1.63.0` is already taken (re-release of the same Playwright version), the tag increments to `v1.63.0-r2`, `-r3`, …

For the fully automatic path, configure once:

* **Repo secret `PLAYWRIGHT_UPDATE_TOKEN`** — a PAT with `repo` scope (classic) or a fine-grained token with *Contents* + *Pull requests* read/write. It is needed twice: GitHub never fires `on: pull_request` for PRs created with the built-in `GITHUB_TOKEN` (the bump PR would carry no CI checks), and events created by `GITHUB_TOKEN` never trigger workflows (a release tag pushed with it would never start the publish job). Without the PAT the bump PR still opens and waits for a manual merge (close & reopen it to force CI), but the pushed tag does not auto-publish — re-push the tag from a machine or run the workflow manually.
* **Settings → General → Pull Requests → "Allow auto-merge"** enabled, so the PR can merge itself once checks pass.

Without the secret everything still works, just human-gated: the PR opens, you verify, you merge — tagging and publishing then run automatically. Manual `v*` tags keep working exactly as before, and a manual Playwright bump merged to main is auto-tagged and released the same way.

## Security considerations

* **The CDP endpoint has no authentication.** Full browser control is one TCP connect away — publish `9222` on localhost or a trusted network only, never on a public IP.
* **The web UI is unauthenticated by default.** Set `SELKIES_BASIC_AUTH_PASSWORD` whenever the stream is reachable by anyone you don't trust; use HTTPS alongside it (plain HTTP + basic auth leaks the password).
* Chromium runs with `--no-sandbox` (standard for containerized Chrome without a seccomp profile that allows userns); run the container as a dedicated user/VM you'd be comfortable exposing a browser to.
* Generated TLS keys are self-signed — browsers will warn; that is expected. Bring a real certificate for anything public.
* The container runs as **root** (the entrypoint is PID 1 and binds the privileged ports 80/443). If your threat model allows it, add `--cap-drop=ALL --security-opt=no-new-privileges` or run behind a reverse proxy on unprivileged ports.

## Troubleshooting

| Symptom | Fix |
| --- | --- |
| `curl :9222/json/version` fails | `docker compose logs`; check `/tmp/chromium.log` inside the container. Port busy? change `CDP_PORT`. |
| Web UI unreachable | `ENABLE_SELKIES=false` set? Check `/tmp/nginx/error.log` and that Selkies came up (`/tmp` logs). |
| Browser window not in the stream | `CHROMIUM_HEADLESS=1` set? The default `0` runs headed on the streamed display. |
| Tabs crash under load | raise `SHM_SIZE` (already 1 GB via compose; use `--shm-size` with `docker run`). |
| Profile "in use by another process" after restart | normally auto-cleaned; `rm chrome-user-data/Singleton*` if it persists. |
| Locale not applied to an old profile | the entrypoint seeds prefs at startup; ensure `CHROMIUM_LANG` is set for the *container*, not just for one page. |
| HTTPS errors | a broken cert pair fails fast by design — fix or delete `tls/fullchain.pem` + `tls/privkey.pem` (a deleted pair is regenerated self-signed). |

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Issues and PRs are welcome — bug fixes, doc improvements and well-argued feature additions alike.

## License

[MIT](LICENSE) — the image additionally bundles Chromium, Selkies, nginx and other third-party software under their own licenses.
