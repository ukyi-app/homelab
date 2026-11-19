// 올리브 실행 대상 목록. platform/olive/targets.yaml을 빌드할 때 실행 파일에 넣는다.
// GitHub에 연결할 수 없어도 상태를 조회할 수 있도록 빌드할 때 대상 목록을 포함한다.
// 함정: CLI를 다시 설치할 때까지 설치된 실행 파일은 이전 목록의 대상만 조회한다.
// 모양이 틀려도 모든 명령이 시작부터 죽지 않게 읽을 때 검사한다(doctor 같은 명령은 이 목록을 쓰지 않는다).
import doc from "../../../platform/olive/targets.yaml";
import { isArray } from "./intrinsics";

export type OliveTarget = { id: string; kind: string; namespace: string; deployment: string; declaredBy: string; stop: boolean; start: boolean };

// core/olive.ts가 받는 이름 꼴과 같다.
const LABEL = /^[a-z0-9]([-a-z0-9]*[a-z0-9])?$/;
const isLabel = (v: unknown): v is string => typeof v === "string" && v.length <= 63 && LABEL.test(v);

export function parseOliveTargets(raw: unknown): OliveTarget[] {
  const list = (raw as { targets?: unknown } | null)?.targets;
  if (!isArray(list) || list.length === 0) throw new Error("올리브 대상 목록이 비었거나 꼴이 다르다");
  const seen = new Set<string>();
  return list.map((t: any, i: number) => {
    const ok = isLabel(t?.id) && typeof t?.kind === "string" && isLabel(t?.namespace) && isLabel(t?.deployment) && typeof t?.declaredBy === "string" && typeof t?.stop === "boolean" && typeof t?.start === "boolean";
    if (!ok) throw new Error(`올리브 대상 ${i + 1}번째 줄의 꼴이 다르다`);
    if (seen.has(t.id)) throw new Error(`올리브 대상 이름이 겹친다: ${t.id}`);
    seen.add(t.id);
    return { id: t.id, kind: t.kind, namespace: t.namespace, deployment: t.deployment, declaredBy: t.declaredBy, stop: t.stop, start: t.start };
  });
}

export const oliveTargets = (): OliveTarget[] => parseOliveTargets(doc);
