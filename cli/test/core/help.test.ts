// 도움말 계약(C48). 등록 표의 모든 명령·접두사가 도움말을 갖고, 도움말의 플래그는 실제 파서와 같고, 80칸을 넘지 않는다.
// 기대값은 등록 표가 아니라 바깥에서 본 동작(파서가 받는 플래그, Bun.stringWidth의 칸 수)과 맞춘다.
import { describe, expect, test } from "bun:test";
import { renderCommand, renderGroup, renderOverview } from "../../src/core/help";
import { REGISTRY, SECTIONS } from "../../src/registry";
import { runCli, runCliTty } from "../harness";

const paths = REGISTRY.map((c) => c.path.join(" "));
// 명령 경로의 진짜 접두사(묶음). bot은 명령이면서 bot account의 접두사다.
const prefixes = [...new Set(REGISTRY.flatMap((c) => c.path.slice(0, -1).map((_, i) => c.path.slice(0, i + 1).join(" "))))];
const under = (prefix: string) => paths.filter((p) => p.startsWith(`${prefix} `));
const cols = (line: string) => Bun.stringWidth(line.replace(/\x1b\[[0-9;]*m/g, ""));
const wide = (text: string, max: number) => text.split(/\r?\n/).filter((l) => cols(l) > max);
// 파서가 받는 플래그 집합. 모르는 플래그 오류가 받는 플래그를 모두 나열한다(값은 되찍지 않는다).
async function parserFlags(path: string[]): Promise<string[]> {
  const r = await runCli([...path, "--zz-nope"], []);
  const m = /받는 플래그: ([^)]*)\)/.exec(r.stderr);
  if (!m) throw new Error(`파서 오류 꼴이 다르다: ${r.stderr}`);
  return m[1].split(", ").sort();
}
// 도움말 글에서 플래그 줄의 이름만.
const helpFlags = (text: string) =>
  [...text.matchAll(/^ {2}(?:-h, )?--([a-z-]+)/gm)].map((m) => `--${m[1]}`).sort();

describe("도움말 자료", () => {
  test("모든 명령이 분류 하나에 들고, 한 줄 설명·설명·예를 갖는다", () => {
    const listed = SECTIONS.flatMap((s) => s.commands.map((c) => c.path.join(" ")));
    expect([...listed].sort()).toEqual([...paths].sort());
    expect(new Set(listed).size).toBe(listed.length);
    for (const c of REGISTRY) {
      const name = c.path.join(" ");
      expect([name, c.summary.length > 0 && Bun.stringWidth(c.summary) <= 44]).toEqual([name, true]);
      expect([name, c.help.about.length > 0]).toEqual([name, true]);
      expect([name, c.help.examples.length >= 1 && c.help.examples.length <= 3]).toEqual([name, true]);
      for (const e of c.help.examples) expect(e.startsWith(`homelab ${name}`)).toBe(true);
      for (const r of c.help.related ?? []) expect([name, paths.includes(r)]).toEqual([name, true]);
    }
  });

  test("사람에게 보이는 글에 내부 번호·스크립트 이름이 없다", () => {
    const internal = /\bC\.\d|tools\/|\.sh\b|\bT\d{2}\b|\bC\d{2}\b|레인/;
    for (const c of REGISTRY) {
      const texts = [c.summary, c.help.about, ...c.flags.map((f) => f.help), ...c.args.map((a) => a.help), ...(c.help.actions ?? []).map((a) => a.about)];
      for (const t of texts) expect([c.path.join(" "), t, internal.test(t)]).toEqual([c.path.join(" "), t, false]);
    }
  });

  test("예는 실제 파서를 통과한다(사용법 오류 64가 아니다)", async () => {
    for (const c of REGISTRY) {
      for (const e of c.help.examples) {
        // 계획(plan)으로만 돌린다. 스텁 응답이 없어 실패(1)는 괜찮고 사용법 오류(64)만 아니면 된다.
        const argv = e.split(" ").slice(1).filter((t) => t !== "--apply");
        const r = await runCli([...argv, "--json"], []);
        expect([e, r.code]).not.toEqual([e, 64]);
      }
    }
  }, 120_000);

  test("homelab bot의 동작 목록이 실제로 받는 동작과 같다", async () => {
    const bot = REGISTRY.find((c) => c.path.join(" ") === "bot")!;
    const actions = bot.help.actions!;
    const sample: Record<string, string> = { "<작업 ID>": "0f0f0f0f-0000-4000-8000-000000000001", "<Discord 사용자 ID>": "123456789012345678" };
    for (const a of actions) {
      const r = await runCli(["bot", a.name, ...(a.target ? [sample[a.target] ?? a.target] : []), "--json"], []);
      expect([a.name, a.target, r.code]).not.toEqual([a.name, a.target, 64]);
    }
    // 받는 동작 이름은 모두 목록에 있다.
    const accepted = bot.args[0].pattern!.source.split("|");
    expect([...new Set(actions.map((a) => a.name))].sort()).toEqual([...accepted].sort());
  }, 60_000);
});

describe("맨 위 도움말", () => {
  test("homelab -h·--help·help는 0, 인자 없으면 같은 화면에 64", async () => {
    for (const argv of [["-h"], ["--help"], ["help"], []]) {
      const r = await runCli(argv, []);
      expect([argv.join(" "), r.code]).toEqual([argv.join(" "), argv.length === 0 ? 64 : 0]);
      for (const s of SECTIONS) expect(r.stdout).toContain(s.title);
      for (const p of paths) expect(r.stdout).toMatch(new RegExp(`^ {2}${p} `, "m"));
      expect(r.stdout).toContain("homelab <명령> -h");
      expect(r.stdout).toContain("--apply");
      expect(wide(r.stdout, 80)).toEqual([]);
      // 플래그는 맨 위 목록에 싣지 않는다.
      expect(r.stdout).not.toContain("--backup-first");
    }
  });

  test("--json이면 분류·명령·플래그의 기계용 문서", async () => {
    const r = await runCli(["--help", "--json"], []);
    expect(r.code).toBe(0);
    expect(r.json.schema).toBe("homelab-cli-help/v1");
    expect(r.json.sections.map((s: { title: string }) => s.title)).toEqual(SECTIONS.map((s) => s.title));
    const all = r.json.sections.flatMap((s: { commands: { command: string }[] }) => s.commands.map((c) => c.command));
    expect([...all].sort()).toEqual([...paths].sort());
    const add = r.json.sections.flatMap((s: { commands: any[] }) => s.commands).find((c: any) => c.command === "app add");
    expect(add.flags.map((f: { name: string }) => `--${f.name}`).sort()).toEqual(await parserFlags(["app", "add"]));
    expect(r.stdout).not.toContain("\x1b[");
  });
});

describe("묶음 도움말", () => {
  test("모든 접두사에 -h·--help가 0이고 그 아래 명령을 모두 보인다", async () => {
    expect(prefixes.length).toBeGreaterThan(5);
    for (const p of prefixes) {
      for (const h of ["-h", "--help"]) {
        const r = await runCli([...p.split(" "), h], []);
        expect([p, h, r.code]).toEqual([p, h, 0]);
        for (const c of under(p)) expect([p, r.stdout.includes(c)]).toEqual([p, true]);
        expect(wide(r.stdout, 80)).toEqual([]);
      }
    }
  });

  test("help <묶음>도 같은 화면이다", async () => {
    const a = await runCli(["help", "bot", "account"], []);
    const b = await runCli(["bot", "account", "-h"], []);
    expect([a.code, a.stdout]).toEqual([0, b.stdout]);
  });

  test("묶음만 치면 사용법 오류 대신 도움말을 stdout에 보이고 64", async () => {
    for (const p of prefixes) {
      const r = await runCli(p.split(" "), []);
      expect([p, r.code]).toEqual([p, 64]);
      for (const c of under(p)) expect([p, r.stdout.includes(c)]).toEqual([p, true]);
      expect(r.calls).toEqual([]);
    }
    const bot = await runCli(["bot"], []);
    for (const a of ["emergency-stop", "status", "resume emergency-stop", "resume <작업 ID>", "block <Discord 사용자 ID>", "release <작업 ID>"]) expect(bot.stdout).toContain(a);
  });

  test("묶음만 치고 --json이면 지금처럼 사용법 결과 문서", async () => {
    const r = await runCli(["bot", "--json"], []);
    expect(r.code).toBe(64);
    expect(r.json).toMatchObject({ schema: "homelab-cli/v1", status: "usage" });
  });
});

describe("명령별 도움말", () => {
  for (const c of REGISTRY) {
    const name = c.path.join(" ");
    test(`homelab ${name} -h`, async () => {
      const r = await runCli([...c.path, "-h"], []);
      expect(r.code).toBe(0);
      expect(r.stdout).toStartWith(`homelab ${name}`);
      expect(r.stdout).toContain("사용법");
      expect(r.stdout).toContain(c.summary);
      for (const a of c.args) expect(r.stdout).toContain(`<${a.name}>`);
      expect(helpFlags(r.stdout)).toEqual(await parserFlags(c.path));
      for (const e of c.help.examples) expect(r.stdout).toContain(e);
      if (c.kind === "change") expect(r.stdout).toContain("--apply");
      expect(wide(r.stdout, 80)).toEqual([]);
      const j = await runCli([...c.path, "-h", "--json"], []);
      expect(j.code).toBe(0);
      expect(j.json.schema).toBe("homelab-cli-help/v1");
      expect(j.json.command.command).toBe(name);
      expect(j.json.command.flags.map((f: { name: string }) => `--${f.name}`).sort()).toEqual(await parserFlags(c.path));
    });
  }

  test("필수 인자 없이 명령만 치면 그 명령의 도움말을 stdout에 보이고 64", async () => {
    const r = await runCli(["app", "add"], []);
    expect(r.code).toBe(64);
    expect(r.stdout).toStartWith("homelab app add");
    expect(r.stdout).toContain("--public");
  });

  test("bot -h는 동작 목록과 하위 명령을 보인다", async () => {
    const r = await runCli(["bot", "-h"], []);
    expect(r.code).toBe(0);
    for (const s of under("bot")) expect(r.stdout).toContain(s);
    expect(r.stdout).toContain("block <Discord 사용자 ID>");
  });
});

describe("보기", () => {
  test("터미널이면 색·굵기, 좁은 터미널에서도 폭을 넘지 않는다", async () => {
    const t = await runCliTty(["--help"], [], { cols: 100 });
    expect(t.code).toBe(0);
    expect(t.screen).toContain("\x1b[1m");
    for (const width of [50, 80]) {
      for (const argv of [["--help"], ["cache", "restore", "-h"], ["bot", "-h"]]) {
        const n = await runCliTty(argv, [], { cols: width });
        expect([width, argv.join(" "), wide(n.screen, width)]).toEqual([width, argv.join(" "), []]);
      }
    }
  });

  test("NO_COLOR면 터미널이어도 색이 없다", async () => {
    const t = await runCliTty(["app", "add", "-h"], [], { env: { NO_COLOR: "1" } });
    expect(t.code).toBe(0);
    expect(t.screen).not.toContain("\x1b[");
  });

  test("파이프면 색이 없다", async () => {
    const r = await runCli(["--help"], []);
    expect(r.stdout).not.toContain("\x1b[");
  });
});

describe("오타", () => {
  test("가까운 명령을 한 줄로 권하고 친 말은 되찍지 않는다", async () => {
    const a = await runCli(["stauts"], []);
    expect(a.code).toBe(64);
    expect(a.stderr).toContain("homelab status");
    expect(a.stderr).not.toContain("stauts");
    const b = await runCli(["app", "ad", "smoke"], []);
    expect(b.code).toBe(64);
    expect(b.stderr).toContain("homelab app add");
    expect(b.stderr).not.toContain("ad smoke");
  });

  test("가까운 것이 없으면 권하지 않는다", async () => {
    const r = await runCli(["zzzzzzzzzz"], []);
    expect(r.code).toBe(64);
    expect(r.stderr).not.toContain("혹시");
    expect(r.stderr).toContain("homelab -h");
  });
});

describe("묶음 도움말의 플래그 검증", () => {
  // 묶음도 명령과 같은 파서 규칙: 모르는·중복 플래그는 64, -- 뒤는 플래그가 아니다.
  const bad = [
    ["app", "--bogus", "-h"],
    ["app", "-h", "-h"],
    ["app", "--help", "--json", "--json"],
    ["app", "--", "-h"],
    ["bot", "account", "--bogus", "--help"],
    ["bot", "account", "--", "--help"],
    ["--bogus", "-h"],
    ["-h", "-h"],
    // 맨 앞의 `homelab -- -h`는 시험 하네스(bun <파일> …)에서 bun이 첫 --를 먹어 잴 수 없다. 빌드한 실행 파일로 따로 본다.
  ];
  test("묶음·맨 위에서 틀린 플래그와 함께 -h를 줘도 64", async () => {
    for (const argv of bad) {
      const r = await runCli(argv, []);
      expect([argv.join(" "), r.code]).toEqual([argv.join(" "), 64]);
      // --json이면 사용법 결과 문서가 stdout에 온다. 그 밖에는 도움말을 stdout에 내지 않는다.
      if (argv.includes("--json")) expect(r.json).toMatchObject({ status: "usage" });
      else expect([argv.join(" "), r.stdout]).toEqual([argv.join(" "), ""]);
    }
  });

  test("명령별 -h도 같은 규칙이다", async () => {
    for (const argv of [["app", "add", "--bogus", "-h"], ["app", "add", "-h", "-h"], ["app", "add", "--json", "--json", "-h"], ["app", "add", "--", "-h"], ["bot", "--", "-h"]]) {
      const r = await runCli(argv, []);
      expect([argv.join(" "), r.code]).toEqual([argv.join(" "), 64]);
    }
  });

  test("묶음 사용법 오류는 짧은 사용법과 도움말 위치를 보이고 친 말은 되찍지 않는다", async () => {
    const r = await runCli(["bot", "account", "--hunter2-secret", "-h"], []);
    expect(r.code).toBe(64);
    expect(r.stderr).toContain("사용법 오류");
    expect(r.stderr).toContain("homelab bot account -h");
    expect(r.stderr).not.toContain("hunter2");
    const j = await runCli(["app", "-h", "-h", "--json"], []);
    expect(j.code).toBe(64);
    expect(j.json).toMatchObject({ schema: "homelab-cli/v1", status: "usage" });
  });

  test("맞는 전역 플래그는 그대로 받는다", async () => {
    for (const argv of [["app", "--json", "-h"], ["bot", "account", "--help", "--json"], ["app", "-h", "add"]]) {
      const r = await runCli(argv, []);
      expect([argv.join(" "), r.code]).toEqual([argv.join(" "), 0]);
    }
  });
});

describe("좁은 폭", () => {
  // 등록 표에서 바로 그려 모든 묶음·명령을 30·40·80칸에서 본다(색을 넣어도 칸 수는 같아야 한다).
  test("모든 맨 위·묶음·명령 도움말이 30·40·80칸을 넘지 않는다", () => {
    for (const cols of [30, 40, 80]) {
      for (const color of [false, true]) {
        const st = { color, cols };
        const pages: [string, string][] = [
          ["homelab", renderOverview(SECTIONS, st)],
          ...prefixes.map((p) => [p, renderGroup(p.split(" "), SECTIONS, st)] as [string, string]),
          ...REGISTRY.map((c) => [c.path.join(" "), renderCommand(c, REGISTRY.filter((s) => s.path.length > c.path.length && c.path.every((w, i) => s.path[i] === w)), st)] as [string, string]),
        ];
        for (const [name, text] of pages) expect([cols, color, name, wide(text, cols)]).toEqual([cols, color, name, []]);
      }
    }
  });

  test("터미널 30·40칸에서 맨 위와 모든 묶음이 넘치지 않는다", async () => {
    for (const width of [30, 40]) {
      for (const argv of [["--help"], ...prefixes.map((p) => [...p.split(" "), "-h"])]) {
        const n = await runCliTty(argv, [], { cols: width });
        expect([width, argv.join(" "), n.code, wide(n.screen, width)]).toEqual([width, argv.join(" "), 0, []]);
      }
    }
  }, 120_000);
});

describe("봇 동작 오타", () => {
  test("가까운 동작 이름을 권하고 친 말은 되찍지 않는다(64 그대로)", async () => {
    const a = await runCli(["bot", "stauts"], []);
    expect(a.code).toBe(64);
    expect(a.stderr).toContain("혹시: homelab bot status");
    expect(a.stderr).not.toContain("stauts");
    const b = await runCli(["bot", "emergncy-stop", "--apply"], []);
    expect(b.code).toBe(64);
    expect(b.stderr).toContain("혹시: homelab bot emergency-stop");
    const c = await runCli(["bot", "zzzzzzzzzz"], []);
    expect(c.code).toBe(64);
    expect(c.stderr).not.toContain("혹시");
    // 동작이 맞고 대상만 틀리면 권하지 않는다.
    const d = await runCli(["bot", "resume", "nope"], []);
    expect(d.code).toBe(64);
    expect(d.stderr).not.toContain("혹시");
    // --json 사용법 결과 문서는 지금 꼴 그대로다.
    const j = await runCli(["bot", "stauts", "--json"], []);
    expect(j.code).toBe(64);
    expect(JSON.stringify(j.json)).not.toContain("혹시");
  });
});

describe("되돌릴 수 없는 명령의 예", () => {
  // 되돌릴 수 없는 일을 하는 명령. 표시(help.destructive)를 지우면 이 목록과 어긋나 실패한다.
  const DESTRUCTIVE = ["app remove", "data purge", "db restore", "cache restore", "db rotate", "cache rotate", "cache add", "secret set", "bot account add", "github apply"];
  test("표시가 있는 명령은 정해진 목록과 같다", () => {
    expect(REGISTRY.filter((c) => c.help.destructive).map((c) => c.path.join(" ")).sort()).toEqual([...DESTRUCTIVE].sort());
  });

  test("표시가 있는 명령의 예에는 실행 플래그(--apply, --allow-destroy)가 없고 도움말이 실행 방법을 글로 알린다", async () => {
    for (const c of REGISTRY.filter((x) => x.help.destructive)) {
      const name = c.path.join(" ");
      for (const e of c.help.examples) expect([name, e, /--apply\b|--allow-destroy\b/.test(e)]).toEqual([name, e, false]);
      const r = await runCli([...c.path, "-h"], []);
      // 80칸에서 접힌 줄을 이어 붙여 본다.
      const flat = r.stdout.replace(/\n/g, " ");
      expect(flat).toContain(c.help.destructive!);
      if (c.kind === "change") expect(flat).toContain("확인한 뒤 --apply");
    }
  });

  test("어떤 예도 확인값과 실행 플래그를 함께 싣지 않는다", () => {
    for (const c of REGISTRY) for (const e of c.help.examples) expect([e, /--confirm\b/.test(e) && /--apply\b/.test(e)]).toEqual([e, false]);
  });
});

describe("설명이 실제 동작과 맞다", () => {
  const about = (path: string) => REGISTRY.find((c) => c.path.join(" ") === path)!;
  test("app remove: DB·영속 Valkey는 남고 일반 캐시는 함께 지워진다", () => {
    const c = about("app remove");
    expect(c.help.about).toContain("일반 캐시");
    expect(c.help.about).toContain("영속 Valkey");
    expect(c.help.about).not.toContain("DB·Valkey 데이터는 그대로");
    expect(c.summary).toContain("영속");
  });
  test("secret set: 새 키는 app add PR 병합 뒤, 선언된 키 교체는 바로 secret sync", () => {
    const c = about("secret set");
    expect(c.help.about).toContain("app add");
    expect(c.help.about).toContain("secret sync");
    expect(c.help.related).toContain("app add");
  });
  test("status: 앱 없이 --platform만 주면 플랫폼만 본다", () => {
    const c = about("status");
    expect(c.help.about).toContain("플랫폼만");
    expect(c.flags.find((f) => f.name === "platform")!.help).toContain("플랫폼만");
  });
  test("db restore: 마지막 백업 뒤 시각이면 CLI가 멈추고 사람이 수동 백업을 만든다", () => {
    const c = about("db restore");
    expect(c.help.about).not.toContain("먼저 백업을 하나 만듭니다");
    expect(c.help.about).toContain("수동");
  });
  test("cache rotate: 비워지는 것은 일반 캐시뿐이다", () => {
    expect(about("cache rotate").help.about).toContain("일반 캐시");
  });
  test("db restore-check: 이어 가기는 내용 확인이 끝난 뒤뿐이고 그 전은 --abort 뒤 새로 시작한다", () => {
    const text = about("db restore-check").help.about;
    expect(text).toContain("내용 확인까지 끝난 뒤");
    expect(text).toContain("--abort");
    expect(text).toContain("새로 시작");
  });
});
