#!/usr/bin/env bats
# 오타 옵션 침묵-무시 차단 — create-app/provision-cache의 arg() 헬퍼는 미지정 플래그를
# 조용히 무시해 디폴트를 적용했다(예: --nam을 오타하면 --name이 무시되고 디폴트). allowed-set 거부로
# 오타를 즉시 비-0 종료시킨다. (전체 cli.ts 통합 아님 — 침묵버그 슬라이스만.)
# ⚠️ 중간 단언은 [ ]만 — bash 3.2 [[ ]] 침묵 통과.

setup() { ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"; cd "$ROOT" || exit 1; }

@test "create-app rejects an unknown flag" {
  run bun tools/create-app.ts --dry-run --bogus-flag x
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "알 수 없는 옵션"
}

@test "provision-cache rejects an unknown flag" {
  run bun tools/provision-cache.ts --dry-run --bogus-flag x
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "알 수 없는 옵션"
}

@test "teardown-app rejects an unknown flag" {
  run bun tools/teardown-app.ts --app blog --dry-run --bogus-flag x
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "알 수 없는 옵션"
}

@test "teardown-resource rejects an unknown flag" {
  run bun tools/teardown-resource.ts --db shared --dry-run --bogus-flag x
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "알 수 없는 옵션"
}

@test "parseFlags rejects a value that starts with -- (arg-swallow guard)" {
  run bun -e '
    import { parseFlags } from "./tools/lib/cli.ts";
    try { parseFlags(["--name", "--dry-run"], { value: ["--name"], bool: ["--dry-run"] }); console.log("DID-NOT-THROW"); }
    catch { console.log("threw"); }
  '
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "^threw$"
}

@test "parseFlags rejects unknown flag and accepts a well-formed value" {
  run bun -e '
    import { parseFlags } from "./tools/lib/cli.ts";
    const ok = parseFlags(["--name", "blog", "--dry-run"], { value: ["--name"], bool: ["--dry-run"] });
    if (ok["--name"] !== "blog" || ok["--dry-run"] !== true) { console.error("parse"); process.exit(1); }
    try { parseFlags(["--bogus", "x"], { value: [], bool: [] }); console.log("DID-NOT-THROW"); }
    catch { console.log("ok"); }
  '
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "^ok$"
}

@test "migrated mutators import the shared parseFlags (cli.ts adoption)" {
  # ⚠️ 피연산자를 **import 줄**로 좁힌다 — 맨 `lib/cli.ts` 매치는 그 파일 어디든(주석 한 줄에도)
  #    걸려 「리터럴 언급이면 참」이 된다. 실측 2026-09-04: create-app.ts의 import를 주석으로 바꾸고
  #    lib 본문을 그대로 복사한 로컬 function parseFlags로 교체해도 이 파일 12/12 그대로 초록이었다.
  #    형제 선례: test_identity.bats의 identity.ts 루프(같은 이유로 이미 앵커드).
  for f in db-url cache-url teardown-resource provision-db provision-cache create-app teardown-app activate-app verify-db-marker; do
    run grep -qE '^import .*"\./lib/cli\.ts"' "tools/$f.ts"; [ "$status" -eq 0 ]
  done
}

@test "migrated mutators reject a missing flag value (arg-swallow guard per callsite)" {
  # 값-요구 플래그 뒤 값 누락 → fail-closed(이전엔 다음 플래그를 삼킴).
  # [ABS-EXEC] W1(감사 63) — 도구가 리네임/부재여도 bun은 rc 1(Module not found)을 내 아래
  # `-ne 0`이 같은 값으로 침묵 통과한다(R2 실증). 실제 출력 문구로 "값이 필요하다" 오류임을 못박는다.
  run bun tools/teardown-app.ts --app --dry-run;     [ "$status" -ne 0 ]
  echo "$output" | grep -q "값이 필요하다"
  run bun tools/db-url.ts --name --dry-run;          [ "$status" -ne 0 ]
  echo "$output" | grep -q "값이 필요하다"
  run bun tools/provision-cache.ts --name --dry-run; [ "$status" -ne 0 ]
  echo "$output" | grep -q "값이 필요하다"
  run bun tools/teardown-resource.ts --db --dry-run; [ "$status" -ne 0 ]
  echo "$output" | grep -q "값이 필요하다"
}

@test "activate-app rejects an unknown flag with usage exit code 2" {
  run bun tools/activate-app.ts --app orders --sha deadbee --synced-rev deadbee --bogus x
  [ "$status" -eq 2 ]
  echo "$output" | grep -q "알 수 없는 옵션"
}

@test "verify-db-marker rejects an unknown flag with usage exit code 2" {
  run bun tools/verify-db-marker.ts --name shared --bogus x
  [ "$status" -eq 2 ]
  echo "$output" | grep -q "알 수 없는 옵션"
}

@test "provision-db exits 2 on flag-parse errors (exit-code convention alignment)" {
  run bun tools/provision-db.ts --bogus x
  [ "$status" -eq 2 ]
  echo "$output" | grep -q "알 수 없는 옵션"   # [ABS-EXEC] W1(감사 63)
}

@test "cli.ts documents the shared exit-code convention" {
  grep -q "종료코드 규약" tools/lib/cli.ts
}
