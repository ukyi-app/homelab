#!/usr/bin/env bats
# homelab CLI 진입점 — 서브커맨드 라우팅·사용법·종료코드·설치(bin) 계약(워킹 스켈레톤).
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

@test "every schema variant validates through the mini validator with its mapped exit code (floor 7)" {
  run bun -e '
    import { schemaErrors } from "./tools/lib/schema-check.ts";
    import { readFileSync } from "node:fs";
    const sch = JSON.parse(readFileSync("tools/cli-result-schema.json", "utf8"));
    const map = sch["x-contract"].exitCodes;
    const variants = sch.properties.variant.enum;
    const ids = sch.definitions.doctorCheck.properties.id.enum;
    const result = { checks: ids.map((id) => ({ id, status: "pass", detail: "x" })), summary: { pass: ids.length, fail: 0, warn: 0 } };
    let n = 0;
    for (const v of variants) {
      const code = map[v];
      if (code === undefined) { console.error("exit 매핑 없음: " + v); process.exit(1); }
      const env = { schema: "homelab-cli/1", verb: "doctor", variant: v, exitCode: code, omitted: [], result };
      const errs = schemaErrors(env, sch, sch);
      if (errs.length) { console.error(v + ": " + errs.join(" | ")); process.exit(1); }
      n++;
    }
    console.log("ok:" + n);
  '
  [ "$status" -eq 0 ]
  # 열거 바닥값: variant 7종 전부 순회(루프 붕괴 → vacuous green 차단)
  echo "$output" | grep -q "^ok:7$"
}

@test "schema rejects every variant paired with a wrong exit code (coupling enforced, floor 7)" {
  # structure r1 b2: variant와 exitCode가 독립이면 success+exit 1도 green — 허용 쌍을 스키마가 강제한다.
  run bun -e '
    import { schemaErrors } from "./tools/lib/schema-check.ts";
    import { readFileSync } from "node:fs";
    const sch = JSON.parse(readFileSync("tools/cli-result-schema.json", "utf8"));
    const map = sch["x-contract"].exitCodes;
    const variants = sch.properties.variant.enum;
    const codes = sch.properties.exitCode.enum;
    const ids = sch.definitions.doctorCheck.properties.id.enum;
    const result = { checks: ids.map((id) => ({ id, status: "pass", detail: "x" })), summary: { pass: ids.length, fail: 0, warn: 0 } };
    let n = 0;
    for (const v of variants) {
      const wrong = codes.find((c) => c !== map[v]);
      const env = { schema: "homelab-cli/1", verb: "doctor", variant: v, exitCode: wrong, omitted: [], result };
      const errs = schemaErrors(env, sch, sch);
      if (errs.length === 0) { console.error("잘못된 쌍이 통과: " + v + "+" + wrong); process.exit(1); }
      n++;
    }
    console.log("rejected:" + n);
  '
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "^rejected:7$"
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
  run bun -e '
    import { readFileSync } from "node:fs";
    const sch = JSON.parse(readFileSync("tools/cli-result-schema.json", "utf8"));
    const map = sch["x-contract"].exitCodes;
    const pairBranches = sch.allOf.find((b) => b.oneOf?.[0]?.properties?.variant)?.oneOf ?? [];
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
