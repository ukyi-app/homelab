#!/usr/bin/env bats
# vmalert가 GitOps로 동기화된 룰 변경을 자동 반영하도록 강제한다.
# configCheckInterval이 없으면 vmalert는 mount된 룰 파일 변경을 감시하지 않아, ArgoCD가 ConfigMap을
# 갱신해도 메모리상 옛 룰을 계속 평가한다(수동 rollout restart/-/reload 전까지 silent staleness).
# (중간 단언은 [ ]/grep 단순 명령으로 — bash 3.2에서 [[ ]] 실패 침묵 통과 회피)

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  VMALERT="$ROOT/platform/victoria-stack/vmalert.yaml"
}

@test "vmalert auto-reloads rule files on change (configCheckInterval set)" {
  grep -q 'configCheckInterval' "$VMALERT"
}
