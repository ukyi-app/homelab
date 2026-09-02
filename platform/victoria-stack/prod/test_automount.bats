#!/usr/bin/env bats
# 메타갭 ⑤ W2-C: k8s API를 쓰지 않는 관측 컴포넌트는 default SA 토큰을 마운트하지 않는다
# (RBAC 감사 리포트 Category A — 라이브 tokenVol=yes로 미사용 토큰 마운트 확인됨). 회귀 차단.
# **Category B(2026-09-02 추가)**: API를 *쓰는* 컴포넌트의 **권한 폭**. Category A는 토큰의 유무만 봐서
# "쓰는데 너무 많이 쓴다"를 원리적으로 못 본다 — KSM이 그 자리였다(효용 0의 클러스터 전역 secrets read).
# ⚠️ @test 이름은 영어만(bats dir-run 인코딩), 중간 단언은 [ ]/grep만(bash 3.2 [[ ]] 침묵통과).

setup() { ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"; D="$ROOT/platform/victoria-stack/prod"; }

# Category A 면제 — SA 토큰이 **필요한** k8s API 사용자. 각 파일에 "false로 바꾸지 마라" 근거 주석이
# 실재한다: vmagent=service discovery로 스크레이프 대상(파드/엔드포인트/노드) 발견 ·
# kube-state-metrics=kube_* 전 계열의 유일한 생산자 · vector=kubernetes_logs 소스가 파드 메타데이터를
# API에서 읽는다. 면제하는 것은 토큰의 **유무**뿐이고 권한의 **폭**은 Category B가 따로 본다.
# 추가하려면 이 한 줄을 고쳐야 하므로 리뷰에 반드시 보인다.
AUTOMOUNT_EXEMPT="vmagent kube-state-metrics vector"

# 워크로드 추출 질의 — 파드 템플릿을 가진 전 kind. CronJob은 파드 스펙이 한 단계 더 깊다.
# ⚠️ `// "unset"` 같은 alternative 연산자를 쓰지 마라 — yq의 `//`는 **false도 null 취급**해서
#    정확히 통과시켜야 할 `automountServiceAccountToken: false`를 "미설정"으로 바꿔버린다
#    (실측 2026-09-03; cf. docs/traps-detail.md 「yq -e는 값이 false면 exit 1이다」와 같은 갈래).
#    `| tostring`은 선언된 값을 그대로("false"/"true") 내고 부재는 빈 값이 되므로 둘이 갈린다
#    (빈 값의 "unset" 라벨링은 아래 루프가 한다 — yq가 아니라 셸에서).
AUTOMOUNT_Q='(select(.kind=="Deployment" or .kind=="DaemonSet" or .kind=="StatefulSet") | .metadata.name + "|" + (.spec.template.spec.automountServiceAccountToken | tostring)), (select(.kind=="CronJob" or .kind=="Job") | .metadata.name + "|" + (.spec.jobTemplate.spec.template.spec.automountServiceAccountToken | tostring))'

@test "API-free observability components disable SA token automount (Category A)" {
  # 🔴 2026-09-03까지 이 분모는 **손으로 적은 8개 이름**이었다(+ 형제 @test가 glances·pvc-du-exporter
  #    둘을 더 손으로 들었다). 실측: 새 Deployment(automount 선언 없음)를 kustomization에 배선해도
  #    3 ok/3 전건 초록이었고, 실제로 `gha-liveness-exporter`는 automount:false를 갖고 있으면서도
  #    그 로스터 밖이었다 — 로스터가 완전했던 것은 우연이지 기계가 지키는 성질이 아니었다.
  #    그래서 분모를 **매니페스트 열거에서 파생**한다(레포 커널과 같은 어휘: 열거하고 바닥값을 건다).
  # `git ls-files`인 이유: ArgoCD가 싱크하는 것은 tracked 파일뿐이라 분모가 배포 진실과 일치한다.
  #    (신규 매니페스트는 `git add` 뒤에 이 가드에 보인다 — CI는 tracked 트리만 체크아웃한다.)
  cd "$ROOT"
  local files f L C n name am bad="" e
  L="$BATS_TEST_TMPDIR/workloads-raw.txt"
  C="$BATS_TEST_TMPDIR/workloads.txt"
  : > "$L"
  files="$(git ls-files -- platform/victoria-stack/prod | grep '\.yaml$' | LC_ALL=C sort)"
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    yq "$AUTOMOUNT_Q" "$f" >> "$L"   # yq 실패는 set -e로 즉시 red — 파싱 불가 매니페스트도 신호다
  done <<EOF
$files
EOF
  grep -v '^---$' "$L" | grep . > "$C" || true   # `|| true`는 바로 아래 바닥값이 즉시 소비한다
  n="$(grep -c . "$C" || true)"
  # 열거 붕괴 바닥값 — 2026-09-03 실측 14건. 값은 **붕괴 경계**이지 현재 도메인 크기가 아니다
  # (스냅샷을 굳히면 워크로드를 정당하게 철거할 때마다 red가 난다 — check-argocd-revision.sh:47-50).
  [ "$n" -ge 10 ] || { echo "관측 워크로드 열거가 ${n}건으로 붕괴했다(기대 >=10)"; false; }
  # 면제 로스터 등식 — 이름이 실제 워크로드를 가리키지 않으면 죽은 면제다(리네임/철거 드리프트).
  for e in $AUTOMOUNT_EXEMPT; do
    grep -q "^$e|" "$C" || { echo "면제 로스터의 죽은 항목: $e (열거에 그 워크로드가 없다)"; false; }
  done
  while IFS='|' read -r name am; do
    [ -n "$name" ] || continue
    case " $AUTOMOUNT_EXEMPT " in *" $name "*) continue;; esac
    [ -n "$am" ] || am="unset"        # 키 부재는 yq 문자열 연결에서 빈 값으로 나온다
    [ "$am" = "false" ] || bad="$bad $name(automount=$am)"
  done < "$C"
  [ -z "$bad" ] || { echo "automountServiceAccountToken:false가 없는 관측 워크로드:$bad"; false; }
}

@test "kube-state-metrics ClusterRole grants no secrets or configmaps (Category B: unused crown-jewel read)" {
  # Category A(위)는 **API를 안 쓰는** 컴포넌트의 토큰 마운트를 닫는다. KSM은 API 사용자라 분모 밖이고,
  # 그래서 이 파일의 스코프는 "API 사용 컴포넌트의 **권한 폭**"까지로 넓어진다. k8s의 `list secrets`는
  # 메타데이터가 아니라 Secret data 전체를 돌려주는데 이 레포에는 kube_secret_*/kube_configmap_*
  # 소비자가 0건이었다 — 효용 0의 순수 노출면.
  F="$D/kube-state-metrics.yaml"
  # ⚠️ 판정은 **파싱한 목록**에만 한다 — 파일 전체 grep은 같은 자리의 재도입 금지 주석이 부재 단언을
  #    만족시킨다(「규약을 설명한 파일이 그 규약에서 면제된다」 클래스).
  R="$BATS_TEST_TMPDIR/ksm-clusterrole.txt"
  yq -e 'select(.kind == "ClusterRole") | .rules[].resources[]' "$F" | LC_ALL=C sort > "$R"
  # 양성 대조 — 열거가 붕괴하면 아래 부재 단언이 공집합에 대해 vacuous green이 된다.
  n="$(grep -c . "$R")"
  [ "$n" -ge 10 ]
  grep -qxF 'pods' "$R"
  run grep -qxE 'secrets|configmaps' "$R"; [ "$status" -eq 1 ]

  # ClusterRole = `--resources` 등식. 한쪽만 지우면 KSM reflector가 403을 영구 로깅하고,
  # ClusterRole에만 남은 항목은 요청조차 안 하는 죽은 권한이다 — 등식이 양쪽 드리프트를 함께 잡는다.
  A="$BATS_TEST_TMPDIR/ksm-args.txt"
  yq -e 'select(.kind == "Deployment") | .spec.template.spec.containers[0].args[]' "$F" \
    | grep '^--resources=' | sed 's/^--resources=//' | tr ',' '\n' | LC_ALL=C sort > "$A"
  [ -s "$A" ]
  run diff "$R" "$A"; [ "$status" -eq 0 ]
}

# ⓘ 여기 있던 "already-hardened components keep automount disabled" @test는 삭제했다 —
#   glances(선행)·pvc-du-exporter(Task 2) 두 이름을 손으로 든 **두 번째 하드코딩 로스터**였고,
#   위 Category A의 파생 분모가 둘을 이미 포함한다(파일 전체 grep이 아니라 파싱한 값으로 판정하므로
#   엄격히 더 강하다). 같은 회귀를 두 자리에서 재는 대신 분모 하나를 기계가 지키게 둔다.
