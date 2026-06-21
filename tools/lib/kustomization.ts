// kustomization.yaml resources 리스트 멱등 편집 SSOT — provision(등록)·teardown(해제) 공용.
// parseDocument로 주석/포맷 보존. trailing slash 정규화(인스턴스 디렉토리 name vs name/).
import { parseDocument } from "yaml";

const norm = (v: unknown): string => String(v).replace(/\/$/, "");

export function addResource(kustomizationYaml: string, entry: string): string {
  const doc = parseDocument(kustomizationYaml);
  const seq: any = doc.get("resources");
  const items: any[] = seq?.items ?? [];
  if (items.some((it) => norm(it.value ?? it) === norm(entry))) return kustomizationYaml; // 멱등
  if (!seq) doc.set("resources", [entry]);
  else doc.addIn(["resources"], entry);
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
