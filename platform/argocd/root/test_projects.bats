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

# --- default-lockdown (설계리뷰 #3 + Pass1 #1): 전수 스캔 ---
# root app이 platform/argocd/root를 recurse하므로 그 트리 **전체**(새 파일/하위디렉토리 포함) +
# argocd-app(부모)을 스캔. 어디든 default 쓰는 Application·ApplicationSet 템플릿이 끼면 잡는다.
@test "only argocd and root use the default project — exhaustive scan of the recursed tree" {
  cd "$ROOT"
  offenders=""
  files="$(find platform/argocd/root -name '*.yaml') platform/argocd/argocd-app.yaml"
  for f in $files; do
    # Application 문서: "name project" (multi-doc 안전 — yq가 전 문서 순회)
    while read -r name proj; do
      [ -n "$name" ] || continue
      case "$name" in
        argocd|root) [ "$proj" = "default" ] || offenders="$offenders $name:$proj";;
        *) [ "$proj" != "default" ] || offenders="$offenders $name:default";;
      esac
    done < <(yq 'select(.kind=="Application") | .metadata.name + " " + .spec.project' "$f")
    # ApplicationSet 템플릿 project
    while read -r proj; do
      [ -n "$proj" ] || continue
      [ "$proj" != "default" ] || offenders="$offenders appset@$(basename "$f"):default"
    done < <(yq 'select(.kind=="ApplicationSet") | .spec.template.spec.project' "$f")
  done
  [ -z "$offenders" ] || { echo "default escape hatch:$offenders"; false; }
}

@test "both ApplicationSet templates use the new non-default projects" {
  run yq '.spec.template.spec.project' "$APPSET"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx "platform"
  echo "$output" | grep -qx "apps"
}

# --- destination-permitted 가드 (설계 §A / plan 리뷰 Pass2 #1) ---
# ArgoCD는 매니페스트 검사 **전에** 각 Application의 .spec.destination을 그 project의 destinations로
# 검증한다. appset 생성 platform 앱은 destination.namespace가 **비어있으므로**(appset 템플릿은
# destination.server만), project가 빈 destination을 허용(namespace '*')해야 InvalidSpec이 안 난다.
# 미래에 누가 destinations를 named-only로 tightening하면 이 가드가 빈/named destination 미허용을 잡는다.
@test "every Application spec.destination (server AND namespace) is permitted by its AppProject" {
  cd "$ROOT"
  P="platform/argocd/root/projects.yaml"
  # $1=proj $2=server $3=ns → project destinations 중 (server 글롭)&(namespace 글롭) **동시** 매치 시 0.
  # plan 리뷰 Pass4 #2: server도 검사해야 잘못된 클러스터 타깃·server 와일드카드 약화를 잡는다.
  permits() {
    local proj="$1" srv="$2" ns="$3" ds dn
    while IFS="$(printf '\t')" read -r ds dn; do
      { [ "$ds" = "*" ] || [ "$ds" = "$srv" ]; } || continue
      { [ "$dn" = "*" ] || [ "$dn" = "$ns" ]; } && return 0
    done < <(yq "select(.metadata.name==\"$proj\") | .spec.destinations[] | .server + \"\t\" + .namespace" "$P")
    return 1
  }
  miss=""
  # 수동 platform/apps 앱 (재배정된 것만)
  for f in platform/argocd/root/apps/*.yaml; do
    proj="$(yq '.spec.project' "$f")"
    case "$proj" in platform|apps) ;; *) continue;; esac
    srv="$(yq '.spec.destination.server // ""' "$f")"
    ns="$(yq '.spec.destination.namespace // ""' "$f")"
    permits "$proj" "$srv" "$ns" || miss="$miss $(yq '.metadata.name' "$f")@$proj"
  done
  # 두 appset 템플릿 (platform-components=빈 namespace, apps=prod)
  for an in platform-components apps; do
    proj="$(yq "select(.metadata.name==\"$an\") | .spec.template.spec.project" "$APPSET")"
    srv="$(yq "select(.metadata.name==\"$an\") | .spec.template.spec.destination.server // \"\"" "$APPSET")"
    ns="$(yq "select(.metadata.name==\"$an\") | .spec.template.spec.destination.namespace // \"\"" "$APPSET")"
    permits "$proj" "$srv" "$ns" || miss="$miss appset-$an@$proj"
  done
  [ -z "$miss" ] || { echo "destination 미허용(InvalidSpec/잘못된 server 위험):$miss"; false; }
}

@test "apps and platform AppProject destinations target only the in-cluster API server" {
  # plan 리뷰 Pass4 #2: server 경계 — destination server가 정확히 in-cluster여야(‘*’/외부 클러스터 금지).
  run yq 'select(.kind=="AppProject") | .spec.destinations[].server' platform/argocd/root/projects.yaml
  [ "$status" -eq 0 ]
  # yq 멀티독(2 AppProject) 출력의 '---' 구분자 제외 후, 모든 server가 in-cluster여야(외부/‘*’ 0줄)
  bad="$(echo "$output" | grep -vx -- '---' | grep -vx 'https://kubernetes.default.svc' || true)"
  [ -z "$bad" ]
}

@test "every platform component helm repoURL is in the platform project sourceRepos" {
  cd "$ROOT"
  repos="$(yq 'select(.metadata.name=="platform") | .spec.sourceRepos[]' platform/argocd/root/projects.yaml | sort -u)"
  miss=""
  for f in platform/argocd/root/apps/*.yaml; do
    [ "$(yq '.spec.project' "$f")" = "platform" ] || continue
    for u in $(yq '[.spec.source.repoURL // (.spec.sources[]?.repoURL)] | flatten | .[]' "$f"); do
      echo "$repos" | grep -qx "$u" || miss="$miss $u"
    done
  done
  [ -z "$miss" ] || { echo "sourceRepos 누락:$miss"; false; }
}
