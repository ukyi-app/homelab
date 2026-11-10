// homelab bot: 봇 관리 기능(봇 COLLEAGUE_SPEC §4.8, DECISIONS "동료 봇 전환" 3). 비상 정지, 해제(비상 정지·멈춘 작업),
// 차단(거부 목록에 더하기만), 상태 보기, unknown 해제. 봇 게시 서버 파드 안의 관리 진입점(admin-main)을 kubectl exec로 부른다.
// 진입점은 모델을 거치지 않고 감사에 행위자 cli를 남긴다. 차단 해제는 이 명령에 없다(Infisical revocationRestores 절차).
// kubectl exec는 쓰기로 판정하므로(설계 C.7) 상태 보기까지 plan은 대상 파드와 argv만 보이고 --apply에서만 실행한다.
// 진입점의 결과는 단계 재조회로 다시 읽을 수 없어(읽기 문맥에는 exec가 없다) 이 실행의 결과를 들고 있다가 same으로 낸다.
import { defineCommand, type BotAdminCommand, type BotAdminReport, type Observation, type Step } from "../core/command";
import { CliError, UsageError } from "../core/result";

const ACTIONS = ["emergency-stop", "resume", "status", "block", "release"];
const UUID = /[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/;
const SNOWFLAKE = /[1-9][0-9]{16,19}/;
const TARGET = new RegExp(`emergency-stop|${UUID.source}|${SNOWFLAKE.source}`);

const whole = (re: RegExp, v: string | undefined): v is string => v !== undefined && new RegExp(`^(?:${re.source})$`).test(v);

function commandOf(action: string, target: string | undefined): BotAdminCommand {
  if ((action === "emergency-stop" || action === "status") && target === undefined) return { name: action };
  if (action === "resume" && target === "emergency-stop") return { name: "resume", target: "emergency-stop" };
  if (action === "resume" && whole(UUID, target)) return { name: "resume", target: "job", job: target };
  if (action === "block" && whole(SNOWFLAKE, target)) return { name: "block", user: target };
  if (action === "release" && whole(UUID, target)) return { name: "release", job: target };
  throw new UsageError("동작과 대상: emergency-stop | status | resume emergency-stop | resume <작업 ID> | block <Discord 사용자 ID> | release <작업 ID>");
}

function describe(report: BotAdminReport): string {
  const s = report.state;
  const state = s ? ` (emergency=${s.emergency}, paused=${s.paused}, executionPending=${s.executionPending}, taskLaneClosed=${s.taskLaneClosed ?? "none"})` : "";
  return `${report.result}${state}`;
}

// 봇이 받지 않거나 거부한 결과의 다음 행동. 결과 이름은 봇 admin.ts의 AdminResult다.
const NEXT: Record<string, string> = {
  running_jobs: "실행 중이거나 종료를 확인하지 못한 작업이 있다. homelab bot status --apply로 보고, 끝난 뒤 다시 실행한다",
  unsupported: "지금 봇 이미지의 관리 진입점이 이 동작을 받지 않는다(봇 C32 이전 이미지). 봇 배포 버전을 확인하고, 그동안은 '/' 명령(/revoke·/task-release·/resume-model)으로 한다",
  not_releasable: "unknown으로 막힌 작업이 아니거나 없는 작업 ID다. homelab bot status --apply로 상태를 본다",
  not_waiting: "모델 멈춤(한도·인증)으로 기다리는 작업이 아니라 재개하지 않았다. 작업 상태를 확인한다",
  emergency_stopped: "비상 정지 중이라 재개하지 않았다. 먼저 homelab bot resume emergency-stop --apply",
  queue_full: "대화 대기열이 차 있어 재개하지 않았다. 대기열이 줄어든 뒤 다시 실행한다",
  usage: "봇 이미지와 CLI의 관리 명령 꼴이 다르다. 봇 배포 버전을 확인한다",
};

export default defineCommand({
  path: ["bot"],
  summary: "봇 관리 기능(비상 정지·해제·차단·상태 보기·unknown 해제)",
  kind: "change",
  args: [
    { name: "action", required: true, help: ACTIONS.join(" | "), pattern: new RegExp(ACTIONS.join("|")) },
    { name: "target", required: false, help: "emergency-stop | 작업 ID | Discord 사용자 ID", pattern: TARGET },
  ],
  flags: [],
  async run(ctx, input) {
    const cmd = commandOf(input.args.action as string, input.args.target);
    let done: BotAdminReport | null = null;
    const step: Step = {
      id: "bot-admin",
      target: `봇 관리 기능 ${[input.args.action, input.args.target].filter(Boolean).join(" ")}`,
      async read(c): Promise<Observation> {
        // 엔진은 실행 뒤 재조회의 warn만 결과 notes에 올린다. 봇이 낸 결과 이름과 상태 값을 그 줄로 보인다.
        if (done) return { state: "same", action: "none", detail: describe(done), warn: `결과 ${describe(done)}` };
        return { state: "differs", action: "update", detail: `실행: ${c.bot.argv(c.bot.pod(), cmd).join(" ")}` };
      },
      async apply(w) {
        const report = w.bot.admin(cmd);
        if (report.exit !== 0) throw new CliError(`봇이 처리하지 않았다: ${describe(report)}`, NEXT[report.result] ?? "kubectl -n app-homelab-bot logs deploy/homelab-bot에서 admin_failed를 본다");
        done = report;
      },
    };
    return ctx.engine({ command: "bot", steps: [step] });
  },
});
