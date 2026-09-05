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
  # 판정 단위는 **줄이 아니라 규칙 객체**다 — HCL 객체 constructor는 개행으로 쪼개도 유효하고
  # `terraform fmt`가 그것을 합치지 않는다(실측: 멀티라인 member 5432 규칙 삽입 후 fmt rc 0).
  # 그래서 줄 단위 grep은 같은 의미의 규칙을 두세 줄로 적으면 통째로 지나갔다. tr로 파일을 한 줄로
  # 접은 뒤 `{...}` 하나씩 뽑아 규칙마다 판정한다(acl.tf 주석에 `{`/`}`가 0건이라 조인이 주석을
  # 규칙으로 오인하지 않는다 — 실측).
  # ⚠️ 형제 양성 단언이 없는 @test다 — 예전 `-ne 0`에서는 acl.tf를 리네임하면 이 파일 4개 중
  #    **이것만 초록으로 남았다**(2026-08-29 격리 트리 실측). crown-jewel DB 과다노출 가드가
  #    ACL 파일 부재에 공허했다는 뜻이다.
  # 닫힌 축: 파일 부재(아래 양성 대조) + 표기 형태(멀티라인·src/dst 역순) + 포트 와일드카드(tag:k8s:*)
  #          + src 와일드카드(`src = ["*"]`)·dst 호스트 와일드카드(`"*:5432"`) + 규칙 집합 상한.
  # 여전히 열린 축: tag:k8s 태그 부여 경로(operator가 무엇을 tag:k8s로 태그하는가)는 여기서 안 본다.
  rules="$(tr '\n' ' ' < "$ACL" | grep -oE '\{[^{}]*\}')"
  # 양성 대조: 규칙 추출이 실제로 돌았다(파일 부재/서식 변화에 공허해지지 않는다).
  run bash -c "printf '%s\n' \"\$1\" | grep -qE 'autogroup:member[^}]*tag:k8s:80,443'" _ "$rules"
  [ "$status" -eq 0 ]
  # 부재: 한 규칙 객체 안에서 member가 tag:k8s의 5432 또는 포트 와일드카드에 닿으면 안 된다(양방향).
  # `tag:k8s:` 앵커가 acl.tf:10의 정당한 `autogroup:self:*`를 오탐하지 않게 한다.
  run bash -c "printf '%s\n' \"\$1\" | grep -qE 'autogroup:member[^}]*tag:k8s:[^\"]*(\*|5432)|tag:k8s:[^\"]*(\*|5432)[^{]*autogroup:member'" _ "$rules"
  [ "$status" -ne 0 ]
  # ⚠️ 위 두 술어는 좌변에 `autogroup:member` 리터럴을 요구한다 — 그 **진상위집합**인 `src = ["*"]`와
  #    dst 호스트 와일드카드 `"*:5432"`는 분모 밖이라, 규칙 한 줄을 더하는 것만으로 crown-jewel DB가
  #    전 tailnet(최악 any:any)에 열려도 이 파일이 전건 초록이었다(감사 6라운드 실측 5/5 ok).
  #    표기를 넓히는 대신 **규칙 집합 자체를 계약으로 못 박는다** — acl.tf의 규칙은 인스턴스 가변이
  #    아니라 손으로 쓰는 계약이라, 추가·삭제 양방향이 즉시 red이고 정당한 추가 시 이 숫자를 함께
  #    올리는 것이 곧 crown-jewel 리뷰 신호가 된다(형제 관용구: 존재 단언 N개 + length == N —
  #    platform/network-policies/prod/test_netpol.bats:33-38).
  # 존재 단언 5개: member↔self(:10) · member↔80,443(:23, 위 양성 대조) · admin↔5432(:28, @test 1) ·
  #                operator↔tag:k8s:*(아래) · ssh root(:39-40, @test 4).
  run bash -c "printf '%s\n' \"\$1\" | grep -qE 'tag:k8s-operator[^}]*tag:k8s:\*'" _ "$rules"
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$rules" | grep -c 'action = "accept"')" -eq 5 ]
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

@test "pg 5432 is never opened to autogroup:member via a port range or wildcard (F2 range-aware)" {
  # 위 @test는 리터럴 `5432`·`*`만 본다 — Tailscale ACL의 포트 범위(n-m) 문법은 분모 밖이라
  # `tag:k8s:5400-5450` 한 줄로 전 tailnet 멤버에 DB 직결이 열려도 무증인이었다(실측 4/4 ok).
  rules="$(tr '\n' ' ' < "$ACL" | grep -oE '\{[^{}]*\}')"
  mrules="$(printf '%s\n' "$rules" | grep -E 'autogroup:member[^}]*tag:k8s:')"
  [ -n "$mrules" ]   # 양성 대조 — member/tag:k8s 규칙이 최소 1건(추출이 공허하지 않다)
  bad=0
  set -f   # ⚠️ 토큰 `*`가 unquoted `for` 확장에서 파일명 글로빙되지 않게 막는다(실측 함정)
  for p in $(printf '%s\n' "$mrules" | grep -oE 'tag:k8s:[0-9*,-]+' | sed 's/^tag:k8s://' | tr ',' ' '); do
    case "$p" in
      '*') bad=1 ;;
      *-*) [ "${p%-*}" -le 5432 ] && [ "${p#*-}" -ge 5432 ] && bad=1 ;;
      *) [ "$p" -eq 5432 ] 2>/dev/null && bad=1 ;;
    esac
  done
  set +f
  [ "$bad" -eq 0 ]
}
