#!/usr/bin/env bats
# sops 라운드트립 — CONTRIBUTING 황금률 2("평문 시크릿은 절대 금지")의 게이트.
# ⚠️ 부재 단언은 `-ne 0`이 아니라 `-eq 1`이다 — rc 기전(대상 부재 rc 2 vs 무매치 rc 1)은
#    docs/traps-detail.md 「열거 붕괴 → vacuous green」 ③·③-a가 SSOT.
#    이 파일에서 실측한 실효 뮤테이션은 **부재 단언의 피연산자만** 드리프트시키는 것이다
#    (`secret.enc.yaml` → `secret.enc.yml`): 전환 전 `-ne 0`은 ok, 전환 후 `-eq 1`은 red.
#    setup의 WORK 경로를 옮기는 것은 뮤테이션이 못 된다 — `sops --encrypt`가 먼저 죽어
#    첫 단언(`-eq 0`)에서 전환 전후가 똑같이 red라 둘을 가르지 못한다.

setup() {
  export SOPS_AGE_KEY_FILE="$HOME/.config/sops/age/keys.txt"
  WORK="apps/_rttest/prod"
  mkdir -p "$WORK"
  cp tests/fixtures/sample-secret.yaml "$WORK/secret.enc.yaml"
}

teardown() {
  rm -rf apps/_rttest
}

@test "sops encrypts a prod-path secret to two recipients" {
  run sops --encrypt --in-place "apps/_rttest/prod/secret.enc.yaml"
  [ "$status" -eq 0 ]
  run grep -c 'recipient:' "apps/_rttest/prod/secret.enc.yaml"
  [ "$output" -eq 2 ]
  # 파일 피연산자라 `-eq 1` 하나로 리네임·삭제가 닫힌다(rc 2를 통과로 읽지 않는다).
  # 디렉토리·재귀 자리가 요구하는 비공허 바닥값 + 양성 대조 쌍은 여기 필요 없다.
  run grep -q 'super-secret-value-123' "apps/_rttest/prod/secret.enc.yaml"
  [ "$status" -eq 1 ]   # 평문이 절대 살아남으면 안 된다
}

@test "sops decrypt round-trips to the original plaintext" {
  sops --encrypt --in-place "apps/_rttest/prod/secret.enc.yaml"
  run sops --decrypt "apps/_rttest/prod/secret.enc.yaml"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'TOKEN: super-secret-value-123'
  echo "$output" | grep -q 'URL: postgres://user:pw@db:5432/app'
}
