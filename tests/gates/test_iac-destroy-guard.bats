#!/usr/bin/env bats
# drift-1: iac.yaml의 primary merge→apply 경로(apply job)는 plan과 apply 사이에 tf-destroy-guard
# (mode=block)를 거쳐야 한다. iac-plan preview는 동일 composite를 mode=warn으로 쓴다.
# ⚠️ bash 3.2: 중간 단언은 [ ]만. 순수 grep — terraform/cluster 비접촉(required gate-safe).

WF="$BATS_TEST_DIRNAME/../../.github/workflows/iac.yaml"

# ⚠️ 값 판정은 **잡 스코프**여야 한다 — preview(warn)와 apply(block)가 한 파일에 공존하므로
#    파일 전체 grep은 두 값을 맞바꿔도 전건 통과한다(실측: `mode: warn`↔`mode: block` 맞바꿈
#    뮤테이션에서 5/5 초록. warn은 `::warning::`만 내고 delete를 막지 않으므로 무인 apply의
#    destroy 차단선이 사라진 상태였다). 같은 디렉토리 test_pr-sweeper.bats의 yq 관용구를 쓴다.
#    mode 판정으로 landed한 관용구를 $2 키 일반으로 넓혀 allow/allow_max도 같은 함수로 잰다.
guard_with() { # $1: 잡 이름, $2: with 키 — 그 잡의 tf-destroy-guard 콜사이트 값
  yq -r ".jobs.\"$1\".steps[] | select(.uses == \"./.github/actions/tf-destroy-guard\") | .with.$2" "$WF"
}

@test "apply job uses tf-destroy-guard with mode=block" {
  # apply job 블록(plan→apply 사이)에 composite + block 모드가 있어야 한다.
  run grep -q 'uses: ./.github/actions/tf-destroy-guard' "$WF"
  [ "$status" -eq 0 ]
  m="$(guard_with apply mode)"
  [ -n "$m" ]        # 비공허 바닥값 — 잡/스텝 리네임으로 추출이 0줄이면 아래 비교가 공허해진다
  [ "$m" = "block" ]
}

@test "apply job no longer applies without a guard (apply preceded by guard usage)" {
  # apply 스텝과 guard 사용이 같은 워크플로에 공존 — guard 미사용 회귀를 차단.
  run grep -c 'uses: ./.github/actions/tf-destroy-guard' "$WF"
  [ "$status" -eq 0 ]
  [ "$output" -ge 2 ]   # apply(block) + iac-plan preview(warn) 두 콜사이트
}

@test "iac-plan preview uses tf-destroy-guard mode=warn (not an inline jq block)" {
  m="$(guard_with iac-plan mode)"
  [ -n "$m" ]
  [ "$m" = "warn" ]
  # 인라인 destroy jq 셀렉터는 composite로 옮겨졌어야 한다(워크플로에서 제거).
  # rc 2(대상 부재)를 통과로 읽지 않는다 — 무매치는 정확히 rc 1이다. `-ne 0`이면 iac.yaml을
  # 리네임·삭제해도 이 단언이 초록이다. 바로 위 mode=warn 단언(rc 0)이 $WF의 양성 대조다.
  run grep -F 'select(. == "delete")' "$WF"
  [ "$status" -eq 1 ]
}

@test "iac.yaml primary apply guard stays block (drift-2 alert-and-skip is reconcile-only)" {
  # primary apply(iac.yaml)는 alert-and-skip로 완화하지 않는다 — 구조적 무인 delete는 여기서 끝까지
  # 막힌다(app 공개 DNS만 allow로 자동 apply, tunnel/zone/waf/r2 등 delete/replace는 block 유지).
  m="$(guard_with apply mode)"
  [ -n "$m" ]
  [ "$m" = "block" ]
  run grep -qE 'continue-on-error:[[:space:]]*true' "$WF"
  # rc 2(대상 부재)를 통과로 읽지 않는다. 위 mode=block 단언(rc 0)이 $WF의 양성 대조다.
  [ "$status" -eq 1 ]   # iac.yaml apply 경로엔 continue-on-error 없음
}

@test "iac guards pass allow=app-DNS + allow_max cap (both apply+preview)" {
  # cloudflare_dns_record.app[*]만 자동 허용(apex/www=public[*]는 보호), allow_max로 대량 삭제 차단.
  # ⚠️ 부분문자열 grep은 값 axis에 무증인이다 — allow에 `|^cloudflare_dns_record\.public\[`를
  #    덧대도(apex/www까지 자동 허용) grep -cF는 그대로 매치한다(실측). yq로 잡-스코프 값을 뽑아
  #    정확 등식으로 잰다(위 guard_with()와 같은 관용구).
  for j in apply iac-plan; do
    a="$(guard_with "$j" allow)"; m="$(guard_with "$j" allow_max)"
    [ -n "$a" ]   # 비공허 바닥값 — 잡/스텝 리네임으로 추출이 0줄이면 아래 비교가 공허해진다
    [ "$a" = '^cloudflare_dns_record\.app\[' ]
    [ "$m" = "1" ]
  done
}

@test "iac.yaml accounting job's fork boundary stays head.repo.full_name == github.repository" {
  # wf-iac-actions-1: G-09 준비상태 회계(accounting job)는 fork PR을 원장 면제가 아니라 트리거
  # 경계로 제외한다(140-147행 주석) — 그런데 check-workflow-readiness.ts의 checkStatic은
  # !cancelled() 존재만 정규식으로 보고 이 fork 절은 파싱하지 않는다(무증인). `==`가 `!=`로 반전되면
  # same-repo PR에서 accounting이 꺼져(G-09가 막으려던 침묵 재발) fork PR마다는 spurious red가 뜬다.
  cond="$(yq -r '.jobs.accounting.if' "$WF")"
  [ -n "$cond" ]   # 비공허 바닥값 — 잡 리네임으로 추출이 0줄이면 아래 비교가 공허해진다
  case "$cond" in
    *'head.repo.full_name == github.repository'*) : ;;
    *)
      echo "unwitnessed fork boundary: accounting job의 if에 'head.repo.full_name == github.repository'가 없다('$cond')"
      false
      ;;
  esac
}
