#!/usr/bin/env bats
# AppProject 권한경계 + appset 거버넌스 정적 가드 (gate, CI-safe: yq/grep만)

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  P="$ROOT/platform/argocd/root/projects.yaml"
  APPSET="$ROOT/platform/argocd/root/appset.yaml"
  HOMELAB="https://github.com/ukyi-app/homelab.git"
}

# --- AppProject 존재 + 종류 ---
@test "projects.yaml defines apps and platform AppProjects" {
  run yq 'select(.kind=="AppProject") | .metadata.name' "$P"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx "apps"
  echo "$output" | grep -qx "platform"
}

@test "AppProjects sync strictly before every non-default project consumer (Pass3 #1)" {
  cd "$ROOT"
  # AppProjects의 (가장 늦은) wave
  # yq는 멀티독(2 AppProject) 출력 사이에 '---' 구분자를 넣으므로 숫자 줄만 추려 sort(플랜 버그 수정)
  projwave="$(yq 'select(.kind=="AppProject") | .metadata.annotations."argocd.argoproj.io/sync-wave"' "$P" | grep -E '^-?[0-9]+$' | sort -n | tail -1)"
  # non-default consumer 최소 wave: appset 생성앱은 템플릿에 sync-wave 없어 wave 0,
  # 수동 root/apps 앱(project!=default)은 자기 sync-wave(없으면 0).
  minwave=0
  for f in platform/argocd/root/apps/*.yaml; do
    [ "$(yq '.spec.project' "$f")" != "default" ] || continue
    w="$(yq '.metadata.annotations."argocd.argoproj.io/sync-wave" // "0"' "$f")"
    [ "$w" -lt "$minwave" ] && minwave="$w"
  done
  # AppProjects가 최소 consumer보다 strictly 먼저(더 작은 wave)여야 fresh/DR에서 project 선존재 보장
  [ "$projwave" -lt "$minwave" ]
}

# --- apps 프로젝트: 엄격 (멀티레포 위협 표면) ---
@test "apps project locks sourceRepos to the homelab repo only" {
  run yq 'select(.metadata.name=="apps") | .spec.sourceRepos | length' "$P"
  [ "$output" = "1" ]
  run yq 'select(.metadata.name=="apps") | .spec.sourceRepos[0]' "$P"
  [ "$output" = "$HOMELAB" ]
}

@test "apps project restricts destinations to in-cluster prod only" {
  run yq 'select(.metadata.name=="apps") | .spec.destinations | length' "$P"
  [ "$output" = "1" ]
  run yq 'select(.metadata.name=="apps") | .spec.destinations[0].namespace' "$P"
  [ "$output" = "prod" ]
  run yq 'select(.metadata.name=="apps") | .spec.destinations[0].server' "$P"
  [ "$output" = "https://kubernetes.default.svc" ]
}

@test "apps project forbids all cluster-scoped resources" {
  # clusterResourceWhitelist 비움 = cluster-scoped 전면 금지
  run yq 'select(.metadata.name=="apps") | .spec.clusterResourceWhitelist | length' "$P"
  [ "$output" = "0" ]
}

@test "apps project namespaceResourceWhitelist covers exactly the shared-chart kinds" {
  # 공유 차트(deployment/service/configmap/httproute/migrate-job) + source#3 SealedSecret
  run yq 'select(.metadata.name=="apps") | .spec.namespaceResourceWhitelist[] | .group + "/" + .kind' "$P"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx "apps/Deployment"
  echo "$output" | grep -qx "/Service"
  echo "$output" | grep -qx "/ConfigMap"
  echo "$output" | grep -qx "batch/Job"
  echo "$output" | grep -qx "gateway.networking.k8s.io/HTTPRoute"
  echo "$output" | grep -qx "bitnami.com/SealedSecret"
}

# --- platform 프로젝트: 스코프 (소유자 PR 경로, 동작보존) ---
@test "platform project sourceRepos cover homelab + jetstack + cnpg helm repos" {
  run yq 'select(.metadata.name=="platform") | .spec.sourceRepos[]' "$P"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx "$HOMELAB"
  echo "$output" | grep -qx "https://charts.jetstack.io"
  echo "$output" | grep -qx "https://cloudnative-pg.io/charts"
}

@test "platform project allows cluster-scoped resources (CRD/ClusterRole/Namespace)" {
  run yq 'select(.metadata.name=="platform") | .spec.clusterResourceWhitelist[0].kind' "$P"
  [ "$output" = "*" ]
}
