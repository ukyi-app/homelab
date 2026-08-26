// update-secrets 생성기 — 앱 레포의 SealedSecret을 homelab 배포에 검증·복사하고
// values.yaml/envFrom + kustomization.yaml/resources까지 선언적으로 배선한다.
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { parse as parseYaml, stringify as toYaml } from "yaml";
import { APP_NAME_RE } from "./lib/identity.ts";
import { appPaths } from "./lib/app-surface.ts";
import { parseFlags } from "./lib/cli.ts";
import { addResource } from "./lib/kustomization.ts";
import { readSealed } from "./lib/sealed-contract.ts";

let flags: Record<string, string | boolean>;
try {
  flags = parseFlags(process.argv.slice(2), {
    value: ["--app", "--repo-root", "--app-repo-root"],
    bool: ["--dry-run"],
  });
} catch (e) {
  console.error(`${e instanceof Error ? e.message : String(e)}\n허용: --app --repo-root --app-repo-root --dry-run`);
  process.exit(2);
}

const arg = (key: string, fallback?: string) => (typeof flags[key] === "string" ? flags[key] as string : fallback);
const app = arg("--app");
const root = arg("--repo-root") ?? ".";
const appRepoRoot = arg("--app-repo-root", ".apprepo");
const dryRun = flags["--dry-run"] === true;

function fail(message: string): never {
  console.error(`::error::update-secrets: ${message}`);
  process.exit(1);
}

if (!app) fail("--app 필수");
if (!APP_NAME_RE.test(app)) fail(`app 이름 불량: '${app}'`);

// 앱 표면 경로는 app-surface module 소유(d4) — 이 도구는 기존 표면의 **부분 갱신**(봉인본 교체 +
// values checksum + kustomization resources)이라 쓰기 로직은 여기 남는다(writeAppSurface는 생성 전용).
const p = appPaths(root, app);
if (!existsSync(p.prod)) fail(`미온보딩 앱 '${app}' — create-app 먼저`);

const sealedPath = `${appRepoRoot}/deploy/${app}-secrets.sealed.yaml`;
const dstSealedPath = p.sealed(`${app}-secrets.sealed.yaml`);
const valuesPath = p.values;
const kustomizationPath = p.kustomization;

if (!existsSync(sealedPath)) fail(`${sealedPath} 없음 — 앱 레포에서 bun run secret:seal 먼저`);
if (!existsSync(valuesPath)) fail(`${valuesPath} 없음`);
if (!existsSync(kustomizationPath)) fail(`${kustomizationPath} 없음`);

// 봉인 계약 커널이 검증·checksum·디스크 바이트를 소유(create-app과 같은 구현). ::error:: 접두는 콜사이트 소유.
const r = readSealed(readFileSync(sealedPath, "utf8"), app);
if (!r.ok) fail(r.why);
const { keys: sealedKeys, checksum, secretName, sealedFile, bytes } = r.facts;

const values = parseYaml(readFileSync(valuesPath, "utf8")) ?? {};
if (values.envFrom != null && !Array.isArray(values.envFrom)) fail("values.yaml envFrom은 배열이어야 한다");
const envFrom = Array.isArray(values.envFrom) ? values.envFrom : [];
if (!envFrom.some((entry: any) => entry?.secretRef?.name === secretName)) {
  envFrom.push({ secretRef: { name: secretName } });
}
values.envFrom = envFrom;
values.podAnnotations = values.podAnnotations && typeof values.podAnnotations === "object" && !Array.isArray(values.podAnnotations)
  ? values.podAnnotations
  : {};
values.podAnnotations["checksum/secrets"] = checksum;

const kustomization = addResource(readFileSync(kustomizationPath, "utf8"), sealedFile);

if (!dryRun) {
  writeFileSync(dstSealedPath, bytes); // 원본 바이트 그대로(facts.bytes = checksum 소스와 동일 — #299 정합)
  writeFileSync(valuesPath, toYaml(values));
  writeFileSync(kustomizationPath, kustomization);
}

console.log(JSON.stringify({ app, secret: secretName, keys: sealedKeys, checksum, dryRun }, null, 2));
