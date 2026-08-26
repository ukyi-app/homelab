// kubeseal 봉인 SSOT — 평문 Secret manifest를 디스크에 쓰지 않고 kubeseal stdin으로만 흘려
// 봉인 YAML을 반환한다. provision-db/provision-cache 공용(homelab 전용 .ts).
// ⚠️ 평문은 절대 stdout/예외메시지에 안 싣는다. (app-shared seal-secret.mts는 자체 블록 유지 — Pass1 F3.)
// 실행은 exec seam의 kubeseal adapter 경유(d6④) — 평문은 stdin으로만 흐르고 seam 원장(HOMELAB_EXEC_LEDGER)은
// stdin을 절대 기록하지 않는다(원장에 남는 argv는 cert 경로뿐). timeoutMs 0 = 종전 무-timeout 보존.
import { kubeseal } from "./exec.ts";

export function sealManifest(manifest: object, certPath: string): string {
  const res = kubeseal(["--cert", certPath, "--format", "yaml"], {
    input: JSON.stringify(manifest), // kubeseal은 JSON manifest도 받는다(YAML 슈퍼셋)
    timeoutMs: 0,
  });
  if (res.errKind !== undefined) throw new Error(`kubeseal 실행 실패: ${res.err}`);
  // ⚠️ 종전대로 stderr(res.err)는 메시지에 싣지 않는다 — 평문이 stderr로 에코되는 경로를 막는 성질 보존.
  if (!res.ok) throw new Error(`kubeseal 종료 코드 ${res.status} — cert(${certPath})/컨트롤러 점검 (stderr는 값 미포함 시에만)`);
  return res.out;
}
