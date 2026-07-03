// active&&public host가 실제로 resolve되는지 확인 — apply 실패로 DNS가 안 생긴 경우(active:true인데 미노출)를
// 잡는다. Cloudflare proxied 레코드는 anycast IP로 뜨므로 "resolve=레코드 존재, NXDOMAIN=미생성"으로 본다.
// resolver는 주입 가능: 라이브는 node:dns, 테스트는 --fixture(host→records|null) JSON.
import { readFileSync } from "node:fs";
import { promises as dnsp } from "node:dns";
import { dirname, join } from "node:path";

const arg = (k: string) => { const i = process.argv.indexOf(k); return i > -1 ? process.argv[i + 1] : undefined; };
const appsPath = arg("--apps") ?? "infra/cloudflare/apps.json";
const fixture = arg("--fixture");
// 예약 platform host SSOT — 기본은 --apps 형제(reserved-hosts.json). 형제 부재면 빈 목록(tmp-fixture 회귀 0).
const reservedPath = arg("--reserved") ?? join(dirname(appsPath), "reserved-hosts.json");

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

const registry = JSON.parse(readFileSync(appsPath, "utf8"));
const drift = [];       // NXDOMAIN — active:true인데 DNS 레코드 미존재(apply 누락). 이것만 drift로 센다.
const transient = [];   // ⚠️ codex pass4 F3: SERVFAIL/timeout/저하된 resolver — drift로 단정 불가(별도 버킷)
for (const r of registry) {
  if (!(r.public && r.active)) continue;                   // dns.tf는 public&&active만 노출
  const recs = await resolve(r.host);
  if (recs === null) drift.push({ host: r.host, name: r.name, reason: "NXDOMAIN — active:true인데 DNS 레코드 미존재(apply 누락 의심)" });
  else if (recs === undefined) transient.push({ host: r.host, name: r.name, reason: "resolve 일시 실패(SERVFAIL/timeout) — drift 아님, 재확인 필요" });
}
// 예약 platform host(reserved-hosts.json SSOT) — 구조적으로 항상 public&&active라 반드시 resolve돼야
// 한다. M11: apps.json만 감시하던 dns-drift가 argocd-webhook/files를 놓치던 갭 해소. 파일 부재는
// 빈 목록(tmp-fixture 테스트 무영향 — 형제 파일 없음).
let reservedHosts: string[] = [];
try { reservedHosts = JSON.parse(readFileSync(reservedPath, "utf8")).platform_hosts ?? []; } catch { reservedHosts = []; }
for (const host of reservedHosts) {
  const recs = await resolve(host);
  if (recs === null) drift.push({ host, name: "platform", reason: "NXDOMAIN — 예약 platform host인데 DNS 레코드 미존재(apply 누락 의심)" });
  else if (recs === undefined) transient.push({ host, name: "platform", reason: "resolve 일시 실패(SERVFAIL/timeout) — drift 아님, 재확인 필요" });
}
// drift와 transient 분리 출력 — 워크플로는 .drift.length만 drift 알림으로(transient는 별도 경고).
console.log(JSON.stringify({ drift, transient }, null, 2));
