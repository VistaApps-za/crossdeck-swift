#!/usr/bin/env node
/**
 * Emit `Sources/Crossdeck/Resources/contracts.json` — the SDK
 * sidecar consumed by the public `CrossdeckContracts` API. The
 * file is committed and re-emitted by this script; CI runs the
 * monorepo-level `contract-audit` to ensure it stays in lockstep
 * with `contracts/**\/*.json`.
 *
 * SwiftPM has no pre-build hook concept, so emission is manual or
 * CI-driven rather than a `swift build` side-effect. The committed
 * JSON is what ships in the binary via Package.swift's
 * `.copy("Resources/contracts.json")` resource entry.
 *
 * Source of truth: `contracts/**\/*.json` at the monorepo root.
 * Filters by `appliesTo` containing "swift" and stamps `bundledIn`
 * from `_Version.swift` parsed inline (kept in lockstep with the
 * other SDKs' version constants by `scripts/sync-sdk-versions.mjs`).
 */
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const sdkRoot = path.resolve(__dirname, "..");
const resourcesDir = path.join(sdkRoot, "Sources", "Crossdeck", "Resources");
const repoRoot = path.resolve(sdkRoot, "../..");
const contractsRoot = path.join(repoRoot, "contracts");
const target = path.join(resourcesDir, "contracts.json");

const SDK_IDENTIFIER = "swift";

function readSdkVersion() {
  const versionFile = path.join(
    sdkRoot,
    "Sources",
    "Crossdeck",
    "_Version.swift",
  );
  const src = fs.readFileSync(versionFile, "utf8");
  const match = src.match(/version\s*=\s*"([^"]+)"/);
  if (!match) {
    console.error(`[emit-contracts] could not parse version from _Version.swift`);
    process.exit(1);
  }
  return match[1];
}

function collectContracts(dir) {
  const found = [];
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) found.push(...collectContracts(full));
    else if (entry.isFile() && entry.name.endsWith(".json")) found.push(full);
  }
  return found;
}

const sdkVersion = readSdkVersion();
const bundledIn = `@cross-deck/${SDK_IDENTIFIER}@${sdkVersion}`;

if (!fs.existsSync(resourcesDir)) {
  fs.mkdirSync(resourcesDir, { recursive: true });
}

const matching = [];
for (const file of collectContracts(contractsRoot)) {
  const parsed = JSON.parse(fs.readFileSync(file, "utf8"));
  if (!Array.isArray(parsed?.appliesTo)) {
    console.error(`[emit-contracts] ${file} missing appliesTo`);
    process.exit(1);
  }
  if (parsed.appliesTo.includes(SDK_IDENTIFIER)) {
    matching.push({ ...parsed, bundledIn });
  }
}
matching.sort((a, b) => a.id.localeCompare(b.id));

const payload = {
  $schema: "https://json-schema.org/draft/2020-12/schema",
  generatedAt: new Date().toISOString(),
  sdk: `@cross-deck/${SDK_IDENTIFIER}`,
  sdkVersion,
  bundledIn,
  count: matching.length,
  contracts: matching,
};

fs.writeFileSync(target, JSON.stringify(payload, null, 2) + "\n", "utf8");
console.log(
  `[emit-contracts] wrote ${matching.length} contracts (appliesTo includes "${SDK_IDENTIFIER}") to Sources/Crossdeck/Resources/contracts.json`,
);
