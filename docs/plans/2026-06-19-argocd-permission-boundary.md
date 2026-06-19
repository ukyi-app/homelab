# ArgoCD 컨트롤플레인 권한경계 + 라이프사이클 정합성 — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** ArgoCD 멀티레포 플랫폼에 AppProject 권한경계(apps 엄격 / platform 스코프)를 도입하고, ApplicationSet의 라이프사이클 정합성 갭(finalizer 부재·exclude 무가드·namespaces wave 비대칭)을 동작 비파괴로 닫는다.

**Architecture:** 3개 순차 머지로 진행하며 각 머지 후 라이브 ArgoCD가 전부 Synced/Healthy임을 게이트로 확인한다. 머지1=AppProject 2개+프로젝트 재배정, 머지2=namespaces wave 승격(exclude+adopt, finalizer 없음), 머지3=appset finalizer+가드 4종. finalizer-vs-namespaces cascade 레이스 때문에 단일 PR로 합칠 수 없다.

**Tech Stack:** ArgoCD Application/ApplicationSet/AppProject, kustomize, bats(gate), yq.

**설계 SSOT:** `docs/plans/2026-06-19-argocd-permission-boundary-design.md` (Phase A.5 codex 설계리뷰 3건 반영 완료).

---

## 실행 모델 (필독 — 안전 핵심)

> ⛔ **3개 배치는 반드시 별도 PR로, 각 머지+라이브 게이트 통과 후에만 다음 배치.** finalizer-vs-namespaces
> cascade 레이스(머지2의 namespace exclude + 머지3의 appset finalizer가 **한 sync에 함께** 적용되면 전
> 네임스페이스+워크로드 cascade 삭제) 때문에 **한 PR/한 브랜치에 여러 배치를 담는 것은 금지**다(plan 리뷰 Pass4 #1).

- **배치별 브랜치/PR (single-PR 금지)**:
  - **배치1**: 현재 워크트리 브랜치 `worktree-feat+argocd-permission-boundary`에 배치1만 커밋 → PR → 머지 → 라이브 게이트.
  - **배치2**: 배치1이 **main에 머지되고 라이브 게이트 통과한 뒤**, 갱신된 `main`에서 **새 브랜치/워크트리**로 시작 → 배치2만 커밋 → PR → 머지 → 라이브 게이트.
  - **배치3**: 배치2 머지+라이브 게이트 통과 뒤, 갱신된 `main`에서 **새 브랜치/워크트리** → 배치3만 → PR → 머지 → 라이브 게이트.
- **⛔ STOP 조건 (continuous-run 오버라이드)**: executing-plans는 각 배치의 마지막 `Commit`+PR 생성 후
  **반드시 중단**하고 owner에게 인계한다. 다음 배치는 **이전 배치가 main 머지 + 라이브 ArgoCD 게이트 통과를
  owner가 확인한 뒤** 별도 실행으로 시작한다. **한 실행이 2개 이상 배치를 연속 구현·커밋하면 안 된다**(single-PR
  cascade 위험). 즉 본 plan은 3회의 분리된 executing-plans 실행으로 수행된다.
- **gate 재현**: 정적 검증은 `bash scripts/run-bats.sh`(전체) 또는 영향 파일만 `bats <file>`. 신규 bats는 전부 CI-safe(yq/grep/plain kustomize)라 gate가 수집한다.
- **bats 규약**: `@test` 이름은 **영어**(한글 이름은 침묵 스킵). 주석은 한국어. bash 3.2 호환(중간 단언은 단순 명령으로).
- **AppProject 검증**: AppProject는 `kustomize build`가 아니라 root app `directory.recurse:true`로 동기화된다. 정적 검증은 yq로 파일을 읽는다.

---

## 배치 1 — 머지1: AppProject 2개 + 프로젝트 재배정

### Task 1: `apps`·`platform` AppProject 매니페스트 생성

**Files:**
- Create: `platform/argocd/root/projects.yaml`
- Create: `platform/argocd/root/test_projects.bats`

**Step 1: 실패하는 테스트 작성** — `platform/argocd/root/test_projects.bats`

```bash
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
  projwave="$(yq 'select(.kind=="AppProject") | .metadata.annotations."argocd.argoproj.io/sync-wave"' "$P" | sort -n | tail -1)"
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
```

**Step 2: 실패 확인**

Run: `bats platform/argocd/root/test_projects.bats`
Expected: FAIL (projects.yaml 부재 → yq가 파일 없음으로 실패).

**Step 3: 최소 구현** — `platform/argocd/root/projects.yaml`

```yaml
# ArgoCD AppProject 권한경계 (테마1 / plan 1) — root app(directory.recurse)이 동기화.
# wave -10: 모든 non-default 참조 컴포넌트(최이른 namespaces -9·sealed-secrets -8)보다 strictly 먼저 생성
# — fresh/DR 일괄 sync에서 project가 Application 검증 전 존재 보장(plan 리뷰 Pass3 #1). argocd self-manage(-10)
# 가 AppProject CRD를 설치하고 root(-9 app)가 그 뒤 sync하므로 CRD는 이미 존재.
# apps = 멀티레포 자동발견 위협 표면(엄격). platform = 소유자 PR 경로(스코프, 동작보존).
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: apps
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "-10"
spec:
  description: 멀티레포 자동발견 앱 (apps ApplicationSet) — 엄격 경계
  sourceRepos:
    - https://github.com/ukyi-app/homelab.git
  destinations:
    - server: https://kubernetes.default.svc
      namespace: prod
  clusterResourceWhitelist: [] # cluster-scoped 전면 금지 (앱은 namespaced만)
  namespaceResourceWhitelist:
    - { group: apps, kind: Deployment }
    - { group: "", kind: Service }
    - { group: "", kind: ConfigMap }
    - { group: batch, kind: Job }
    - { group: gateway.networking.k8s.io, kind: HTTPRoute }
    - { group: bitnami.com, kind: SealedSecret }
---
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: platform
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "-10"
spec:
  description: 플랫폼 컴포넌트 (소유자 PR 경로) — server+repo+namespace 스코프
  sourceRepos:
    - https://github.com/ukyi-app/homelab.git
    - https://charts.jetstack.io
    - https://cloudnative-pg.io/charts
  # destinations='*' (설계 §A / plan 리뷰 Pass2 #1): appset 생성 platform 앱은 Application
  # destination.namespace가 **비어있고** ArgoCD가 매니페스트 검사 전에 그 빈 destination을 검증한다 →
  # named-only면 InvalidSpec(동작파괴). '*'로 빈 destination 허용. platform 경계=server+repo,
  # tight namespace 경계는 apps 프로젝트(ns=prod). Task 3 가드가 '빈 destination permitted'를 강제.
  destinations:
    - { server: https://kubernetes.default.svc, namespace: "*" }
  clusterResourceWhitelist:
    - { group: "*", kind: "*" } # CRD/ClusterRole/GatewayClass/Namespace 정당 — 좁히면 동작파괴
  namespaceResourceWhitelist:
    - { group: "*", kind: "*" }
```

**Step 4: 통과 확인**

Run: `bats platform/argocd/root/test_projects.bats`
Expected: PASS (8 tests).

**Step 5: Commit**

```bash
git add platform/argocd/root/projects.yaml platform/argocd/root/test_projects.bats
git commit -m "feat: ArgoCD AppProject 2개(apps 엄격·platform 스코프) 도입"
```

---

### Task 2: 매니페스트의 프로젝트 재배정 (default → platform/apps)

**Files:**
- Modify: `platform/argocd/root/apps/cert-manager.yaml` (`.spec.project`)
- Modify: `platform/argocd/root/apps/cnpg-operator.yaml`
- Modify: `platform/argocd/root/apps/cnpg-barman-plugin.yaml`
- Modify: `platform/argocd/root/apps/cnpg-data.yaml`
- Modify: `platform/argocd/root/apps/sealed-secrets.yaml`
- Modify: `platform/argocd/root/apps/victoria-stack.yaml`
- Modify: `platform/argocd/root/apps/argocd-extras.yaml`
- Modify: `platform/argocd/root/appset.yaml` (두 템플릿 `spec.project`)
- Test: `platform/argocd/root/test_projects.bats` (default-lockdown 단언 추가)

**Step 1: default-lockdown 테스트 추가** — `test_projects.bats`에 append

```bash
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
```

**Step 2: 실패 확인**

Run: `bats platform/argocd/root/test_projects.bats -f "default project|non-default projects"`
Expected: FAIL (현재 전부 default).

**Step 3: 재배정 적용**

수동 앱 7개 — 각 파일의 `  project: default` → `  project: platform`:

```bash
cd "$(git rev-parse --show-toplevel)"
for f in cert-manager cnpg-operator cnpg-barman-plugin cnpg-data sealed-secrets victoria-stack argocd-extras; do
  yq -i '.spec.project = "platform"' "platform/argocd/root/apps/$f.yaml"
done
```

appset.yaml 두 템플릿 (수동 편집 — line 33 platform-components, line 66 apps):
- platform-components 템플릿(`metadata.name: platform-components`) `spec.template.spec.project: default` → `platform`
- apps 템플릿(`metadata.name: apps`) `spec.template.spec.project: default` → `apps`

**Step 4: 통과 확인**

Run: `bats platform/argocd/root/test_projects.bats`
Expected: PASS (10 tests).
Run: `bats platform/argocd/root/test_root_app.bats`
Expected: PASS (root·argocd는 default 유지라 기존 단언 무변경).

**Step 5: Commit**

```bash
git add platform/argocd/root/apps/*.yaml platform/argocd/root/appset.yaml platform/argocd/root/test_projects.bats
git commit -m "feat: 플랫폼 Application·appset을 platform/apps AppProject로 재배정 (argocd·root는 default 유지)"
```

---

### Task 3: platform 가드 (destination permitted + repoURL ⊆ sourceRepos)

**Files:**
- Test: `platform/argocd/root/test_projects.bats` (가드 2종 append)

**Step 1: 가드 테스트 추가** — `test_projects.bats`에 append

```bash
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
  while IFS= read -r s; do [ "$s" = "https://kubernetes.default.svc" ]; done <<< "$output"
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
```

**Step 2: 실패→통과 확인**

Run: `bats platform/argocd/root/test_projects.bats`
Expected: PASS — destinations='*'라 빈 destination 포함 전 Application이 permitted, 전 platform repoURL이
sourceRepos에 포함되어 즉시 green. (FAIL이면 projects.yaml sourceRepos에 누락 repo 추가, 또는 destinations가
'*'를 잃었는지 확인 — 후자는 InvalidSpec 회귀를 잡은 것.)

**Step 3: 영향 게이트 확인**

Run: `bash scripts/run-bats.sh --list | grep argocd`
Expected: `platform/argocd/root/test_projects.bats`가 목록에 포함(gate 수집 확인).

**Step 4: Commit**

```bash
git add platform/argocd/root/test_projects.bats
git commit -m "test: platform AppProject 가드 — destination permitted + repoURL ⊆ sourceRepos (동작보존)"
```

---

### 머지1 라이브 게이트 (owner, 머지 후)

```
export KUBECONFIG=$PWD/infra/k3s-bootstrap/kubeconfig   # (main 체크아웃 경로)
kubectl get appproject -n argocd            # apps, platform 존재
kubectl get applications -A                 # 전부 Synced/Healthy (project 재배정 후 OutOfSync 0)
kubectl get application -n argocd cnpg-data -o jsonpath='{.spec.project}'  # => platform
```
전부 Healthy 확인 후에만 머지2 진행. (롤백=projects.yaml 제거 + project default 복원 — **머지2 적용 전에만**
단독 유효. 머지2/3 이후엔 역순 복합 롤백, "동작 비파괴 요약" 참조.)

> ⛔ **STOP — 배치1 종료**. PR 생성→머지→라이브 게이트 통과를 owner가 확인하기 전엔 배치2를 구현하지 않는다.
> 배치2는 갱신된 main에서 새 브랜치/워크트리로 별도 실행한다.

---

## 배치 2 — 머지2: namespaces wave 승격 (exclude + adopt, finalizer 없음)

> ⚠️ **순서 불변식**: 이 머지는 **appset에 finalizer가 아직 없는 상태**(머지3 이전)에서만 안전하다.
> appset이 namespaces-prod 생성을 멈출 때 finalizer가 있으면 전 네임스페이스를 cascade 삭제한다.
> 머지1이 라이브 Healthy인 뒤, 머지3 **이전**에 수행.

> ⛔ **배치2 PRE-MERGE preflight (owner, 머지 전 필수 — plan 리뷰 Pass5 #2)**: 라이브 namespaces-prod
> Application에 resources-finalizer가 **없음**을 확인한 뒤에만 배치2 PR을 머지한다. 드리프트/이전 실패/수동
> patch로 finalizer가 붙어있으면 exclude가 적용되는 순간 전 네임스페이스를 cascade 삭제한다. post-merge
> 게이트는 너무 늦다 — 반드시 **머지 전**에:
> ```bash
> kubectl -n argocd get application namespaces-prod -o jsonpath='{.metadata.finalizers}'; echo
> # 기대: 빈 출력(또는 [] ). resources-finalizer.argocd.argoproj.io 가 보이면 ⛔ 머지 중단.
> ```
> finalizer가 있으면 복구: ① `kubectl -n argocd get application namespaces-prod -o jsonpath='{.status.operationState.phase}'`
> 로 삭제/Terminating이 **진행 중이 아님**을 확인 → ② `kubectl -n argocd patch application namespaces-prod
> --type merge -p '{"metadata":{"finalizers":null}}'`로 finalizer 제거 → ③ preflight 재확인(빈 출력) 후 머지.

### Task 4: namespaces를 appset에서 빼고 수동 Application으로 adopt

**Files:**
- Modify: `platform/argocd/root/appset.yaml` (platform-components generator에 exclude 추가)
- Create: `platform/argocd/root/apps/namespaces.yaml`
- Modify: `platform/namespaces/prod/namespaces.yaml` (6 Namespace에 Prune=false 어노테이션)
- Test: `platform/argocd/root/test_projects.bats` (namespaces 마이그레이션 + Prune=false 단언 append)

**Step 1: 테스트 추가** — `test_projects.bats`에 append

```bash
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
  total="$(echo "$out" | yq 'select(.kind=="Namespace") | .metadata.name' | grep -c .)"
  pf="$(echo "$out" | yq 'select(.kind=="Namespace") | .metadata.annotations."argocd.argoproj.io/sync-options" // ""' | grep -c 'Prune=false')"
  [ "$total" -gt 0 ]
  [ "$total" = "$pf" ]
}
```

**Step 2: 실패 확인**

Run: `bats platform/argocd/root/test_projects.bats -f "namespaces"`
Expected: FAIL (exclude 미존재 + namespaces.yaml 부재).

**Step 3-a: appset에 exclude 추가** — `platform/argocd/root/appset.yaml` platform-components generator의 directories 리스트(line 23-27 블록)에 한 줄 추가:

```yaml
          - { path: platform/sealed-secrets/*, exclude: true }
          - { path: platform/namespaces/*, exclude: true } # 수동 Application으로 wave 제어(root/apps/namespaces.yaml)
```

**Step 3-b: 수동 namespaces Application 생성** — `platform/argocd/root/apps/namespaces.yaml`

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: namespaces
  namespace: argocd
  annotations:
    # sealed-secrets(-8)·traefik(-8)보다 먼저 — bare ns + PSA 라벨 윈도우 제거
    argocd.argoproj.io/sync-wave: "-9"
  # ⚠️ resources-finalizer 없음 (설계리뷰 #1): Namespace는 cascade 삭제 금지.
  # 삭제/롤백 시 non-cascading → 네임스페이스 orphan-retain(안전). 다른 수동앱과 다른 의도적 예외.
spec:
  project: platform
  source:
    repoURL: https://github.com/ukyi-app/homelab.git
    targetRevision: main
    path: platform/namespaces/prod
  destination:
    server: https://kubernetes.default.svc
    # destination.namespace 없음 — Namespace는 cluster-scoped (appset namespaces-prod와 동일 렌더)
  syncPolicy:
    automated: { prune: true, selfHeal: true }
    syncOptions:
      - CreateNamespace=true # moot(ns 없음)이나 appset namespaces-prod와 동일 옵션 유지
      - ServerSideApply=true
```

**Step 3-c: 각 Namespace를 non-prunable로 표시** — `platform/namespaces/prod/namespaces.yaml`의 **6개 Namespace
모두**(gateway·edge·prod·sealed-secrets·cache·homepage)의 `metadata`에 sync-option 어노테이션을 추가한다
(기존 `labels`는 유지). 예(prod):

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: prod
  annotations:
    argocd.argoproj.io/sync-options: Prune=false # plan 리뷰 Pass5 #1: 매니페스트서 빠져도 ns prune(삭제) 금지
  labels:
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/warn: restricted
    pod-security.kubernetes.io/audit: restricted
```

(의도적 Namespace 삭제는 ArgoCD prune이 아니라 **owner-local 수동 경로**로만: 매니페스트 제거 후
`kubectl delete ns <name>` 명시 실행. Prune=false라 자동 삭제가 막힌 것이 안전장치다.)

**Step 4: 통과 + 렌더 패리티 확인**

Run: `bats platform/argocd/root/test_projects.bats`
Expected: PASS (전체, Prune=false 가드 포함).
Run: `kustomize build platform/namespaces/prod | yq 'select(.kind=="Namespace") | .metadata.name' | sort`
Expected: `cache edge gateway homepage prod sealed-secrets` — Namespace **이름·PSA 라벨은 무변경**, 추가된 것은
Prune=false 어노테이션뿐(adopt 시 SSA가 라이브 ns에 어노테이션만 머지 — 무중단). 즉 appset namespaces-prod
대비 유일 diff = 의도된 Prune=false 어노테이션.
Run: `bats platform/namespaces/prod/test_psa.bats platform/argocd/root/test_root_app.bats`
Expected: PASS (PSA 라벨·root/argocd 무변경 — 어노테이션만 추가).

**Step 5: Commit**

```bash
git add platform/argocd/root/appset.yaml platform/argocd/root/apps/namespaces.yaml platform/namespaces/prod/namespaces.yaml platform/argocd/root/test_projects.bats
git commit -m "feat: namespaces를 wave -9 수동 Application으로 승격 (PSA 라벨 윈도우 제거, finalizer 없음, Namespace Prune=false)"
```

### 머지2 라이브 게이트 (owner, 머지 후)

```
kubectl get application -n argocd namespaces -o jsonpath='{.status.sync.status}{" "}{.status.health.status}'
  # => Synced Healthy (수동 app이 네임스페이스 adopt)
kubectl get application -n argocd namespaces-prod 2>&1 | grep -q NotFound && echo "appset이 namespaces-prod 제거(non-cascading)"
kubectl get ns gateway edge prod sealed-secrets cache homepage   # 전부 Active(무중단)
kubectl get applications -A   # 전부 Synced/Healthy
```
namespaces가 무중단 유지 + 수동 app이 소유 확인 후에만 머지3. (롤백=수동 app 제거 + exclude 제거,
finalizer 없어 non-cascading.)

> ⛔ **STOP — 배치2 종료**. PR→머지→라이브 게이트 통과 확인 전엔 배치3을 구현하지 않는다(이 순서가
> finalizer-vs-namespaces cascade를 막는 핵심 — 배치3의 appset finalizer는 namespaces가 appset 밖에
> 안착한 뒤에만 적용돼야 한다). 배치3은 갱신된 main에서 새 브랜치/워크트리로 별도 실행한다.

---

## 배치 3 — 머지3: appset finalizer + 가드 4종

> ⚠️ 머지2가 라이브 Healthy(namespaces가 appset 밖)인 뒤에만. 그래야 finalizer 추가가 namespaces에
> cascade를 일으키지 않는다.

### Task 5: 두 appset 템플릿에 resources-finalizer 추가

**Files:**
- Modify: `platform/argocd/root/appset.yaml` (두 template.metadata)
- Test: `platform/argocd/root/test_projects.bats` (finalizer 단언 append)

**Step 1: 테스트 추가** — `test_projects.bats`에 append

```bash
# --- appset finalizer (설계 §D, teardown cascade prune) ---
@test "both ApplicationSet templates carry resources-finalizer" {
  run yq '.spec.template.metadata.finalizers[]' "$APPSET"
  [ "$status" -eq 0 ]
  # platform-components + apps 두 템플릿 모두
  n="$(yq '[.spec.template.metadata.finalizers[] | select(. == "resources-finalizer.argocd.argoproj.io")] | length' "$APPSET" | paste -sd+ - | bc)"
  [ "$n" -eq 2 ]
}
```

**Step 2: 실패 확인**

Run: `bats platform/argocd/root/test_projects.bats -f "resources-finalizer"`
Expected: FAIL (템플릿에 finalizers 없음).

**Step 3: 두 템플릿에 finalizer 추가** — `appset.yaml` 각 `template.metadata`(platform-components line 28-31, apps line 62-64)에 `finalizers` 추가:

```yaml
    metadata:
      name: '{{ index .path.segments 1 }}-{{ .path.basename }}'
      labels: { homelab.env: '{{ .path.basename }}' }
      finalizers:
        - resources-finalizer.argocd.argoproj.io # teardown 시 워크로드 cascade prune (고아화 방지)
```

**Step 4: 통과 확인**

Run: `bats platform/argocd/root/test_projects.bats`
Expected: PASS (전체).

**Step 5: Commit**

```bash
git add platform/argocd/root/appset.yaml platform/argocd/root/test_projects.bats
git commit -m "feat: 두 ApplicationSet 템플릿에 resources-finalizer 추가 (teardown cascade prune)"
```

---

### Task 6: 거버넌스 가드 3종 (exclude⊇root/apps · Namespace-소유앱 no-finalizer · traps 원장)

**Files:**
- Test: `platform/argocd/root/test_projects.bats` (가드 append)
- Modify: `docs/traps.md` (원장 한 줄)

**Step 1: 거버넌스 가드 3종 추가**(exclude⊇root/apps · root/apps Namespace 소유앱 no-finalizer ·
appset-생성 Namespace 소유 금지) — `test_projects.bats`에 append

```bash
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
NS_FINALIZER_ALLOW="cnpg-data" # 의도적 예외(database ns 라이프사이클 결합) — 추가 시 근거 주석 필수
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
```

**Step 2: 실패→통과 확인**

Run: `bats platform/argocd/root/test_projects.bats -f "excluded from|carry no resources-finalizer|owns a Namespace"`
Expected: PASS — exclude는 머지2에서 namespaces 추가됨(나머지는 기존), namespaces app은 finalizer 없음.
cnpg-data는 정적 탐지로 Namespace 소유 확인되나 allowlist 예외 → 통과. appset-생성 컴포넌트는 현재 Namespace
소유 0(namespaces·cnpg는 exclude)이라 통과. 신규 Namespace 소유자(수동·appset 양쪽)는 강제.

**Step 3: traps.md 원장에 한 줄 추가** — `docs/traps.md`의 표 마지막 행 뒤에:

```markdown
| ArgoCD AppProject 권한경계 + appset finalizer/exclude/default-lockdown 거버넌스 | gate | `platform/argocd/root/test_projects.bats` |
```

**Step 4: traps 가드 통과 확인**

Run: `make verify-traps`
Expected: PASS (백틱 경로 `platform/argocd/root/test_projects.bats` 실재).
Run: `bash scripts/run-bats.sh --list | grep -c test_projects.bats`
Expected: `1` (gate 수집).

**Step 5: Commit**

```bash
git add platform/argocd/root/test_projects.bats docs/traps.md
git commit -m "test: appset 거버넌스 가드(exclude⊇root/apps·Namespace 소유앱 no-finalizer·appset Namespace 금지) + traps 원장"
```

### 머지3 라이브 게이트 (owner, 머지 후)

```
kubectl get applicationset -n argocd platform-components apps -o jsonpath='{range .items[*]}{.metadata.name}{": "}{.spec.template.metadata.finalizers}{"\n"}{end}'
  # => 두 appset 템플릿에 resources-finalizer
kubectl get applications -A   # 전부 Synced/Healthy
kubectl get ns prod gateway edge   # 여전히 Active (finalizer 추가가 namespaces에 무영향 — 이미 appset 밖)
```

> ✅ **배치3 종료 = plan 완료**. 3개 배치가 각각 별도 PR로 머지되고 라이브 게이트를 통과하면 테마1 plan1 완료.

---

## 전체 검증 (3 머지 후, 최종)

```bash
bash scripts/run-bats.sh                    # 전체 gate green (신규 test_projects.bats 포함)
make verify-traps                           # 원장 일관
```

라이브: `kubectl get applications -A`(전부 Synced/Healthy) + `kubectl get appproject -n argocd`(apps·platform) +
멀티레포 위협 표면(apps appset)이 `apps` 프로젝트 경계 안에 묶였는지 확인.

## 동작 비파괴 요약

- 전부 가산(AppProject·finalizer·가드) → 라이브 워크로드 매니페스트 무변경.
- **롤백은 역순으로**(plan 리뷰 Pass3 #2): 머지는 의존 체인이라 독립 단일-revert가 아니다 —
  머지2가 namespaces app(project=platform)을 추가한 뒤 머지1만 revert하면 platform AppProject가 사라져
  namespaces app(및 재배정된 전 앱)이 깨진 project 참조(InvalidSpec)가 된다.
  - 머지3 적용 후 롤백: 머지3 revert → (필요시) 머지2 revert → (필요시) 머지1 revert 순.
  - 머지1 단독 revert는 **머지2 적용 전에만** 안전. 이후 상태에선 역순 복합 롤백을 쓴다.
- 최대 위험점=머지2 namespaces adopt(렌더 패리티 게이트로 사전 차단).
- finalizer-vs-namespaces cascade 레이스는 머지2(finalizer 전)→머지3(finalizer) 순서 불변식으로 차단.

## 범위 밖 (후속 plan)

테마1 항목5(데이터 per-app appset 전환)·항목6(targetRevision 롤백SSOT) + 테마2~8. 설계 §범위 밖 참조.

## Adversarial review dispositions

codex 적대적 plan 리뷰 **5패스**(3패스 cap + 사용자 승인 2회 추가) — 총 **12 발견 전부 Accept·반영**.
발견은 매 패스 새것(반복 0)이고, 핵심 위험(namespace-삭제 blast radius)을 passes 3-5가 다각도로 폐쇄.
(설계 리뷰 Phase A.5 3건은 설계 문서에 별도 기록.)

- **Pass1** (needs-attention, 3건, **전부 Accept**): default-lockdown 전수 스캔화 · destination 가드
  렌더기준화 · no-finalizer 정적탐지+allowlist (가드 false-green 제거).
- **Pass2** (needs-attention, 2건): platform named-only destinations가 빈 Application destination을
  InvalidSpec → `destinations='*'`(server+repo 경계) **Accept**(설계 §A 변경, 사용자 승인) · tailscale
  multi-ns → 파생 ns 가드 제거로 **자동 해소**.
- **Pass3** (needs-attention, 3건, **전부 Accept**): AppProjects wave -10(strict 선행)+순서 테스트 ·
  롤백 역순화 · no-finalizer 가드 appset 경로 확장.
- **Pass4** (needs-attention, 2건, **전부 Accept**): 순차 머지 operationalize(배치별 PR+STOP,
  continuous-run 오버라이드) · destination 가드 server+namespace화 + server 단언.
- **Pass5** (needs-attention, 2건, **전부 Accept**): Namespace `Prune=false`(prune 삭제벡터 폐쇄)+가드 ·
  배치2 pre-merge preflight(라이브 finalizer 부재 확인).

**최종 패스(Pass5) verdict** = `needs-attention`, summary "still leaves a Namespace deletion path open and
relies on an unverified live invariant at the riskiest migration step" — 그 2건을 **본 plan에 반영 완료**한
뒤, 사용자가 cap(3패스)을 2 초과해 finalize 승인(**미해결 high/critical 0건** — 12건 전부 Accept·적용).
6패스 미실행은 사용자 결정. namespace-삭제 표면은 3벡터(Application 삭제 no-finalizer · 리소스 prune
Prune=false · 마이그레이션 드리프트 preflight)로 체계적 폐쇄.

## Execution directives

- **Skill:** `executing-plans`로 구현 — **별도 세션, 워크트리에서**.
- **실행 — 배치 경계 STOP, 완전 continuous 아님 (이 plan의 안전 핵심)**: 한 배치 **안에서는** 연속
  실행하되, **각 배치의 마지막 `Commit`+PR 생성 후 반드시 STOP**하고 owner에게 인계한다. 다음 배치는
  이전 배치가 **main 머지 + 라이브 ArgoCD 게이트 통과**를 owner가 확인한 뒤 **별도 executing-plans 실행**으로
  시작한다. **한 실행이 2개 이상 배치를 구현·커밋하면 안 된다**(single-PR cascade 위험 — "실행 모델"·Pass4 #1).
  그 외엔 executing-plans의 'When to Stop and Ask'(의존성 누락·반복 실패·모순·critical gap)도 적용.
- **배치2 PRE-MERGE preflight 필수**: 머지 전 라이브 namespaces-prod에 resources-finalizer 부재 확인
  (배치2 preflight 블록). 있으면 중단+복구 후 머지.
- **Commits — 규칙을 직접 적용, `Skill(commit)` 호출 금지**(인터랙티브라 흐름 깨짐):
  - 한국어, AI 마커 금지(`🤖`·`Co-Authored-By` 등 절대 금지).
  - 형식 `<type>(<scope>): 한국어 설명`. **type ∈ {feat, fix, refactor, docs, style, test, chore}만**
    (perf/build/ci 등 금지).
  - 그룹핑: 각 Task의 `Commit` 스텝 `git add` 목록 그대로(같은 목적·같은 디렉토리 묶음).
  - 위치: 각 plan `Commit` 스텝에서, 현재 배치의 feature-branch 워크트리에 직접 커밋(이미 main 밖).
