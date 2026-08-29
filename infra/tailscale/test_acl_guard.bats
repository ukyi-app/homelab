#!/usr/bin/env bats
# tailscale ACL F2 회귀 가드 — CNPG pg(5432)가 전 tailnet 멤버(autogroup:member)에 열리지 않게 강제.
# crown-jewel DB 직결은 owner(autogroup:admin)만. grep 기반(terraform 불요 → CI-safe, required gate).
# @test 이름은 영어(디렉토리 단위 실행 시 한글 인코딩 깨짐). 중간 단언은 [ ]만(bash 3.2).
# ⚠️ 부재 단언은 `[ "$status" -eq 1 ]`이다 — 피연산자가 단일 파일($ACL)이라 그것으로 닫힌다.
#    cf. docs/traps-detail.md 「열거 붕괴 → vacuous green」③·③-a
setup() { ACL="${BATS_TEST_DIRNAME}/acl.tf"; }

@test "pg 5432 is exposed to the owner (autogroup:admin), not all members" {
  run grep -Eq 'tag:k8s:5432' "$ACL"; [ "$status" -eq 0 ]
  # 5432 규칙과 같은 줄에 autogroup:admin(src)이 있어야 한다(owner-only).
  run grep -Eq 'autogroup:admin.*tag:k8s:5432' "$ACL"; [ "$status" -eq 0 ]
}

@test "pg 5432 is never opened to autogroup:member (F2 over-exposure guard)" {
  # member rule(현재 80,443)에 5432가 섞이면 전 tailnet 노출 → 같은 줄에 member와 5432 공존 시 실패.
  # ⚠️ 형제 양성 단언이 없는 @test다 — 예전 `-ne 0`에서는 acl.tf를 리네임하면 이 파일 4개 중
  #    **이것만 초록으로 남았다**(2026-08-29 격리 트리 실측). crown-jewel DB 과다노출 가드가
  #    ACL 파일 부재에 공허했다는 뜻이다.
  run grep -E 'autogroup:member.*5432|5432.*autogroup:member' "$ACL"
  [ "$status" -eq 1 ]
}

# D-i(2026-08-12) 의존 가드 — 아래 두 줄이 사라지면 D-i의 두 경로가 조용히 죽는다.
# ⚠️ 이 @test들은 "이 접근이 옳다"가 아니라 **"이 접근에 기대는 결정이 있다"**를 고정한다.
#    좁히고 싶다면 먼저 D-i(핸드오프 §1.9)를 재검토할 것.

@test "members keep full access to their own devices (D-i remote kubectl rides this)" {
  # apiserver 6443은 tag:k8s 규칙이 아니라 이 self 규칙으로 도달한다(실측: Mac에서 401).
  # 이 줄을 좁히면 Mac 사본의 원격 kubectl과 Tailscale SSH가 함께 끊긴다.
  run grep -Eq 'autogroup:member.*autogroup:self' "$ACL"; [ "$status" -eq 0 ]
}

@test "tailscale ssh still allows root (D-i uses it as the non-interactive escape for check 5)" {
  # verify-cluster [5]는 노드 root를 요구한다. `ssh root@<node>`가 패스워드 없이 되는 것이
  # NOPASSWD sudoers 드롭인을 불필요하게 만든 근거다(D-i 확정).
  run grep -Eq '"root"' "$ACL"; [ "$status" -eq 0 ]
}
