// active&&public host가 실제로 resolve되는지 확인 — apply 실패로 DNS가 안 생긴 경우(active:true인데 미노출)를
// 잡는다. Cloudflare proxied 레코드는 anycast IP로 뜨므로 "resolve=레코드 존재, NXDOMAIN=미생성"으로 본다.
// resolver는 주입 가능: 라이브는 node:dns, 테스트는 --fixture(host→records|null) JSON.
import { existsSync, readFileSync } from "node:fs";
import { promises as dnsp } from "node:dns";
import { dirname, join } from "node:path";
import { typedFlags } from "./lib/cli.ts";
import { assertFloorKeys, floorOf, takeFloors } from "./lib/scan-floor.ts";

let flags;
let floors: Map<string, number>;
try {
  // 바닥값 오버라이드는 공용 어휘 `--floor <도메인>=<n>`뿐이다(kernel-followups 05 — 구 --min-reserved 폐지).
  const taken = takeFloors(process.argv.slice(2));
  floors = taken.floors;
  flags = typedFlags(taken.rest, {
    value: ["--apps", "--fixture", "--reserved"],
    bool: [],
  });
} catch (e) {
  console.error(e instanceof Error ? e.message : String(e));
  console.error("사용법: dns-drift-check.ts [--apps <path>] [--reserved <path>] [--floor reserved=<n>] [--fixture <json>]");
  process.exit(2);
}
// guardMain은 쓰지 않는다 — 판정이 비동기(resolve await)라 동기 check() 계약 밖이다
// (stdout JSON은 이유가 아니다: output:"none"이 그 용도다 — check-guard-authority 선례).
// 도메인 라벨 상수 — 선언과 조회가 같은 리터럴을 본다(오타 = 조용히 꺼진 바닥값 방지).
const FLOOR_RESERVED = "dns-drift-check:reserved";
try {
  assertFloorKeys(floors, [FLOOR_RESERVED]);
} catch (e) {
  console.error(e instanceof Error ? e.message : String(e));
  process.exit(2);
}
const appsPath = flags.str("--apps", "infra/cloudflare/apps.json")!;
const fixture = flags.str("--fixture");
// 예약 platform host SSOT — 기본은 --apps 형제(reserved-hosts.json).
const reservedPath = flags.str("--reserved", join(dirname(appsPath), "reserved-hosts.json"))!;
// **레인별 바닥값**(합계 바닥값은 작은 레인의 붕괴를 못 잡는다). apps 레인은 정당하게 0일 수 있지만
// (첫 공개 앱 이전) 예약 platform host는 구조적으로 항상 ≥1이다 — 0이면 그건 "검사할 게 없다"가
// 아니라 **파일이 사라졌거나 키가 바뀌었다**는 뜻이고, 그 상태에서 조용히 0건 검사하면 이 체커가
// vacuous해진다. 기본값을 1(fail-closed)로 두고, 픽스처는 `--min-reserved 0`으로 **명시** 해제한다
// (기본이 off면 '조용히 꺼진 바닥값'이 된다 — 같은 클래스의 실측 버그가 있었다. 해제 어휘는
// `--floor reserved=0` — kernel-followups 05).
const minReserved = floorOf(floors, FLOOR_RESERVED, 1);

// resolver: host → 배열(존재) | null(NXDOMAIN) | undefined(transient: SERVFAIL/timeout)
let resolve;
if (fixture !== undefined) {
  const map = JSON.parse(fixture);
  // 테스트용 sentinel: 값이 "TRANSIENT" 문자열이면 undefined(일시 실패)로 매핑(JSON엔 undefined가 없으므로).
  resolve = async (h: string) => {
    if (!Object.prototype.hasOwnProperty.call(map, h)) return null;
    const v = map[h];
    return v === "TRANSIENT" ? undefined : v;
  };
} else {
  resolve = async (h: string) => {
    try { return await dnsp.resolve(h); }                 // A/AAAA — proxied면 Cloudflare anycast IP
    catch (e: any) {
      if (e.code === "ENOTFOUND" || e.code === "ENODATA") return null;  // 레코드 없음(미생성)
      return undefined;                                    // transient(SERVFAIL/timeout) — drift 단정 불가
    }
  };
}

// ── 열거 ── 검사 대상을 먼저 모두 확정하고 바닥값을 건 뒤에 resolve한다. resolve 도중에 세면
// "글롭이 깨져 0건"과 "정당하게 0건"이 같은 초록으로 끝난다(티켓 08의 열거 붕괴 클래스).
const registry = JSON.parse(readFileSync(appsPath, "utf8"));
const appHosts = registry.filter((r: { public?: boolean; active?: boolean }) => r.public && r.active);
// 예약 platform host(reserved-hosts.json SSOT) — 구조적으로 항상 public&&active라 반드시 resolve돼야
// 한다. M11: apps.json만 감시하던 dns-drift가 argocd-webhook/files를 놓치던 갭 해소.
// ⚠️ 파일 **부재**만 빈 목록으로 흡수한다(tmp-fixture는 형제 파일이 없다) — 파싱 실패는 흡수하지
// 않는다. 조용한 []는 "예약 호스트를 0건 검사했다"와 구별되지 않아 정확히 fail-open이다.
// 부재 자체도 드리프트지만 그건 바로 아래 바닥값(minReserved)이 잡는다.
let reservedHosts: string[] = [];
if (existsSync(reservedPath)) {
  reservedHosts = JSON.parse(readFileSync(reservedPath, "utf8")).platform_hosts ?? [];
}
if (reservedHosts.length < minReserved) {
  console.error(`FAIL: 예약 platform host ${reservedHosts.length}건 < ${minReserved} — 열거 붕괴(${reservedPath} 부재/키 변경). 검사가 vacuous해진다.`);
  process.exit(1);
}

const drift = [];       // NXDOMAIN — active:true인데 DNS 레코드 미존재(apply 누락). 이것만 drift로 센다.
const transient = [];   // ⚠️ codex pass4 F3: SERVFAIL/timeout/저하된 resolver — drift로 단정 불가(별도 버킷)
for (const r of appHosts) {                                // dns.tf는 public&&active만 노출
  const recs = await resolve(r.host);
  if (recs === null) drift.push({ host: r.host, name: r.name, reason: "NXDOMAIN — active:true인데 DNS 레코드 미존재(apply 누락 의심)" });
  else if (recs === undefined) transient.push({ host: r.host, name: r.name, reason: "resolve 일시 실패(SERVFAIL/timeout) — drift 아님, 재확인 필요" });
}
for (const host of reservedHosts) {
  const recs = await resolve(host);
  if (recs === null) drift.push({ host, name: "platform", reason: "NXDOMAIN — 예약 platform host인데 DNS 레코드 미존재(apply 누락 의심)" });
  else if (recs === undefined) transient.push({ host, name: "platform", reason: "resolve 일시 실패(SERVFAIL/timeout) — drift 아님, 재확인 필요" });
}
// drift와 transient 분리 출력 — 워크플로는 .drift.length만 drift 알림으로(transient는 별도 경고).
// `scanned`는 스캔 신호다: stdout이 기계 판독 JSON이라 `SCAN:` 마커를 낼 수 없으므로(마커가 출력을
// 오염시킨다 — CONTRIBUTING '가드 스캔 신호') 같은 정보를 페이로드 안에 싣는다.
console.log(JSON.stringify({ scanned: appHosts.length + reservedHosts.length, drift, transient }, null, 2));
