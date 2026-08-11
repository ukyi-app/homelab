#!/usr/bin/env bats
WF=".github/workflows/build.yaml"

@test "build job runs on native arm64 runner with QEMU for the amd64 leg" {
  # arm64 leg는 네이티브로 돌고 amd64 leg만 에뮬레이션을 탄다(NUC 이전, 2026-08).
  # 이전엔 "setup-qemu 부재"를 단언했으나 멀티아치 전환으로 뒤집혔다 — 이제 **존재**가 불변식이다.
  run yq '.jobs.build.runs-on' "$WF"
  [ "$output" = "ubuntu-24.04-arm" ]
  run grep -i "setup-qemu" "$WF"
  [ "$status" -eq 0 ]
}

@test "setup-qemu precedes setup-buildx (binfmt handlers must exist before the builder)" {
  # buildx 빌더는 **생성 시점**에 등록된 binfmt 핸들러만 본다. 순서가 뒤집히면 amd64 leg가
  # 'exec format error'로 죽는데, 그 실패는 빌드 로그 깊숙이에서만 보인다.
  # ⚠️ grep -n으로 줄번호를 비교하면 안 된다 — 이 함정을 설명하는 **주석**이 먼저 잡혀
  #   qemu 스텝이 삭제돼도 비교가 참이 된다(자체 뮤테이션 테스트에서 실측). steps 배열의
  #   .uses 인덱스로 구조 비교한다.
  qemu_idx="$(yq '[.jobs.build.steps[].uses // ""] | to_entries | map(select(.value|test("setup-qemu"))) | .[0].key // "null"' "$WF")"
  buildx_idx="$(yq '[.jobs.build.steps[].uses // ""] | to_entries | map(select(.value|test("setup-buildx"))) | .[0].key // "null"' "$WF")"
  [ "$qemu_idx" != "null" ]
  [ "$buildx_idx" != "null" ]
  [ "$qemu_idx" -lt "$buildx_idx" ]
}

@test "build pushes immutable :sha-<gitsha> to GHCR for both architectures" {
  run grep -E "ghcr.io/.*:sha-" "$WF"
  [ "$status" -eq 0 ]
  # ⚠️ `[[ ]]`를 쓰지 않는다 — bats는 [[ 실패를 errexit 면제로 **침묵 통과**시켜
  #   (scripts/check-bats-style.sh:3) 마지막이 아닌 단언이 무력화된다. 자체 뮤테이션에서
  #   실측: arm64만 지웠는데 초록. 평범한 명령(grep)이라야 errexit이 잡는다.
  run yq '.jobs.build.steps[] | select(.uses | test("build-push-action")) | .with.platforms' "$WF"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -q "linux/arm64"
  printf '%s' "$output" | grep -q "linux/amd64" # NUC(amd64) 이전 — 한쪽만 남으면 그 노드에서 못 돈다
}

@test "provenance stays false — 2-platform index digest must be deterministic" {
  # attestation이 켜지면 index에 unknown/unknown child가 붙고 그 매니페스트가 run마다 달라져
  # index digest가 비결정적이 된다(실측: provenance=false 2회 동일 / 기본값 2회 상이).
  # 그러면 tools/poll-ghcr.ts의 "동일 digest — 멱등 no-op"이 영영 안 걸려 내용 무변경 커밋마다
  # PR→머지→rollout이 헛돈다. 2플랫폼이 된 지금 이 값이 더 중요하다.
  run yq '.jobs.build.steps[] | select(.uses | test("build-push-action")) | .with.provenance' "$WF"
  [ "$output" = "false" ]
}

@test "matrix builds only the platform ops image pg-tools (no in-repo apps)" {
  run yq '.jobs.build.strategy.matrix.app' "$WF"
  printf '%s' "$output" | grep -qF -- "pg-tools"
  case "$output" in *"api"*) false ;; *) true ;; esac # 사용자 앱은 외부 레포에서 빌드 — homelab matrix엔 없음
  run grep -E "pg-tools:18-rclone" "$WF"
  [ "$status" -eq 0 ]
}
