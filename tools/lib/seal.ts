// kubeseal 봉인 SSOT — 평문 Secret manifest를 디스크에 쓰지 않고 kubeseal stdin으로만 흘려
// 봉인 YAML을 반환한다. provision-db/provision-cache 공용(homelab 전용 .ts).
// ⚠️ 평문은 절대 stdout/예외메시지에 안 싣는다. (app-shared seal-secret.mts는 자체 블록 유지 — Pass1 F3.)
import { spawnSync } from "node:child_process";

export function sealManifest(manifest: object, certPath: string): string {
  const res = spawnSync("kubeseal", ["--cert", certPath, "--format", "yaml"], {
    input: JSON.stringify(manifest), // kubeseal은 JSON manifest도 받는다(YAML 슈퍼셋)
    encoding: "utf8",
  });
  if (res.error) throw new Error(`kubeseal 실행 실패: ${res.error.message}`);
  if (res.status !== 0) throw new Error(`kubeseal 종료 코드 ${res.status} — cert(${certPath})/컨트롤러 점검 (stderr는 값 미포함 시에만)`);
  return res.stdout;
}
