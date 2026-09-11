#!/usr/bin/env bats
# 툴링 발견성 — 읽기전용 진입점 just audit + `--help`는 stdout·exit 0 표준.
#
# 스코프는 **homelab 통합 CLI가 라우팅하는 전 표면**과 고빈도 단독 도구 2개다. 노드 열거는
# lib/verbs.ts VERBS 파생이라 손 목록이 없다(리프 + 그룹 노드 + top-level), 그리고 `mcp`는
# VERBS 밖(transport 모드)이지만 CLI가 라우팅하는 표면이므로 **명시 포함**한다.
#
# ⚠️ 도입 커밋(5f330c0, 2026-06-16)의 헤더는 「16개 도구 전체 --help/통합 CLI는 F3 P2」라는 유예를
#    적었다. 그 시점 tools/ 실행물은 16개였고 오늘은 34개다. 유예의 절반(통합 CLI)은 착지했지만
#    **유예를 회수하는 티켓은 존재한 적이 없다** — 그래서 여기서 정리한다:
#      · CLI TREE 전 노드로 넓힌다(이 파일의 아래 @test).
#      · tools/ 34개 전 도구 확장은 **유예가 아니라 기각**이다. 실측: `--help` 문자열을 어떤 형태로든
#        갖는 도구가 6개뿐이라 넓히면 red 28건이고, 그 28개는 대부분 워크플로가 고정 argv로 부르는
#        비대화형 산출물이다(사람이 --help를 구할 표면이 아니다). 발견성의 SSOT는 tools/README.md
#        로스터이고 그쪽은 check-doc-index가 강제한다.
# ⚠️ 중간 단언은 [ ]만 — bash 3.2 [[ ]] 침묵 통과. @test 이름은 영어(인코딩 함정).
bats_require_minimum_version 1.5.0

setup() { ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"; cd "$ROOT" || exit 1; }

@test "audit-orphans --help prints usage and exits 0" {
  run bun tools/audit-orphans.ts --help
  [ "$status" -eq 0 ]
  echo "$output" | grep -qi "audit-orphans"
  echo "$output" | grep -q -- "--ci"
}

@test "poll-ghcr --help prints usage and exits 0 (was: unknown-arg exit 2)" {
  run bun tools/poll-ghcr.ts --help
  [ "$status" -eq 0 ]
  echo "$output" | grep -qi "poll-ghcr"
  echo "$output" | grep -q -- "--root"
}

@test "just audit runs the read-only static drift audit" {
  run just --dry-run audit
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "audit-orphans"
}

@test "every homelab CLI node answers --help on stdout with exit 0 and no stderr (leaves, groups, mcp, top-level)" {
  # 열거는 catalog 파생 — 손 목록이면 동사 추가가 조용히 게이트 밖으로 나간다.
  nodes="$(bun -e '
    import { VERBS } from "./tools/lib/verbs.ts";
    const leaves = VERBS.map((v) => v.path.join(" "));
    const groups = [...new Set(VERBS.filter((v) => v.path.length > 1).map((v) => v.path[0]))];
    // mcp는 transport 모드라 VERBS 밖이지만 CLI가 라우팅하는 표면이라 명시 포함한다.
    for (const n of [...leaves, ...groups, "mcp"]) console.log(n);
  ')"
  want="$(printf '%s\n' "$nodes" | grep -c .)"
  # 빈 열거 = red. 리프 10 + 그룹 3 + mcp = 14가 오늘의 실측이고, 바닥값은 붕괴만 잡는다.
  [ "$want" -ge 14 ]
  n=0
  while IFS= read -r node; do
    [ -n "$node" ] || continue
    # ⚠️ 의도적 비인용 확장 — "db create"는 argv 두 토큰이어야 한다.
    # shellcheck disable=SC2086
    run --separate-stderr bun tools/homelab.ts $node --help
    [ "$status" -eq 0 ]
    [ -n "$output" ]
    [ -z "$stderr" ]
    n=$(( n + 1 ))
  done <<EOF
$nodes
EOF
  # 상한 — 열거한 노드를 **전부** 돌았다(루프 붕괴 시 n < want로 red).
  [ "$n" -eq "$want" ]
  # top-level까지 같은 표준을 지킨다(노드 열거 밖이라 따로 잰다).
  run --separate-stderr bun tools/homelab.ts --help
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  [ -z "$stderr" ]
}

# ── README 동사 표 대조 ────────────────────────────────────────────
# 표는 **손 사본**이다 — README 헤더가 선언한 '손 사본은 반드시 드리프트한다' 규약과의 긴장은
# 의도된 선택이다(docs/adr/0001이 descriptor 파생을 기각했으므로 생성이 아니라 대조로 막는다).
# 그 대조가 아래 세 @test이고, 머지·`--wait` 종결 두 열은 명시 제외 + 각주 왕복으로 대신한다.

@test "the README verb table's verb column equals the contract rows (floors: block, row count, header cells)" {
  run bun -e '
    import { readFileSync } from "node:fs";
    import { CONTRACT_ROWS } from "./tools/lib/catalog-rows.ts";
    const lines = readFileSync("tools/README.md", "utf8").split("\n");
    const head = lines.findIndex((l) => l.startsWith("| 동사 | 디스패처"));
    // 바닥값 ① — 표 블록이 사라지면 "행 0개 = 집합 일치"로 접히지 않고 여기서 죽는다.
    if (head < 0) { console.error("표 블록 미발견: 헤더 행 「| 동사 | 디스패처 …」이 없다"); process.exit(1); }
    const cells = (l) => l.replace(/^\s*\|/, "").replace(/\|\s*$/, "").split("|").map((c) => c.trim().replace(/`/g, ""));
    const header = cells(lines[head]);
    // 바닥값 ③ — 열이 통째로 사라져도 행 등식은 초록이므로 헤더 셀 수를 따로 잰다.
    if (header.length !== 6) { console.error("헤더 셀 " + header.length + " != 6: " + header.join("/")); process.exit(1); }
    const rows = [];
    for (let i = head + 2; i < lines.length && lines[i].startsWith("|"); i++) rows.push(cells(lines[i]));
    // 바닥값 ② — 행 수(계약 행과 같은 10).
    if (rows.length !== 10) { console.error("표 행 " + rows.length + " != 10"); process.exit(1); }
    const want = CONTRACT_ROWS.map((r) => r.verb).join(",");
    const got = rows.map((r) => r[0]).join(",");
    // mcp는 표 밖이다(VERBS 밖 transport 모드) — 등식에서 명시 면제하고 산문(MCP 절)이 담는다.
    if (got !== want) { console.error("동사 열 [" + got + "] != CONTRACT_ROWS [" + want + "]"); process.exit(1); }
    console.log("TABLE_OK " + rows.length + " " + header.length);
  '
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "^TABLE_OK 10 6$"
}

@test "the README verb table derives its dispatcher, convergence and variant columns from the lane and contract rows" {
  run bun -e '
    import { readFileSync } from "node:fs";
    import { CONTRACT_ROWS, LANES } from "./tools/lib/catalog-rows.ts";
    const lines = readFileSync("tools/README.md", "utf8").split("\n");
    const head = lines.findIndex((l) => l.startsWith("| 동사 | 디스패처"));
    if (head < 0) { console.error("표 블록 미발견"); process.exit(1); }
    const cells = (l) => l.replace(/^\s*\|/, "").replace(/\|\s*$/, "").split("|").map((c) => c.trim().replace(/`/g, ""));
    const rows = [];
    for (let i = head + 2; i < lines.length && lines[i].startsWith("|"); i++) rows.push(cells(lines[i]));
    if (rows.length !== CONTRACT_ROWS.length) { console.error("표 행 " + rows.length + " != 계약 행 " + CONTRACT_ROWS.length); process.exit(1); }
    const set = (s) => s.split("·").map((x) => x.trim()).filter(Boolean).sort().join(",");
    // ⚠️ verb→LaneAction 사상은 정적으로 파생되지 않는다(`app teardown`은 결과 형상이 갈려
    // simple 행이라 mutation.action이 없다). 그래서 디스패처 열은 **커버리지 등식**으로 잰다:
    // 표에 등장한 워크플로 집합 = LANES 전체(5), 각 이름은 한 번만, 그리고 그 행의 수렴 열은
    // 그 레인의 applications와 일치. 손 사상 없이도 오배치·누락이 red가 된다.
    const seen = new Map();
    let n = 0;
    for (const row of CONTRACT_ROWS) {
      const cell = rows[n];
      let lane = null;
      if (row.mutation) {
        lane = LANES[row.mutation.action];
        if (cell[1] !== lane.workflow) { console.error(row.verb + ": 디스패처 [" + cell[1] + "] != " + lane.workflow); process.exit(1); }
      } else if (cell[1] !== "—") {
        lane = Object.values(LANES).find((l) => l.workflow === cell[1]) ?? null;
        if (lane === null) { console.error(row.verb + ": 디스패처 [" + cell[1] + "]는 LANES에 없는 워크플로다"); process.exit(1); }
      }
      if (lane !== null) {
        if (seen.has(lane.workflow)) { console.error(lane.workflow + ": 두 행이 같은 레인을 주장한다(" + seen.get(lane.workflow) + " · " + row.verb + ")"); process.exit(1); }
        seen.set(lane.workflow, row.verb);
      }
      // 수렴 Application 열 — 레인 행의 이름을 {key} 치환한 집합(레인 없는 동사는 「—」).
      const wantApps = lane ? lane.applications.map((a) => a.name.split("{key}").join("<app>")).join(" · ") : "—";
      if (set(cell[4]) !== set(wantApps)) { console.error(row.verb + ": 수렴 [" + cell[4] + "] != " + wantApps); process.exit(1); }
      // variant 열 — 계약 행의 허용 집합(순서 무관).
      const wantVars = [...new Set(row.mutation ? row.mutation.variants : row.simple.flatMap((s) => s.variants))];
      if (set(cell[5]) !== set(wantVars.join("·"))) { console.error(row.verb + ": variant [" + cell[5] + "] != " + wantVars.join("·")); process.exit(1); }
      n++;
    }
    // 상한 — 계약 행을 **전부** 돌았다(루프 붕괴 시 n < 행 수).
    if (n !== CONTRACT_ROWS.length) { console.error("대조 " + n + "행 != " + CONTRACT_ROWS.length); process.exit(1); }
    // 커버리지 등식 — 레인 5개가 표에 정확히 한 번씩 등장한다(누락 = red, 바닥값 포함).
    const laneWfs = Object.values(LANES).map((l) => l.workflow).sort().join(",");
    const tableWfs = [...seen.keys()].sort().join(",");
    if (laneWfs !== tableWfs) { console.error("레인 커버리지 [" + tableWfs + "] != LANES [" + laneWfs + "]"); process.exit(1); }
    if (seen.size !== 5) { console.error("레인 " + seen.size + "건 != 5(바닥값)"); process.exit(1); }
    console.log("COLUMNS_OK " + n + " " + seen.size);
  '
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "^COLUMNS_OK 10 5$"
}

@test "the merge and --wait columns are excluded from that equality and their footnotes cite live verbs.ts lines" {
  # 머지 모드·--wait 종결은 export되지 않는 **인라인 리터럴**(verbs.ts의 manualMerge/converge)이라
  # 정적 등식을 세우면 원장의 두 함정(정적 증인이 자기 도메인 표기법에 눈멀기 · 이름 있는 집합의
  # 상한 부재)을 그대로 밟는다. 대신 각주가 준 file:line이 그 리터럴을 실제로 가리키는지 왕복으로 잰다.
  run bun -e '
    import { readFileSync } from "node:fs";
    const md = readFileSync("tools/README.md", "utf8");
    const src = readFileSync("tools/lib/verbs.ts", "utf8").split("\n");
    const refs = [...md.matchAll(/tools\/lib\/verbs\.ts:(\d+)/g)].map((m) => Number(m[1]));
    // 바닥값 — 각주 3개(공개 승인·파괴 승인·converge absence)가 최소치다.
    if (refs.length < 3) { console.error("각주 file:line " + refs.length + "건 < 3"); process.exit(1); }
    let hit = 0;
    for (const n of refs) {
      const line = src[n - 1] ?? "";
      if (line.indexOf("manualMerge") < 0 && line.indexOf("converge") < 0) {
        console.error("각주가 가리키는 verbs.ts:" + n + "이 manualMerge/converge 리터럴이 아니다: [" + line.trim() + "]");
        process.exit(1);
      }
      hit++;
    }
    if (hit !== refs.length) { console.error("왕복 " + hit + " != " + refs.length); process.exit(1); }
    console.log("FOOTNOTES_OK " + hit);
  '
  [ "$status" -eq 0 ]
  echo "$output" | grep -qE "^FOOTNOTES_OK [3-9][0-9]*$"
}

@test "the README CLI section carries a synopsis line for every catalog verb (floor = VERBS length)" {
  # 열거는 catalog 파생이라 동사가 늘면 README가 함께 red가 된다.
  run bun -e '
    import { readFileSync } from "node:fs";
    import { VERBS } from "./tools/lib/verbs.ts";
    const md = readFileSync("tools/README.md", "utf8");
    if (VERBS.length < 10) { console.error("VERBS " + VERBS.length + " < 10(바닥값)"); process.exit(1); }
    let n = 0;
    for (const v of VERBS) {
      // 인자 있는 동사는 뒤에 공백이, 인자 없는 동사는 닫는 백틱이 온다 — 둘 다 시놉시스다.
      const lit = "`homelab " + v.path.join(" ");
      if (md.indexOf(lit + " ") < 0 && md.indexOf(lit + "`") < 0) { console.error("README에 시놉시스 없음: " + lit); process.exit(1); }
      n++;
    }
    if (n !== VERBS.length) { console.error("대조 " + n + " != " + VERBS.length); process.exit(1); }
    console.log("SYNOPSIS_OK " + n);
  '
  [ "$status" -eq 0 ]
  echo "$output" | grep -qE "^SYNOPSIS_OK [1-9][0-9]+$"
}

# ── 빠른 시작 블록·코드 근거 앵커 ─────────────────────────────────

@test "every homelab line in the README quickstart routes to a real catalog verb (floor 5)" {
  # 블록의 각 줄이 실재 동사 경로여야 한다 —
  # 오타·폐기된 동사가 들어가면 red다(사람이 그대로 복사해 붙이는 줄이라 값이 크다).
  run bun -e '
    import { readFileSync } from "node:fs";
    import { VERBS } from "./tools/lib/verbs.ts";
    const lines = readFileSync("tools/README.md", "utf8").split("\n");
    const start = lines.findIndex((l) => l.startsWith("### 빠른 시작"));
    if (start < 0) { console.error("빠른 시작 절 미발견"); process.exit(1); }
    const open = lines.indexOf("```bash", start);
    if (open < 0) { console.error("빠른 시작 코드블록 미발견"); process.exit(1); }
    const close = lines.indexOf("```", open + 1);
    if (close < 0) { console.error("코드블록이 닫히지 않았다"); process.exit(1); }
    const paths = VERBS.map((v) => v.path.join(" "));
    let n = 0;
    for (const raw of lines.slice(open + 1, close)) {
      const cmd = raw.replace(/^\s+/, "");
      if (!cmd.startsWith("homelab ")) continue;
      const rest = cmd.slice("homelab ".length);
      const hit = paths.filter((p) => rest === p || rest.startsWith(p + " "));
      if (hit.length === 0) { console.error("catalog 밖 동사: " + cmd); process.exit(1); }
      n++;
    }
    // 바닥값 — 블록이 비거나 주석만 남으면 "전건 통과"로 접히지 않는다.
    if (n < 5) { console.error("빠른 시작의 homelab 줄 " + n + "건 < 5"); process.exit(1); }
    console.log("QUICKSTART_OK " + n);
  '
  [ "$status" -eq 0 ]
  echo "$output" | grep -qE "^QUICKSTART_OK [5-9]|^QUICKSTART_OK [1-9][0-9]"
}

@test "every file:line code citation in the README resolves to a non-empty line in that file (floor 4)" {
  # 각주·근거 표기는 손 사본이라 파일이 움직이면 조용히 엉뚱한 줄을 가리킨다. 최소한 그 줄이
  # 실재하고 비어 있지 않은지는 기계가 잰다(개별 리터럴 왕복은 위 각주 @test가 따로 맡는다).
  run bun -e '
    import { existsSync, readFileSync } from "node:fs";
    const md = readFileSync("tools/README.md", "utf8");
    const refs = [...md.matchAll(/(tools\/[A-Za-z0-9_./-]+\.ts):(\d+)/g)];
    // 바닥값 — 인용이 통째로 지워지면 "전건 유효"가 되지 않는다.
    if (refs.length < 4) { console.error("file:line 인용 " + refs.length + "건 < 4"); process.exit(1); }
    let n = 0;
    for (const m of refs) {
      const [, file, num] = m;
      if (!existsSync(file)) { console.error("인용한 파일 부재: " + file); process.exit(1); }
      const src = readFileSync(file, "utf8").split("\n");
      const i = Number(num);
      if (!(i >= 1 && i <= src.length)) { console.error(file + ":" + i + " — 줄 범위 밖(총 " + src.length + "줄)"); process.exit(1); }
      if (src[i - 1].trim() === "") { console.error(file + ":" + i + " — 빈 줄을 가리킨다"); process.exit(1); }
      n++;
    }
    if (n !== refs.length) { console.error("검증 " + n + " != " + refs.length); process.exit(1); }
    console.log("CITATIONS_OK " + n);
  '
  [ "$status" -eq 0 ]
  echo "$output" | grep -qE "^CITATIONS_OK [4-9]|^CITATIONS_OK [1-9][0-9]"
}

@test "the MCP server registration recipe lives in both the README and mcp --help, with the KUBECONFIG-absent outcome" {
  # 전부 **양성** grep이라 표기가 사라지면 red다.
  run grep -c "claude mcp add homelab" tools/README.md
  [ "$status" -eq 0 ]
  [ "$output" -ge 1 ]
  grep -q "KUBECONFIG" tools/README.md
  # KUBECONFIG 부재 시 관측 결과 두 가지(url 동사 = variant skip · status = 라이브 계층 생략).
  grep -q "variant skip" tools/README.md
  grep -q 'omitted=\["live"\]' tools/README.md
  run --separate-stderr bun tools/homelab.ts mcp --help
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "claude mcp add homelab"
  echo "$output" | grep -q "KUBECONFIG"
}
