// verify-db-marker — per-DB freshness 마커(db-<name>-ready) 소비자 (adversarial pass4).
// ensure-role-password PostSync hook Job이 방출한 마커가 (a) 존재하고 (b) 기록된 resourceVersion이
// 현재 owner/ro 비번 Secret의 resourceVersion과 일치(=fresh)함을 확인한다. 일반 Job 성공이나 무관한
// 카나리 readiness가 아니라 '대상 DB로 키된' 신선한 마커만 온보딩/노출을 통과시킨다 — stale한 이전
// 검증/무관 신호로 통과되는 레이스를 차단한다.
//
// 권위: ensure-role-password Job의 passwordStatus.<role>.resourceVersion == 적용된 비번 Secret의
// metadata.resourceVersion(라이브 확인). 마커는 그 값을 기록하고, 이 도구는 현재 Secret rv와 대조한다.
// owner-local(admin kubeconfig) — DB가 'usable'한지의 단일 권위. WS2 온보딩 수용/activation이 호출.
import { execFileSync } from "node:child_process";
import { RESOURCE_NAME_RE } from "./lib/identity.ts";

function die(msg: string): never { console.error(`verify-db-marker: ${msg}`); process.exit(1); }

const args: Record<string, string> = {};
const argv = process.argv.slice(2);
for (let i = 0; i < argv.length; i++) {
  const a = argv[i];
  if (a.startsWith("--")) args[a.slice(2)] = argv[++i];
  else die(`알 수 없는 인자: ${a}`);
}
const name = args.name;
const ns = args.namespace ?? "database";
if (!name) die("--name <db> 필수");
if (!RESOURCE_NAME_RE.test(name)) die(`db 이름 형식 불량: ${name}`);

const kubectl = (...a: string[]) => execFileSync("kubectl", a, { encoding: "utf8" });

// 마커 ConfigMap — 부재면 DB가 아직 verified되지 않음(ensure-role-password 미완료/실패) = fail-closed
let markerJson: string;
try {
  markerJson = kubectl("-n", ns, "get", "configmap", `db-${name}-ready`, "-o", "json");
} catch {
  die(`마커 ConfigMap db-${name}-ready 부재 — DB가 아직 verified되지 않음(ensure-role-password 미완료/실패). 온보딩 진행 금지`);
}
const data: Record<string, string> = (JSON.parse(markerJson).data ?? {});
const markerOwner = data.ownerSecretResourceVersion;
const markerRo = data.roSecretResourceVersion;
if (markerOwner === undefined || markerRo === undefined)
  die(`마커 db-${name}-ready가 불완전(owner/ro resourceVersion 누락)`);

// 현재 비번 Secret resourceVersion (값은 읽지 않고 metadata만)
const curOwner = kubectl("-n", ns, "get", "secret", `db-${name}-owner`, "-o", "jsonpath={.metadata.resourceVersion}").trim();
const curRo = kubectl("-n", ns, "get", "secret", `db-${name}-ro`, "-o", "jsonpath={.metadata.resourceVersion}").trim();

// freshness — 마커 rv == 현재 secret rv 여야 한다(불일치 = 회전 후 미재검증/무관 마커)
if (markerOwner !== curOwner)
  die(`stale 마커: owner rv=${markerOwner} ≠ 현재 secret rv=${curOwner} (db-${name}-owner) — 회전 후 재검증 필요`);
if (markerRo !== curRo)
  die(`stale 마커: ro rv=${markerRo} ≠ 현재 secret rv=${curRo} (db-${name}-ro) — 회전 후 재검증 필요`);

console.log(JSON.stringify({ ok: true, name, namespace: ns, ownerRv: curOwner, roRv: curRo, verifiedAt: data.verifiedAt ?? null }));
