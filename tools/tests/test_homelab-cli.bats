#!/usr/bin/env bats
# homelab CLI 진입점 — 서브커맨드 라우팅·사용법·종료코드·설치(bin) 계약(전 동사 착지).
# 계약 SSOT: --json 결과 오브젝트·variant·종료코드 매핑은 tools/cli-result-schema.json.
# 라우팅 커널은 tools/lib/cli.ts parseCommand(fail-closed) — 여기서는 CLI 프로세스 경계로 단언한다.
# ⚠️ 중간 단언은 [ ]만 — bash 3.2 [[ ]] 침묵 통과. @test 이름은 영어(인코딩 함정).
bats_require_minimum_version 1.5.0

setup() { ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"; cd "$ROOT" || exit 1; }

@test "homelab --help enumerates the verb hierarchy and exits 0" {
  run bun tools/homelab.ts --help
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "doctor"
  echo "$output" | grep -q "사용법"
  echo "$output" | grep -q -- "--json"
}

@test "bare homelab is a usage error: exit 2, usage on stderr, empty stdout" {
  run --separate-stderr bun tools/homelab.ts
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  echo "$stderr" | grep -q "사용법"
}

@test "unknown verb exits 2 and lists the available vocabulary" {
  run --separate-stderr bun tools/homelab.ts bogus
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  echo "$stderr" | grep -q "알 수 없는 서브커맨드: bogus"
  echo "$stderr" | grep -q "doctor"
}

@test "unknown flag on doctor exits 2 with usage on stderr" {
  run --separate-stderr bun tools/homelab.ts doctor --bogus
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  echo "$stderr" | grep -q -- "--bogus"
  echo "$stderr" | grep -q "사용법"
}

@test "homelab doctor --help prints the verb usage and exits 0" {
  run bun tools/homelab.ts doctor --help
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "doctor"
  echo "$output" | grep -q -- "--json"
}

@test "doctor --json --help: help wins over json — usage text on stdout, no envelope (contract exception)" {
  # 계약(x-contract.stdout): --help는 --json보다 우선한다 — 사용법 질의는 동사 실행 결과가 아니다.
  run --separate-stderr bun tools/homelab.ts doctor --json --help
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "사용법: homelab doctor"
  case "$output" in "{"*) false ;; *) : ;; esac
}

@test "package.json exposes homelab as a bun bin and the entrypoint carries a bun shebang with exec bit" {
  run jq -r '.bin.homelab' package.json
  [ "$output" = "tools/homelab.ts" ]
  run head -1 tools/homelab.ts
  [ "$output" = "#!/usr/bin/env bun" ]
  mode=$(git ls-files -s tools/homelab.ts | awk '{print $1}')
  [ "$mode" = "100755" ]
}

@test "result schema pins envelope version, all variants, and the exit-code map" {
  run jq -r '."x-contract".envelope' tools/cli-result-schema.json
  [ "$output" = "homelab-cli/1" ]
  run jq -r '.properties.variant.enum | join(",")' tools/cli-result-schema.json
  [ "$output" = "success,failure,race,skip,pending,no-op,superseded" ]
  run jq -r '."x-contract".exitCodes | to_entries | map("\(.key)=\(.value)") | join(",")' tools/cli-result-schema.json
  [ "$output" = "success=0,failure=1,race=3,skip=4,pending=1,no-op=0,superseded=3" ]
  run jq -r '."x-contract".usageExit' tools/cli-result-schema.json
  [ "$output" = "2" ]
}

@test "mcp variant lists partition the variant enum and an unknown variant fails closed (floor 7)" {
  # contract-4: mcpIsError는 exitFor와 극성이 같아야 한다 — 미지 variant는 조용한 '정상'이 아니라
  # 계약 파손이다. 분할(합집합=variant enum · 교집합 0 · exitCodes 키 집합 동일)은 생성기가 생성
  # 시점에 단언하고, 여기서는 커밋된 생성물과 런타임 리더로 다시 잰다.
  run bun -e '
    import { readFileSync } from "node:fs";
    import { mcpIsError } from "./tools/lib/contract.ts";
    const sch = JSON.parse(readFileSync("tools/cli-result-schema.json", "utf8"));
    const isErr = sch["x-contract"].mcp.isErrorVariants;
    const normal = sch["x-contract"].mcp.normalVariants;
    const all = sch.properties.variant.enum;
    const union = new Set([...isErr, ...normal]);
    if (union.size !== all.length || !all.every((v) => union.has(v))) { console.error("분할 아님: " + JSON.stringify([...union])); process.exit(1); }
    const inter = isErr.filter((v) => normal.includes(v));
    if (inter.length !== 0) { console.error("교집합 비지 않음: " + inter.join(",")); process.exit(1); }
    const keys = Object.keys(sch["x-contract"].exitCodes).sort().join(",");
    if (keys !== [...all].sort().join(",")) { console.error("exitCodes 키 집합 어긋남: " + keys); process.exit(1); }
    // 양성 대조 — 두 목록의 전 원소가 실제로 판정된다(리더가 살아 있다).
    let n = 0;
    for (const v of isErr) { if (mcpIsError(v) !== true) { console.error("isError 아님: " + v); process.exit(1); } n++; }
    for (const v of normal) { if (mcpIsError(v) !== false) { console.error("normal 아님: " + v); process.exit(1); } n++; }
    // 부정 단언 — 미지 variant는 throw(같은 @test 안에 위의 양성 대조가 있다).
    let threw = false;
    try { mcpIsError("bogus"); } catch { threw = true; }
    if (!threw) { console.error("mcpIsError(bogus)가 throw하지 않았다"); process.exit(1); }
    console.log("partition:" + n);
  '
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "^partition:7$"
}

@test "the v1 contract root is hand-anchored (required set + property order — destructive-change witness)" {
  # 버전 규칙(tools/README.md '버전 규칙' 3줄)의 증인: 추가는 v1 호환이고, **삭제·필수화·enum 축소**는
  # /2 승격이다. 골든은 엔진과 함께 재생성되므로 파괴적 변경을 못 잡는다 — 루트 앵커 2줄이 잡는다.
  # 편집처는 생성기(HEADER_A)다(생성물 직접 편집 금지).
  run jq -r '.required | join(",")' tools/cli-result-schema.json
  [ "$output" = "schema,verb,variant,exitCode,omitted,result" ]
  run jq -r '.properties | keys_unsorted | join(",")' tools/cli-result-schema.json
  [ "$output" = "schema,verb,variant,exitCode,omitted,result" ]
}

@test "schema validates the per-verb allowed-outcome matrix and rejects disallowed variants (counts derived from contract rows)" {
  # structure r1 시도2 A2·B2: verb만 result를 고르면 불가능한 variant(doctor+pending 등)가 valid로
  # 남는다 — verb 분기가 허용 variant 집합까지 선언하고, verb별 허용∪비허용 = variant 전체(7종).
  # 표본 result는 공유 코퍼스(helpers/contract-samples.ts)가 SSOT — 축자 이중 사본 제거(티켓 05).
  # 바닥값은 계약 행(CONTRACT_ROWS)에서 파생한다 — 손 재계산(구 36/34) 대체. 열거 붕괴 방지의
  # 손 앵커는 파생 밖에 남는다: oneOf 분기 수 34 · 계약 행 수 10 (exitCodes 리터럴 7쌍 핀은
  # 위의 "result schema pins …" @test가 소유). doctor·status 행 분할(티켓 25)로 분기가 32→34가
  # 됐지만 **variant 셀 총합 39는 불변**이다 — 분할이 셀을 잃지 않았다는 증거.
  run bun -e '
    import { schemaErrors } from "./tools/lib/schema-check.ts";
    import { CONTRACT_ROWS } from "./tools/lib/catalog-rows.ts";
    import { buildSamples, matrixCellCounts } from "./tools/tests/helpers/contract-samples.ts";
    import { readFileSync } from "node:fs";
    const sch = JSON.parse(readFileSync("tools/cli-result-schema.json", "utf8"));
    const map = sch["x-contract"].exitCodes;
    const all = sch.properties.variant.enum;
    const verbBranches = sch.allOf.find((b) => b.oneOf?.[0]?.properties?.verb)?.oneOf ?? [];
    if (verbBranches.length !== 34) { console.error("oneOf 분기 수 " + verbBranches.length + " != 34(손 앵커)"); process.exit(1); }
    if (CONTRACT_ROWS.length !== 10) { console.error("계약 행 수 " + CONTRACT_ROWS.length + " != 10(손 앵커)"); process.exit(1); }
    // variant 셀 총합 핀 — 다중 variant 엔트리에서 variant가 지워지면 분기·행 수는 그대로인 채
    // 파생과 워커가 함께 내려가 초록이 된다(리뷰 실측) — 구판 ok:36 리터럴의 정확한 복원이다.
    const cellTotal = verbBranches.reduce((n, b) => n + b.properties.variant.enum.length, 0);
    if (cellTotal !== 39) { console.error("variant 셀 총합 " + cellTotal + " != 39(손 앵커)"); process.exit(1); }
    const SAMPLES = buildSamples(sch.definitions.doctorCheck.properties.id.enum);
    const byVerb = {};
    for (const br of verbBranches) (byVerb[br.properties.verb.enum[0]] ??= []).push(br);
    let okN = 0, rejN = 0;
    for (const [verb, brs] of Object.entries(byVerb)) {
      const allowed = new Set(brs.flatMap((b) => b.properties.variant.enum));
      if (allowed.size === 0) { console.error(verb + ": 허용 variant 선언 없음"); process.exit(1); }
      for (const br of brs) for (const v of br.properties.variant.enum) {
        const result = SAMPLES[verb + "|" + v];
        if (result === undefined) { console.error(verb + "|" + v + ": SAMPLES에 유효 표본 없음"); process.exit(1); }
        const env = { schema: "homelab-cli/1", verb, variant: v, exitCode: map[v], omitted: [], result };
        if (schemaErrors(env, sch, sch).length) { console.error("허용 조합 거부됨: " + verb + "+" + v); process.exit(1); }
        okN++;
      }
      const anySample = SAMPLES[verb + "|" + [...allowed][0]];
      for (const v of all.filter((x) => !allowed.has(x))) {
        const env = { schema: "homelab-cli/1", verb, variant: v, exitCode: map[v], omitted: [], result: anySample };
        if (schemaErrors(env, sch, sch).length === 0) { console.error("비허용 조합 통과: " + verb + "+" + v); process.exit(1); }
        rejN++;
      }
    }
    const want = matrixCellCounts(CONTRACT_ROWS, all.length);
    if (okN !== want.allowed || rejN !== want.rejected) {
      console.error("행 파생 바닥값 불일치: ok=" + okN + "/" + want.allowed + " rej=" + rejN + "/" + want.rejected);
      process.exit(1);
    }
    console.log("ok");
  '
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "^ok$"
}

@test "variant-shape coupling rejects mis-shaped results on the split rows (floor 5, with controls)" {
  # contract-5 실측: 행이 verb→variant 집합만 묶고 variant→result 형상을 묶지 않던 동안, 아래 다섯은
  # 전부 스키마 유효였다(success에 error가 실린 envelope · failure에 성공 형상 · doctor의 exitCode
  # 거짓말). doctor는 summary.fail을 maximum:0/minimum:1로 갈라 **스키마가 독립 검출**하게 하고,
  # status는 success(list|app|run|pr)/failure(statusError)로 나눠 닫았다.
  run bun -e '
    import { schemaErrors } from "./tools/lib/schema-check.ts";
    import { readFileSync } from "node:fs";
    const sch = JSON.parse(readFileSync("tools/cli-result-schema.json", "utf8"));
    const ids = sch.definitions.doctorCheck.properties.id.enum;
    const checks = (fail) => ids.map((id, i) => ({ id, status: i < fail ? "fail" : "pass", detail: "x" }));
    const doctor = (fail) => ({ checks: checks(fail), summary: { pass: ids.length - fail, fail, warn: 0 } });
    const env = (verb, variant, result) => ({ schema: "homelab-cli/1", verb, variant, exitCode: sch["x-contract"].exitCodes[variant], omitted: [], result });
    const rejected = [
      ["status success carrying an error branch", env("status", "success", { mode: "app", error: "x" })],
      ["status failure carrying a list result", env("status", "failure", { mode: "list", repo: { root: "/x" }, apps: [], count: 0 })],
      ["status failure carrying a run result", env("status", "failure", { mode: "run", run: { status: "completed", url: "u" } })],
      ["doctor success with fail 9 (exitCode lie)", env("doctor", "success", doctor(9))],
      ["doctor failure with fail 0 (exitCode lie)", env("doctor", "failure", doctor(0))],
    ];
    let n = 0;
    for (const [label, e] of rejected) {
      if (schemaErrors(e, sch, sch).length === 0) { console.error("ACCEPTED(통과해선 안 됨): " + label); process.exit(1); }
      n++;
    }
    // 양성 대조 — 정상 형상 4종은 그대로 통과해야 한다(분할이 정당한 산출물을 죽이지 않는다).
    const accepted = [
      ["doctor success fail 0", env("doctor", "success", doctor(0))],
      ["doctor failure fail 1", env("doctor", "failure", doctor(1))],
      ["status success list", env("status", "success", { mode: "list", repo: { root: "/x" }, apps: [], count: 0 })],
      ["status failure app error", env("status", "failure", { mode: "app", error: "x" })],
    ];
    for (const [label, e] of accepted) {
      const errs = schemaErrors(e, sch, sch);
      if (errs.length) { console.error("REJECTED(통과해야 함): " + label + " — " + errs.join(" | ")); process.exit(1); }
    }
    console.log("rejected:" + n);
  '
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "^rejected:5$"
}

@test "schema rejects an allowed verb variant paired with the wrong exit code (coupling enforced, count derived)" {
  # structure r1 b2: variant와 exitCode가 독립이면 success+exit 1도 green — 허용 쌍을 스키마가 강제한다.
  # 표본은 공유 코퍼스, 기대 건수는 계약 행 파생(allowed 전수) — 손 앵커는 위 행렬 @test 소유.
  # 표본 키는 전수 "verb|variant"다(verb 단위 폴백 제거 — 폴백이 남으면 doctor·status의 두 셀이
  # 한 표본으로 통과해 방금 착지한 형상 결합이 자기 증인 없이 초록이 된다).
  run bun -e '
    import { schemaErrors } from "./tools/lib/schema-check.ts";
    import { CONTRACT_ROWS } from "./tools/lib/catalog-rows.ts";
    import { buildSamples, matrixCellCounts } from "./tools/tests/helpers/contract-samples.ts";
    import { readFileSync } from "node:fs";
    const sch = JSON.parse(readFileSync("tools/cli-result-schema.json", "utf8"));
    const map = sch["x-contract"].exitCodes;
    const codes = sch.properties.exitCode.enum;
    const verbBranches = sch.allOf.find((b) => b.oneOf?.[0]?.properties?.verb)?.oneOf ?? [];
    const SAMPLES = buildSamples(sch.definitions.doctorCheck.properties.id.enum);
    let n = 0;
    for (const br of verbBranches) {
      const verb = br.properties.verb.enum[0];
      for (const v of br.properties.variant.enum) {
        const result = SAMPLES[verb + "|" + v];
        if (result === undefined) { console.error(verb + "|" + v + ": SAMPLES에 유효 표본 없음"); process.exit(1); }
        const wrong = codes.find((c) => c !== map[v]);
        const env = { schema: "homelab-cli/1", verb, variant: v, exitCode: wrong, omitted: [], result };
        if (schemaErrors(env, sch, sch).length === 0) { console.error("잘못된 쌍 통과: " + verb + "+" + v + "+" + wrong); process.exit(1); }
        n++;
      }
    }
    const want = matrixCellCounts(CONTRACT_ROWS, sch.properties.variant.enum.length);
    if (n !== want.allowed) { console.error("행 파생 바닥값 불일치: " + n + "/" + want.allowed); process.exit(1); }
    console.log("ok");
  '
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "^ok$"
}

@test "schema rejects a doctor envelope whose result does not match doctorResult (verb-result coupling)" {
  # structure r1 a1·b1: result가 열린 object면 doctorResult가 죽은 정의 — verb별 결합을 스키마가 강제한다.
  run bun -e '
    import { schemaErrors } from "./tools/lib/schema-check.ts";
    import { readFileSync } from "node:fs";
    const sch = JSON.parse(readFileSync("tools/cli-result-schema.json", "utf8"));
    const env = { schema: "homelab-cli/1", verb: "doctor", variant: "success", exitCode: 0, omitted: [], result: {} };
    const errs = schemaErrors(env, sch, sch);
    console.log(errs.length > 0 ? "rejected" : "ACCEPTED");
  '
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "^rejected$"
}

@test "exit-code coupling branches restate x-contract.exitCodes exactly (SSOT pinning, floor 7)" {
  # 결합 분기(allOf/oneOf)는 x-contract.exitCodes의 재진술이다 — 둘이 어긋나면 드리프트.
  # 생성기(티켓 04) 이후에도 둘은 서로 다른 수제 조각(HEADER_A vs TAIL_MID)이라 이 대조가 살아
  # 있고, 리터럴 7쌍 핀은 위 "result schema pins …" @test의 jq 단언이 소유한다(손 앵커 ①).
  run bun -e '
    import { readFileSync } from "node:fs";
    const sch = JSON.parse(readFileSync("tools/cli-result-schema.json", "utf8"));
    const map = sch["x-contract"].exitCodes;
    const pairBranches = sch.allOf.find((b) => b.oneOf?.[0]?.properties?.exitCode)?.oneOf ?? [];
    const fromBranches = {};
    for (const br of pairBranches) for (const v of br.properties.variant.enum) fromBranches[v] = br.properties.exitCode.enum[0];
    const variants = Object.keys(map);
    let n = 0;
    for (const v of variants) {
      if (fromBranches[v] !== map[v]) { console.error("드리프트: " + v + " map=" + map[v] + " branch=" + fromBranches[v]); process.exit(1); }
      n++;
    }
    console.log("pinned:" + n);
  '
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "^pinned:7$"
}

@test "mini validator rejects a broken envelope (not vacuous)" {
  run bun -e '
    import { schemaErrors } from "./tools/lib/schema-check.ts";
    import { readFileSync } from "node:fs";
    const sch = JSON.parse(readFileSync("tools/cli-result-schema.json", "utf8"));
    const bad = { schema: "homelab-cli/1", verb: "doctor", variant: "definitely-not", exitCode: 99, omitted: [], result: {} };
    const errs = schemaErrors(bad, sch, sch);
    console.log(errs.length > 0 ? "rejected" : "ACCEPTED");
  '
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "^rejected$"
}

@test "schema keeps verb-specific precision: chain only on app secrets, correlation required for dispatch failures (floor 3)" {
  # ticket 08 리뷰: app secrets 전용 완화(chain·디스패치 전 거부)가 db/cache 분기까지 느슨하게 만들면 안 된다.
  run bun -e '
    import { schemaErrors } from "./tools/lib/schema-check.ts";
    import { readFileSync } from "node:fs";
    const sch = JSON.parse(readFileSync("tools/cli-result-schema.json", "utf8"));
    const env = (verb, variant, result) => ({ schema: "homelab-cli/1", verb, variant, exitCode: sch["x-contract"].exitCodes[variant], omitted: [], result });
    const cases = [
      ["db create failure without correlation", env("db create", "failure", { action: "create-database", name: "mydb", error: "x" })],
      ["cache create success carrying chain", env("cache create", "success", { action: "create-cache", name: "c", correlation: "corr-fixed-nonce-01", waited: false, run: { id: 1, url: "u" }, pr: { number: 1, url: "u", merged: false }, chain: { mode: "dispatch-only" } })],
      ["app secrets success without chain", env("app secrets", "success", { action: "update-secrets", name: "a", correlation: "corr-fixed-nonce-01", waited: false, run: { id: 1, url: "u" }, pr: { number: 1, url: "u", merged: false } })],
    ];
    let n = 0;
    for (const [label, e] of cases) {
      if (schemaErrors(e, sch, sch).length === 0) { console.error("통과해선 안 됨: " + label); process.exit(1); }
      n++;
    }
    // 대조군: app secrets 디스패치 전 거부(correlation 없음 + chain)는 통과해야 한다
    const refused = env("app secrets", "failure", { action: "update-secrets", name: "a", error: "x", chain: { mode: "chain" } });
    if (schemaErrors(refused, sch, sch).length) { console.error("거부 형상이 거부됨: " + schemaErrors(refused, sch, sch).join(" | ")); process.exit(1); }
    console.log("rejected:" + n);
  '
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "^rejected:3$"
}

@test "url verbs are consumed directly at the op interface (no child process, schema-valid)" {
  # AC2(티켓 08)의 직접 형태 — MCP 왕복 없이 op 결과 자체가 계약 적합함을 단언한다.
  run bun -e '
    import { CACHE_URL, DB_URL } from "./tools/lib/verbs.ts";
    import { schemaErrors } from "./tools/lib/schema-check.ts";
    import { readFileSync } from "node:fs";
    const sch = JSON.parse(readFileSync("tools/cli-result-schema.json", "utf8"));
    const cases = [
      ["db url", DB_URL.op({ name: "mydb", dryRun: true })],
      ["cache url", CACHE_URL.op({ name: "mycache", dryRun: true })],
    ];
    for (const [verb, env] of cases) {
      if (env.verb !== verb || env.variant !== "success" || env.result.dryRun !== true) { console.error(verb + ": " + JSON.stringify(env).slice(0, 120)); process.exit(1); }
      const errs = schemaErrors(env, sch, sch);
      if (errs.length) { console.error(verb + ": " + errs.join(" | ")); process.exit(1); }
    }
    console.log("ok:2");
  '
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "^ok:2$"
}

@test "url verbs accept a positional name like every other verb (documented surface)" {
  run --separate-stderr bun tools/homelab.ts db url t --dry-run --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.result.name')" = "t" ]
}

# ── 파싱 커널의 fail-closed(homelab-cli-r2 티켓 11) ────────────────────────────────────────────
# 이름 이중 지정·중복 플래그는 이전엔 침묵 last-wins였다 — 엉뚱한 리소스의 자격이 .env.local에
# 기록되거나(--name이 위치 인자를 이긴다) 편집 실수가 파괴 확인을 통과했다. 둘 다 usage-error다.

@test "a name given both positionally and via --name is a usage error in either order (url verbs, floor 4)" {
  # shell-4 실측: `db url foo --name bar` → result.name "bar", rc 0 — foo에 대한 언급이 어디에도 없었다.
  # 검출은 원본 argv를 parseFlags와 같은 걸음으로 훑으므로 순서 무관이고 두 값을 모두 인용한다.
  n=0
  for noun in db cache; do
    run --separate-stderr bun tools/homelab.ts "$noun" url foo --name bar --dry-run --json
    [ "$status" -eq 2 ]
    [ -z "$output" ]
    echo "$stderr" | grep -q "이름이 두 번 지정"
    echo "$stderr" | grep -qF "foo"
    echo "$stderr" | grep -qF "bar"
    n=$((n + 1))
    run --separate-stderr bun tools/homelab.ts "$noun" url --name bar foo --dry-run --json
    [ "$status" -eq 2 ]
    [ -z "$output" ]
    echo "$stderr" | grep -q "이름이 두 번 지정"
    echo "$stderr" | grep -qF "foo"
    echo "$stderr" | grep -qF "bar"
    n=$((n + 1))
  done
  [ "$n" -eq 4 ]
}

@test "a repeated flag is a usage error instead of silent last-wins (shared parsing kernel at the process boundary)" {
  # shell-7 실측: `--env-local a --env-local b` → envFile "b", rc 0. 편집 실수가 조용히 뒤 값으로 접혔다.
  run --separate-stderr bun tools/homelab.ts db url t --env-local a --env-local b --dry-run --json
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  echo "$stderr" | grep -q -- "--env-local"
  echo "$stderr" | grep -q "중복"
  # 양성 대조 — 한 번만 준 같은 플래그는 그대로 통과한다(거부가 전칭이 아님)
  run --separate-stderr bun tools/homelab.ts db url t --env-local "$BATS_TEST_TMPDIR/one.env.local" --dry-run --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.result.name')" = "t" ]
}

@test "url verbs still reject a second positional argument and still accept a lone one (fail-closed anchors)" {
  # 티켓 11의 별칭 검출이 기존 두 경계를 밀어내지 않았음을 같은 @test에서 양방향으로 고정한다.
  run --separate-stderr bun tools/homelab.ts db url foo bar --dry-run --json
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  echo "$stderr" | grep -q "예상치 못한 위치 인자: bar"
  run --separate-stderr bun tools/homelab.ts db url foo --dry-run --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.result.name')" = "foo" ]
}

# ── CLI 관례 정렬(homelab-cli-r2 티켓 12) ──────────────────────────────────────────────────────
# 그룹 노드 --help·-h/help/--version·단일 대시 토큰. 계약(x-contract.stdout)은 「--help는 stdout
# (exit 0)」을 규약으로 적어 뒀는데 리프만 그랬고 그룹 노드는 usage 오류였다.

@test "group nodes answer --help on stdout with their own vocabulary and no stderr (floor 3)" {
  n=0
  for noun in db cache app; do
    run --separate-stderr bun tools/homelab.ts "$noun" --help
    [ "$status" -eq 0 ]
    [ -z "$stderr" ]
    echo "$output" | grep -q "사용법: homelab $noun"
    n=$((n + 1))
  done
  [ "$n" -eq 3 ]
  # 어휘가 실제로 실려 있는가 — 노드마다 자기 서브커맨드(빈 목록이면 위의 grep은 여전히 통과한다)
  run --separate-stderr bun tools/homelab.ts db --help
  echo "$output" | grep -q "db create"
  echo "$output" | grep -q "db url"
  run --separate-stderr bun tools/homelab.ts app --help
  echo "$output" | grep -q "app teardown"
  echo "$output" | grep -q "app init"
}

@test "help routing narrows to fully valid node prefixes: unknown words stay usage errors (floor 4)" {
  # 리스크: argv.includes(\"--help\")로 판정하면 fail-open이다 — 알 수 없는 서브커맨드까지 exit 0으로 접힌다.
  n=0
  run --separate-stderr bun tools/homelab.ts bogus --help
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  n=$((n + 1))
  run --separate-stderr bun tools/homelab.ts db creat --help
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  echo "$stderr" | grep -q "알 수 없는 서브커맨드: creat"
  n=$((n + 1))
  run --separate-stderr bun tools/homelab.ts --json db
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  n=$((n + 1))
  # 리프 --help는 그대로 stdout·exit 0(양성 대조 — 거부가 전칭이 아님)
  run --separate-stderr bun tools/homelab.ts app init --help
  [ "$status" -eq 0 ]
  echo "$output" | grep -q -- "--archetype"
  n=$((n + 1))
  [ "$n" -eq 4 ]
}

@test "-h and help are top-level --help aliases while a single-dash token stays an unknown option at a leaf" {
  for tok in -h help; do
    run --separate-stderr bun tools/homelab.ts "$tok"
    [ "$status" -eq 0 ]
    [ -z "$stderr" ]
    echo "$output" | grep -q "사용법: homelab <동사>"
  done
  # 리프에서는 단일 대시가 위치 인자(이름)로 해석돼 '이름 형식 불량'을 받았다 — 옵션 오류로 정정된다.
  run --separate-stderr bun tools/homelab.ts db create -h
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  echo "$stderr" | grep -q "알 수 없는 옵션"
}

@test "--version reports the resolved entrypoint, the checkout HEAD and the contract schema (no package.json literal)" {
  # ⚠️ 지역 변수는 bats 프로세스에서 뽑는다 — `run bash -c` 안의 bats 변수는 빈 문자열이라
  #    grep이 0건으로 항상 통과한다(함정 원장 「정적 증인의 두 함정」).
  head="$(git rev-parse --short HEAD)"
  branch="$(git rev-parse --abbrev-ref HEAD)"
  [ -n "$head" ]
  [ -n "$branch" ]
  run --separate-stderr bun tools/homelab.ts --version
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  echo "$output" | grep -qF "$ROOT/tools/homelab.ts"
  echo "$output" | grep -qF "$head"
  echo "$output" | grep -qF "$branch"
  # package.json version은 최초 커밋 이후 불변이라 거짓 확신이다 — 부재를 카운트로 재고,
  # 같은 출력에서 계약 schema 존재를 양성 대조로 둔다(검출기 사망 시 둘 다 0이 된다).
  [ "$(printf '%s' "$output" | grep -cF "1.0.0")" = "0" ]
  [ "$(printf '%s' "$output" | grep -cF "homelab-cli/1")" -ge 1 ]
}

@test "the stdout contract states the group-node --help convention and the internal-error exception (generator-owned prose)" {
  run jq -r '."x-contract".stdout' tools/cli-result-schema.json
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "그룹 노드"
  echo "$output" | grep -q -- "--help"
  # 티켓 13 — 세 번째 예외(내부 오류)와 그 커버리지 경계(import 시점 스키마 로드는 포획 밖)
  echo "$output" | grep -q "예외 셋"
  echo "$output" | grep -q "내부 오류"
  echo "$output" | grep -q "import 시점"
}

# ── 셸 출력의 총체성(homelab-cli-r2 티켓 13) ───────────────────────────────────────────────────
# 렌더러는 lib/render.ts가 소유한다(op는 Envelope만 반환 — 표현은 셸). 골든 전수 스윕이 그
# 총체성(throw 0 · undefined/NaN 누출 0)을 재고, 미지 verb·미지 mode는 조용한 폴백이 아니라 throw다.

@test "every result golden renders without throwing and without leaking undefined or NaN (floor = golden file count)" {
  want="$(find tools/tests/fixtures/homelab -name '*.golden.json' | wc -l | tr -d ' ')"
  [ "$want" -ge 22 ]
  run bun -e '
    import { renderFor } from "./tools/lib/render.ts";
    import { readdirSync, readFileSync } from "node:fs";
    const dir = "tools/tests/fixtures/homelab";
    const files = readdirSync(dir).filter((f) => f.endsWith(".golden.json")).sort();
    let n = 0;
    for (const f of files) {
      const env = JSON.parse(readFileSync(dir + "/" + f, "utf8"));
      const lines = renderFor(env);
      if (!Array.isArray(lines) || lines.length === 0) { console.error(f + ": 렌더 0줄"); process.exit(1); }
      for (const l of lines) {
        if (l.includes("undefined") || l.includes("NaN")) { console.error(f + ": 누출 — " + l); process.exit(1); }
      }
      n++;
    }
    console.log("rendered:" + n);
  '
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "^rendered:$want\$"
}

@test "the renderers are total: an unknown status mode and an unknown verb throw instead of falling through (floor 2)" {
  # shell-6 실측: renderStatus의 마지막 return이 'mode는 pr일 것'을 가정해 합성 mode "resource"에서
  # `undefined is not an object (evaluating 'r.pr.number')`로 죽었다 — 조용한 폴백의 늦은 실패.
  run bun -e '
    import { renderFor, renderStatus } from "./tools/lib/render.ts";
    const base = { schema: "homelab-cli/1", variant: "success", exitCode: 0, omitted: [] };
    let n = 0;
    try { renderStatus({ ...base, verb: "status", result: { mode: "resource" } }); console.error("mode: DID-NOT-THROW"); process.exit(1); }
    catch { n++; }
    try { renderFor({ ...base, verb: "app bogus", result: {} }); console.error("verb: DID-NOT-THROW"); process.exit(1); }
    catch { n++; }
    // 대조군 — 알려진 mode·verb는 그대로 렌더된다(throw가 전칭이 아님)
    const ok = renderFor({ ...base, verb: "status", result: { mode: "list", count: 0 } });
    if (ok.length === 0) { console.error("대조군 렌더 0줄"); process.exit(1); }
    console.log("threw:" + n);
  '
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "^threw:2$"
}

# ── 티켓 33: 어휘·종료코드·요구 도메인·관측 레버를 표면이 말하게 ──────────────────────────

@test "the top-level usage renders every exit code paired with its variant on one line (schema is the oracle)" {
  # ⚠️ 맨 숫자 grep은 금지다 — WAIT_FLAG_LINES가 이미 5000·1200000을 뿌려 어떤 숫자든 매치하는
  # vacuous green이 된다. 기준은 스키마 열거(x-contract)이고 usage가 피검사자이며, 판정은
  # "variant 이름과 그 코드가 **같은 줄**"이라는 쌍 단위다.
  bun tools/homelab.ts --help > "$BATS_TEST_TMPDIR/help.txt"
  HELP="$BATS_TEST_TMPDIR/help.txt" run bun -e '
    import { readFileSync } from "node:fs";
    const sch = JSON.parse(readFileSync("tools/cli-result-schema.json", "utf8"));
    const help = readFileSync(process.env.HELP, "utf8").split("\n");
    const codeOnLine = (line, code) => new RegExp("(^|[^0-9])" + code + "([^0-9]|$)").test(line);
    let n = 0;
    for (const [variant, code] of Object.entries(sch["x-contract"].exitCodes)) {
      if (!help.some((l) => l.includes(variant) && codeOnLine(l, code))) {
        console.error("미표기 쌍: " + variant + "=" + code); process.exit(1);
      }
      n++;
    }
    // usage 코드(2)는 variant가 아니라 파싱 실패의 코드다 — 스크립트가 가장 자주 밟는데 원안에 없었다.
    if (!help.some((l) => l.includes("usage") && codeOnLine(l, sch["x-contract"].usageExit))) {
      console.error("usage 코드 미표기"); process.exit(1);
    }
    console.log("pairs:" + n);
  '
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "^pairs:7$"
  # 같은 코드를 나눠 갖는 variant가 있다는 사실도 한 줄로 말한다(0=success·no-op, 1=failure·pending).
  grep -q "variant" "$BATS_TEST_TMPDIR/help.txt"
}

@test "no --help output leaks the internal seam label, and the exec ledger lever is advertised instead" {
  # '심(seam)'은 레포 내부 어휘라 owner/에이전트에게는 '쓰지 말라'로도 읽힌다 — 데드라인 조정은
  # 정당한 운영 노브다. 반대로 실재하는 관측 레버(HOMELAB_EXEC_LEDGER)는 문서가 0건이었다.
  ALL="$BATS_TEST_TMPDIR/all-help.txt"
  : > "$ALL"
  bun tools/homelab.ts --help >> "$ALL"
  n=0
  while read -r verb; do
    bun tools/homelab.ts $verb --help >> "$ALL"
    n=$((n + 1))
  done < <(bun -e 'import { VERBS } from "./tools/lib/verbs.ts"; for (const v of VERBS) console.log(v.path.join(" "));')
  [ "$n" -ge 10 ]   # 열거 바닥값 — 0건이면 아래 '0회' 단언이 공허하다
  [ "$(grep -c '심)' "$ALL")" = "0" ]
  # 같은 검출기의 양성 대조 — 착지 전 라벨 모양에서는 1건을 센다.
  [ "$(printf '%s\n' "  --poll-ms <n>      폴링 간격(기본 5000 — 시간 주입 심)" | grep -c '심)')" = "1" ]
  grep -q "HOMELAB_EXEC_LEDGER" "$ALL"
}

@test "every verb usage declares its required network domains, rendered from the descriptor (no hand copies)" {
  # 홈랩에서는 두 도메인(GitHub=인터넷 / 클러스터=tailscale·LAN)이 독립으로 끊긴다 — 한쪽만
  # 끊긴 상태가 정상인데 그 비대칭이 어휘에 없었다. 값은 VerbShape의 데이터 한 칸이 소유한다.
  run bun -e '
    import { VERBS } from "./tools/lib/verbs.ts";
    let n = 0;
    for (const v of VERBS) {
      if (typeof v.needs !== "string" || v.needs.trim() === "") { console.error("needs 없음: " + v.path.join(" ")); process.exit(1); }
      n++;
    }
    console.log("verbs:" + n);
  '
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "^verbs:10$"
  # 그 데이터가 실제로 렌더된다 — 동사별 --help가 자기 행의 문자열을 그대로 담는다(손 사본 0).
  n=0
  while IFS="	" read -r verb needs; do
    bun tools/homelab.ts $verb --help > "$BATS_TEST_TMPDIR/h.txt"
    grep -qF "요구: $needs" "$BATS_TEST_TMPDIR/h.txt"
    n=$((n + 1))
  done < <(bun -e 'import { VERBS } from "./tools/lib/verbs.ts"; for (const v of VERBS) console.log(v.path.join(" ") + "\t" + v.needs);')
  [ "$n" -eq 10 ]
}

@test "every pending golden points at a resume command the CLI actually accepts" {
  # '핸들로 재조회 가능'은 다음 명령을 주지 않았다 — 포인터를 넣되 **실재하는 것만** 지목한다.
  n=0
  for g in db-create-pending cache-create-pending app-create-pending app-teardown-pending; do
    reason="$(jq -r '.result.pendingReason' "tools/tests/fixtures/homelab/$g.golden.json")"
    printf '%s\n' "$reason" | grep -q "homelab status --"
    flag="$(printf '%s\n' "$reason" | grep -o -- "--run\|--pr" | head -1)"
    [ -n "$flag" ]
    bun tools/homelab.ts status --help > "$BATS_TEST_TMPDIR/su.txt"
    grep -q -- "$flag" "$BATS_TEST_TMPDIR/su.txt"
    n=$((n + 1))
  done
  [ "$n" -eq 4 ]
}
