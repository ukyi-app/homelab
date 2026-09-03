#!/usr/bin/env bats
# `</dev/null` 규약 가드(scripts/check-bats-fd0.sh)의 **변별력** 테스트.
#
# 왜 필요한가: 이 규약이 막는 것은 red가 아니라 **hang**이다. 그리고 venue가 갈린다 —
# `ci.yaml`은 러너를 `&`로 띄워 fd 0이 `/dev/null`이므로 **CI는 우연히 면역**이고, `make ci`만
# 밟는다. 즉 검출기가 조용히 죽어도 CI는 영원히 초록이라 사후에 드러나지 않는다.
# ⚠️ @test 이름은 영어만 · 중간 단언은 [ ]만(bash 3.2 [[ ]] 침묵 통과).

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"; cd "$ROOT" || exit 1
  S="$ROOT/scripts/check-bats-fd0.sh"
  FX="$BATS_TEST_TMPDIR"
}

@test "the detector fires on a bats call without the redirect and stays quiet with it" {
  printf 'run:\n  bats tests/foo.bats\n'            > "$FX/bad.sh"
  printf 'run:\n  bats tests/foo.bats </dev/null\n' > "$FX/ok.sh"
  run bash "$S" "$FX/bad.sh"; [ "$status" -ne 0 ]; echo "$output" | grep -qF '[FD0]'
  run bash "$S" "$FX/ok.sh";  [ "$status" -eq 0 ]
}

@test "a flag-preceding call site is still caught (the runner's own bats --print-output-on-failure <path> shape)" {
  # ★ 옛 판정은 `bats` **바로 다음 토큰**만 봐서 플래그가 선행하면 SITES 계상도 위반 판정도
  #   못 했다(2026-09-03 실측: 레포 러너 자신 scripts/run-bats.sh:67의 표기가 정확히 이 모양이라
  #   `exec 0</dev/null`을 지워도 SCAN 8·전건 OK가 그대로였다). 플래그 뒤 첫 경로꼴 토큰까지 훑는다.
  printf 'run:\n  bats --print-output-on-failure tests/foo.bats\n'            > "$FX/flagbad.sh"
  printf 'run:\n  bats --print-output-on-failure tests/foo.bats </dev/null\n' > "$FX/flagok.sh"
  run bash "$S" "$FX/flagbad.sh"; [ "$status" -ne 0 ]; echo "$output" | grep -qF '[FD0]'
  run bash "$S" "$FX/flagok.sh";  [ "$status" -eq 0 ]
}

@test "prose, Makefile help text and version checks are not calls (false-positive control)" {
  # ★ 이 레포의 문장에는 "bats accounting"·"bats 실행(docs/runbooks/)"처럼 bats가 산문으로 나온다.
  #   그걸 호출로 읽으면 가드가 문서를 물어 아무도 켜지 않는다.
  printf '#!/usr/bin/env bash\n# bats accounting 설명\nx: ## 로컬 런북 bats 실행(docs/runbooks/)\nbats --version | grep -q x\n' > "$FX/prose.sh"
  run bash "$S" "$FX/prose.sh"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qE '^SCAN: check-bats-fd0: 0$'
}

@test "the runner exemption is decided by the exec line, not by a file allowlist" {
  # 면제를 파일 목록으로 두면 러너를 옮기거나 새로 만드는 순간 규칙이 갈린다.
  printf '#!/usr/bin/env bash\nexec 0</dev/null\nbats "${SEL[@]}"\n' > "$FX/runner.sh"
  run bash "$S" "$FX/runner.sh"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qE '^SCAN: check-bats-fd0: 1$'   # 호출면으로는 셌고, 면제만 됐다
  # exec 줄을 떼면 같은 파일이 잡힌다(면제가 사실 판정임을 증명한다).
  printf '#!/usr/bin/env bash\nbats "${SEL[@]}"\n' > "$FX/norunner.sh"
  run bash "$S" "$FX/norunner.sh"; [ "$status" -ne 0 ]
}

@test "the exemption is decided by real code, not by a comment that merely quotes the exec line" {
  # ★ 적대적 리뷰가 잡은 자리. self 판정이 주석·`name:` 스킵보다 **위**에 있어, 그 문자열을
  #   인용하기만 한 줄에도 self=1이 서서 **파일 전체가 면제**됐다. 그리고 이 가드 자신이
  #   자기 헤더에서 그 규약을 설명하므로 **영구 면제 상태**였다 — hard-zero 보증이 거짓이었다.
  #   세 표면을 전부 건다: 셸 주석 · Makefile `##` 도움말 · 워크플로 스텝 `name:`.
  printf '#!/usr/bin/env bash\n# 규약: exec 0</dev/null 을 한다\nbats tools/tests/\n' > "$FX/cmt.sh"
  run bash "$S" "$FX/cmt.sh"; [ "$status" -ne 0 ]; echo "$output" | grep -qF '[FD0]'
  printf 'x: ## 러너는 exec 0</dev/null 을 한다\n\t@bats tests/foo.bats\n' > "$FX/Makefile"
  run bash "$S" "$FX/Makefile"; [ "$status" -ne 0 ]; echo "$output" | grep -qF '[FD0]'
  printf 'steps:\n  - name: 러너 (exec 0</dev/null 로 fd 0을 끊는다)\n    run: |\n      bats tests/foo.bats\n' > "$FX/wf.yaml"
  run bash "$S" "$FX/wf.yaml"; [ "$status" -ne 0 ]; echo "$output" | grep -qF '[FD0]'
  # 음성 대조 — **진짜** exec 줄은 여전히 면제다(위 레인이 면제를 통째로 없앤 것이 아니다).
  printf '#!/usr/bin/env bash\nexec 0</dev/null\nbats tools/tests/\n' > "$FX/real.sh"
  run bash "$S" "$FX/real.sh"; [ "$status" -eq 0 ]
}

@test "the floor counts call sites, not files — a broken regex must not pass on file count" {
  # ★ 파일은 수백 개인데 bats 호출면은 한 자리다. 파일 수로 바닥을 걸면 정규식이 깨져 호출면을
  #   0개 찾아도 그 바닥을 통과한다(무측정 초록). 바닥의 대상이 호출면임을 여기서 문다.
  run bash "$S"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qE '^SCAN: check-bats-fd0: [0-9]+$'
  sites="$(printf '%s\n' "$output" | sed -n 's/^SCAN: check-bats-fd0: //p')"
  [ "$sites" -ge 5 ]
  run bash "$S" --floor check-bats-fd0=99999
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "열거 붕괴"
  echo "$output" | grep -qF '열거 붕괴'
}

@test "the repo tree is clean — every call site outside the runner detaches fd 0" {
  run bash "$S"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qF '전건 fd 0 격리 OK'
}

@test "an unreadable target fails closed instead of scanning nothing" {
  run bash "$S" "$FX/nonexistent.sh"
  [ "$status" -ne 0 ]
  echo "$output" | grep -qF '읽을 수 없는 대상'
}
