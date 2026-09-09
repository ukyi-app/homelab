// pgdump 헤지 DBS(공백 구분 DB 이름 목록) 편집 SSOT — provision-db(등록)·teardown-resource(해제) 공용.
// DBS는 pgdump-hedge-cronjob.yaml args 스크립트 **본문 안의 셸 변수 한 줄**이고(yaml 값이 아니다 —
// 파서로는 못 만진다), test_pgdump_hedge.bats가 databases/*.yaml과의 **집합 등식**을 강제한다:
// DBS 토큰 집합 == {app} ∪ {`ensure: absent`가 아닌 CR의 metadata.name}. 즉 present CR은 목록에
// 있어야 하고, absent CR은 없어야 하며, **CR이 아예 없는 토큰(유령 DB)도 red**다(상한, 티켓 53
// 2026-09-09 — 그 전까지 분모가 CR 쪽이라 유령 토큰은 어느 DB 개수에서도 통과했다). 그래서 생성/철거가
// 이 줄을 갱신하지 않으면 create-database PR의 required check가 **항상** red다(드릴 실측 2026-09-08 PR #689).
//
// 이 module이 소유하는 것 = **DBS 줄 문법 전부**: 줄 앵커(들여쓰기·인용·뒤따르는 주석 보존) ·
// 항목 경계(공백) · **토큰 동일성**(부분 매치 금지 — `page`는 `pages`에 매치되지 않는다) · 존재 판정.
// 세 문법을 콜사이트가 각자 재유도하면 같은 줄에 서로 다른 문법이 생긴다(선례: lib/digest-exporter.ts).
//
// 추가는 **말미 append**다(정렬하지 않는다): 헤지 루프는 `set -euo pipefail`이라 앞선 DB가 실패하면
// 뒤가 통째로 죽는다 — restore_canary를 담은 부트스트랩 `app`이 선두에 남는 순서가 곧 복구 우선순위다.
// (정렬은 알파벳순으로 새 DB를 app 앞에 세운다.)
const DBS_RE = /^([ \t]*DBS=")([^"\n]*)(".*)$/m;
// 같은 문법의 전역 판 — **매치 개수**를 세기 위한 것이다(아래 matchDbs 주석).
const DBS_RE_ALL = new RegExp(DBS_RE.source, "gm");

// DBS 줄 매치 — 에러 문구가 여기 한 곳뿐이라 모든 진입점이 같은 fail-loud 문구를 낸다.
// 매치는 **정확히 1개**여야 한다:
//   0 = 포맷 드리프트. 조용한 no-op은 "백업 0인데 알림은 녹색"인 무성 갭으로 착지한다.
//   2+ = 첫 줄만 고치고 나머지는 방치된다(String.replace는 비전역 정규식에서 첫 매치만 바꾸고,
//        존재 판정도 첫 줄만 본다). 셸은 마지막 대입이 이기므로 "갱신했다"는 보고와 실제 평가되는
//        목록이 어긋난다 — 절반 갱신은 조용히 지나가면 안 되는 부류다.
function matchDbs(text: string): RegExpMatchArray {
  const all = text.match(DBS_RE_ALL);
  const n = all ? all.length : 0;
  if (n !== 1) throw new Error(`pgdump 헤지 DBS="…" 줄이 ${n}개 — 정확히 1개여야 갱신 가능(포맷 드리프트)`);
  return text.match(DBS_RE)!;
}

const splitDbs = (val: string): string[] => val.trim().split(/\s+/).filter(Boolean);

function edit(text: string, fn: (a: string[]) => string[]): string {
  const next = fn(splitDbs(matchDbs(text)[2]!)).join(" ");
  // 치환은 **콜백**이다 — 문자열 치환자는 `$&`류를 해석하므로 이름이 그대로 실리지 않을 수 있다.
  return text.replace(DBS_RE, (_m, head: string, _val: string, tail: string) => `${head}${next}${tail}`);
}

// 멱등 추가 — 이미 있으면 무변경(재실행 안전).
export function addDb(text: string, name: string): string {
  return edit(text, (a) => (a.includes(name) ? a : [...a, name]));
}
// 멱등 제거 — 부재면 무변경. 토큰 동일성이라 접두가 같은 형제(shared-archive)는 남는다.
export function removeDb(text: string, name: string): string {
  return edit(text, (a) => a.filter((x) => x !== name));
}
// 존재 판정 — `edit`과 **같은 문법**을 지난다. 반환값이 두 사정을 가른다: 부재는 `false`(호출부의
// 정상 no-op), DBS 줄 소실은 `throw`(포맷 드리프트 = 고장). 손 정규식은 그 둘을 같은 무성 경로로 뭉갠다.
export function hasDb(text: string, name: string): boolean {
  return splitDbs(matchDbs(text)[2]!).includes(name);
}
