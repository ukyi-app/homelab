#!/usr/bin/env bats
# 메타갭 ⑤ W2-C: k8s API를 쓰지 않는 관측 컴포넌트는 default SA 토큰을 마운트하지 않는다
# (RBAC 감사 리포트 Category A — 라이브 tokenVol=yes로 미사용 토큰 마운트 확인됨). 회귀 차단.
# ⚠️ @test 이름은 영어만(bats dir-run 인코딩), 중간 단언은 [ ]/grep만(bash 3.2 [[ ]] 침묵통과).

setup() { ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"; D="$ROOT/platform/victoria-stack/prod"; }

@test "API-free observability components disable SA token automount (Category A)" {
  for c in grafana vmsingle victorialogs vmalert alertmanager node-exporter deadmanswitch-relay digest-exporter; do
    grep -q 'automountServiceAccountToken: false' "$D/$c.yaml" || { echo "MISSING automount:false in $c.yaml"; false; }
  done
}

@test "already-hardened components keep automount disabled (no regression)" {
  # glances(선행)·pvc-du-exporter(Task 2)도 유지.
  grep -q 'automountServiceAccountToken: false' "$D/glances.yaml"
  grep -q 'automountServiceAccountToken: false' "$D/pvc-du-exporter.yaml"
}
