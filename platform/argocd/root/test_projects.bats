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
  # yq는 멀티독(2 AppProject) 출력 사이에 '---' 구분자를 넣으므로 숫자 줄만 추려 sort
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
  # 공유 차트(deployment/service/configmap/httproute) + source#3 (Job/SealedSecret/NetworkPolicy).
  # Job은 더 이상 차트가 렌더하지 않지만(migrate 폐기), 앱이 source#3로 일회성 Job 배포 가능하도록 화이트리스트 유지.
  run yq 'select(.metadata.name=="apps") | .spec.namespaceResourceWhitelist[] | .group + "/" + .kind' "$P"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx "apps/Deployment"
  echo "$output" | grep -qx "/Service"
  echo "$output" | grep -qx "/ConfigMap"
  echo "$output" | grep -qx "batch/Job"
  echo "$output" | grep -qx "gateway.networking.k8s.io/HTTPRoute"
  echo "$output" | grep -qx "bitnami.com/SealedSecret"
  # 외부 egress 앱이 자체 NetworkPolicy를 source#3로 배포할 수 있어야 함(없으면 첫 외부-egress 앱 sync 거부).
  echo "$output" | grep -qx "networking.k8s.io/NetworkPolicy"
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
    # 구분자는 리터럴 '|' — yq의 "\t" 이스케이프는 버전 따라 탭(v4.52)/리터럴(v4.44 CI)이라 분할이 깨진다(CI green 보장).
    while IFS='|' read -r ds dn; do
      { [ "$ds" = "*" ] || [ "$ds" = "$srv" ]; } || continue
      { [ "$dn" = "*" ] || [ "$dn" = "$ns" ]; } && return 0
    done < <(yq "select(.metadata.name==\"$proj\") | .spec.destinations[] | .server + \"|\" + .namespace" "$P")
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
    # ★매칭 doc을 먼저 단일 YAML로 추출 후 질의 — 멀티독 select+`// ""`은 yq v4.44(CI)서 비매칭 doc에
    # 빈 줄을 방출하고, 매칭이 2번째 doc(apps)이면 그 앞 빈 줄이 $()에 잔존해 srv를 오염시킨다(v4.52 로컬은 무방출).
    d="$(yq "select(.metadata.name==\"$an\")" "$APPSET")"
    proj="$(echo "$d" | yq '.spec.template.spec.project')"
    srv="$(echo "$d" | yq '.spec.template.spec.destination.server // ""')"
    ns="$(echo "$d" | yq '.spec.template.spec.destination.namespace // ""')"
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

# --- namespaces wave 승격 (설계 §C) ---
@test "platform appset excludes namespaces (no double-ownership with manual app)" {
  run grep -E "path: platform/namespaces/\*, exclude: true" "$APPSET"
  [ "$status" -eq 0 ]
}

@test "manual namespaces Application: platform project, wave -9, adopts the same path" {
  N="$ROOT/platform/argocd/root/apps/namespaces.yaml"
  run yq '.spec.project' "$N"; [ "$output" = "platform" ]
  run yq '.spec.source.path' "$N"; [ "$output" = "platform/namespaces/prod" ]
  run yq '.metadata.annotations."argocd.argoproj.io/sync-wave"' "$N"; [ "$output" = "-9" ]
}

@test "manual namespaces Application has NO resources-finalizer (cascade-delete forbidden)" {
  # 설계리뷰 #1: namespaces는 cascade 삭제 절대 금지 → finalizer 없으면 삭제 시 orphan-retain(안전)
  N="$ROOT/platform/argocd/root/apps/namespaces.yaml"
  run yq '(.metadata.finalizers // []) | length' "$N"
  [ "$output" = "0" ]
}

@test "every owned Namespace is non-prunable (Prune=false sync-option)" {
  # plan 리뷰 Pass5 #1: finalizer 부재는 Application 삭제만 막는다. prune:true라 namespaces.yaml에서
  # Namespace를 빼면 ArgoCD가 그 ns를 prune(삭제)한다 — 별개 삭제 벡터. 각 Namespace를 Prune=false로 보호.
  out="$(kustomize build "$ROOT/platform/namespaces/prod")"
  # ★yq 멀티독 출력은 결과 사이에 '---' 구분자를 넣으므로 이름 카운트서 제외.
  total="$(echo "$out" | yq 'select(.kind=="Namespace") | .metadata.name' | grep -v '^---$' | grep -c .)"
  pf="$(echo "$out" | yq 'select(.kind=="Namespace") | .metadata.annotations."argocd.argoproj.io/sync-options" // ""' | grep -c 'Prune=false')"
  [ "$total" -gt 0 ]
  [ "$total" = "$pf" ]
}

# --- appset finalizer (설계 §D, teardown cascade prune) ---
@test "both ApplicationSet templates carry resources-finalizer" {
  run yq '.spec.template.metadata.finalizers[]' "$APPSET"
  [ "$status" -eq 0 ]
  # platform-components + apps 두 템플릿 모두 — yq 멀티독 '---' 무관하게 grep -c로 카운트
  n="$(yq '.spec.template.metadata.finalizers[]' "$APPSET" | grep -c 'resources-finalizer.argocd.argoproj.io')"
  [ "$n" -eq 2 ]
}

# --- exclude ⊇ root/apps (이중소유 플립플롭 차단, 설계 §D) ---
@test "every root/apps platform path is excluded from the platform appset" {
  cd "$ROOT"
  miss=""
  for f in platform/argocd/root/apps/*.yaml; do
    # source path(들) 중 platform/<comp>/... 패턴의 comp 추출
    for p in $(yq '[.spec.source.path // (.spec.sources[]?.path)] | flatten | .[]' "$f" 2>/dev/null); do
      case "$p" in
        platform/*/*)
          comp="$(echo "$p" | cut -d/ -f2)"
          grep -qE "path: platform/$comp/\*, exclude: true" platform/argocd/root/appset.yaml \
            || miss="$miss $(yq '.metadata.name' "$f"):$comp"
          ;;
      esac
    done
  done
  [ -z "$miss" ] || { echo "appset exclude 누락(이중소유 위험):$miss"; false; }
}

# --- Namespace-소유 Application은 finalizer 금지 (설계리뷰 #1 + Pass1 #3) ---
# **정적 탐지**(render 불요, KSOPS도 안 스킵): source 디렉토리에 `kind: Namespace` 매니페스트가 있으면
# 그 Application은 Namespace 소유자다. build-실패-skip은 가장 위험한 소유자(cnpg-data 등 KSOPS)를 놓치므로 금지.
# **명시 allowlist**: cnpg-data는 자기 `database` ns를 라이프사이클에 결합 소유 — 의도적 예외다(cnpg-data
# 삭제 = 의도적 DB teardown, R2 백업 보유, 소유자 PR로만 발생). namespaces app은 공유 foundational ns 다수를
# 소유하므로 cascade 절대 금지(finalizer 없음 강제). 신규 Namespace 소유자는 전부 강제 검사.
# 의도적 예외 — 각자 자기 전용 ns를 라이프사이클에 결합 소유(삭제=의도적 teardown, owner PR로만): cnpg-data=database·
# victoria-stack=observability(둘 다 기존 finalizer, 자기 스택만 cascade). 공유 foundational ns 다수를 소유하는
# namespaces app은 finalizer 0(cascade 절대 금지)이라 비-allowlist. 추가 시 '자기 전용 ns' 근거 주석 필수.
NS_FINALIZER_ALLOW="cnpg-data victoria-stack"
@test "Namespace-owning Applications carry no resources-finalizer (allowlist documented)" {
  cd "$ROOT"
  bad=""
  for f in platform/argocd/root/apps/*.yaml; do
    name="$(yq '.metadata.name' "$f")"
    case " $NS_FINALIZER_ALLOW " in *" $name "*) continue;; esac
    owns=0
    for p in $(yq '[.spec.source.path // (.spec.sources[]?.path)] | flatten | .[]' "$f" 2>/dev/null); do
      [ -d "$p" ] || continue
      grep -rqs '^kind: Namespace$' "$p" && owns=1
    done
    [ "$owns" = "1" ] || continue
    fin="$(yq '(.metadata.finalizers // []) | length' "$f")"
    [ "$fin" = "0" ] || bad="$bad $name"
  done
  [ -z "$bad" ] || { echo "Namespace 소유인데 finalizer 보유(cascade 위험):$bad"; false; }
}

# --- appset-생성 컴포넌트의 Namespace 소유 금지 (설계리뷰 Pass3 #3) ---
# Task 5가 두 appset 템플릿에 finalizer를 부여하므로, appset이 발견하는 platform/*/prod(exclude 제외)는
# finalizer를 **상속**한다. 그 경로가 Namespace를 소유하면 cascade 위험 → Namespace 소유 컴포넌트는
# 반드시 exclude(수동 root/apps Application, finalizer 없음)로 관리해야 한다. 정적 grep(CI-safe).
@test "no ApplicationSet-discovered platform component owns a Namespace (would inherit finalizer)" {
  cd "$ROOT"
  bad=""
  for d in platform/*/prod; do
    comp="$(echo "$d" | cut -d/ -f2)"
    case "$comp" in charts) continue;; esac                          # 라이브러리(앱 아님)
    # appset exclude(수동 관리)면 제외 — 그건 위 root/apps 가드가 커버
    grep -qE "path: platform/$comp/\*, exclude: true" platform/argocd/root/appset.yaml && continue
    grep -rqs '^kind: Namespace$' "$d" && bad="$bad $comp"
  done
  [ -z "$bad" ] || { echo "appset-생성 컴포넌트가 Namespace 소유(finalizer 상속 cascade 위험):$bad"; false; }
}
