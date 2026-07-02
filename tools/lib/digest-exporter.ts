// digest-exporter APPS(공백 구분 "name=ref" 목록) 편집 SSOT — create-app/teardown-app 공용.
// APPS는 digest-exporter.yaml CronJob env의 단일 문자열 value. R6 ImageDigestDrift가 이 목록의 각 앱
// 최신 GHCR digest를 조회하므로, 앱 생성/철거 시 목록을 함께 갱신해야 drift 감시가 정확하다(parity 게이트가 강제).
// value 라인을 정규식으로 겨냥, 매치 0이면 throw(fail-loud — 포맷 드리프트로 silent no-op 차단). 이름 정렬 결정론.
const APPS_RE = /(- name: APPS\n\s+value: ")([^"]*)(")/;
type Entry = { name: string; ref: string };

function splitApps(val: string): Entry[] {
  return val.trim().split(/\s+/).filter(Boolean).map((e) => {
    const i = e.indexOf("=");
    return { name: e.slice(0, i), ref: e.slice(i + 1) };
  });
}
function edit(text: string, fn: (a: Entry[]) => Entry[]): string {
  const m = text.match(APPS_RE);
  if (!m) throw new Error("digest-exporter APPS(value) 라인을 찾지 못함 — 포맷 드리프트로 갱신 불가");
  const next = fn(splitApps(m[2])).sort((a, b) => a.name.localeCompare(b.name))
    .map((a) => `${a.name}=${a.ref}`).join(" ");
  return text.replace(APPS_RE, `$1${next}$3`);
}
export function addApp(text: string, name: string, ref: string): string {
  return edit(text, (a) => (a.some((x) => x.name === name) ? a : [...a, { name, ref }]));
}
export function removeApp(text: string, name: string): string {
  return edit(text, (a) => a.filter((x) => x.name !== name));
}
