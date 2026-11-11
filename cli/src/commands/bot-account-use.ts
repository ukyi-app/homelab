// homelab bot account use <이름>: 봇이 쓰는 계정 바꾸기(봇 COLLEAGUE_SPEC §4.8 "계정 전환", rotate.md 3e). 대화·리뷰·작업이 함께 바뀐다.
// 순서가 계약이다. 하나라도 실패하면 뒤 단계는 돌지 않는다(엔진). 그래서 작업자 반영을 확인하기 전에는 멈춘 일을 해제하지 않는다.
//  1. 계정 폴더에 두 레인 토큰이 있고 봇 DB에 그 계정 기록이 있는지 본다(없으면 아무것도 바꾸지 않는다).
//  2. 두 값을 작업자 키(/apps/homelab-bot/worker)로 옮긴다. 둘 다 쓴 뒤에만 다음 단계로 간다(한 레인만 바뀐 채 멈추면 재실행이 이어 쓴다).
//  3. 두 ExternalSecret을 즉시 동기화하고 Secret 해시가 계정 값과 같아질 때까지 기다린다.
//  4. 두 작업자 파드의 자격 파일 지문이 같아질 때까지 기다린다(kubelet 볼륨 갱신, 보통 1분 안팎).
//  5. 관리 진입점으로 봇 DB의 지금 계정을 바꾸고 모델 멈춤 작업(결제 멈춤 포함)을 해제한다.
// 이미 돌던 실행은 옛 자격으로 끝난다. 봇은 스스로 계정을 바꾸지 않는다(D-14 조건 5). 값은 해시로만 비교하고 출력하지 않는다.
// --by api(API 크레딧)는 C23이 더한다. 지금은 구독만 받는다.
import { defineCommand, type BotAdminCommand, type BotAdminReport, type Observation, type Step, type WorkerLane } from "../core/command";
import { BOT_ACCOUNT_NAME, BOT_LANES, BOT_WORKER_FOLDER, BOT_WORKER_NS, BOT_WORKER_SECRET_KEY, botAccountFolder } from "../core/names";
import { CliError, UsageError } from "../core/result";

const same = (detail: string, warn?: string): Observation => ({ state: "same", action: "none", detail, ...(warn ? { warn } : {}) });
// ESO 동기화와 볼륨 반영 기다림. 합쳐 명세의 "대략 2분" 안에 들어오는 값이다(kubelet 동기화 주기 기본 1분 + 캐시).
const SYNC_WAIT_SEC = 60;
const SECRET_WAIT_SEC = 90;
const VOLUME_WAIT_SEC = 180;

function switchDetail(r: BotAdminReport): string {
  const s = r.switch;
  if (!s) return r.result;
  const held = s.held === "emergency_stopped" ? " · 비상 정지 중이라 해제하지 않았다(homelab bot resume emergency-stop --apply 뒤 같은 명령을 다시)"
    : s.held === "queue_full" ? " · 대기열이 차 남은 작업은 대기열이 줄어든 뒤 같은 명령을 다시" : "";
  return `${r.result} · 해제 ${s.resumed}건 · 아직 대기 ${s.waiting}건${held}`;
}

export default defineCommand({
  path: ["bot", "account", "use"],
  summary: "봇이 쓰는 계정 바꾸기(두 레인 자격 → 작업자 반영 확인 → 멈춘 일 해제)",
  kind: "change",
  args: [{ name: "name", required: true, help: "계정 이름(homelab bot account add로 등록한 것)", pattern: BOT_ACCOUNT_NAME }],
  flags: [{ name: "by", kind: "value", valueName: "방식", help: "subscription(기본). api는 아직 없다(C23)", values: ["subscription", "api"] }],
  async run(ctx, input) {
    const name = input.args.name as string;
    if (input.flags.by === "api") throw new UsageError("API 크레딧 방식(--by api)은 아직 없다. 구독 계정만 바꿀 수 있다(--by subscription 또는 생략)");
    const folder = botAccountFolder(name);
    // 계정 값의 해시. 읽기마다 다시 읽는다(다른 실행이 바꿨을 수 있다).
    const source = (c: { infisical: { folderExists(p: string): boolean; valueHash(p: string, k: string): string | null } }) =>
      c.infisical.folderExists(folder) ? BOT_LANES.map((l) => c.infisical.valueHash(folder, l.key)) : BOT_LANES.map(() => null);
    const want = (hashes: (string | null)[]): Record<WorkerLane, string> =>
      Object.fromEntries(BOT_LANES.map((l, i) => [l.lane, hashes[i] as string])) as Record<WorkerLane, string>;
    let known = false;
    let volumes = false;
    let switched: BotAdminReport | null = null;

    // 확인 단계(apply 없음): 계정 폴더에 두 레인 토큰이 없으면 아무것도 쓰기 전에 멈춘다.
    const tokens: Step = {
      id: "account-tokens",
      target: `계정 ${name} 토큰(Infisical ${folder})`,
      async read(c) {
        if (source(c).some((h) => h === null)) return { state: "missing", action: "none", detail: "두 레인 토큰이 다 있지 않다", next: `homelab bot account add ${name}` };
        return same("두 레인 토큰 있음");
      },
    };
    const account: Step = {
      id: "account-record",
      target: `계정 ${name} 봇 DB 기록`,
      async read() {
        if (known) return same("봇 DB에 기록이 있다");
        return { state: "differs", action: "update", detail: "봇 DB에 이 계정 기록이 있는지 본다(kubectl exec)" };
      },
      async apply(w) {
        const list = w.bot.admin({ name: "account", action: "list" });
        if (list.exit !== 0 || list.result !== "accounts") throw new CliError(`봇이 계정 목록을 내지 않았다: ${list.result}`, "봇 배포 버전(봇 C22 이후)과 봇 파드 상태를 확인한다");
        if (!list.accounts?.some((a) => a.name === name && a.method === "subscription"))
          throw new CliError(`봇 DB에 계정 ${name}(구독) 기록이 없다. 아무것도 바꾸지 않았다`, `homelab bot account add ${name} --apply(토큰이 이미 있으면 기록만 한다)`);
        known = true;
      },
    };

    const keys: Step = {
      id: "worker-keys",
      target: `Infisical homelab/prod ${BOT_WORKER_FOLDER} ${BOT_LANES.map((l) => l.key).join("·")}`,
      async read(c) {
        const hashes = source(c);
        const now = BOT_LANES.map((l) => c.infisical.valueHash(BOT_WORKER_FOLDER, l.key));
        if (hashes.every((h, i) => h !== null && h === now[i])) return same(`두 레인 모두 ${name} 값`);
        const lanes = BOT_LANES.filter((_, i) => hashes[i] === null || hashes[i] !== now[i]).map((l) => l.label);
        return { state: "differs", action: "update", detail: `${lanes.join("·")} 레인이 다른 값 → 계정 ${name}의 두 값을 옮긴다(해시로만 비교)` };
      },
      async apply(w) {
        // 두 값을 먼저 다 읽고 나서 쓴다. 하나라도 없으면 아무것도 쓰지 않는다.
        const values = BOT_LANES.map((l) => w.infisical.getValue(folder, l.key));
        if (values.some((v) => v === null)) throw new CliError(`계정 ${name}의 레인 토큰이 없다`, `homelab bot account add ${name} --replace --apply`);
        BOT_LANES.forEach((l, i) => w.infisical.setValue(BOT_WORKER_FOLDER, l.key, values[i]!));
      },
    };

    const secrets: Step = {
      id: "worker-secrets",
      target: `${BOT_WORKER_NS} Secret ${BOT_LANES.map((l) => l.secret).join("·")}`,
      async read(c) {
        const hashes = source(c);
        const now = BOT_LANES.map((l) => c.k8s.secretHash(BOT_WORKER_NS, l.secret, BOT_WORKER_SECRET_KEY));
        if (hashes.every((h, i) => h !== null && h === now[i])) return same(`두 Secret 모두 ${name} 값`);
        return { state: "differs", action: "update", detail: "ExternalSecret 즉시 동기화 → Secret 해시가 계정 값과 같아질 때까지" };
      },
      async apply(w) {
        const hashes = source(w);
        for (const l of BOT_LANES) w.k8s.forceSync(BOT_WORKER_NS, l.secret, { waitSec: SYNC_WAIT_SEC });
        // 맞지 않으면 시간 초과로 둔다. 엔진이 다시 읽어 판단하고(재시도 없음) 다르면 여기서 멈춘다(해제하지 않는다).
        BOT_LANES.forEach((l, i) => { w.k8s.waitSecret(BOT_WORKER_NS, l.secret, BOT_WORKER_SECRET_KEY, { hash: hashes[i] as string }, SECRET_WAIT_SEC); });
      },
    };

    const mounted: Step = {
      id: "worker-volumes",
      target: `${BOT_WORKER_NS} 작업자 두 파드의 자격 파일`,
      async read() {
        if (volumes) return same("두 파드 모두 새 값의 지문");
        return { state: "differs", action: "update", detail: "kubectl exec로 자격 파일 지문이 계정 값과 같아질 때까지 기다린다" };
      },
      async apply(w) {
        const seen = w.bot.waitWorkerCredentials(want(source(w)), VOLUME_WAIT_SEC);
        const late = BOT_LANES.filter((l) => !seen[l.lane]).map((l) => l.label);
        if (late.length) throw new CliError(`${late.join("·")} 레인 작업자에 ${VOLUME_WAIT_SEC}초 안에 반영되지 않았다. 멈춘 일은 해제하지 않았다`,
          "kubectl -n sandbox get pods로 작업자 파드를 보고 같은 명령을 다시 실행한다(된 단계는 건너뛴다)");
        volumes = true;
      },
    };

    const cmd: BotAdminCommand = { name: "account", action: "use", account: name, method: "subscription" };
    const release: Step = {
      id: "bot-account-use",
      target: `봇 지금 계정 ${name}(구독)과 멈춘 일 해제`,
      async read(c) {
        if (switched) return same(switchDetail(switched), `결과 ${switchDetail(switched)}`);
        return { state: "differs", action: "update", detail: `실행: ${c.bot.argv(c.bot.pod(), cmd).join(" ")}` };
      },
      async apply(w) {
        const report = w.bot.admin(cmd);
        if (report.exit !== 0 || report.result !== "switched")
          throw new CliError(`봇이 계정을 바꾸지 않았다: ${report.result}. 작업자 자격은 이미 ${name}이다`,
            report.result === "unknown_account" ? `homelab bot account add ${name} --apply 뒤 같은 명령을 다시 실행한다` : "같은 명령을 다시 실행한다(된 단계는 건너뛴다)");
        switched = report;
      },
    };

    return ctx.engine({ command: "bot account use", steps: [tokens, account, keys, secrets, mounted, release] });
  },
});
