#!/usr/bin/env bats
# 파싱 커널 서브커맨드 확장 — parseCommand는 어휘(CommandTree)를 선언한 호출에서만 위치 인자를
# 동사 라우팅으로 받는다. 미등록 명사/동사는 fail-closed(throw + 사용 가능 어휘 안내)이고,
# 라우팅 뒤 잉여 argv(rest)는 기존 parseFlags 경로가 그대로 fail-closed로 거부한다.
# parseFlags 자체는 불변 — 비선언 소비자의 의미론 비회귀는 이 파일 마지막 테스트가 고정한다.
# ⚠️ 중간 단언은 [ ]만 — bash 3.2 [[ ]] 침묵 통과.

setup() { ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"; cd "$ROOT" || exit 1; }

@test "parseCommand routes a registered noun-verb pair and returns rest argv" {
  run bun -e '
    import { parseCommand } from "./tools/lib/cli.ts";
    const r = parseCommand(["app", "init", "--json", "--name", "blog"], { app: { init: null, create: null } });
    if (r.path.join(" ") !== "app init") { console.error("path=" + r.path.join(" ")); process.exit(1); }
    if (r.rest.join(" ") !== "--json --name blog") { console.error("rest=" + r.rest.join(" ")); process.exit(1); }
    console.log("ok");
  '
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "^ok$"
}

@test "parseCommand routes a bare verb leaf at depth 1" {
  run bun -e '
    import { parseCommand } from "./tools/lib/cli.ts";
    const r = parseCommand(["doctor"], { doctor: null, status: null });
    if (r.path.join(" ") !== "doctor" || r.rest.length !== 0) { console.error("bad"); process.exit(1); }
    console.log("ok");
  '
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "^ok$"
}

@test "parseCommand rejects an unregistered noun with available vocabulary" {
  run bun -e '
    import { parseCommand } from "./tools/lib/cli.ts";
    try { parseCommand(["bogus"], { app: { init: null }, doctor: null }); console.log("DID-NOT-THROW"); }
    catch (e) { console.log(String(e.message)); }
  '
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "알 수 없는 서브커맨드: bogus"
  echo "$output" | grep -q "사용 가능:.*app"
  echo "$output" | grep -q "사용 가능:.*doctor"
}

@test "parseCommand rejects an unregistered verb under a registered noun" {
  run bun -e '
    import { parseCommand } from "./tools/lib/cli.ts";
    try { parseCommand(["app", "bogus"], { app: { init: null, create: null } }); console.log("DID-NOT-THROW"); }
    catch (e) { console.log(String(e.message)); }
  '
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "알 수 없는 서브커맨드: bogus"
  echo "$output" | grep -q "사용 가능:.*app init"
  echo "$output" | grep -q "사용 가능:.*app create"
}

@test "parseCommand rejects a missing verb after a noun with that noun's vocabulary" {
  run bun -e '
    import { parseCommand } from "./tools/lib/cli.ts";
    try { parseCommand(["app"], { app: { init: null, create: null } }); console.log("DID-NOT-THROW"); }
    catch (e) { console.log(String(e.message)); }
  '
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "서브커맨드가 필요하다"
  echo "$output" | grep -q "사용 가능:.*app init"
}

@test "parseCommand rejects a flag where a subcommand word is expected" {
  run bun -e '
    import { parseCommand } from "./tools/lib/cli.ts";
    try { parseCommand(["--json", "app"], { app: { init: null } }); console.log("DID-NOT-THROW"); }
    catch (e) { console.log(String(e.message)); }
  '
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "서브커맨드가 필요하다"
}

@test "parseCommand rejects prototype-inherited words fail-closed" {
  run bun -e '
    import { parseCommand } from "./tools/lib/cli.ts";
    const words = ["constructor", "__proto__", "hasOwnProperty", "toString"];
    for (const w of words) {
      try { parseCommand([w], { app: { init: null } }); console.error("DID-NOT-THROW: " + w); process.exit(1); }
      catch (e) { if (!String(e.message).includes("알 수 없는 서브커맨드")) { console.error("wrong error for " + w); process.exit(1); } }
    }
    console.log("ok:" + words.length);
  '
  [ "$status" -eq 0 ]
  # 열거 바닥값: 케이스 4개 전부 순회했음을 카운트로 고정(루프 붕괴 → vacuous green 차단)
  echo "$output" | grep -q "^ok:4$"
}

@test "rest argv flows into parseFlags preserving fail-closed positional rejection" {
  run bun -e '
    import { parseCommand, parseFlags } from "./tools/lib/cli.ts";
    const r = parseCommand(["app", "init", "extra", "--json"], { app: { init: null } });
    try { parseFlags(r.rest, { value: [], bool: ["--json"] }); console.log("DID-NOT-THROW"); }
    catch (e) { console.log(String(e.message)); }
  '
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "예상치 못한 위치 인자: extra"
}

@test "parseFlags still rejects positional args for non-subcommand consumers (non-regression)" {
  run bun -e '
    import { parseFlags } from "./tools/lib/cli.ts";
    try { parseFlags(["oops"], { value: [], bool: [] }); console.log("DID-NOT-THROW"); }
    catch (e) { console.log(String(e.message)); }
  '
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "예상치 못한 위치 인자: oops"
}
