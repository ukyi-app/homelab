// 출력 계층. stdout·stderr에 쓰는 곳은 이 파일 하나다(정적 시험이 다른 곳의 console·process.stdout을 막는다).
// stdout에는 결과 하나만(사람용 또는 JSON 문서 하나), 진행 줄과 경고는 stderr.
// 시크릿 차단 두 겹: Result 안에 Secret 객체가 있으면 렌더하지 않고, 렌더한 글자에 추적 중인 원문이 있으면 내보내지 않는다.
import { findSecretPath } from "./guard";
import { containsTracked } from "./secret";
import type { Result, StepResult } from "./result";

export const SCHEMA = "homelab-cli/v1";

export class OutputBlocked extends Error {}

// 어느 단계가 값을 섞었는지만 알려 준다(값은 찍지 않는다).
export function secretProblem(r: Result): string | null {
  const obj = findSecretPath(r, "result");
  if (obj) return `${obj}에 시크릿 객체가 있다`;
  for (const s of r.steps) if (containsTracked(JSON.stringify(s))) return `단계 ${s.id}`;
  const rest = JSON.stringify({ ...r, steps: [] });
  return containsTracked(rest) ? "단계 밖(notes·next·error)" : null;
}

export function renderJson(r: Result): string {
  const doc: Record<string, unknown> = { schema: SCHEMA, command: r.command };
  if (r.app !== undefined) doc.app = r.app;
  doc.mode = r.mode;
  doc.status = r.status;
  doc.steps = r.steps;
  doc.notes = r.notes;
  doc.next = r.next;
  if (r.error) doc.error = r.error;
  if (r.exitCode !== undefined) doc.exitCode = r.exitCode;
  return JSON.stringify(doc) + "\n";
}

// 한글·CJK는 터미널에서 두 칸이다. 열 맞춤에 쓴다.
function width(s: string): number {
  let w = 0;
  for (const ch of s) w += /[ᄀ-ᅟ⺀-꓏가-힣豈-﫿︰-﹏＀-｠￠-￦]/.test(ch) ? 2 : 1;
  return w;
}

const SUFFIX: Partial<Record<StepResult, string>> = { skipped: "건너뜀", applied: "했다", waiting: "대기", failed: "실패", "not-run": "안 함" };

export function renderHuman(r: Result): string {
  const lines: string[] = [];
  const head = r.title ?? (r.mode === "plan" ? "계획 (아무것도 바꾸지 않았다)" : r.mode === "apply" ? "실행" : `homelab ${r.command}${r.app ? ` ${r.app}` : ""}`);
  lines.push(head);
  const col = Math.max(0, ...r.steps.map((s) => width(s.target)));
  const num = String(r.steps.length).length;
  r.steps.forEach((s, i) => {
    // plan은 결과가 없고, 읽기 명령은 실패만 표시한다.
    const label = r.mode === "apply" || (r.mode === "read" && s.result === "failed") ? SUFFIX[s.result] : undefined;
    lines.push(`  ${String(i + 1).padStart(num)} ${s.target}${" ".repeat(col - width(s.target))}   ${s.detail}${label ? ` (${label})` : ""}`);
  });
  for (const n of r.notes) lines.push(`주의: ${n}`);
  if (r.error) lines.push(`실패: ${r.error.message}`);
  lines.push(`다음: ${r.next ?? "없음"}`);
  return lines.join("\n") + "\n";
}

export function render(r: Result, json: boolean): string {
  const problem = secretProblem(r);
  if (problem) throw new OutputBlocked(`출력에 시크릿 값이 섞여 막았다(${problem})`);
  const text = json ? renderJson(r) : renderHuman(r);
  if (containsTracked(text)) throw new OutputBlocked("출력에 시크릿 값이 섞여 막았다");
  return text;
}

export function writeStdout(text: string): void {
  if (containsTracked(text)) throw new OutputBlocked("출력에 시크릿 값이 섞여 막았다");
  process.stdout.write(text);
}

export function writeStderr(text: string): void {
  process.stderr.write(containsTracked(text) ? "진행 줄에 시크릿 값이 섞여 뺐다\n" : text);
}
