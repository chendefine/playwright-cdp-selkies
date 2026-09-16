# AGENTS.md

Guidance for AI coding agents (Codex, Claude Code, Cursor, …) working in this
repository. Human-oriented intro and rationale: [CONTRIBUTING.md](CONTRIBUTING.md).
User-facing docs: [README.md](README.md) / [README.zh-CN.md](README.zh-CN.md).

## What this repo is

A single Docker image (`chendefine/playwright-cdp-selkies`) bundling a
Playwright-managed Chromium, a live-viewable Selkies remote desktop, and a
public CDP endpoint behind one nginx front door. It is an infrastructure
repo, not an application codebase: the deliverables are a Dockerfile, a bash
PID-1 supervisor, compose files, a Node version-sync script, and mirrored
bilingual docs. There is no unit-test suite — "testing" means static lint +
image build + runtime smoke tests.

| Path | Role |
| --- | --- |
| `Dockerfile` | Single-stage ubuntu:24.04 image: Node.js, pinned Playwright Chromium, nginx, Xvfb/PulseAudio/picom, sha256-pinned Selkies wheels. **Source of truth for pinned versions.** |
| `docker-entrypoint.sh` | PID-1 supervisor: starts Xvfb → picom → PulseAudio → Selkies → Chromium → nginx, and **generates the nginx config into `/tmp/nginx/nginx.conf` at every container start** |
| `compose.yaml` | Base stack; reads `.env` (`env_file` passes unlisted vars through, e.g. native `SELKIES_*`) |
| `compose.https.yaml`, `compose.gpu.yaml`, `compose.gpu-nvidia.yaml` | Opt-in overlays (HTTPS publishing; Intel/AMD `/dev/dri`; NVIDIA CDI) |
| `.env.example` | Every runtime knob, documented |
| `update-playwright-node.mjs` | Version-sync script — rewrites the Playwright/Node pins in `Dockerfile` + `compose.yaml` + `.env.example` together |
| `.github/workflows/ci.yaml` | lint → build → smoke tests → release-tag → publish (GHCR + Docker Hub) |
| `.github/workflows/playwright-update.yaml` | Daily cron: re-pin → bump PR → auto-merge → release |
| `examples/` | CDP client examples (`connect-playwright.mjs`, `webgl-renderer-probe.mjs`) |
| `README.md` / `README.zh-CN.md` | Mirrored EN / zh-CN user docs |

Untracked local state — never commit: `.env`, `tls/`, `chrome-user-data/`
(all git-ignored), plus scratch dirs `detect/`, `.playwright-cli/` if present.

## Commands

Static checks — CI runs exactly these; all must pass before any commit:

```bash
docker run --rm -i -e HADOLINT_CONFIG=/.hadolint.yaml \
  -v "$PWD/.hadolint.yaml:/.hadolint.yaml" hadolint/hadolint:v2.12.0 < Dockerfile
docker run --rm -v "$PWD:/mnt" koalaman/shellcheck:v0.10.0 /mnt/docker-entrypoint.sh
node --check update-playwright-node.mjs
docker build --check .
```

Build and smoke-test:

```bash
docker compose build

# CDP path (Selkies off)
docker run -d --name cdp-smoke -p 9222:9222 -e ENABLE_SELKIES=false \
  chendefine/playwright-cdp-selkies:latest
curl -sf http://127.0.0.1:9222/json/version | jq -e '.Browser and .webSocketDebuggerUrl'
docker rm -f cdp-smoke

# Web-UI path (CDP off)
docker run -d --name web-smoke -p 8080:80 -e ENABLE_CDP=false \
  chendefine/playwright-cdp-selkies:latest
curl -sf http://127.0.0.1:8080/ | grep -qi '<html'
docker rm -f web-smoke
```

When a smoke test fails: container logs live in `/tmp/*.log` (`xvfb.log`,
`chromium.log`, `pulseaudio.log`, `nginx/error.log`, …); `docker logs` shows
the entrypoint's own output.

Version sync:

```bash
node update-playwright-node.mjs            # pin latest playwright-core (+ matching Node LTS)
node update-playwright-node.mjs 1.63.0     # pin a specific version
node update-playwright-node.mjs --check    # CI drift mode: exit 1 on drift
```

## Hard rules

1. **Never hand-edit the Playwright/Node pins.** They live in three files
   (`Dockerfile`, `compose.yaml`, `.env.example`); only
   `update-playwright-node.mjs` keeps them in sync. Also never hardcode the
   pinned version in docs or comments — link to the Dockerfile instead (the
   READMEs have drifted before).
2. **A `SELKIES_VERSION` bump means new wheel digests**: update
   `SELKIES_SHA256`, `PIXELFLUX_SHA256_{AMD64,ARM64}` and
   `PCMFLUX_SHA256_{AMD64,ARM64}` in the Dockerfile (digests from the GitHub
   release API), and `SELKIES_PYTAG` if the base image's Python changes
   (ubuntu:24.04 → `cp312`). The build fails fast on a mismatch, by design.
3. **There is no static nginx config in the repo.** Listener/proxy/TLS
   changes go into the heredocs in `docker-entrypoint.sh` that generate
   `/tmp/nginx/nginx.conf`; `nginx -t` runs on the generated file before
   start.
4. **Container ports 80/443/9222 are fixed by design.** `NGINX_HTTP_PORT` /
   `NGINX_HTTPS_PORT` / `CDP_PORT` pick only the *host-side* published ports.
   Do not turn them into container-side knobs.
5. **New behavior needs an env knob** with a default that is safe for the
   majority, plus matching entries in `docker-entrypoint.sh`, `.env.example`,
   `compose.yaml` and BOTH READMEs — same PR.
6. **Docs are a deliverable.** `README.md` and `README.zh-CN.md` mirror each
   other; update both or the change is incomplete.
7. **Lint gates are hard:** shellcheck-clean (keep the existing
   `# shellcheck disable=... # reason` style), hadolint-clean under
   `.hadolint.yaml` (each `ignored` rule there documents its justification —
   extend that pattern instead of silencing inline), `docker build --check`-
   clean, `node --check`-clean.
8. **No secrets or runtime state in git.** `.env`, `tls/`,
   `chrome-user-data/` are ignored on purpose; never weaken that.

## Architecture invariants — do not break

* **PID-1 semantics.** Any argv other than `start` is `exec`'d as a command
  (passthrough mode — `docker run -it <image> bash` depends on it). In start
  mode the supervisor exits when ANY supervised service dies, so
  `restart: always` recovers the container. New daemons must join the
  `pids` array and the cleanup trap; never background something the
  supervisor does not watch.
* **Loopback-only internals; nginx is the only public front door.** Selkies
  (`127.0.0.1:${SELKIES_INTERNAL_PORT}`) and Chromium DevTools
  (`127.0.0.1:${CDP_INTERNAL_PORT}`) bind loopback only. Every public
  listener is an nginx proxy and must stay WebSocket-capable (CDP and
  Selkies signaling both need the Upgrade/Connection headers).
* **Entrypoint shell style:** `set -uo pipefail` deliberately WITHOUT `-e`;
  fatal conditions use `die`, warnings use `log`. Preserve that pattern —
  commands whose failure must abort startup need an explicit check.
* **TLS policy:** reuse any parseable cert/key pair that belongs together
  (self-signed counts as valid); self-sign ONLY when no usable pair exists;
  a broken pair fails fast, never gets silently replaced.
* **CDP gateway details:** the DevTools Host header is rewritten to the
  loopback upstream (DNS-rebinding protection) and `webSocketDebuggerUrl`
  hosts inside JSON responses are `sub_filter`'ed back to the public
  host:port the client dialed. Changing either side breaks
  `connectOverCDP` from outside the container.
* **GPU policy is one knob:** `CHROMIUM_GPU=auto|off|strict`. Hardware GL
  goes through Vulkan/ANGLE (`--use-angle=vulkan --enable-features=Vulkan`)
  because native GL cannot work on the Xvfb display; SwiftShader stays
  allowed as a runtime fallback unless `strict`.
* **Chromium flag order matters:** the entrypoint appends its flags before
  `CHROMIUM_EXTRA_ARGS` so user flags win (Chromium honors the last
  occurrence of a repeated switch). Keep new flags on the entrypoint side of
  that boundary.

## Releases

Routine releases are fully automated — do not hand-tag Playwright bumps.
Merging to main a change of the `ARG PLAYWRIGHT_VERSION` pin makes the
`release-tag` job in `ci.yaml` push `vX.Y.Z` (`-r2`, `-r3`, … on re-release),
which triggers the `publish` job (GHCR always; Docker Hub when the
`DOCKERHUB_*` secrets exist). The daily `playwright-update.yaml` cron opens
the bump PR and auto-merges it once CI is green. Manual `v*` tags still
work.

## Commit style

Conventional-ish subjects: `feat:`, `fix:`, `docs(cn):`, `chore:`, `ci:`.
One PR per concern, with a short rationale and how it was verified (which
smoke test ran, which logs were checked).
