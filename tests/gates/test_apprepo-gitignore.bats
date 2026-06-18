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

@test "teardown wrapper does not use git add -A (explicit allowlist only)" {
  # teardown은 owner-local scripts/teardown.sh로 이전됨(구 teardown 워크플로 제거) — 명시 allowlist만 add.
  run grep -E 'git add -A' scripts/teardown.sh
  [ "$status" -ne 0 ]
  # allowlist에 apps/ + 원장 + cloudflare apps.json + platform/ 포함 확인
  run grep -E 'apps/' scripts/teardown.sh
  [ "$status" -eq 0 ]
}
