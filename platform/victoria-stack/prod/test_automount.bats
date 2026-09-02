#!/usr/bin/env bats
# 메타갭 ⑤ W2-C: k8s API를 쓰지 않는 관측 컴포넌트는 default SA 토큰을 마운트하지 않는다
# (RBAC 감사 리포트 Category A — 라이브 tokenVol=yes로 미사용 토큰 마운트 확인됨). 회귀 차단.
# **Category B(2026-09-02 추가)**: API를 *쓰는* 컴포넌트의 **권한 폭**. Category A는 토큰의 유무만 봐서
# "쓰는데 너무 많이 쓴다"를 원리적으로 못 본다 — KSM이 그 자리였다(효용 0의 클러스터 전역 secrets read).
# ⚠️ @test 이름은 영어만(bats dir-run 인코딩), 중간 단언은 [ ]/grep만(bash 3.2 [[ ]] 침묵통과).

setup() { ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"; D="$ROOT/platform/victoria-stack/prod"; }

@test "API-free observability components disable SA token automount (Category A)" {
  for c in grafana vmsingle victorialogs vmalert alertmanager node-exporter deadmanswitch-relay digest-exporter; do
    grep -q 'automountServiceAccountToken: false' "$D/$c.yaml" || { echo "MISSING automount:false in $c.yaml"; false; }
  done
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

@test "already-hardened components keep automount disabled (no regression)" {
  # glances(선행)·pvc-du-exporter(Task 2)도 유지.
  grep -q 'automountServiceAccountToken: false' "$D/glances.yaml"
  grep -q 'automountServiceAccountToken: false' "$D/pvc-du-exporter.yaml"
}
