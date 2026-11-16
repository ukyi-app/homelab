// homelab bot account list: 봇 모델 계정 목록(봇 COLLEAGUE_SPEC §4.8 "계정 목록"). 이름, 방식, 지금 계정, 토큰 만료일,
// 마지막으로 본 구독 사용률과 풀리는 시각, 모델 멈춤으로 기다리는 작업 수를 보인다. 값과 크레딧 잔액은 없다(봇 DB에 값이 없다).
// 봇 DB는 관리 진입점(kubectl exec)으로만 읽는다. kubectl exec는 쓰기로 판정하므로(설계 C.7) 다른 homelab bot 명령처럼
// plan은 대상 파드와 argv만 보이고 --apply에서만 실행한다.
import { defineCommand, type BotAccount, type BotAdminCommand, type BotAdminReport, type BotPaused, type Observation, type Plan, type Step } from "../core/command";
import { CliError } from "../core/result";

const METHOD: Record<BotAccount["method"], string> = { subscription: "구독", api: "API 크레딧" };
// 봇은 초 단위 UTC(…Z)만 낸다. 한국은 서머타임이 없어 +9시간이 늘 맞다.
const kst = (iso: string | null) => (iso === null ? "모름" : `${new Date(Date.parse(iso) + 9 * 3_600_000).toISOString().slice(0, 16).replace("T", " ")} KST`);

function accountLine(a: BotAccount): string {
  const head = `- ${a.name}(${METHOD[a.method]}${a.current ? ", 지금 계정" : ""})`;
  const expiry = a.method === "subscription" ? ` · 토큰 만료 ${a.expiresAt === null ? "모름(CLI 밖에서 등록)" : kst(a.expiresAt)}` : "";
  const l = a.limit;
  const usage = l === null ? " · 사용률 관측 없음"
    : ` · 사용률 ${l.utilization === null ? "모름" : `${Math.round(l.utilization * 100)}%`}(${[l.rateLimitType, l.status].filter(Boolean).join(", ") || "종류 모름"}) · 풀리는 시각 ${kst(l.resetsAt)} · 관측 ${kst(l.observedAt)}`;
  return `${head}${expiry}${usage}`;
}

export function accountListBody(accounts: BotAccount[], paused: BotPaused): string {
  const current = accounts.find((a) => a.current);
  const lines = [
    `지금 계정: ${current ? `${current.name}(${METHOD[current.method]})` : "없음(미등록)"}`,
    ...(accounts.length ? accounts.map(accountLine) : ["- 등록된 계정 없음(homelab bot account add <이름>)"]),
    `모델 멈춤 작업: 한도 ${paused.rate_limit} · 인증 만료 ${paused.auth_expired} · 결제 ${paused.billing}`,
  ];
  // 결제 멈춤은 저절로 재개하지 않는다. 계정 전환의 해제가 그 작업까지 이어 준다(같은 계정으로 다시 써도 된다).
  if (paused.billing > 0) lines.push(`결제 멈춤은 원인을 푼 뒤 homelab bot account use <이름> --apply로 해제한다${current ? `(지금 계정이면 ${current.name})` : ""}`);
  return lines.join("\n");
}

export default defineCommand({
  path: ["bot", "account", "list"],
  summary: "봇 모델 계정 목록 보기",
  help: {
    about:
      "등록한 계정의 이름·방식·지금 쓰는 계정·토큰 만료일·마지막 사용률과 모델 문제로 멈춘 작업 수를 봅니다. 값과 크레딧 잔액은 보이지 않습니다. 봇 파드 안에서 실행하므로 --apply가 있어야 실행합니다.",
    examples: ["homelab bot account list --apply"],
    related: ["bot account add", "bot account use"],
  },
  kind: "change",
  terminalSummary: true,
  args: [],
  flags: [{ name: "verbose", kind: "bool", help: "터미널에서도 단계 표 전체 보기" }],
  async run(ctx) {
    const cmd: BotAdminCommand = { name: "account", action: "list" };
    let done: BotAdminReport | null = null;
    const step: Step = {
      id: "bot-account-list",
      target: "봇 모델 계정 목록",
      async read(c): Promise<Observation> {
        if (done) return { state: "same", action: "none", detail: "읽었다" };
        return { state: "differs", action: "update", detail: `실행: ${c.bot.argv(c.bot.pod(), cmd).join(" ")}` };
      },
      async apply(w) {
        const report = w.bot.admin(cmd);
        if (report.exit !== 0 || report.result !== "accounts" || !report.accounts || !report.paused)
          throw new CliError(`봇이 목록을 내지 않았다: ${report.result}`, report.result === "usage" || report.result === "unsupported"
            ? "지금 봇 이미지의 관리 진입점이 계정 명령을 받지 않는다(봇 C22 이전 이미지). 봇 배포 버전을 확인한다"
            : "kubectl -n app-homelab-bot logs deploy/homelab-bot에서 admin_failed를 본다");
        done = report;
        plan.body = accountListBody(report.accounts, report.paused);
      },
    };
    const plan: Plan = {
      command: "bot account list",
      steps: [step],
      summary: {
        names: { "bot-account-list": "봇 계정 목록 읽기" },
        // 목록 본문의 첫 줄(지금 계정)이 머리, 나머지가 줄이다.
        done: (r) => {
          const [head, ...lines] = (r.body ?? "").split("\n");
          return { head, lines, next: null };
        },
      },
    };
    return ctx.engine(plan);
  },
});
