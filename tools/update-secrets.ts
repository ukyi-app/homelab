// update-secrets 생성기 — 앱 레포의 SealedSecret을 homelab 배포에 검증·복사하고
// values.yaml/envFrom + kustomization.yaml/resources까지 선언적으로 배선한다.
import { copyFileSync, existsSync, readFileSync, writeFileSync } from "node:fs";
import { createHash } from "node:crypto";
import { parse as parseYaml, stringify as toYaml } from "yaml";
import { APP_NAME_RE } from "./lib/identity.ts";
import { parseFlags } from "./lib/cli.ts";
import { addResource } from "./lib/kustomization.ts";

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
const root = arg("--repo-root", ".");
const appRepoRoot = arg("--app-repo-root", ".apprepo");
const dryRun = flags["--dry-run"] === true;

function fail(message: string): never {
  console.error(`::error::update-secrets: ${message}`);
  process.exit(1);
}

if (!app) fail("--app 필수");
if (!APP_NAME_RE.test(app)) fail(`app 이름 불량: '${app}'`);

const appDir = `${root}/apps/${app}/deploy/prod`;
if (!existsSync(appDir)) fail(`미온보딩 앱 '${app}' — create-app 먼저`);

const sealedPath = `${appRepoRoot}/deploy/${app}-secrets.sealed.yaml`;
const dstSealedPath = `${appDir}/${app}-secrets.sealed.yaml`;
const valuesPath = `${appDir}/values.yaml`;
const kustomizationPath = `${appDir}/kustomization.yaml`;

if (!existsSync(sealedPath)) fail(`${sealedPath} 없음 — 앱 레포에서 pnpm secret:seal 먼저`);
if (!existsSync(valuesPath)) fail(`${valuesPath} 없음`);
if (!existsSync(kustomizationPath)) fail(`${kustomizationPath} 없음`);

const sealedYaml = readFileSync(sealedPath, "utf8");
const sealedDoc = parseYaml(sealedYaml) ?? {};
if (sealedDoc?.kind !== "SealedSecret") fail("sealed 파일이 kind: SealedSecret이 아니다");
if (sealedDoc?.metadata?.namespace !== "prod") fail(`sealed namespace는 prod여야 한다(strict-scope): ${sealedDoc?.metadata?.namespace}`);
if (sealedDoc?.metadata?.name !== `${app}-secrets`) fail(`sealed name은 ${app}-secrets여야 한다: ${sealedDoc?.metadata?.name}`);

const sealedKeys = Object.keys(sealedDoc?.spec?.encryptedData ?? {}).sort();
if (sealedKeys.length === 0) fail("sealed encryptedData가 비어 있다");
const badKeys = sealedKeys.filter((key) => !/^[A-Z][A-Z0-9_]*$/.test(key));
if (badKeys.length) fail(`sealed encryptedData 키는 UPPER_SNAKE여야 한다: ${badKeys.join(", ")}`);
const deniedKeys = sealedKeys.filter((key) => key === "DATABASE_ADMIN_URL");
if (deniedKeys.length) fail(`앱 런타임 봉인 금지 키: ${deniedKeys.join(", ")}`);

const checksum = createHash("sha256").update(sealedYaml).digest("hex").slice(0, 16);
const secretName = `${app}-secrets`;
const sealedFile = `${secretName}.sealed.yaml`;

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
  copyFileSync(sealedPath, dstSealedPath);
  writeFileSync(valuesPath, toYaml(values));
  writeFileSync(kustomizationPath, kustomization);
}

console.log(JSON.stringify({ app, secret: secretName, keys: sealedKeys, checksum, dryRun }, null, 2));
