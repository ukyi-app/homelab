// 동사 operation catalog — transport 중립·부수효과 없는 import-safe SSOT(structure r1 A1·B1:
// bin 모듈(homelab.ts)은 import하면 main이 실행되므로 MCP가 재사용할 catalog는 lib에 산다).
// 행 하나 = 동사 하나: path(라우팅 어휘)·desc(--help 열거)·op(operation — 타입 입력을 받아
// 계약 Envelope 반환, 프로세스/표현 관심사 없음). argv 파싱·렌더링·stdout·종료코드는 CLI 셸
// (homelab.ts) 소유이고, MCP 서버(후속 티켓)는 op를 직접 호출해 같은 envelope을 tool 결과로 쓴다.
// MCP 노출 정책 필드는 MCP 티켓에서 이 descriptor에 추가한다.
import { ENVELOPE, exitFor, type Envelope } from "./contract.ts";
import { runDoctor } from "./doctor.ts";

// 동사 형상 — I가 그 동사의 타입 입력(structure r2-a1: op를 입력 0개로 고정하면 입력 있는
// 동사가 catalog를 우회해야 한다). 동사 추가 = 입력 타입 + 구체 Verb 타입 + union 멤버 +
// named export + VERBS 행 — 전부 이 파일 안이라 우회 표면이 없다.
type VerbShape<I> = { path: readonly string[]; desc: string; op: (input: I) => Envelope };

// doctor는 입력이 없는 동사다 — 입력 필드가 생기면 이 타입에서 확장한다.
export type DoctorInput = Record<string, never>;
export type DoctorVerb = VerbShape<DoctorInput>;

// 전 동사의 union — 후속 동사가 멤버로 추가된다(예: DoctorVerb | DbCreateVerb).
export type Verb = DoctorVerb;

function doctorOp(_input: DoctorInput): Envelope {
  const { checks, summary } = runDoctor();
  const variant = summary.fail > 0 ? "failure" : "success";
  return { schema: ENVELOPE, verb: "doctor", variant, exitCode: exitFor(variant), omitted: [], result: { checks, summary } };
}

// named export — CLI 어댑터·MCP가 정확한 입력 타입으로 호출한다(union 좁히기 불필요).
export const DOCTOR: DoctorVerb = {
  path: ["doctor"],
  desc: "플랫폼 전제 진단(gh 인증·owner 일치·스코프 / bun·kubeseal / KUBECONFIG / 템플릿 호환성)",
  op: doctorOp,
};

// 열거 SSOT — 라우팅 어휘(TREE)·usage·MCP tool 목록이 여기서 파생된다.
export const VERBS: readonly Verb[] = [DOCTOR];
