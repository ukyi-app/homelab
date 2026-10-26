// homelab logs: 지금 파드의 로그(kubectl logs). 설계 C.7은 과거 로그를 VictoriaLogs에서 읽는다고 했지만, CLI에서 닿을 경로가
// 없다(클러스터 안 서비스이고 읽기 경로는 Grafana 데이터소스 뒤 vmauth다, C.3.7). 새 자격·port-forward를 CLI에 두지 않고
// (T12 "새 외부 자격 없음") 과거 로그는 Grafana Explore로 안내한다(T12-02 결정, C.7에 적음).
// 앱 로그는 그대로 보인다. 앱이 자격을 로그에 쓰지 않는 것은 앱 계약이다(설계 C.7). 제어 문자는 출력 계층이 바꾼다.
import { defineCommand } from "../core/command";
import { APP_NAME } from "../core/names";

export default defineCommand({
  path: ["logs"],
  summary: "로그(지금 파드, 과거는 Grafana)",
  kind: "read",
  args: [{ name: "app", required: true, help: "앱 이름", pattern: APP_NAME }],
  flags: [
    { name: "since", kind: "value", valueName: "기간", pattern: /[1-9][0-9]{0,5}[smhd]/, help: "예 30m, 2h, 7d" },
    { name: "job", kind: "value", valueName: "이름", values: ["migrate"], help: "마이그레이션 Job(<app>-migrate)의 로그" },
    { name: "previous", kind: "bool", help: "직전 컨테이너(재시작 전)의 로그" },
  ],
  async run(ctx, input) {
    const app = input.args.app as string;
    const ns = `app-${app}`;
    const job = input.flags.job === "migrate";
    const target = job ? { job: `${app}-migrate` } : { deployment: app };
    const name = job ? `job/${app}-migrate` : `deploy/${app}`;
    const text = ctx.k8s.logs(ns, target, { since: input.flags.since as string | undefined, previous: input.flags.previous === true });
    const lines = text === "" ? 0 : text.replace(/\n$/, "").split("\n").length;
    return ctx.engine({
      command: "logs",
      app,
      title: `homelab logs ${app}`,
      steps: [{ id: "logs", target: `${ns} ${name}`, read: async () => ({ state: "same", action: "none", detail: `${lines}줄(최근 200줄까지)` }) }],
      notes: [`과거 로그: Grafana Explore, 데이터소스 victorialogs, LogsQL {namespace="${ns}"}`],
      body: text,
    });
  },
});
