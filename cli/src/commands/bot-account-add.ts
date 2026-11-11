// homelab bot account add <이름> [--by subscription|api] [--separate-tokens]: 봇이 쓸 Claude 계정 등록(봇 COLLEAGUE_SPEC §4.8 "계정 등록").
// 자리가 둘이다: 대화용(대화와 PR 리뷰)과 작업용(코드 변경 작성). 기본은 값 하나를 두 자리에 함께 쓴다(로그인 한 번, 사용자 결정
// 2026-11-11). --separate-tokens면 자리마다 따로 받는다(한쪽만 교체·철회하거나, 샌 값으로 어느 자리인지 가르려면).
// - 구독(기본): tty면 `claude setup-token`을 가짜 터미널로 띄워 owner는 브라우저 로그인만 하고, CLI가 화면에서 토큰 줄을 받는다.
//   화면에는 토큰 줄을 가려 보인다. 출력 꼴이 관측과 다르면 지금처럼 토큰이 보이고 가려진 입력으로 받는다. 그래서 `claude`가
//   이 CLI를 돌리는 기기에 있어야 한다. stderr가 터미널이 아니면 로그인을 띄우지 않는다.
// - API 크레딧(--by api): Claude Console에서 만든 API 키를 가려진 입력으로 받는다. 자식을 띄우지 않는다.
// 파이프면 stdin 한 줄(--separate-tokens면 대화용·작업용 두 줄)이다. 값은 argv·출력·파일에 두지 않고(secret set과 같은 입력 경로)
// Infisical 계정 폴더에만 둔다. 작업자 키는 바꾸지 않는다(그건 account use). 다 받은 뒤에만 쓴다. 끝나면 관리 진입점으로 봇 DB에
// 이름·방식(·구독이면 발급일)을 적는다.
import { defineCommand, type BotAdminCommand, type BotMethod, type Observation, type Step } from "../core/command";
import { BOT_ACCOUNT_NAME, BOT_LANES, botAccountFolder, botLaneKey } from "../core/names";
import { CliError } from "../core/result";

const same = (detail: string, warn?: string): Observation => ({ state: "same", action: "none", detail, ...(warn ? { warn } : {}) });

export default defineCommand({
  path: ["bot", "account", "add"],
  summary: "봇 계정 등록(구독: claude setup-token 로그인 한 번, API 크레딧: Console API 키. 대화용·작업용에 함께 쓴다, 값은 stdin·tty)",
  kind: "change",
  args: [{ name: "name", required: true, help: "계정 이름(소문자·숫자·하이픈, 32자 이하)", pattern: BOT_ACCOUNT_NAME }],
  flags: [
    { name: "by", kind: "value", valueName: "방식", help: "subscription(기본, 구독 장기 토큰) 또는 api(API 크레딧, Console API 키)", values: ["subscription", "api"] },
    { name: "replace", kind: "bool", help: "이미 등록한 계정의 값을 새로 받는다(만료 전 교체·키 교체)" },
    { name: "separate-tokens", kind: "bool", help: "대화용·작업용에 토큰(API 키)을 따로 받는다(기본은 하나를 함께 쓴다)" },
    { name: "verbose", kind: "bool", help: "터미널에서도 단계 표 전체를 보인다" },
  ],
  async run(ctx, input) {
    const name = input.args.name as string;
    const method: BotMethod = input.flags.by === "api" ? "api" : "subscription";
    const api = method === "api";
    const replace = input.flags.replace === true;
    const separate = input.flags["separate-tokens"] === true;
    const folder = botAccountFolder(name);
    const keys = BOT_LANES.map((l) => botLaneKey(l, method));
    const what = api ? "API 키" : "토큰";
    const how = separate ? `대화용·작업용 ${what}를 따로` : `${what} 하나를 대화용·작업용에 함께`;
    // 이 실행이 쓴 두 값의 해시. 재조회가 이것과 같아야 same이다(다시 실행하면 --replace는 다시 받는다).
    let written: string[] | null = null;
    let recorded = false;

    const values: Step = {
      id: "infisical-account",
      target: `Infisical homelab/prod ${folder}${api ? " (API 크레딧)" : ""}`,
      async read(c) {
        const has = c.infisical.folderExists(folder);
        const hashes = keys.map((k) => (has ? c.infisical.valueHash(folder, k) : null));
        if (written !== null && hashes.every((h, i) => h === written![i])) return same(`${how} 저장했다`);
        if (hashes.every((h) => h !== null) && !replace) return same(`대화용·작업용 ${what} 있음(그대로. 새로 받으려면 --replace)`);
        const missing = keys.filter((_, i) => hashes[i] === null);
        const source = api ? "Console API 키를 받아" : separate ? "claude setup-token을 자리마다 띄워 받아" : "claude setup-token 로그인 한 번으로 받아";
        return { state: missing.length ? "missing" : "differs", action: missing.length ? "create" : "update",
          detail: `${missing.length ? `없음(${missing.join(", ")})` : "있음(--replace)"} → ${source} ${how} 저장(값은 tty·stdin)` };
      },
      async apply(w) {
        const labels = BOT_LANES.map((l) => l.label);
        const got = api ? await w.readApiKeys(labels, separate) : await w.readSetupTokens(labels, separate);
        // 쓰기 전에 기억한다. 서버에는 반영됐는데 응답이 시간 초과면 엔진이 다시 읽어 이 해시로 반영을 확인한다.
        written = got.map((v) => v.sha256Prefix(12));
        if (!w.infisical.folderExists(folder)) w.infisical.createFolder(folder);
        keys.forEach((k, i) => w.infisical.setValue(folder, k, got[i]));
      },
    };

    const cmd: BotAdminCommand = { name: "account", action: "record", account: name, method };
    const record: Step = {
      id: "bot-account-record",
      target: `봇 DB 계정 기록 ${name}(${api ? "API 크레딧" : "구독"})`,
      async read(c) {
        if (recorded) return same(api ? "이름·방식을 적었다" : "이름·방식·발급일을 적었다");
        return { state: "differs", action: "update", detail: `${api ? "기록이 없으면 만든다" : "토큰을 새로 저장했으면 발급일을 적는다, 기록이 없으면 만든다"}. 실행: ${c.bot.argv(c.bot.pod(), cmd).join(" ")}` };
      },
      async apply(w) {
        // 이 실행이 값을 쓰지 않았으면 발급일을 바꾸지 않는다. 기록이 없을 때만(앞 실행이 값을 쓰고 여기서 멈춘 경우) 적는다.
        if (written === null) {
          const list = w.bot.admin({ name: "account", action: "list" });
          if (list.exit === 0 && list.accounts?.some((a) => a.name === name && a.method === method)) {
            recorded = true;
            return;
          }
        }
        const report = w.bot.admin(cmd);
        if (report.exit !== 0 || report.result !== "recorded")
          throw new CliError(`봇이 계정을 기록하지 않았다: ${report.result}`, report.result === "usage" || report.result === "unsupported"
            ? `지금 봇 이미지의 관리 진입점이 이 계정 명령을 받지 않는다(${api ? "봇 C23" : "봇 C22"} 이전 이미지). 봇 배포 버전을 확인한 뒤 같은 명령을 다시 실행한다`
            : `같은 명령을 다시 실행한다(저장한 ${what}는 그대로 두고 기록만 한다)`);
        recorded = true;
      },
    };

    return ctx.engine({
      command: "bot account add",
      steps: [values, record],
      notes: [api
        ? `API 키는 Claude Console의 봇 전용 workspace에서 만든다(자동 충전 끔, rotate.md 3e). 키는 화면에 보이지 않게 붙여 넣거나 stdin으로 넘긴다(기본 한 줄, --separate-tokens면 대화용·작업용 두 줄)`
        : "claude setup-token은 이 기기에서 실행한다(Claude Code CLI 필요). CLI가 화면에서 토큰 줄을 받아 가린다. 출력 꼴이 달라 받지 못하면 화면에 나온 토큰을 붙여 넣고 터미널 스크롤을 지운다. stderr가 터미널이 아니면 로그인을 띄우지 않는다(그때는 토큰을 stdin으로 넘긴다)"],
      next: (status) => (status === "done" ? `봇이 이 계정을 쓰게 하려면: homelab bot account use ${name}${api ? " --by api" : ""}` : undefined) as string | null,
    });
  },
});
