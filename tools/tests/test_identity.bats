#!/usr/bin/env bats
# dry-6: 앱-이름 regex SSOT(tools/lib/identity.mjs). 4종 분기 regex를 validator 정책으로 수렴.
# trailing hyphen 금지(`^[a-z][a-z0-9-]{0,38}[a-z0-9]$`). 모든 mutator 콜사이트가 동일 검증.
# ⚠️ 중간 단언은 [ ]만 — bash 3.2 [[ ]] 침묵 통과 함정.

setup() { ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"; cd "$ROOT" || exit 1; }

@test "identity exports APP_NAME_RE with the validator policy (no trailing hyphen, 2..40)" {
  run node --input-type=module -e '
    import { APP_NAME_RE } from "./tools/lib/identity.mjs";
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
    tools/create-app.mjs tools/teardown-app.mjs tools/bump-tag.mjs
  [ "$status" -ne 0 ]   # grep이 아무것도 못 찾아야(=잔존 0) status!=0
  for f in create-app teardown-app validate-mutation activate-app bump-tag; do
    run grep -q "lib/identity.mjs" "tools/$f.mjs"
    [ "$status" -eq 0 ]
  done
}

@test "teardown-app now rejects a trailing-hyphen app name (policy tightened)" {
  run node tools/teardown-app.mjs --app bad- --dry-run
  [ "$status" -ne 0 ]
}
