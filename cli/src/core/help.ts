// 도움말 화면(homelab -h, 묶음 -h, 명령 -h)과 그 JSON. 자료는 명령 정의(summary·help·args·flags)와 등록 표의 분류에서만
// 온다. 플래그 줄은 파서가 받는 목록(allFlags)을 그대로 그려서 도움말과 파서가 어긋날 수 없다.
// 글은 열 수(cols)에 맞춰 접는다. 한글은 두 칸이다. 색은 style.color일 때만 넣는다(파이프·NO_COLOR·--json은 글자만).
import { APPLY_FLAG, GLOBAL_FLAGS, type FlagSpec } from "./args";
import type { CommandSpec } from "./command";
import { jsonStringify } from "./intrinsics";

export type HelpStyle = { color: boolean; cols: number };
export type HelpSection = { title: string; commands: CommandSpec[] };

export const HELP_SCHEMA = "homelab-cli-help/v1";
// 80칸에서 한 줄에 들어가게 짧게 둔다(맨 위 도움말 끝 세 줄).
const PLAN_LINE = "바꾸는 명령은 먼저 계획(plan)만 보여 주고, --apply를 붙여야 실제로 바꿉니다.";
const EXIT_LINE = "종료 코드: 0 끝남·계획, 1 실패, 3 PR 병합·동기화 기다림, 64 사용법 오류";
const EXIT_GITHUB = "github 명령의 종료 코드는 그 명령의 도움말을 봅니다.";
// 열이 이보다 좁으면 설명을 이름 아래 줄로 내린다(옆에 두면 한두 글자씩 접혀 읽을 수 없다).
const MIN_TEXT = 24;

// 파서가 받는 플래그 전부(명령 플래그, 바꾸는 명령의 --apply, 전역). main의 파서도 이것을 쓴다.
export function allFlags(c: CommandSpec): FlagSpec[] {
  return [...c.flags, ...(c.kind === "change" ? [APPLY_FLAG] : []), ...GLOBAL_FLAGS];
}

// 한글·CJK는 터미널에서 두 칸이다.
export function width(s: string): number {
  let w = 0;
  for (const ch of s) w += /[ᄀ-ᅟ⺀-꓏가-힣豈-﫿︰-﹏＀-｠￠-￦]/.test(ch) ? 2 : 1;
  return w;
}

const paint = (st: HelpStyle, code: string) => (s: string) => (st.color ? `\x1b[${code}m${s}\x1b[0m` : s);

// 낱말 단위로 접는다. 한 낱말이 폭보다 길면 글자 단위로 자른다.
export function wrap(text: string, max: number): string[] {
  const lines: string[] = [];
  let line = "";
  const push = (word: string) => {
    if (line === "") line = word;
    else if (width(line) + 1 + width(word) <= max) line += ` ${word}`;
    else {
      lines.push(line);
      line = word;
    }
  };
  for (const word of text.split(" ").filter(Boolean)) {
    if (width(word) <= max) {
      push(word);
      continue;
    }
    let part = "";
    for (const ch of word) {
      if (width(part) + width(ch) > max) {
        push(part);
        part = "";
      }
      part += ch;
    }
    push(part);
  }
  if (line !== "") lines.push(line);
  return lines.length ? lines : [""];
}

const pad = (s: string, w: number) => s + " ".repeat(Math.max(0, w - width(s)));

// 글 한 덩이를 indent만큼 들여 접는다.
function para(text: string, indent: number, st: HelpStyle, tone = (s: string) => s): string[] {
  return wrap(text, Math.max(8, st.cols - indent)).map((l) => " ".repeat(indent) + tone(l));
}

// 두 칸 목록(이름 | 설명). 이름 칸은 cap까지만 넓히고, 넘치는 이름은 설명을 다음 줄로 내린다.
function table(rows: { left: string; right: string }[], st: HelpStyle, cap: number, leftTone: (s: string) => string): string[] {
  const indent = 2;
  const col = Math.min(cap, Math.max(0, ...rows.map((r) => width(r.left)))) + 2;
  const stacked = st.cols - indent - col < MIN_TEXT;
  const out: string[] = [];
  for (const r of rows) {
    const left = wrap(r.left, Math.max(8, st.cols - indent));
    if (stacked) {
      out.push(...left.map((l) => " ".repeat(indent) + leftTone(l)));
      out.push(...para(r.right, indent + 4, st));
      continue;
    }
    const right = wrap(r.right, st.cols - indent - col);
    if (left.length > 1 || width(left[0]) > col - 2) {
      out.push(...left.map((l) => " ".repeat(indent) + leftTone(l)));
      out.push(...right.map((l) => " ".repeat(indent + col) + l));
      continue;
    }
    out.push(" ".repeat(indent) + leftTone(pad(left[0], col)) + right[0]);
    out.push(...right.slice(1).map((l) => " ".repeat(indent + col) + l));
  }
  return out;
}

export function flagLabel(f: FlagSpec): string {
  if (f.name === "help") return "-h, --help";
  const v = f.valueName ?? f.values?.join("|") ?? "값";
  return f.kind === "bool" ? `--${f.name}` : f.kind === "value" ? `--${f.name} <${v}>` : `--${f.name}[=${v}]`;
}

export function shortUsage(c: CommandSpec): string {
  const args = c.args.map((a) => (a.required ? `<${a.name}>` : `[<${a.name}>]`));
  return ["homelab", ...c.path, ...args, "[플래그]"].join(" ");
}

// 제목 줄: 이름과 한 줄 설명. 폭이 모자라면 설명을 다음 줄로.
function title(name: string, summary: string, st: HelpStyle): string[] {
  const b = paint(st, "1");
  if (width(name) + 2 + width(summary) <= st.cols) return [`${b(name)}  ${summary}`];
  return [b(name), ...para(summary, 0, st)];
}

const heading = (st: HelpStyle, s: string) => paint(st, "1")(s);
const NAME_CAP = 20;

function commandRows(cmds: CommandSpec[]) {
  return cmds.map((c) => ({ left: c.path.join(" "), right: c.summary }));
}

export function renderOverview(sections: HelpSection[], st: HelpStyle): string {
  const cyan = paint(st, "36");
  const dim = paint(st, "2");
  const lines = [...title("homelab", "홈랩 운영 도구", st), "", `${heading(st, "사용법")}  homelab <명령> [인자] [플래그]`];
  // 분류마다 이름 칸을 따로 재면 묶음끼리 설명 칸이 어긋난다. 전체에서 한 번 잰다.
  const all = commandRows(sections.flatMap((s) => s.commands));
  const cap = Math.min(NAME_CAP, Math.max(...all.map((r) => width(r.left))));
  for (const s of sections) {
    lines.push("", heading(st, s.title));
    lines.push(...table(commandRows(s.commands).map((r) => ({ ...r, left: pad(r.left, cap) })), st, cap, cyan));
  }
  lines.push("", ...para(PLAN_LINE, 0, st, dim), ...para(EXIT_LINE, 0, st, dim), ...para(EXIT_GITHUB, 0, st, dim), "", ...para("자세히: homelab <명령> -h", 0, st));
  return lines.join("\n") + "\n";
}

export function renderGroup(prefix: string[], cmds: CommandSpec[], st: HelpStyle): string {
  const name = ["homelab", ...prefix].join(" ");
  const lines = [...title(name, `명령 ${cmds.length}개`, st), "", `${heading(st, "사용법")}  ${name} <명령> [인자] [플래그]`, ""];
  lines.push(...table(commandRows(cmds), st, NAME_CAP, paint(st, "36")));
  lines.push("", ...para(`자세히: ${name} <명령> -h`, 0, st));
  return lines.join("\n") + "\n";
}

// subs: 이 명령 경로 아래의 명령(bot → bot account …). 없으면 빈 배열.
export function renderCommand(c: CommandSpec, subs: CommandSpec[], st: HelpStyle): string {
  const cyan = paint(st, "36");
  const dim = paint(st, "2");
  const name = `homelab ${c.path.join(" ")}`;
  const lines = [...title(name, c.summary, st), "", ...para(c.help.about, 0, st)];
  lines.push("", heading(st, "사용법"), ...para(shortUsage(c), 2, st));
  if (c.args.length) {
    lines.push("", heading(st, "인자"));
    lines.push(...table(c.args.map((a) => ({ left: `<${a.name}>`, right: a.required ? a.help : `${a.help}, 생략 가능` })), st, NAME_CAP, cyan));
  }
  lines.push("", heading(st, "플래그"));
  lines.push(...table(allFlags(c).map((f) => ({ left: flagLabel(f), right: f.help })), st, 22, cyan));
  if (c.help.actions?.length) {
    lines.push("", heading(st, "동작"));
    lines.push(...table(c.help.actions.map((a) => ({ left: [a.name, a.target].filter(Boolean).join(" "), right: a.about })), st, 28, cyan));
  }
  if (subs.length) {
    lines.push("", heading(st, "하위 명령"));
    lines.push(...table(commandRows(subs), st, NAME_CAP, cyan));
  }
  lines.push("", heading(st, "예"));
  for (const e of c.help.examples) lines.push(...para(e, 2, st));
  const tail: string[] = [];
  if (c.kind === "change") tail.push(...para("계획과 실행: 이 명령은 먼저 계획(plan)만 보여 주고, --apply를 붙여야 실제로 바꿉니다.", 0, st, dim));
  if (c.help.doc) tail.push(...para(`자세히: ${c.help.doc}`, 0, st));
  if (c.help.related?.length) tail.push(...para(`관련: ${c.help.related.map((r) => `homelab ${r}`).join(" · ")}`, 0, st));
  if (tail.length) lines.push("", ...tail);
  return lines.join("\n") + "\n";
}

function commandDoc(c: CommandSpec, section: string | undefined) {
  return {
    command: c.path.join(" "),
    ...(section ? { section } : {}),
    kind: c.kind,
    summary: c.summary,
    about: c.help.about,
    usage: shortUsage(c),
    args: c.args.map((a) => ({ name: a.name, required: a.required, help: a.help })),
    flags: allFlags(c).map((f) => ({ name: f.name, kind: f.kind, ...(f.kind !== "bool" ? { value: f.valueName ?? f.values?.join("|") ?? "값" } : {}), ...(f.values ? { values: f.values } : {}), help: f.help })),
    ...(c.help.actions ? { actions: c.help.actions } : {}),
    examples: c.help.examples,
    related: (c.help.related ?? []).map((r) => `homelab ${r}`),
    ...(c.help.doc ? { doc: c.help.doc } : {}),
  };
}

const sectionOf = (sections: HelpSection[], c: CommandSpec) => sections.find((s) => s.commands.includes(c))?.title;

export function overviewJson(sections: HelpSection[]): string {
  return jsonStringify({ schema: HELP_SCHEMA, usage: "homelab <명령> [인자] [플래그]", sections: sections.map((s) => ({ title: s.title, commands: s.commands.map((c) => commandDoc(c, undefined)) })), notes: [PLAN_LINE, EXIT_LINE, EXIT_GITHUB] }) + "\n";
}

export function groupJson(sections: HelpSection[], prefix: string[], cmds: CommandSpec[]): string {
  return jsonStringify({ schema: HELP_SCHEMA, group: prefix.join(" "), commands: cmds.map((c) => commandDoc(c, sectionOf(sections, c))) }) + "\n";
}

export function commandJson(sections: HelpSection[], c: CommandSpec, subs: CommandSpec[]): string {
  return jsonStringify({ schema: HELP_SCHEMA, command: commandDoc(c, sectionOf(sections, c)), ...(subs.length ? { subcommands: subs.map((s) => commandDoc(s, sectionOf(sections, s))) } : {}) }) + "\n";
}

function distance(a: string, b: string): number {
  const d = Array.from({ length: a.length + 1 }, (_, i) => [i, ...Array<number>(b.length).fill(0)]);
  for (let j = 1; j <= b.length; j++) d[0][j] = j;
  for (let i = 1; i <= a.length; i++) for (let j = 1; j <= b.length; j++) d[i][j] = Math.min(d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + (a[i - 1] === b[j - 1] ? 0 : 1));
  return d[a.length][b.length];
}

// 친 낱말(word)과 가장 가까운 후보. 둘 이상이 같은 거리면 권하지 않는다(엉뚱한 명령을 권하지 않게).
// 돌려주는 것은 등록 표의 이름뿐이다. 친 말은 되찍지 않는다(시크릿을 잘못 친 경우 출력에 실린다).
export function closest(word: string, candidates: string[]): string | null {
  const limit = word.length <= 4 ? 1 : 2;
  const scored = [...new Set(candidates)].map((c) => ({ c, d: distance(word, c) })).filter((x) => x.d <= limit);
  if (!scored.length) return null;
  const best = Math.min(...scored.map((x) => x.d));
  const top = scored.filter((x) => x.d === best);
  return top.length === 1 ? top[0].c : null;
}
