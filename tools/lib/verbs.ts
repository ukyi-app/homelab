// 동사 operation catalog — transport 중립·부수효과 없는 import-safe SSOT(structure r1 A1·B1:
// bin 모듈(homelab.ts)은 import하면 main이 실행되므로 MCP가 재사용할 catalog는 lib에 산다).
// 행 하나 = 동사 하나: path(라우팅 어휘)·desc(--help 열거)·op(operation — 계약 Envelope 반환,
// 프로세스/표현 관심사 없음). argv 파싱·렌더링·stdout·종료코드는 CLI 셸(homelab.ts) 소유이고,
// MCP 서버(후속 티켓)는 op를 직접 호출해 같은 envelope을 tool 결과로 쓴다.
// 후속 티켓은 여기 행을 추가한다. 입력이 있는 동사(create 등)는 op 시그니처를 그 행에서 타입
// 입력으로 확장하고, MCP 노출 정책 필드는 MCP 티켓에서 이 descriptor에 추가한다.
import { ENVELOPE, exitFor, type Envelope } from "./contract.ts";
import { runDoctor } from "./doctor.ts";

export type Verb = { path: string[]; desc: string; op: () => Envelope };

function doctorOp(): Envelope {
  const { checks, summary } = runDoctor();
  const variant = summary.fail > 0 ? "failure" : "success";
  return { schema: ENVELOPE, verb: "doctor", variant, exitCode: exitFor(variant), omitted: [], result: { checks, summary } };
}

export const VERBS: Verb[] = [
  { path: ["doctor"], desc: "플랫폼 전제 진단(gh 인증·owner 일치·스코프 / bun·kubeseal / KUBECONFIG / 템플릿 호환성)", op: doctorOp },
];
