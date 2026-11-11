// homelab bot account use <이름> [--by subscription|api]: 봇이 쓰는 계정과 방식 바꾸기(봇 COLLEAGUE_SPEC §4.8 "계정 전환",
// rotate.md 3e). 대화·리뷰·작업이 함께 바뀐다. 순서가 계약이다. 하나라도 실패하면 뒤 단계는 돌지 않는다(엔진). 그래서 작업자
// 반영을 확인하기 전에는 멈춘 일을 해제하지 않는다.
//  1. 계정 폴더에 그 방식의 두 레인 값이 있고, 두 작업자 ExternalSecret이 그 방식의 자격(API면 방식 표시도)을 Secret의 작업자
//     파일 이름으로 옮기는지, 봇 DB에 그 계정·방식 기록이 있는지 본다. 하나라도 아니면 아무것도 쓰지 않는다. 옮기지 않는 배포에서
//     쓰면 다음 동기화가 옛 방식 자리 표시값만 Secret에 들여 지금 돌던 작업자의 인증이 깨진다(sandbox PR 전의 --by api).
//  2. 작업자 키(/apps/homelab-bot/worker)에 그 방식의 두 값 → 방식 표시를 쓴다. 옛 방식 자격은 아직 그대로 둔다.
//  3. 두 ExternalSecret을 즉시 동기화하고 그 방식의 Secret 키 해시가 계정 값과 같아질 때까지 기다린다. 방식 표시도 맞아야 한다.
//  4. 두 작업자 파드의 자격 파일 지문과 방식 표시가 맞을 때까지 기다린다(kubelet 볼륨 갱신, 보통 1분 안팎).
//  5. 그 뒤에만 다른 방식 두 키를 자리 표시값(unset)으로 비우고, 그 키를 옮기는 ExternalSecret이면 Secret에서도 비워질 때까지 본다.
//     다 끝나면 작업자 키에 자격이 하나뿐이다(sandbox ExternalSecret 머리 주석).
//  6. 관리 진입점으로 봇 DB의 지금 계정·방식을 바꾸고 모델 멈춤 작업(결제 멈춤 포함)을 해제한다.
// 2~4 사이에는 한 Secret에 두 방식 자격이 함께 보인다. 이 틈은 허용한다: 작업자(봇 src/credentials.ts MethodEnvCredential)는
// 방식 표시가 고른 자격만 실행 env에 넣고, 다른 방식 자격은 반사·유출 검사에만 쓴다. 반대로 자격이 없는 틈(옛 자격을 먼저
// 비움)은 허용하지 않는다. ESO 주기 동기화(1시간)가 쓰기 도중에 끼거나 새 자격이 Secret에 오지 않아도, 새 자격이 볼륨에
// 반영된 것을 확인하기 전에는 옛 자격이 Secret에 남아 있어야 작업자가 멈추지 않는다.
// 구독은 방식 표시 키가 없는 Secret(sandbox가 아직 옮기지 않음)에서도 된다. 작업자는 표시가 없으면 구독으로 본다.
// 이미 돌던 실행은 옛 자격으로 끝난다. 봇은 스스로 계정을 바꾸지 않는다(D-14 조건 5). 값은 해시로만 비교하고 출력하지 않는다.
import { defineCommand, type BotAdminCommand, type BotAdminReport, type BotMethod, type Observation, type Step, type WorkerLane } from "../core/command";
import { BOT_ACCOUNT_NAME, BOT_LANES, BOT_METHOD_KEY, BOT_UNSET, BOT_WORKER_FILE, BOT_WORKER_FOLDER, BOT_WORKER_NS, botAccountFolder, botLaneKey, publicHash } from "../core/names";
import { CliError } from "../core/result";

const same = (detail: string, warn?: string): Observation => ({ state: "same", action: "none", detail, ...(warn ? { warn } : {}) });
// ESO 동기화와 볼륨 반영 기다림. 합쳐 명세의 "대략 2분" 안에 들어오는 값이다(kubelet 동기화 주기 기본 1분 + 캐시).
const SYNC_WAIT_SEC = 60;
const SECRET_WAIT_SEC = 90;
const VOLUME_WAIT_SEC = 180;
const METHOD_LABEL: Record<BotMethod, string> = { subscription: "구독", api: "API 크레딧" };

function switchDetail(r: BotAdminReport): string {
  const s = r.switch;
  if (!s) return r.result;
  const held = s.held === "emergency_stopped" ? " · 비상 정지 중이라 해제하지 않았다(homelab bot resume emergency-stop --apply 뒤 같은 명령을 다시)"
    : s.held === "queue_full" ? " · 대기열이 차 남은 작업은 대기열이 줄어든 뒤 같은 명령을 다시" : "";
  return `${r.result} · 해제 ${s.resumed}건 · 아직 대기 ${s.waiting}건${held}`;
}

// ExternalSecret이 옮기는 Secret 키 → Infisical 키. spec.data의 remoteRef.key만 판정한다. dataFrom이나 template 데이터가 있으면
// 그 키가 덮이거나 이름이 바뀔 수 있어 판정하지 않고 문자열(사유)을 돌려준다. 호출자는 그때 쓰지 않는 쪽으로 닫는다.
function esMapping(es: any): Map<string, string> | string {
  if (!es) return "ExternalSecret이 없다";
  const spec = es.spec ?? {};
  const tpl = spec.target?.template ?? {};
  if ((spec.dataFrom ?? []).length || Object.keys(tpl.data ?? {}).length || (tpl.templateFrom ?? []).length)
    return "dataFrom·template 데이터를 써서 키 매핑을 판정하지 못한다";
  const m = new Map<string, string>();
  for (const d of spec.data ?? []) {
    // property가 있으면 원격 값 안의 한 필드라 그 키 값 그대로가 아니다.
    if (typeof d?.secretKey === "string" && typeof d?.remoteRef?.key === "string" && d.remoteRef.property === undefined) m.set(d.secretKey, d.remoteRef.key);
  }
  return m;
}
type Lane = (typeof BOT_LANES)[number];
// 이 방식으로 돌려면 ExternalSecret이 옮겨야 하는 [Secret 키, Infisical 키]. 구독은 방식 표시가 없어도 된다.
const needs = (l: Lane, m: BotMethod): [string, string][] =>
  [[BOT_WORKER_FILE[m], botLaneKey(l, m)], ...(m === "api" ? [[BOT_METHOD_KEY, BOT_METHOD_KEY] as [string, string]] : [])];
const carries = (map: Map<string, string>, pairs: [string, string][]) => pairs.filter(([s, k]) => map.get(s) !== k);

export default defineCommand({
  path: ["bot", "account", "use"],
  summary: "봇이 쓰는 계정·방식 바꾸기(두 레인 자격·방식 표시 → 작업자 반영 확인 → 멈춘 일 해제)",
  kind: "change",
  args: [{ name: "name", required: true, help: "계정 이름(homelab bot account add로 등록한 것)", pattern: BOT_ACCOUNT_NAME }],
  flags: [{ name: "by", kind: "value", valueName: "방식", help: "subscription(기본, 구독) 또는 api(API 크레딧)", values: ["subscription", "api"] }],
  async run(ctx, input) {
    const name = input.args.name as string;
    const method: BotMethod = input.flags.by === "api" ? "api" : "subscription";
    const other: BotMethod = method === "api" ? "subscription" : "api";
    const label = METHOD_LABEL[method];
    const folder = botAccountFolder(name);
    const keys = BOT_LANES.map((l) => botLaneKey(l, method));
    const otherKeys = BOT_LANES.map((l) => botLaneKey(l, other));
    const file = BOT_WORKER_FILE[method];
    const marker = publicHash(method);
    const unset = publicHash(BOT_UNSET);
    // Secret·볼륨의 방식 표시가 이 방식인지. 구독은 표시가 없어도 된다(작업자가 없으면 구독으로 본다).
    const markerOk = (hash: string | null) => (method === "api" ? hash === marker : hash === null || hash === marker);
    const addHint = `homelab bot account add ${name}${method === "api" ? " --by api" : ""}`;
    // 계정 값의 해시. 읽기마다 다시 읽는다(다른 실행이 바꿨을 수 있다).
    const source = (c: { infisical: { folderExists(p: string): boolean; valueHash(p: string, k: string): string | null } }) =>
      c.infisical.folderExists(folder) ? keys.map((k) => c.infisical.valueHash(folder, k)) : keys.map(() => null);
    const want = (hashes: (string | null)[]): Record<WorkerLane, string> =>
      Object.fromEntries(BOT_LANES.map((l, i) => [l.lane, hashes[i] as string])) as Record<WorkerLane, string>;
    let known = false;
    let volumes = false;
    let switched: BotAdminReport | null = null;

    // 확인 단계(apply 없음): 계정 폴더에 그 방식의 두 레인 값이 없으면 아무것도 쓰기 전에 멈춘다.
    const tokens: Step = {
      id: "account-tokens",
      target: `계정 ${name} ${label} 자격(Infisical ${folder})`,
      async read(c) {
        if (source(c).some((h) => h === null)) return { state: "missing", action: "none", detail: `두 레인 ${label} 자격이 다 있지 않다`, next: addHint };
        return same(`두 레인 ${label} 자격 있음`);
      },
    };
    // 확인 단계(apply 없음): 두 ExternalSecret이 이 방식의 자격을 옮기지 않으면 plan에서도 막고 아무것도 쓰지 않는다.
    const mapping: Step = {
      id: "worker-mapping",
      target: `${BOT_WORKER_NS} ExternalSecret ${BOT_LANES.map((l) => l.secret).join("·")}의 ${label} 키 매핑`,
      async read(c) {
        const problems: string[] = [];
        for (const l of BOT_LANES) {
          const map = esMapping(c.k8s.get("externalsecret", BOT_WORKER_NS, l.secret));
          if (typeof map === "string") { problems.push(`${l.label} 레인 ${l.secret}: ${map}`); continue; }
          const lack = carries(map, needs(l, method));
          if (lack.length) problems.push(`${l.label} 레인 ${l.secret}이 ${lack.map(([s, k]) => `${k}→${s}`).join("·")}를 옮기지 않는다`);
        }
        if (!problems.length) return same(`두 ExternalSecret이 ${label} 자격${method === "api" ? "·방식 표시" : ""}를 옮긴다`);
        return { state: "differs", action: "none", detail: `${problems.join(", ")}. 지금 배포의 작업자는 ${label} 방식으로 돌 수 없어 아무것도 쓰지 않는다`,
          next: method === "api"
            ? "sandbox 작업자 ExternalSecret에 레인별 API 키와 방식 표시를 더하는 sandbox PR(C23)이 병합·동기화된 뒤 같은 명령을 다시 실행한다"
            : "kubectl -n sandbox get externalsecrets -o yaml로 작업자 ExternalSecret을 확인한다(platform/sandbox 템플릿과 같아야 한다)" };
      },
    };
    const account: Step = {
      id: "account-record",
      target: `계정 ${name}(${label}) 봇 DB 기록`,
      async read() {
        if (known) return same("봇 DB에 기록이 있다");
        return { state: "differs", action: "update", detail: "봇 DB에 이 계정·방식 기록이 있는지 본다(kubectl exec)" };
      },
      async apply(w) {
        const list = w.bot.admin({ name: "account", action: "list" });
        if (list.exit !== 0 || list.result !== "accounts") throw new CliError(`봇이 계정 목록을 내지 않았다: ${list.result}`, "봇 배포 버전(봇 C22 이후)과 봇 파드 상태를 확인한다");
        if (!list.accounts?.some((a) => a.name === name && a.method === method))
          throw new CliError(`봇 DB에 계정 ${name}(${label}) 기록이 없다. 아무것도 바꾸지 않았다`, `${addHint} --apply(값이 이미 있으면 기록만 한다)`);
        known = true;
      },
    };

    const workerKeys: Step = {
      id: "worker-keys",
      target: `Infisical homelab/prod ${BOT_WORKER_FOLDER} ${[...keys, BOT_METHOD_KEY].join("·")}`,
      async read(c) {
        const hashes = source(c);
        const now = keys.map((k) => c.infisical.valueHash(BOT_WORKER_FOLDER, k));
        const shown = c.infisical.valueHash(BOT_WORKER_FOLDER, BOT_METHOD_KEY);
        if (hashes.every((h, i) => h !== null && h === now[i]) && shown === marker) return same(`두 레인 모두 ${name}(${label}) 값, 방식 표시 ${method}`);
        const lanes = BOT_LANES.filter((_, i) => hashes[i] === null || hashes[i] !== now[i]).map((l) => l.label);
        const parts = [...(lanes.length ? [`${lanes.join("·")} 레인이 다른 값`] : []), ...(shown !== marker ? [`방식 표시가 ${method}가 아니다`] : [])];
        return { state: "differs", action: "update", detail: `${parts.join(", ")} → 계정 ${name}의 두 값 → 방식 표시 ${method} 순서로 쓴다(해시로만 비교, ${METHOD_LABEL[other]} 자격은 반영 확인 뒤에 비운다)` };
      },
      async apply(w) {
        // 두 값을 먼저 다 읽고 나서 쓴다. 하나라도 없으면 아무것도 쓰지 않는다.
        const values = keys.map((k) => w.infisical.getValue(folder, k));
        if (values.some((v) => v === null)) throw new CliError(`계정 ${name}의 레인 ${label} 자격이 없다`, `${addHint} --replace --apply`);
        keys.forEach((k, i) => w.infisical.setValue(BOT_WORKER_FOLDER, k, values[i]!));
        w.infisical.setMarker(BOT_WORKER_FOLDER, BOT_METHOD_KEY, method);
      },
    };

    const secrets: Step = {
      id: "worker-secrets",
      target: `${BOT_WORKER_NS} Secret ${BOT_LANES.map((l) => l.secret).join("·")}`,
      async read(c) {
        const hashes = source(c);
        const now = BOT_LANES.map((l) => c.k8s.secretHash(BOT_WORKER_NS, l.secret, file));
        const shown = BOT_LANES.map((l) => c.k8s.secretHash(BOT_WORKER_NS, l.secret, BOT_METHOD_KEY));
        if (hashes.every((h, i) => h !== null && h === now[i]) && shown.every(markerOk)) return same(`두 Secret 모두 ${name}(${label}) 값`);
        return { state: "differs", action: "update", detail: `ExternalSecret 즉시 동기화 → Secret의 ${file} 해시가 계정 값과 같고 방식 표시가 맞을 때까지` };
      },
      async apply(w) {
        const hashes = source(w);
        for (const l of BOT_LANES) w.k8s.forceSync(BOT_WORKER_NS, l.secret, { waitSec: SYNC_WAIT_SEC });
        // 맞지 않으면 시간 초과로 둔다. 엔진이 다시 읽어 판단하고(재시도 없음) 다르면 여기서 멈춘다(해제하지 않는다).
        BOT_LANES.forEach((l, i) => { w.k8s.waitSecret(BOT_WORKER_NS, l.secret, file, { hash: hashes[i] as string }, SECRET_WAIT_SEC); });
      },
    };

    const mounted: Step = {
      id: "worker-volumes",
      target: `${BOT_WORKER_NS} 작업자 두 파드의 자격 파일·방식 표시`,
      async read() {
        if (volumes) return same("두 파드 모두 새 값의 지문과 방식 표시");
        return { state: "differs", action: "update", detail: `kubectl exec로 ${file}의 지문이 계정 값과 같고 방식 표시가 ${method}일 때까지 기다린다` };
      },
      async apply(w) {
        const seen = w.bot.waitWorkerCredentials(want(source(w)), VOLUME_WAIT_SEC, method);
        const late = BOT_LANES.filter((l) => !seen[l.lane]).map((l) => l.label);
        if (late.length) throw new CliError(`${late.join("·")} 레인 작업자에 ${VOLUME_WAIT_SEC}초 안에 반영되지 않았다. 멈춘 일은 해제하지 않았다`,
          "kubectl -n sandbox get pods로 작업자 파드를 보고 같은 명령을 다시 실행한다(된 단계는 건너뛴다)");
        volumes = true;
      },
    };

    // 새 자격이 두 작업자 볼륨에 들어온 것을 본 뒤에만 옛 방식 자격을 비운다(머리 주석 5).
    const otherFile = BOT_WORKER_FILE[other];
    // Secret에 아직 옛 방식 자격이 있는 레인. 그 키를 옮기지 않는 ExternalSecret(sandbox PR 전의 API 키)이면 Secret에 키가 없다.
    const stale = (c: { k8s: { secretHash(ns: string, n: string, k: string): string | null } }) =>
      BOT_LANES.filter((l) => { const h = c.k8s.secretHash(BOT_WORKER_NS, l.secret, otherFile); return h !== null && h !== unset; });
    const clear: Step = {
      id: "worker-old-keys",
      target: `${METHOD_LABEL[other]} 자격 비움(Infisical ${BOT_WORKER_FOLDER} ${otherKeys.join("·")}, ${BOT_WORKER_NS} Secret의 ${otherFile})`,
      async read(c) {
        const left = otherKeys.filter((k) => c.infisical.valueHash(BOT_WORKER_FOLDER, k) !== unset);
        const inSecret = stale(c);
        if (!left.length && !inSecret.length) return same(`${METHOD_LABEL[other]} 자격 자리가 ${BOT_UNSET}이다`);
        const parts = [...(left.length ? [`Infisical ${left.join("·")}`] : []), ...(inSecret.length ? [`${inSecret.map((l) => l.label).join("·")} 레인 Secret`] : [])];
        return { state: "differs", action: "update", detail: `${parts.join(", ")}에 ${METHOD_LABEL[other]} 자격이 남아 있다 → ${BOT_UNSET}으로 쓰고, 그 키를 옮기는 Secret이면 비워질 때까지 본다` };
      },
      async apply(w) {
        for (const k of otherKeys) w.infisical.setMarker(BOT_WORKER_FOLDER, k, BOT_UNSET);
        const lanes = stale(w);
        for (const l of lanes) w.k8s.forceSync(BOT_WORKER_NS, l.secret, { waitSec: SYNC_WAIT_SEC });
        // 맞지 않으면 엔진이 다시 읽어 멈춘다. 이때도 작업자는 방식 표시대로 새 자격으로 돈다(옛 자격이 남을 뿐이다).
        for (const l of lanes) w.k8s.waitSecret(BOT_WORKER_NS, l.secret, otherFile, { hash: unset }, SECRET_WAIT_SEC);
      },
    };

    const cmd: BotAdminCommand = { name: "account", action: "use", account: name, method };
    const release: Step = {
      id: "bot-account-use",
      target: `봇 지금 계정 ${name}(${label})과 멈춘 일 해제`,
      async read(c) {
        if (switched) return same(switchDetail(switched), `결과 ${switchDetail(switched)}`);
        return { state: "differs", action: "update", detail: `실행: ${c.bot.argv(c.bot.pod(), cmd).join(" ")}` };
      },
      async apply(w) {
        const report = w.bot.admin(cmd);
        if (report.exit !== 0 || report.result !== "switched")
          throw new CliError(`봇이 계정을 바꾸지 않았다: ${report.result}. 작업자 자격은 이미 ${name}(${label})이다`,
            report.result === "unknown_account" ? `${addHint} --apply 뒤 같은 명령을 다시 실행한다` : "같은 명령을 다시 실행한다(된 단계는 건너뛴다)");
        switched = report;
      },
    };

    return ctx.engine({
      command: "bot account use",
      steps: [tokens, mapping, account, workerKeys, secrets, mounted, clear, release],
      ...(method === "api" ? { notes: ["API 크레딧 방식은 sandbox 작업자 ExternalSecret이 레인별 API 키와 CLAUDE_AUTH_METHOD를 옮기는 배포 뒤에만 된다(그 전에는 아무것도 쓰지 않고 거부한다)"] } : {}),
    });
  },
});
