#!/usr/bin/env bats
# dry-6: 앱-이름 regex SSOT(tools/lib/identity.ts). 4종 분기 regex를 validator 정책으로 수렴.
# trailing hyphen 금지(`^[a-z][a-z0-9-]{0,38}[a-z0-9]$`). 모든 mutator 콜사이트가 동일 검증.
# ⚠️ 중간 단언은 [ ]만 — bash 3.2 [[ ]] 침묵 통과 함정.

setup() { ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"; cd "$ROOT" || exit 1; }

@test "identity exports APP_NAME_RE with the validator policy (no trailing hyphen, 2..40)" {
  run bun -e '
    import { APP_NAME_RE } from "./tools/lib/identity.ts";
    const ok = ["ab", "blog", "my-app", "a"+"b".repeat(38)+"c"];        // 길이 2..40, 유효
    const bad = ["a", "-bad", "bad-", "Bad", "ab_c", "x".repeat(41)];   // 1글자/선후행 하이픈/대문자/언더스코어/길이초과
    for (const s of ok)  if (!APP_NAME_RE.test(s)) { console.error("FALSE NEG:", s); process.exit(1); }
    for (const s of bad) if (APP_NAME_RE.test(s))  { console.error("FALSE POS:", s); process.exit(1); }
    console.log("ok");
  '
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "ok"
}

@test "every mutator callsite imports APP_NAME_RE from lib/identity (no inline app-name regex left)" {
  # 5 콜사이트가 분기 regex 대신 SSOT를 쓴다 — 인라인 `[a-z][a-z0-9-]{1,29}`/`{0,40}` 잔존 0
  run grep -nE 'a-z0-9-\]\{1,29\}|a-z0-9-\]\{0,40\}' \
    tools/create-app.ts tools/teardown-app.ts tools/bump-tag.ts
  [ "$status" -ne 0 ]   # grep이 아무것도 못 찾아야(=잔존 0) status!=0
  for f in create-app teardown-app validate-mutation activate-app bump-tag; do
    run grep -q "lib/identity.ts" "tools/$f.ts"
    [ "$status" -eq 0 ]
  done
}

@test "teardown-app now rejects a trailing-hyphen app name (policy tightened)" {
  run bun tools/teardown-app.ts --app bad- --dry-run
  [ "$status" -ne 0 ]
}

@test "identity exports RESOURCE_NAME_RE (no trailing hyphen, 1..30, single-char ok)" {
  run bun -e '
    import { RESOURCE_NAME_RE } from "./tools/lib/identity.ts";
    const ok  = ["a", "db1", "my-cache", "x".repeat(30)];          // 1자/kebab/30자 유효
    const bad = ["-x", "x-", "Bad", "a_b", "x".repeat(31)];        // 선후행 하이픈/대문자/언더스코어/31자
    for (const s of ok)  if (!RESOURCE_NAME_RE.test(s)) { console.error("FALSE NEG:", s); process.exit(1); }
    for (const s of bad) if (RESOURCE_NAME_RE.test(s))  { console.error("FALSE POS:", s); process.exit(1); }
    console.log("ok");
  '
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "ok"
}

@test "identity exports EXT_RE (postgres extension names allow underscore)" {
  run bun -e '
    import { EXT_RE } from "./tools/lib/identity.ts";
    const ok  = ["pg_trgm", "uuid-ossp", "postgis"];
    const bad = ["-x", "Bad", "a b", "a;b"];
    for (const s of ok)  if (!EXT_RE.test(s)) { console.error("FALSE NEG:", s); process.exit(1); }
    for (const s of bad) if (EXT_RE.test(s))  { console.error("FALSE POS:", s); process.exit(1); }
    console.log("ok");
  '
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "ok"
}

@test "resource callsites import RESOURCE_NAME_RE (no inline loose resource regex left)" {
  # 느슨한 ^[a-z][a-z0-9-]*$ 가 리소스 검증 파일에서 사라졌는지(seal-secret.mts는 secret 키名이라 제외)
  run grep -nE '\^\[a-z\]\[a-z0-9-\]\*\$' \
    tools/db-url.ts tools/cache-url.ts tools/teardown-resource.ts tools/validate-mutation.ts
  [ "$status" -ne 0 ]
  for f in db-url cache-url teardown-resource validate-mutation provision-db provision-cache; do
    run grep -q "lib/identity.ts" "tools/$f.ts"
    [ "$status" -eq 0 ]
  done
}

@test "EXT_RE has no inline duplicate left (validate-mutation, provision-db)" {
  run grep -nE 'a-z0-9_-\]\*\$/' tools/validate-mutation.ts tools/provision-db.ts
  [ "$status" -ne 0 ]
}

@test "provision-cache now rejects a >30-char name (29->30 tightening consistent)" {
  run bun tools/provision-cache.ts --name "$(printf 'a%.0s' {1..31})" --dry-run
  [ "$status" -ne 0 ]
}

@test "teardown-resource now rejects a trailing-hyphen resource name" {
  run bun tools/teardown-resource.ts --db bad- --dry-run
  [ "$status" -ne 0 ]
}

@test "provision-db still validates --cluster after NAME_RE removal (F10)" {
  run bun tools/provision-db.ts --name blog --cluster 'Bad Cluster' --dry-run
  [ "$status" -ne 0 ]
}
