# Contributing

Thanks for taking the time to improve this project! Issues and pull requests are both welcome.

## Getting started

```bash
git clone https://github.com/chendefine/playwright-cdp-selkies.git
cd playwright-cdp-selkies
cp .env.example .env        # optional; defaults work
docker compose up -d --build
```

Verify your change before opening a PR — CI runs exactly these checks:

```bash
# static checks
docker run --rm -i -e HADOLINT_CONFIG=/.hadolint.yaml \
  -v "$PWD/.hadolint.yaml:/.hadolint.yaml" hadolint/hadolint:v2.12.0 < Dockerfile
docker run --rm -v "$PWD:/mnt" koalaman/shellcheck:v0.10.0 /mnt/docker-entrypoint.sh
node --check update-playwright-node.mjs
docker build --check .                        # Dockerfile lint (BuildKit)

# full build + runtime smoke tests
docker compose build
docker run -d --name cdp-smoke -p 9222:9222 -e ENABLE_SELKIES=false \
  chendefine/playwright-cdp-selkies:latest
curl -sf http://127.0.0.1:9222/json/version   # then: docker rm -f cdp-smoke
```

## Repo layout

| Path | Purpose |
| --- | --- |
| `Dockerfile` | multi-stage image build (selkies wheel + final Ubuntu image) |
| `docker-entrypoint.sh` | PID-1 supervisor: Xvfb, PulseAudio, Selkies, Chromium, nginx |
| `compose.yaml` / `compose.https.yaml` | base + HTTPS overlay compose files |
| `.env.example` | documented runtime configuration template |
| `update-playwright-node.mjs` | version-sync helper (Playwright ↔ Node) |
| `.github/workflows/ci.yaml` | lint → build → smoke test → release-tag → publish |
| `.github/workflows/playwright-update.yaml` | daily upstream Playwright watch → bump PR → auto-merge → release |
| `examples/` | CDP client examples |

## Guidelines

* **Keep behavior configurable.** New features should come with an environment knob, a default that is safe for the majority, and an entry in `.env.example`, `compose.yaml` and both READMEs.
* **One PR per concern**, with a short rationale. For behavioral changes, explain how you verified it.
* **Scripts must pass their linters** (`shellcheck` for bash, `node --check` for JS). The Dockerfile must stay `hadolint`-clean and `docker build --check`-clean.
* **Docs stay in sync**: `README.md` and `README.zh-CN.md` mirror each other; update both.
* **No secrets in the repo** — `.env`, `tls/` and `chrome-user-data/` are git-ignored on purpose.
* Version bumps of Playwright/Node should go through `node update-playwright-node.mjs` (single source of truth) rather than hand edits.

## Commit style

No strict plugin enforced; a concise conventional-ish subject helps history browsing:

```
feat: add SELKIES_FRAMERATE passthrough docs
fix: clear Singleton locks before chromium launch
docs(cn): mirror HTTPS section of README
```

## Reporting security issues

Please do **not** open public issues for security problems — see [SECURITY.md](SECURITY.md).
