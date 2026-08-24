// 스캐폴더 비대화형 계약 SSOT — doctor(사전 진단)와 app init(실제 실행)이 **같은 술어**를
// 공유한다(structure r1 a3: 두 번째 소비자 init이 생겨 추출 — 그전에 만들면 speculative였다).
// 마커는 init이 실제로 scaffold에 넘기는 플래그 전체다: --archetype(아키타입)·--name(앱명)·
// --yes(비대화형 확정). 템플릿 scaffold.ts가 이 플래그들을 해석해야 init이 그 템플릿과 호환된다.
// doctor는 이 계약이 부재하면 fail(init 거부 근거)을, init은 preflight에서 같은 판정을 쓴다 —
// 둘이 갈리면 doctor가 통과시킨 템플릿을 init이 실행 중 거부하는 계약 갭이 생긴다(identity와 같은 원칙).
export const SCAFFOLD_CONTRACT_MARKERS = ["--archetype", "--name", "--yes"] as const;

// scaffold 소스가 계약 마커를 전부 담는지 검사한다. null=호환, 아니면 부재 마커(·구분) 사유.
export function scaffoldContractError(source: string): string | null {
  const absent = SCAFFOLD_CONTRACT_MARKERS.filter((m) => !source.includes(m));
  return absent.length > 0 ? absent.join("·") : null;
}

// 계약 마커의 사람용 표기(doctor detail·init 진단 공유) — "--archetype·--name·--yes".
export const SCAFFOLD_CONTRACT_LABEL = SCAFFOLD_CONTRACT_MARKERS.join("·");
