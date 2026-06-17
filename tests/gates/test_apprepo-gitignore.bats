#!/usr/bin/env bats
# .apprepo(외부/비신뢰 앱 레포 sparse-checkout 경로)는 git에 절대 들어가면 안 된다.
# teardown은 git add -A로 비신뢰 파일을 쓸어담을 수 있어 명시 경로만 add 한다.
# ⚠️ 중간 단언은 [ ]만 — bash 3.2 [[ ]] 침묵 통과.

setup() { ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"; cd "$ROOT" || exit 1; }

@test ".apprepo is gitignored" {
  run grep -E '^\.apprepo/?$' .gitignore
  [ "$status" -eq 0 ]
  # git이 실제로 무시하는지(체크-인 규칙) 확인 — check-ignore는 무시되면 exit 0
  run git check-ignore .apprepo/foo
  [ "$status" -eq 0 ]
}

@test "teardown does not use git add -A (explicit paths only)" {
  run grep -E 'git add -A' .github/workflows/_teardown.yaml
  [ "$status" -ne 0 ]
  # tool이 쓰는 명시 경로를 add 하는지(apps/ + 원장 + cloudflare apps.json + cnpg/cache/data-conn)
  run grep -E 'git add .*apps/' .github/workflows/_teardown.yaml
  [ "$status" -eq 0 ]
}
