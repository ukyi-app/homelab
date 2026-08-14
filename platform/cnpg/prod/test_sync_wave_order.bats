#!/usr/bin/env bats
# 콜드스타트 sync-wave 순서 가드 (2026-08-13 NUC 첫 bootstrap에서 실측한 교착).
#
# ⚠️ **이 순서가 뒤집히면 콜드스타트가 완전히 교착된다.** barman-cloud 플러그인은 Cluster가
#    참조하는 ObjectStore가 없으면 "barman object configuration not found"로 무한 requeue하고,
#    그 pre-reconcile hook이 reconciliation을 멈춘다 → Cluster가 영원히 Healthy가 아니다 →
#    ArgoCD는 그 wave에서 대기하므로 **뒤 wave의 ObjectStore는 영원히 apply되지 않는다**.
# ⚠️ 라이브 Mac에서는 드러나지 않는다 — 점진 구축이라 ObjectStore 추가 시 Cluster가 이미 떠 있었다.
#    즉 이 가드는 **아무도 매일 밟지 않는 경로**(G11 콜드스타트)를 지킨다.
# ⚠️ 중간 단언은 [ ]만 — bash 3.2 [[ ]] 침묵 통과.
setup() { ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"; D="$ROOT/platform/cnpg/prod"; }

wave_of() { # $1=파일 — sync-wave 값(없으면 ArgoCD 기본값 0)
  w="$(LC_ALL=C sed -n 's/^ *argocd\.argoproj\.io\/sync-wave: *"\{0,1\}\(-\{0,1\}[0-9][0-9]*\)"\{0,1\}.*/\1/p' "$1" | head -1)"
  [ -n "$w" ] || w=0
  printf '%s' "$w"
}

@test "ObjectStore applies before the Cluster that references it (cold-start deadlock guard)" {
  os="$(wave_of "$D/object-store.yaml")"
  cl="$(wave_of "$D/cluster.yaml")"
  [ "$os" -lt "$cl" ] || { echo "ObjectStore wave=$os · Cluster wave=$cl — ObjectStore가 더 앞이어야 한다"; false; }
}

@test "the credential generator lands no later than the ObjectStore that consumes it" {
  gen="$(wave_of "$D/kustomization.yaml")"
  os="$(wave_of "$D/object-store.yaml")"
  # 같은 wave는 허용된다 — ArgoCD는 같은 wave 안에서 Secret을 CRD 인스턴스보다 먼저 적용한다.
  [ "$gen" -le "$os" ] || { echo "generator wave=$gen · ObjectStore wave=$os — 자격 Secret이 더 늦으면 안 된다"; false; }
}

@test "the ObjectStore actually declares a wave (an absent one silently means 0)" {
  # 값이 없으면 기본 0이라 Cluster(-1)보다 뒤가 된다 — 그 침묵이 이 사고의 원인이었다.
  run grep -qE '^ *argocd\.argoproj\.io/sync-wave:' "$D/object-store.yaml"
  [ "$status" -eq 0 ]
}
