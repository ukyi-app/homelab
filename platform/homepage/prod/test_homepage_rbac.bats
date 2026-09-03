#!/usr/bin/env bats
# homepage RBAC(최소권한 read-only ClusterRole) 가드. @test 이름은 영어.
# ⚠️ 부재 단언은 `[ "$status" -eq 1 ]`이다 — 피연산자가 rbac.yaml 단일 파일이라 그것으로 닫힌다.
#    cf. docs/traps-detail.md 「열거 붕괴 → vacuous green」③·③-a
setup() { R="${BATS_TEST_DIRNAME}/rbac.yaml"; K="${BATS_TEST_DIRNAME}/kustomization.yaml"; }

# 최소권한 표면의 **전칭 화이트리스트**. 확대는 이 두 줄을 고쳐야만 통과하므로 리뷰에 반드시 보인다.
# ⚠️ 부정 열거(리터럴 동사 블랙리스트)로 되돌리지 마라 — 아래 @test 주석의 실측이 그 이유다.
# 계층 관계: verb 축은 이제 게이트 `tests/gates/test_rbac-verbs.bats`가 **전 컴포넌트**에 같은
#   화이트리스트를 건다(2026-09-03 신설 — 그 전엔 이 파일이 유일한 자리였다). 여기 두 줄은 남는다:
#   resources 축(RO_RESOURCES)은 이 컴포넌트만의 표면이고, 게이트는 verb 축만 본다. 중복이 아니라 계층이다.
RO_VERBS="get list watch"
RO_RESOURCES="httproutes gateways namespaces pods nodes"

@test "serviceaccount, clusterrole and binding are defined" {
  run grep -q 'kind: ServiceAccount' "$R"; [ "$status" -eq 0 ]
  run grep -q 'kind: ClusterRole' "$R"; [ "$status" -eq 0 ]
  run grep -q 'kind: ClusterRoleBinding' "$R"; [ "$status" -eq 0 ]
  # rbac.yaml 자신의 kustomization 멤버십 — 2026-09-04 실측: 이 파일을 resources에서 빼도 이
  # 디렉토리 43/43 전건 초록이었다(형제 deployment·service·httproute·networkpolicy는 렌더를 읽는
  # test_homepage_render.bats가 이미 문다 — rbac만 렌더 단언 밖이라 무증인으로 남아 있었다).
  # 프룬되면 SA/ClusterRole이 사라져 자동발견 타일이 통째로 죽는다(파드는 계속 뜬다 — 무성 회귀).
  # ⚠️ 건수 바닥값·length==N이 아니라 멤버십이다(resources는 정당하게 늘고 준다). 그리고 멤버십은
  #    `yq contains()`가 아니라 **정확 일치**로 잰다 — yq의 배열 contains는 원소마다 **부분문자열**
  #    판정이라(2026-09-04 실측) 이름이 서로의 접미가 되는 자리에서 조용히 참이 된다.
  yq '.resources[]' "$K" | grep -qxF 'rbac.yaml' \
    || { echo "kustomization resources에 rbac.yaml이 없다 — 렌더에서 빠지면 프룬된다"; false; }
}

@test "clusterrole can discover gateway httproutes" {
  run grep -q 'gateway.networking.k8s.io' "$R"; [ "$status" -eq 0 ]
  run grep -q 'httproutes' "$R"; [ "$status" -eq 0 ]
}

@test "clusterrole verbs are a subset of the read-only whitelist" {
  # 🔴 2026-09-03 실측: 옛 검출기는 `create|update|patch|delete` 네 리터럴의 **부정 열거**였고,
  #    RBAC의 최대 권한 확대인 `verbs: ["*"]`가 정확히 그 사각이었다 — rules를
  #    `resources: [namespaces,pods,nodes,secrets] / verbs: ["*"]`로 뒤집어도 이 파일은 5 ok/5로
  #    전건 초록이었다. `deletecollection`·`escalate`·`bind`·`impersonate`도 같은 이유로 통과한다
  #    (`\bdelete\b`는 deletecollection에 매치되지 않는다). 그래서 판정을 전칭 화이트리스트로 뒤집는다.
  # ⚠️ 판정은 **파싱한 목록**에만 한다 — 파일 전체 grep은 이 주석 자체가 부재 단언을 만족시킨다
  #    (「규약을 설명한 파일이 그 규약에서 면제된다」 클래스).
  local verbs n v bad=""
  verbs="$(yq 'select(.kind=="ClusterRole") | .rules[].verbs[]' "$R" | grep .)"
  n="$(printf '%s\n' "$verbs" | grep -c .)"
  # 비공허 바닥값 — rbac.yaml이 사라지거나 rules 경로가 옮겨가면 전칭이 공집합에서 vacuous green이 된다.
  [ "$n" -ge 2 ] || { echo "verb 열거가 ${n}건으로 붕괴했다(기대 >=2)"; false; }
  # ⚠️ `for v in $verbs`(비인용 확장) 금지 — 정작 잡아야 할 `*`가 pathname expansion으로 레포
  #    디렉토리 목록이 돼 위반 verb가 사라진다. heredoc 루프는 글로빙·단어분리 둘 다 없고
  #    파이프와 달리 서브셸이 아니라 $bad가 전파된다(선례: root/test_projects.bats의 Namespace 루프).
  while IFS= read -r v; do
    [ -n "$v" ] || continue
    case " $RO_VERBS " in *" $v "*) ;; *) bad="$bad $v";; esac
  done <<EOF
$verbs
EOF
  [ -z "$bad" ] || { echo "read-only 화이트리스트 밖 verb:$bad"; false; }
}

@test "clusterrole resources are a subset of the discovery whitelist" {
  # 같은 부정 열거의 나머지 축 — verb를 read-only로 묶어도 `resources`에 secrets가 붙으면
  # 클러스터 전역 Secret **read**가 한 줄로 열린다. 표면 자체를 닫힌 로스터로 못박는다.
  local res n r bad=""
  res="$(yq 'select(.kind=="ClusterRole") | .rules[].resources[]' "$R" | grep .)"
  n="$(printf '%s\n' "$res" | grep -c .)"
  [ "$n" -ge 4 ] || { echo "resource 열거가 ${n}건으로 붕괴했다(기대 >=4)"; false; }
  while IFS= read -r r; do            # 비인용 확장 금지 — 근거는 위 @test 주석
    [ -n "$r" ] || continue
    case " $RO_RESOURCES " in *" $r "*) ;; *) bad="$bad $r";; esac
  done <<EOF
$res
EOF
  [ -z "$bad" ] || { echo "discovery 화이트리스트 밖 resource:$bad"; false; }
}

@test "clusterrole does not depend on metrics-server" {
  # ⚠️ 위 @test와 같다 — 부재 단언 단독이라 형제 증인이 없고, 위 실측의 생존 2건 중 나머지가 이 @test다.
  run grep -q 'metrics.k8s.io' "$R"; [ "$status" -eq 1 ]
}

@test "binding targets the homepage namespace serviceaccount" {
  run grep -q 'namespace: homepage' "$R"; [ "$status" -eq 0 ]
}
