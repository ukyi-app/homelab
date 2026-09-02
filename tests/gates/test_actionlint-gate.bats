#!/usr/bin/env bats
# actionlint 설치가 핀+체크섬인지 + queue:max 직렬화 계약 보존. ⚠️ [ ]만.
# ⚠️ "gate가 actionlint를 돌리는가"는 여기 있지 않다: policy/ci-parity.json 원장 + tools/check-ci-parity.ts가
#    소유한다(스텝 삭제·리네임을 양방향으로 잡는다). 설치가 빠지면 gate의 bare `run: actionlint`가 127로 죽는다.
setup() { ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"; cd "$ROOT" || exit 1; }

@test "setup-toolchain has a pinned, checksummed actionlint install step" {
  # YAML은 inputs: + 자식 actionlint: 키 구조 — 리터럴 'inputs.actionlint' 아님(F4). 실제 키를 grep.
  run grep -Eq '^[[:space:]]+actionlint:' .github/actions/setup-toolchain/action.yml
  [ "$status" -eq 0 ]
  run grep -Fq 'rhysd/actionlint' .github/actions/setup-toolchain/action.yml
  [ "$status" -eq 0 ]
  run grep -Fq 'sha256sum -c -' .github/actions/setup-toolchain/action.yml   # 체크섬 검증 패턴
  [ "$status" -eq 0 ]
}

@test "queue: max mutation-queue contract survives actionlint addition (F3)" {
  # actionlint가 concurrency.queue를 schema-lag로 거부해도 queue:max를 지우면 직렬화 계약 파괴 — 보존 단언.
  # ⚠️ **키 행으로 앵커한다.** 무앵커 `grep -F`는 그 규약을 *설명하는 주석*(create-app.yaml:18 ·
  #    bump-poll.yaml:33)을 자기 파일의 증인으로 삼는다 — 규약을 성실히 문서화한 파일일수록 그
  #    규약에서 면제되는 형태다. 실측 2026-09-03: create-app:22·bump-poll:14의 **실키만** 지워도
  #    이 레인과 tools/tests/test_mutation-dispatch.bats #1이 전건 초록이었다. `queue`가 빠지면
  #    GitHub 기본 동작으로 돌아가 대기 중이던 변이 run이 조용히 취소된다(races-1/2 실사고).
  for wf in create-database bump-poll bump tf-reconcile create-app; do
    run grep -Eq '^[[:space:]]*queue:[[:space:]]*max[[:space:]]*$' ".github/workflows/$wf.yaml"
    [ "$status" -eq 0 ]
  done
}
