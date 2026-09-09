// kustomization.yaml resources 리스트 멱등 편집 SSOT — provision(등록)·teardown(해제) 공용.
// parseDocument로 주석/포맷 보존. trailing slash 정규화(인스턴스 디렉토리 name vs name/).
import { parseDocument } from "yaml";

const norm = (v: unknown): string => String(v).replace(/\/$/, "");

export function addResource(kustomizationYaml: string, entry: string): string {
  const doc = parseDocument(kustomizationYaml);
  const seq: any = doc.get("resources");
  const items: any[] = seq?.items ?? [];
  if (items.some((it) => norm(it.value ?? it) === norm(entry))) return kustomizationYaml; // 멱등
  // 키가 없으면(값 null 포함) 새 시퀀스 노드를 만들어 등록하고, 있으면 기존 노드에 추가한다.
  // 두 경로 모두 **같은 노드**에 flow=false를 걸어 block 스타일로 정규화한다 — 그 줄이 없으면
  // purge cleanup이 남긴 `resources: []`(빈 flow)에서 yaml이 flow를 유지해 `resources: [a, b]`로
  // 되살아난다(렌더는 같아도 표기 drift·diff 노이즈). provision-db.ts 자체 헬퍼와 같은 규약.
  // ⚠️ doc.set("resources", [entry])의 평문 배열은 YAMLSeq가 아니라 JS Array로 트리에 들어가
  //    flow 대입이 조용한 no-op이 된다 — createNode로 노드를 실체화해 그 자리를 막는다.
  const seqNode: any = seq ?? doc.createNode([entry]);
  if (seq) doc.addIn(["resources"], entry);
  else doc.set("resources", seqNode);
  seqNode.flow = false;
  return doc.toString();
}

export function removeResource(kustomizationYaml: string, entry: string): string {
  const doc = parseDocument(kustomizationYaml);
  const seq: any = doc.get("resources");
  if (!seq?.items) return kustomizationYaml;
  const idx = seq.items.findIndex((it: any) => norm(it.value ?? it) === norm(entry));
  if (idx < 0) return kustomizationYaml; // 멱등 — 부재면 no-op
  doc.deleteIn(["resources", idx]);
  return doc.toString();
}
