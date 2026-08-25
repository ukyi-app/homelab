// 디스크 자기-상한 ↔ 볼륨 선언 정합 게이트 (D-4).
//
// 병: 워크로드가 **자기 데이터 크기 상한**을 바이트로 선언하는데(예 VictoriaLogs
// `-retention.maxDiskSpaceUsageBytes`), 그 값이 **자기가 쓰는 볼륨의 선언 용량보다 클 수** 있다.
// 그러면 같은 파일이 서로 모순된 두 숫자를 말한다 — "이 볼륨은 10Gi다"와 "내 데이터가 15GB 될
// 때까지 축출하지 않는다". 라이브 실측(2026-07-29): victorialogs가 정확히 그 상태였고(비율 139.7%)
// 전 게이트가 초록이었다.
//
// ⚠️ **왜 "언젠가 터진다"가 아니라 지금 결함인가.** 실측상 그 상한은 한 번도 발동한 적이 없다
//    (축출은 전부 `retentionPeriod`가 하고, 실사용은 상한의 1/69다). 그래도 결함인 이유:
//    ① 용량 계획이 PVC 숫자를 읽으면 틀린 답을 얻는다 ② 쿼터를 강제하는 provisioner로 바뀌는
//    순간 앱은 15GB까지 쓸 수 있다고 믿는 채로 볼륨 한계에서 ENOSPC를 맞는다 ③ 형제 선언
//    (vmagent 450MiB < 512Mi emptyDir)은 올바른 방향이라 **비대칭 자체가 갭의 증거**다.
//
// ⚠️ **단위 혼동이 이 결함의 핵심이다.** `GB`=10⁹ · `Gi`=2³⁰. 15GB(1.50e10)는 10Gi(1.07e10)보다
//    크다 — 접미사만 훑으면 "15 > 10"으로도 "GB < Gi"로도 잘못 읽힌다. 반드시 **바이트로 환산**한다.
//
// ⚠️ **존재 grep으로 만들면 안 된다.** `tests/gates/test_vmalert-config.bats`가 이미
//    `grep -q maxDiskUsagePerURL` 형태인데, 450MiB를 900MiB로 바꿔도 초록이고 victorialogs의
//    위반도 못 잡았다. 규범은 `docs/traps-detail.md`에 문장으로 있었다 — **빠진 것은 규범이 아니라 강제다.**
//
// 열거는 공유 워커의 `platform-manifests` 스코프가 소유한다(tracked · charts/·벤더 제외).

import { walkManifests } from "./lib/repo-walk.ts";
import { guardMain } from "./lib/scan-floor.ts";

const ROOT = process.cwd();

// 상한 플래그는 **패턴으로 발견**한다. 새 플래그가 생겨도 이름에 `maxDisk`가 들어가면 자동 편입된다.
// (하드코딩 목록을 두면 그 목록이 곧 다음 드리프트다 — 이 레포가 반복해서 맞은 클래스.)
const CAP_FLAG = /--[A-Za-z.]*maxDisk[A-Za-z]*=\s*([0-9]+(?:\.[0-9]+)?)\s*([KMGTP]?i?B?)\b/g;

// 볼륨 선언: PVC `requests: { storage: <v> }` · emptyDir `sizeLimit: <v>`
const VOL_DECL = /(?:storage|sizeLimit)\s*:\s*([0-9]+(?:\.[0-9]+)?)\s*([KMGTP]?i?)\b/g;

// 현재 대상 2건(victorialogs · vmagent). 0이면 정규식/스코프가 붕괴한 것이지 "위반 없음"이 아니다.
const MIN_FLAGS = Number(process.env.DISK_CAP_MIN_FLAGS ?? "2");

// SI(10ⁿ) vs IEC(2ⁿ). 접미사가 `i`를 포함하면 IEC다. 접미사 없으면 바이트.
function toBytes(num: string, unit: string): number | null {
  const n = Number(num);
  if (!Number.isFinite(n)) return null;
  const u = unit.replace(/B$/, ""); // "GiB"→"Gi", "GB"→"G", "B"→""
  if (u === "") return n;
  const iec = u.endsWith("i");
  const sym = iec ? u.slice(0, -1) : u;
  const idx = ["K", "M", "G", "T", "P"].indexOf(sym.toUpperCase());
  if (idx < 0) return null;
  return n * Math.pow(iec ? 1024 : 1000, idx + 1);
}

const human = (b: number) => (b >= 2 ** 30 ? `${(b / 2 ** 30).toFixed(2)}Gi` : `${(b / 2 ** 20).toFixed(1)}Mi`);

const bad: string[] = [];
let fileCount = 0;

// 실행 순서(전 도메인 열거 → 전 floor 판정 → SCAN 일괄 방출 → 검사 → 종료코드)는 guardMain이
// 구조로 소유한다 — 워커 throw의 fail-loud 포함(삼키면 0건 열거 후 초록이 되는 vacuous-green
// 클래스). 위반·성공 문구와 **위반의** ::error:: 채널은 이 콜사이트 소유이고, 바닥값·열거 실패
// 진단은 커널이 stderr `FAIL:`로 낸다(셸 커널과 어휘 통일 — 붕괴 경로의 GH annotation은 의도적 미사용).
guardMain({
  domains: [{
    scan: "check-disk-caps:caps",
    min: MIN_FLAGS,
    floorHint: '정규식 드리프트·스코프 변경 — 이 상태의 "위반 0건"은 통과가 아니라 무측정이다',
    enumerate: () => {
      let flagCount = 0;
      for (const entry of walkManifests("platform-manifests", ROOT)) {
        const file = entry.path;
        const text = entry.text;
        CAP_FLAG.lastIndex = 0;
        const caps: { raw: string; bytes: number }[] = [];
        for (const m of text.matchAll(CAP_FLAG)) {
          const b = toBytes(m[1]!, m[2]!);
          if (b === null) {
            bad.push(`${file}: 상한 '${m[0]}'의 단위를 해석할 수 없다 — 판정 불가(fail-closed).`);
            continue;
          }
          caps.push({ raw: `${m[1]}${m[2]}`, bytes: b });
        }
        if (caps.length === 0) continue;
        fileCount++;
        flagCount += caps.length;

        VOL_DECL.lastIndex = 0;
        const vols: { raw: string; bytes: number }[] = [];
        for (const m of text.matchAll(VOL_DECL)) {
          const b = toBytes(m[1]!, m[2]!);
          if (b !== null) vols.push({ raw: `${m[1]}${m[2]}`, bytes: b });
        }
        // ⚠️ 볼륨 선언을 못 찾으면 **통과시키지 않는다.** "비교 대상이 없다"는 곧 판정 불가이고,
        //    조용히 넘기면 상한이 아무 볼륨에도 묶이지 않은 채 초록이 된다(무측정).
        if (vols.length === 0) {
          bad.push(
            `${file}: 디스크 상한(${caps.map((c) => c.raw).join(", ")})이 있는데 같은 파일에 볼륨 크기 선언` +
              `(PVC requests.storage 또는 emptyDir sizeLimit)이 없다 — 무엇과 비교해야 하는지 알 수 없다.`,
          );
          continue;
        }
        // 파일 안에 볼륨이 여럿이면 **가장 작은 것**과 비교한다(보수적). 두 사례 모두 볼륨이 하나다.
        const min = vols.reduce((a, b2) => (b2.bytes < a.bytes ? b2 : a));
        for (const c of caps) {
          if (c.bytes >= min.bytes) {
            bad.push(
              `${file}: 디스크 상한 ${c.raw}(${human(c.bytes)})가 볼륨 선언 ${min.raw}(${human(min.bytes)}) 이상이다 ` +
                `— 비율 ${((c.bytes / min.bytes) * 100).toFixed(1)}%. 같은 파일이 모순된 두 숫자를 말한다.\n` +
                `    → 상한을 볼륨 선언보다 **작게** 내려라(선례: vmagent 450MiB < 512Mi emptyDir).\n` +
                `    ⚠️ PVC requests.storage는 **축소 불가**(확장 전용)라 볼륨 쪽을 올려 맞추면 되돌릴 수 없다.\n` +
                `    ⚠️ 단위: GB=10⁹ · Gi=2³⁰ — 접미사만 보면 15GB < 10Gi로 잘못 읽힌다.`,
            );
          }
        }
      }
      return flagCount;
    },
  }],
  output: "stdout",
  check: () => bad,
  report: (viol) => {
    for (const b of viol) console.error(`::error::disk-caps: ${b}`);
    console.error(`\ncheck-disk-caps: ${viol.length}건 실패`);
  },
  ok: (counts) => console.log(`check-disk-caps OK (파일 ${fileCount}개 · 상한 ${counts[0]}건 전건이 볼륨 선언 미만)`),
});
