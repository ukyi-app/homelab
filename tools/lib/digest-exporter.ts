// digest-exporter APPS(공백 구분 "name=ref" 목록) 편집 SSOT — create-app/teardown-app/bump-tag 공용.
// APPS는 digest-exporter.yaml CronJob env의 단일 문자열 value. R6 ImageDigestDrift가 이 목록의 각 앱
// 최신 GHCR digest를 조회하므로, 앱 생성/철거 시 목록을 함께 갱신해야 drift 감시가 정확하다(parity 게이트가 강제).
// value 라인을 정규식으로 겨냥, 매치 0이면 throw(fail-loud — 포맷 드리프트로 silent no-op 차단). 이름 정렬 결정론.
// 이 module이 소유하는 것 = **APPS 리스트 문법 전부**: 항목 경계(공백) · 이름 키(`=` 앞) · ref 표기
// (`<repo>:<tag>`) · 존재 판정. 세 쓰기 주체가 각자 재유도하면 같은 목록에 서로 다른 문법이 생긴다.
const APPS_RE = /(- name: APPS\n\s+value: ")([^"]*)(")/;
type Entry = { name: string; ref: string };

// APPS value 라인 매치 — 에러 문구가 여기 한 곳뿐이라 모든 진입점이 같은 fail-loud 문구를 낸다.
function matchApps(text: string): RegExpMatchArray {
  const m = text.match(APPS_RE);
  if (!m) throw new Error("digest-exporter APPS(value) 라인을 찾지 못함 — 포맷 드리프트로 갱신 불가");
  return m;
}
function splitApps(val: string): Entry[] {
  return val.trim().split(/\s+/).filter(Boolean).map((e) => {
    const i = e.indexOf("=");
    return { name: e.slice(0, i), ref: e.slice(i + 1) };
  });
}
function edit(text: string, fn: (a: Entry[]) => Entry[]): string {
  const m = matchApps(text);
  // ⚠️ `localeCompare`가 아니라 **코드유닛 비교**다. 이 값은 매니페스트에 쓰이는 산출물이라 순서가
  //    환경에 따라 흔들리면 안 되는데, `localeCompare`의 기본 로케일은 런타임 ICU가 정하고
  //    `LANG`/`LC_ALL`에 반응하지도 않는다(실측: en_US/C.UTF-8/tr_TR/de_DE 4종 동일 — 즉 셸 쪽을
  //    `LC_ALL=C`로 고정해도 이쪽만 따로 논다). 코드유닛 비교는 `LC_ALL=C sort`와 동형이라
  //    셸 대조와 정의상 일치한다. cf. `docs/traps-detail.md` 「로케일 콜레이션이 게이트를 뒤집는다 …」
  const next = fn(splitApps(m[2])).sort((a, b) => (a.name < b.name ? -1 : a.name > b.name ? 1 : 0))
    .map((a) => `${a.name}=${a.ref}`).join(" ");
  return text.replace(APPS_RE, `$1${next}$3`);
}
export function addApp(text: string, name: string, ref: string): string {
  return edit(text, (a) => (a.some((x) => x.name === name) ? a : [...a, { name, ref }]));
}
export function removeApp(text: string, name: string): string {
  return edit(text, (a) => a.filter((x) => x.name !== name));
}
// 항목 존재 판정 — `edit`과 **같은 문법**(같은 APPS_RE · 같은 splitApps)을 지난다. 반환값이 두 사정을
// 가른다: 부재는 `false`(호출부의 정상 no-op), APPS 라인 소실은 `throw`(포맷 드리프트 = 고장).
// 손으로 짠 부분매치 정규식은 이 둘을 같은 무성 경로로 뭉갠다 — bump-tag가 그래서 이 함수를 쓴다.
export function hasApp(text: string, name: string): boolean {
  return splitApps(matchApps(text)[2]).some((x) => x.name === name);
}
// ref의 **태그만** 교체한다(repo 부분 보존). 태그 경계는 마지막 `/` 뒤의 `:` 하나뿐 — 포트를 포함한
// 레지스트리(`reg.io:443/o/n`)의 콜론을 태그로 오인하지 않기 위한 OCI 규칙이고, image-pin의
// non-greedy `(.+?)`가 `:sha-` 경계를 잡는 것과 같은 판단이다. 태그가 없던 ref에는 붙인다.
function retagRef(ref: string, tag: string): string {
  const colon = ref.lastIndexOf(":");
  return colon > ref.lastIndexOf("/") ? `${ref.slice(0, colon)}:${tag}` : `${ref}:${tag}`;
}
// 이름이 일치하는 항목의 태그를 옮긴다(bump-tag의 신선도 동기). 항목 부재 = 집합 무변경.
// 옛 태그의 **모양을 보지 않는다** — 항목이 목록에 있다는 사실만으로 교체하므로, 태그 포맷이
// 드리프트했거나 owner가 다른 ref도 stale로 남지 않는다(손 정규식이 조용히 놓치던 자리).
export function retagApp(text: string, name: string, tag: string): string {
  return edit(text, (a) => a.map((x) => (x.name === name ? { name: x.name, ref: retagRef(x.ref, tag) } : x)));
}
