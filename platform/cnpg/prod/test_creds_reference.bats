#!/usr/bin/env bats
# M2 의존: platform/cnpg/prod/r2-creds.enc.yaml은 M2의 seed-secrets.sh가 생성한다
# (라이브, 실제 R2 자격증명 필요). 이 테스트들은 M2 실행 이후에만 통과한다.
# ⚠️ 피연산자가 **상대 경로**다 — 이 파일은 레포 루트에서 실행해야 rc가 의미를 갖는다
#    (실행처: .ci-exclude 항목 — owner-local `make verify-ksops`).

f=platform/cnpg/prod/r2-creds.enc.yaml # M2 소유 — 여기서는 참조만

@test "M2 seed for cnpg-r2-creds exists" {
  [ -f "$f" ]
}
@test "seed is SOPS-encrypted (has sops metadata)" {
  run grep -q '^sops:' "$f"
  [ "$status" -eq 0 ]
}
@test "seed has NO plaintext AWS secret" {
  # ⚠️ 이 @test 안에는 피연산자 실재를 증언하는 형제 단언이 없다 — 예전 `-ne 0`은 $f 부재(rc 2)를
  #    "평문 없음"으로 읽어 누출 가드가 홀로 초록이었다. (파일 스코프에는 :9-11이 실재를 강제하지만
  #    **다른 @test**라 `bats -f` 단일 실행에서는 증인이 못 된다.)
  #    `-eq 1`이 정당한 상태를 red로 만들지 않는다 — 시드는 tracked이고(`git ls-files` 확인), 부재는
  #    "M2 미실행"이라 헤더 :2-4대로 red가 맞다. 피연산자가 단일 파일이라 rc 하나로 닫힌다.
  #    cf. docs/traps-detail.md 「열거 붕괴 → vacuous green」③
  run grep -E 'AWS_SECRET_ACCESS_KEY:\s+[A-Za-z0-9/+]{20,}' "$f"
  [ "$status" -eq 1 ]
}
@test "seed Secret is named cnpg-r2-creds (canonical)" {
  run bash -c "sops --decrypt '$f' | grep -qE 'name:\s+cnpg-r2-creds'"
  [ "$status" -eq 0 ]
}
@test "seed encrypts to two recipients (cluster + offline recovery)" {
  run bash -c "grep -c 'recipient:' '$f'"
  [ "$output" -ge 2 ]
}
@test "M4 does NOT author a duplicate R2 creds secret" {
  # ⚠️ `ls`는 "무매치"와 "경로째 부재"를 **둘 다 rc 2**로 뭉개므로 `-eq 1` 전환이 원리적으로
  #    불가능하다. 처방대로 극성이 반대인 `find`로 바꾼다(경로 부재=rc 1 / 무매치=rc 0 + 빈 stdout).
  #    예전 `ls … ; [ -ne 0 ]`은 platform/cnpg/prod가 통째로 사라져도 초록이었다.
  #    cf. docs/traps-detail.md 「열거 붕괴 → vacuous green」③-a
  run find platform/cnpg/prod -maxdepth 1 -name 'object-store-creds.enc.yaml'
  [ "$status" -eq 0 ] # 디렉토리 실재 = 비공허 바닥값
  [ -z "$output" ]    # 예전 M4 소유 이름이 존재하면 안 된다
}
