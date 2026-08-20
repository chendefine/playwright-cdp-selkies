#!/usr/bin/env node
/**
 * update-playwright-node.mjs — keep the pinned Playwright + Node.js versions
 * in sync across the repo (Dockerfile, compose.yaml, .env.example).
 *
 * The Node major that pairs with a Playwright release is derived from live
 * metadata instead of guesswork:
 *   1. playwright-core@<version> package metadata (registry.npmjs.org)
 *      declares the supported Node range in `engines.node` (e.g. ">=20"),
 *   2. https://nodejs.org/dist/index.json lists every Node release; the
 *      script picks the NEWEST LTS major that satisfies the engines floor
 *      (production images should ride LTS lines). Only when no LTS major
 *      qualifies — e.g. Playwright just raised its floor above every LTS —
 *      does it fall back to the newest even-numbered major (the next LTS
 *      line; odd majors are short-lived and never become LTS).
 *
 * Usage:
 *   node update-playwright-node.mjs                 # pin the latest playwright-core
 *   node update-playwright-node.mjs 1.62.1          # pin a specific version
 *   node update-playwright-node.mjs --node 22       # force the Node major
 *   node update-playwright-node.mjs --check         # exit 1 on drift, change nothing
 *
 * The selkies-build stage tag (FROM node:<major>-bookworm-slim) is rewritten
 * as well so both stages stay on the same Node line.
 */

import { readFileSync, writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import path from "node:path";

const repoRoot = path.dirname(fileURLToPath(import.meta.url));
const args = process.argv.slice(2);
const CHECK_ONLY = args.includes("--check");
const nodeFlagIdx = args.indexOf("--node");
const FORCED_NODE_MAJOR =
  nodeFlagIdx !== -1 ? parseInt(args[nodeFlagIdx + 1], 10) : null;
const positional = args.filter(
  (a, i) => a && !a.startsWith("--") && i !== nodeFlagIdx + 1,
);
const WANTED_PLAYWRIGHT = positional[0] ?? null;

const log = (msg) => console.log(`[update-playwright-node] ${msg}`);
const die = (msg) => {
  console.error(`[update-playwright-node] ERROR: ${msg}`);
  process.exit(1);
};

async function fetchJson(url) {
  const res = await fetch(url, {
    headers: { "accept": "application/json" },
    signal: AbortSignal.timeout(20_000),
  });
  if (!res.ok) throw new Error(`${res.status} ${res.statusText} for ${url}`);
  return res.json();
}

/** Minimum Node major required by a semver range like ">=20", "^20 || >=22.3". */
function minMajorFromEngines(range) {
  const majors = [...range.matchAll(/>=\s*(\d+)/g)].map((m) =>
    parseInt(m[1], 10),
  );
  if (majors.length > 0) return Math.min(...majors);
  const loose = range.match(/(\d+)/);
  if (loose) return parseInt(loose[1], 10);
  return 0;
}

async function main() {
  // --- 1. which playwright-core version? -----------------------------------
  let pwVersion = WANTED_PLAYWRIGHT;
  if (!pwVersion) {
    log("resolving latest playwright-core from registry.npmjs.org ...");
    const latest = await fetchJson(
      "https://registry.npmjs.org/playwright-core/latest",
    ).catch((e) => die(`cannot reach npm registry: ${e.message}`));
    pwVersion = latest.version;
  }

  const pwMeta = await fetchJson(
    `https://registry.npmjs.org/playwright-core/${pwVersion}`,
  ).catch((e) =>
    die(`playwright-core@${pwVersion} not found on npm: ${e.message}`),
  );
  const enginesNode = pwMeta?.engines?.node ?? null;

  // --- 2. which Node major? --------------------------------------------------
  let nodeMajor = FORCED_NODE_MAJOR;
  let nodeSource = "forced via --node";
  if (!nodeMajor) {
    const minMajor = enginesNode
      ? minMajorFromEngines(enginesNode)
      : die(`playwright-core@${pwVersion} declares no engines.node`);
    const index = await fetchJson("https://nodejs.org/dist/index.json").catch(
      (e) => die(`cannot reach nodejs.org/dist: ${e.message}`),
    );
    // index.json is newest-first. Collect the majors that have shipped LTS
    // releases (r.lts is false until the line goes LTS), then prefer the
    // newest LTS major satisfying the engines floor; fall back to the newest
    // even major (the upcoming LTS line) when no LTS qualifies.
    const majorOf = (r) => parseInt(r.version.replace(/^v/, "").split(".")[0], 10);
    const ltsMajors = [
      ...new Set(index.filter((r) => r.lts !== false).map(majorOf)),
    ].filter(Number.isInteger);
    const allMajors = [...new Set(index.map(majorOf))].filter(Number.isInteger);
    const pick = (majors) =>
      majors.filter((m) => m >= minMajor).sort((a, b) => b - a)[0] ?? null;
    nodeMajor = pick(ltsMajors) ?? pick(allMajors.filter((m) => m % 2 === 0));
    if (nodeMajor === null)
      die(
        `no released Node major satisfies "${enginesNode}" (need >= ${minMajor})`,
      );
    nodeSource = ltsMajors.includes(nodeMajor)
      ? `newest Node LTS major >= engines.node "${enginesNode}"`
      : `no LTS major satisfies engines.node "${enginesNode}" -> newest even major`;
  }

  log(`playwright-core ${pwVersion} (engines.node: ${enginesNode ?? "n/a"})`);
  log(`node ${nodeMajor} (${nodeSource})`);

  // --- 3. rewrite the pinned defaults in place -------------------------------
  /** Replace `re` in `file` once; returns true when the file changed. */
  const rewrites = [
    {
      file: "Dockerfile",
      subs: [
        [/^(ARG PLAYWRIGHT_VERSION=)\S*/m, `$1${pwVersion}`],
        [/^(ARG NODE_VERSION=)\S*/m, `$1${nodeMajor}`],
        [
          /^(FROM node:)\d+(-bookworm-slim AS selkies-build)$/m,
          `$1${nodeMajor}$2`,
        ],
      ],
    },
    {
      file: "compose.yaml",
      subs: [
        [
          /^((\s*)PLAYWRIGHT_VERSION: "\$\{PLAYWRIGHT_VERSION:-)[^}]*(\}")$/m,
          `$1${pwVersion}$3`,
        ],
        [/^((\s*)NODE_VERSION: "\$\{NODE_VERSION:-)[^}]*(\}")$/m, `$1${nodeMajor}$3`],
      ],
    },
    {
      file: ".env.example",
      subs: [
        [/^(#PLAYWRIGHT_VERSION=)\S*/m, `$1${pwVersion}`],
        [/^(#NODE_VERSION=)\S*/m, `$1${nodeMajor}`],
      ],
    },
  ];

  let changed = false;
  for (const { file, subs } of rewrites) {
    const abs = path.join(repoRoot, file);
    let text;
    try {
      text = readFileSync(abs, "utf8");
    } catch {
      log(`SKIP ${file} (not found)`);
      continue;
    }
    let next = text;
    for (const [re, replacement] of subs) {
      if (!re.test(next))
        die(`${file}: pattern ${re} not found — update the script`);
      next = next.replace(re, replacement);
    }
    if (next !== text) {
      changed = true;
      if (CHECK_ONLY) {
        log(`DRIFT: ${file} would be updated`);
      } else {
        writeFileSync(abs, next);
        log(`updated ${file}`);
      }
    }
  }
  if (!changed) log("everything already in sync, nothing to do");
  if (CHECK_ONLY && changed)
    die("version drift detected — run: node update-playwright-node.mjs");
}

main().catch((e) => die(e.stack ?? e.message));
