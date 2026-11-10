// homelab bot account add <이름>: 봇이 쓸 Claude 구독 계정 등록(봇 COLLEAGUE_SPEC §4.8 "계정 등록", 구독 방식만. API 크레딧은 C23).
// 레인이 둘(대화·리뷰, 작업)이라 토큰도 둘이다. tty면 레인마다 `claude setup-token`을 띄워 owner는 브라우저 로그인만 하고,
// 화면에 나온 토큰을 에코 없는 입력으로 붙여 넣는다. 파이프면 stdin 두 줄(대화·리뷰, 작업 순서)이다. 그래서 `claude`가
// 이 CLI를 돌리는 기기에 있어야 한다. 출력 자동 수집은 하지 않는다(출력 꼴이 문서에 없다, 봇 DECISIONS C22).
// claude의 출력(발급 토큰 포함)은 stderr로 간다. stdout은 결과 문서 하나이고, stderr가 터미널이 아니면 로그인을 띄우지 않는다.
// 값은 argv·출력·파일에 두지 않고(secret set과 같은 입력 경로) Infisical 계정 폴더에만 둔다. 작업자 키는 바꾸지 않는다
// (그건 account use). 둘 다 받은 뒤에만 쓴다. 끝나면 관리 진입점으로 봇 DB에 이름·방식·발급일(지금)을 적는다.
import { defineCommand, type BotAdminCommand, type Observation, type Step } from "../core/command";
import { BOT_ACCOUNT_NAME, BOT_LANES, botAccountFolder } from "../core/names";
import { CliError } from "../core/result";

const same = (detail: string, warn?: string): Observation => ({ state: "same", action: "none", detail, ...(warn ? { warn } : {}) });

export default defineCommand({
  path: ["bot", "account", "add"],
  summary: "봇 구독 계정 등록(claude setup-token, 레인 둘, 값은 stdin·tty)",
  kind: "change",
  args: [{ name: "name", required: true, help: "계정 이름(소문자·숫자·하이픈, 32자 이하)", pattern: BOT_ACCOUNT_NAME }],
  flags: [{ name: "replace", kind: "bool", help: "이미 등록한 계정의 토큰을 새로 받는다(만료 전 교체)" }],
  async run(ctx, input) {
    const name = input.args.name as string;
    const replace = input.flags.replace === true;
    const folder = botAccountFolder(name);
    // 이 실행이 쓴 두 값의 해시. 재조회가 이것과 같아야 same이다(다시 실행하면 --replace는 다시 받는다).
    let written: string[] | null = null;
    let recorded = false;

    const tokens: Step = {
      id: "infisical-account",
      target: `Infisical homelab/prod ${folder}`,
      async read(c) {
        const has = c.infisical.folderExists(folder);
        const hashes = BOT_LANES.map((l) => (has ? c.infisical.valueHash(folder, l.key) : null));
        if (written !== null && hashes.every((h, i) => h === written![i])) return same("두 레인 토큰을 저장했다");
        if (hashes.every((h) => h !== null) && !replace) return same("두 레인 토큰 있음(그대로. 새로 받으려면 --replace)");
        const missing = BOT_LANES.filter((_, i) => hashes[i] === null).map((l) => l.key);
        return { state: missing.length ? "missing" : "differs", action: missing.length ? "create" : "update",
          detail: `${missing.length ? `없음(${missing.join(", ")})` : "있음(--replace)"} → 레인마다 claude setup-token으로 받아 저장(값은 tty·stdin)` };
      },
      async apply(w) {
        const values = w.readSetupTokens(BOT_LANES.map((l) => l.label));
        // 쓰기 전에 기억한다. 서버에는 반영됐는데 응답이 시간 초과면 엔진이 다시 읽어 이 해시로 반영을 확인한다.
        written = values.map((v) => v.sha256Prefix(12));
        if (!w.infisical.folderExists(folder)) w.infisical.createFolder(folder);
        BOT_LANES.forEach((l, i) => w.infisical.setValue(folder, l.key, values[i]));
      },
    };

    const cmd: BotAdminCommand = { name: "account", action: "record", account: name, method: "subscription" };
    const record: Step = {
      id: "bot-account-record",
      target: `봇 DB 계정 기록 ${name}(구독)`,
      async read(c) {
        if (recorded) return same("이름·방식·발급일을 적었다");
        return { state: "differs", action: "update", detail: `토큰을 새로 저장했으면 발급일을 적는다, 기록이 없으면 만든다. 실행: ${c.bot.argv(c.bot.pod(), cmd).join(" ")}` };
      },
      async apply(w) {
        // 이 실행이 토큰을 쓰지 않았으면 발급일을 바꾸지 않는다. 기록이 없을 때만(앞 실행이 토큰을 쓰고 여기서 멈춘 경우) 적는다.
        if (written === null) {
          const list = w.bot.admin({ name: "account", action: "list" });
          if (list.exit === 0 && list.accounts?.some((a) => a.name === name && a.method === "subscription")) {
            recorded = true;
            return;
          }
        }
        const report = w.bot.admin(cmd);
        if (report.exit !== 0 || report.result !== "recorded")
          throw new CliError(`봇이 계정을 기록하지 않았다: ${report.result}`, report.result === "usage" || report.result === "unsupported"
            ? "지금 봇 이미지의 관리 진입점이 계정 명령을 받지 않는다(봇 C22 이전 이미지). 봇 배포 버전을 확인한 뒤 같은 명령을 다시 실행한다"
            : "같은 명령을 다시 실행한다(저장한 토큰은 그대로 두고 기록만 한다)");
        recorded = true;
      },
    };

    return ctx.engine({
      command: "bot account add",
      steps: [tokens, record],
      notes: [`claude setup-token은 이 기기에서 실행한다(Claude Code CLI 필요). 토큰은 claude가 화면(stderr)에 한 번 출력하므로 붙여 넣은 뒤 터미널 스크롤을 지운다. stderr가 터미널이 아니면 로그인을 띄우지 않는다(그때는 토큰을 stdin 두 줄로 넘긴다)`],
      next: (status) => (status === "done" ? `봇이 이 계정을 쓰게 하려면: homelab bot account use ${name}` : undefined) as string | null,
    });
  },
});
