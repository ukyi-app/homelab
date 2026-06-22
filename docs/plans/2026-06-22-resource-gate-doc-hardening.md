# 홈랩 자원·게이트·문서 하드닝 Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 2026-06-22 심층 감사에서 확인된 시스템적 갭(메모리 단일축 편향·게이트 false-green·문서 드리프트)을 인-레포 앱 0개 윈도우에서 단일 PR로 수정한다.

**Architecture:** 5개 워크스트림(W1 자원 가드+알림 / W2 AppProject+PSA / W3 공유차트 하드닝 / W4 게이트 false-green / W5 문서·원장)을 한 feature 브랜치(`worktree-feat+resource-hardening`)에 TDD로 쌓고 `make ci`(gate 미러) GREEN 후 단일 PR. ArgoCD가 main을 싱크하므로 라이브 영향 항목은 baseline PSA뿐(나머지 additive/CI-only/문서).

**Tech Stack:** bash 3.2 호환 셸 가드, bats(영어 @test 이름), yq+python3, conftest(rego), JSON Schema(draft-07), VictoriaMetrics vmalert 룰, ArgoCD AppProject/PSA, kustomize.

**전역 규율(매 작업 적용):**
- bats `@test` 이름은 **영어**(한글 침묵스킵 함정). bash3.2 중간단언 침묵통과 주의(`run` + `[ ]` 분리).
- 로컬 GREEN ≠ CI GREEN(yq 버전차 등) → 머지 전 `make ci` + push 후 gate watch.
- 가드 변경은 red(위반 FAIL)→green(정상 통과)→negative-path 순. 시크릿 값/`*.enc.yaml` 평문 출력 금지.
- 라이브 검증은 메인 체크아웃(`/Users/ukyi/workspace/homelab`)에서: `eval "$(make kubeconfig)"`. 워크트리는 KUBECONFIG gitignored라 부재(export 시 sealed-secrets server-dry-run hang).
- 커밋: 한국어 `type(scope): 설명`, AI 마커 금지(AGENTS.md). 작업 단위로 커밋.

---

## W1 — 자원 축 가드 + 노드 압박/eviction 알림

> 발견: critic top-risk #1/#2. 정정 — `values.schema.json:32-33`이 이미 cpu+memory limit을 required+minLength:1로 강제하므로 **앱 경로 CPU는 이미 커버**. 실제 갭은 (a) 플랫폼 매니페스트 가드가 memory만 검사 (b) scan-건수 floor 부재(false-green) (c) 노드 압박/eviction 알림 0건.
>
> **실행 중 결정(사용자 승인)**: 12개 플랫폼 워크로드가 cpu *request*는 있으나 cpu *limit*은 **의도적 생략**(cpu limit=CFS quota라 throttling, SRE 권장 패턴)임을 발견. 가드를 cpu *limit* 강제가 아니라 **`requests.cpu` + `requests.memory` + `limits.memory` 강제**(cpu limit 비요구)로 조정 — starvation은 request 점유율로, OOM은 memory limit으로 막고 throttling 회피. 12개 전부 즉시 통과(현 양호 상태 잠금, 라이브 변경 0).

### Task 1: 자원 가드를 cpu+memory로 확장 + scan floor (가드 rename)

**Files:**
- Rename: `scripts/check-memory-limits.sh` → `scripts/check-resource-limits.sh`
- Rename: `tests/test_memory_limits.bats` → `tests/test_resource_limits.bats`
- Modify: `Makefile`(verify 타겟의 `check-memory-limits.sh` 참조 + help 주석)
- Modify: `policy/memory-limit-allowlist.txt`(헤더 주석만 — cpu 포함 명시. 파일명·키 포맷 `Kind/name/container`는 유지: 한 항목이 cpu·memory 둘 다 면제)

**Step 1: 테스트를 먼저 rename + cpu red-green 케이스 추가 (failing)**

`git mv tests/test_memory_limits.bats tests/test_resource_limits.bats` 후, 파일 내 `check-memory-limits.sh` 참조 5곳(line 6·15·29·39·53)을 `check-resource-limits.sh`로, @test 이름을 "resource limit"으로 치환. 그리고 **cpu 누락 전용 red 케이스**를 추가:

```bash
@test "resource-limit guard fails on a workload missing a CPU limit (memory present)" {
  tmp="$(mktemp -d)"
  mkdir -p "$tmp/scripts" "$tmp/platform/probe/prod" "$tmp/policy"
  cp "${BATS_TEST_DIRNAME}/../scripts/check-resource-limits.sh" "$tmp/scripts/"
  : > "$tmp/policy/memory-limit-allowlist.txt"
  cat > "$tmp/platform/probe/prod/deploy.yaml" <<'YAML'
apiVersion: apps/v1
kind: Deployment
metadata: { name: probe, namespace: probe }
spec:
  template:
    spec:
      containers:
        - name: probe
          image: busybox
          resources: { limits: { memory: 64Mi } }   # cpu limit 없음 — FAIL 기대
YAML
  run bash "$tmp/scripts/check-resource-limits.sh"
  echo "$output"
  rm -rf "$tmp"
  [ "$status" -ne 0 ]
}

@test "resource-limit guard enforces a minimum scan count (selector collapse = fail-loud)" {
  # 매니페스트가 0건이면(셀렉터 붕괴) green이 아니라 fail이어야 한다.
  tmp="$(mktemp -d)"
  mkdir -p "$tmp/scripts" "$tmp/policy" "$tmp/platform"   # platform 비어있음 = 0 매치
  cp "${BATS_TEST_DIRNAME}/../scripts/check-resource-limits.sh" "$tmp/scripts/"
  : > "$tmp/policy/memory-limit-allowlist.txt"
  run bash "$tmp/scripts/check-resource-limits.sh"
  echo "$output"
  rm -rf "$tmp"
  [ "$status" -ne 0 ]
}
```

**Step 2: rename 스크립트 + 실패 확인**

`git mv scripts/check-memory-limits.sh scripts/check-resource-limits.sh`. 아직 로직 미수정 상태로 실행:
Run: `bats tests/test_resource_limits.bats`
Expected: 새 cpu 케이스 FAIL(아직 memory만 검사), scan-floor 케이스 FAIL(0건도 exit 0).

**Step 3: 스크립트 로직 수정 (cpu+memory + scan floor)**

`scripts/check-resource-limits.sh`에서:
- 헤더 주석을 "memory limit 필수" → "memory **와 cpu** limit 필수"로.
- python 컨테이너 루프를 cpu+memory 둘 다 요구로 교체:

```python
for c in spec.get("containers", []) or []:
    limits = (c.get("resources") or {}).get("limits") or {}
    missing = [r for r in ("cpu", "memory") if r not in limits]
    if not missing:
        continue
    key = "%s/%s/%s" % (o.get("kind"), name, c.get("name"))
    if key not in allowed:
        print("%s [missing: %s]" % (key, ",".join(missing)))
```

- scan floor 추가(스크립트 끝, viol 체크 직전 또는 직후 — count는 스캔 매니페스트 파일 수):

```bash
MIN_SCAN=10   # 현재 15. 셀렉터 붕괴(platform 재배치·kind 들여쓰기·grep 회귀)로 0~소수 매치 시 fail-loud.
if [ "$count" -lt "$MIN_SCAN" ]; then
  echo "FAIL: 스캔 대상 ${count}건 < ${MIN_SCAN} — grep 셀렉터 회귀 의심(platform 재배치/kind 들여쓰기?)" >&2
  exit 1
fi
```

- 최종 echo를 `check-resource-limits OK (${count} 워크로드 매니페스트 스캔, cpu+memory limit 위반 0)`로.
- FAIL 메시지의 "memory limit 없는" → "cpu/memory limit 없는".

**Step 4: 테스트 통과 확인**

Run: `bats tests/test_resource_limits.bats`
Expected: PASS(전 케이스). 특히 실제 레포 스캔 케이스(`all resident workload ...`)가 PASS = 기존 15개 플랫폼 매니페스트가 이미 cpu limit 보유(critic 확인) 검증. **만약 FAIL이면** 해당 매니페스트에 cpu limit을 보강(원장 영향 없음 — cpu는 원장 미추적)하거나, 정당한 예외만 allowlist 등재.

**Step 5: 참조 갱신 (Makefile + allowlist 헤더)**

- `Makefile`의 `check-memory-limits.sh` 호출(verify 타겟)을 `check-resource-limits.sh`로.
- `Makefile` verify help 주석(`## 레포 기반 점검 실행 (...)`)에 "자원 limit" 반영(W5 Task 17과 합쳐도 됨).
- `policy/memory-limit-allowlist.txt` 헤더 주석에 "memory **및 cpu** limit 미설정 사유" 명시.
- 잔존 참조 0 확인:
  Run: `! git grep -n 'check-memory-limits' -- ':!docs/plans/*'`
  Expected: 매치 0(plan 문서 제외).

**Step 6: run-bats 수집 + accounting 확인 (rename 무결성)**

Run: `./scripts/run-bats.sh --list | grep resource_limits` → 수집됨.
Run: `bash scripts/check-bats-accounting.sh` → OK(도메인 1개).
Run: `! git grep -n 'test_memory_limits' -- ':!docs/plans/*'` → 매치 0.

**Step 7: Commit**

```bash
git add scripts/check-resource-limits.sh tests/test_resource_limits.bats Makefile policy/memory-limit-allowlist.txt
git commit -m "feat: 자원 가드를 cpu+memory로 확장 + scan-floor (메모리 단일축 편향 해소)"
```

### Task 2: 노드 압박/eviction 알림 메트릭 존재 라이브 선확인

**Files:** (코드 변경 없음 — 사전 검증)

**Step 1: 메인 체크아웃에서 메트릭 존재 확인**

메인 체크아웃에서:
```bash
cd /Users/ukyi/workspace/homelab && eval "$(make kubeconfig)"
kubectl -n observability exec deploy/vmagent -- wget -qO- \
  'http://vmsingle:8428/api/v1/query?query=kube_node_status_condition' | head -c 400
kubectl -n observability exec deploy/vmagent -- wget -qO- \
  'http://vmsingle:8428/api/v1/query?query=kube_pod_status_reason' | head -c 400
```
Expected: 두 메트릭 모두 시리즈 반환(kube-state-metrics scrape). **부재 시** → kube-state-metrics 메트릭 노출 설정 확인 후 알림 expr를 가용 메트릭으로 조정(예: `kube_node_status_condition` 부재면 node-exporter 기반 대체 검토). 결과를 Task 3 진행 전 기록.

### Task 3: 노드 압박/eviction 알림 추가

**Files:**
- Modify: `platform/victoria-stack/prod/rules/core.yaml`(infra 그룹에 알림 2종 추가)
- Modify: `tests/gates/test_vmalert-config.bats`(신규 + 기존 무커버 알림 grep 가드)

**Step 1: 알림 커버리지 테스트 먼저 추가 (failing)**

`tests/gates/test_vmalert-config.bats`에 추가(파일은 실재 — finding의 '부재'는 오류였음):

```bash
@test "core rules cover node pressure and eviction alerts" {
  run grep -q 'alert: NodePressure' platform/victoria-stack/prod/rules/core.yaml
  [ "$status" -eq 0 ]
  run grep -q 'alert: PodEvicted' platform/victoria-stack/prod/rules/core.yaml
  [ "$status" -eq 0 ]
}

@test "node pressure alert uses kubelet condition metric" {
  run grep -q 'kube_node_status_condition' platform/victoria-stack/prod/rules/core.yaml
  [ "$status" -eq 0 ]
}

@test "ContainerMemoryNearLimit uses working_set not max_usage (reclaimable cache trap)" {
  run grep -q 'alert: ContainerMemoryNearLimit' platform/victoria-stack/prod/rules/core.yaml
  [ "$status" -eq 0 ]
  run grep -q 'container_memory_working_set_bytes' platform/victoria-stack/prod/rules/core.yaml
  [ "$status" -eq 0 ]
  # max_usage 회귀 금지(부정단언)
  run grep -q 'container_memory_max_usage_bytes' platform/victoria-stack/prod/rules/core.yaml
  [ "$status" -ne 0 ]
}
```
(Task 2에서 메트릭명이 달라졌으면 그 명칭으로 단언 조정.)

Run: `bats tests/gates/test_vmalert-config.bats`
Expected: 신규 NodePressure/PodEvicted 케이스 FAIL.

**Step 2: core.yaml에 알림 추가**

`platform/victoria-stack/prod/rules/core.yaml`의 `infra` 그룹(NodeMemoryHigh 인근)에 추가:

```yaml
          # 노드-레벨 압박(kubelet condition) — OOM/디스크/PID 고갈의 노드 신호, eviction 선행 지표.
          # 단일 노드라 한 워크로드의 unbounded 자원 증가가 이웃 eviction으로 번진다. hostPath PV 4종이
          # 쿼터 없는 공유 fs를 써 DiskPressure가 현실적 위험(내장 SSD 실용량 224G).
          - alert: NodePressure
            expr: kube_node_status_condition{condition=~"MemoryPressure|DiskPressure|PIDPressure", status="true"} == 1
            for: 5m
            labels: { severity: warning }
            annotations:
              summary: "노드 압박: {{ $labels.node }} {{ $labels.condition }}"
              description: "kubelet이 {{ $labels.condition }}를 보고합니다 — eviction 임박. 자원(메모리/디스크/PID) 소비자를 확인하세요. PVC 포화는 node_filesystem_avail_bytes(/)도 함께 보세요."
          # 파드 eviction 발생(사후) — 노드 압박으로 kubelet이 축출. NodePressure가 선행 경보.
          - alert: PodEvicted
            expr: kube_pod_status_reason{reason="Evicted"} == 1
            for: 0m
            labels: { severity: warning }
            annotations:
              summary: "파드 eviction: {{ $labels.namespace }}/{{ $labels.pod }}"
              description: "노드 압박으로 파드가 축출됐습니다 — 원인 자원(디스크/메모리)을 확인하세요. hostPath PV 포화 가능."
```

**Step 3: vmalert 룰 파서 검증 게이트 추가 (적대적 리뷰 Pass3 #2 — grep-only는 오류 expr 통과)**

grep은 주석·오류 PromQL도 통과시킨다 → 컨테이너화 룰 파서 검사 추가(기존 `tests/gates/alertmanager-render-e2e.sh`·`vector-validate.sh` 선례). `tests/gates/vmalert-rules-validate.sh` 생성:
- `make render COMP=victoria-stack`(또는 kustomize build)로 vmalert 룰 ConfigMap 렌더 → `data."core.yaml"` 추출(yq).
- 컨테이너로 `victoriametrics/vmalert` 이미지 `-rule=<extracted> -dryRun`(또는 `-rule.validateExpressions`) 실행 → 룰 로딩/expr 파싱 검증. 비-0이면 FAIL.
- docker는 러너 기본 제공. `ci.yaml` gate 잡에 스텝 추가(AM/vector validator 인근). shellcheck clean.

Run: `bash tests/gates/vmalert-rules-validate.sh` → PASS(전 룰 파싱 OK). 의도적 오류 expr 임시 주입 시 FAIL 확인(red-green).

**Step 4: 테스트 통과 + 수집 확인**

Run: `bats tests/gates/test_vmalert-config.bats` → PASS.
Run: `bash scripts/run-bats.sh --list | grep vmalert` 수집 확인. 메인 체크아웃에서 `make render COMP=victoria-stack`로 ConfigMap 렌더 무오류 확인.

**Step 5: Commit**

```bash
git add platform/victoria-stack/prod/rules/core.yaml tests/gates/test_vmalert-config.bats tests/gates/vmalert-rules-validate.sh .github/workflows/ci.yaml Makefile
git commit -m "feat: 노드 압박/eviction 알림 + vmalert 룰 커버리지·파서 검증 게이트 (관측 사각 해소)"
```

---

## W2 — AppProject 화이트리스트 + PSA 라벨

### Task 4: apps AppProject에 NetworkPolicy 허용 (M1)

**Files:**
- Modify: `platform/argocd/root/projects.yaml:21-27`
- Modify: `platform/argocd/root/test_projects.bats`

**Step 1: 가드 단언 먼저 추가 (failing)**

`test_projects.bats`의 apps 화이트리스트 단언부에 추가:
```bash
@test "apps project permits NetworkPolicy (apps ship own egress policy via source#3)" {
  run bash -c 'kustomize build platform/argocd/root 2>/dev/null | yq e "select(.kind==\"AppProject\" and .metadata.name==\"apps\") | .spec.namespaceResourceWhitelist[] | .group + \"/\" + .kind"'
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx 'networking.k8s.io/NetworkPolicy'
}
```
(기존 화이트리스트 6-kind 카운트 단언이 있으면 7로 갱신.)

Run: `bats platform/argocd/root/test_projects.bats`
Expected: 신규 케이스 FAIL.

**Step 2: projects.yaml 수정**

`namespaceResourceWhitelist`에 한 줄 추가(주석으로 근거):
```yaml
    - { group: bitnami.com, kind: SealedSecret }
    # 외부/API egress 필요 앱은 deploy/prod(source#3)에 자체 NetworkPolicy 배포(prod=default-deny-egress).
    # namespace-scoped·prod 한정이라 권한경계 안 넓힘. 셀렉터 정합은 owner-local netpol-rehearsal.sh로 검증.
    - { group: networking.k8s.io, kind: NetworkPolicy }
```

**Step 3: 통과 확인**

Run: `bats platform/argocd/root/test_projects.bats` → PASS.

**Step 4: Commit**

```bash
git add platform/argocd/root/projects.yaml platform/argocd/root/test_projects.bats
git commit -m "feat: apps AppProject에 NetworkPolicy 허용 (첫 외부-egress 앱 sync 거부 차단)"
```

### Task 4b: app-owned NetworkPolicy app-scoped 가드 (HIGH — ns 전역 blast radius 차단)

> 적대적 리뷰 Pass1 #2(HIGH): 공유 `prod` ns에서 앱이 빈/광범위 `podSelector` NetworkPolicy를 deploy/prod(source#3)에 넣으면 무관한 앱 트래픽을 열거나 끊을 수 있다. Option A(앱 자체 netpol)를 유지하되 이 blast radius를 가드로 닫는다. (인-레포 앱 0이라 현재 검사 대상 0 — 첫 앱부터 강제되는 계약.)

**Files:**
- Create: `scripts/check-app-netpol.sh`(`apps/*/deploy/**`의 NetworkPolicy를 정적 검사)
- Create: `tests/test_app_netpol.bats`(gate 수집 — .ci-exclude 미등재)
- Modify: `Makefile`(verify 타겟에 호출) 또는 ci.yaml gate 스텝

**⚠️ 유니크 라벨 (적대적 리뷰 Pass2 #2):** 차트 `_helpers.tpl`의 selectorLabels는 `app.kubernetes.io/name`(=차트명, **모든 앱 공유 — 비유니크**)와 `app.kubernetes.io/instance`(=`.Release.Name`, **앱별 유니크**)를 렌더한다. 가드가 허용해야 하는 app-scoped 셀렉터는 **`app.kubernetes.io/instance: <app>`**(유니크)뿐이다 — `app.kubernetes.io/name`만으로는 prod의 전 차트 앱을 매칭해 blast radius가 그대로다.

**Step 0: 차트가 앱별 유니크 라벨을 pod에 렌더하는지 확인**

`helm template t platform/charts/app --set ...`로 pod 라벨에 `app.kubernetes.io/instance`가 release명으로 찍히는지 확인. (현 selectorLabels가 이미 instance를 포함 — Pass2 확인.) instance가 appset에서 앱명과 일치하지 않으면, 차트 pod 템플릿에 전용 `app.homelab/app: {{ .Release.Name }}` 라벨을 추가하고 그것을 가드 기준으로 삼는다.

**Step 1: 가드 red-green 테스트 (failing)**

`tests/test_app_netpol.bats`: (a) 빈 `podSelector: {}`/부재 → FAIL, (b) `app.kubernetes.io/name`만 있고 instance 없는 셀렉터(비유니크) → FAIL, (c) `podSelector.matchLabels["app.kubernetes.io/instance"]`(또는 전용 `app.homelab/app`)가 **디렉토리명(앱)과 일치** → PASS, (d) apps/ 하위 NetworkPolicy 0건 → PASS(현재 상태). yq+python3, age/라이브 불요.

**Step 2: 가드 구현**

`scripts/check-app-netpol.sh`: `apps/*/deploy/**/*.yaml`에서 `kind: NetworkPolicy`를 수집, 각각 `spec.podSelector.matchLabels["app.kubernetes.io/instance"]`(또는 전용 `app.homelab/app`)가 **존재하고 디렉토리명(=앱/release명)과 일치**하는지 검사. 빈 셀렉터·비유니크 라벨(name만)·불일치는 FAIL. 가능하면 `helm template`로 그 앱의 렌더 pod가 실제로 그 instance 라벨을 갖는지 교차확인. bash3.2 호환·shellcheck clean.

**Step 3: 통과 + 수집 확인**

Run: `bats tests/test_app_netpol.bats` → PASS. `./scripts/run-bats.sh --list | grep app_netpol` → 수집됨. `bash scripts/check-bats-accounting.sh` → OK.

**Step 4: netpol-rehearsal discoverability 복원**(별도 감사 finding) — `platform/network-policies/prod/networkpolicies.yaml`의 allow-egress-to-database 주석 또는 `docs/traps-detail.md`에 `scripts/netpol-rehearsal.sh`(owner-local 라이브 셀렉터 검증) 참조 한 줄 복원.

**Step 5: Commit**

```bash
git add scripts/check-app-netpol.sh tests/test_app_netpol.bats Makefile platform/network-policies/prod/networkpolicies.yaml docs/traps-detail.md
git commit -m "feat: app-owned NetworkPolicy app-scoped 셀렉터 가드 (ns 전역 blast radius 차단)"
```

### Task 5: cnpg-system / cert-manager PSA baseline 라벨

**Files:**
- Modify: `platform/namespaces/prod/namespaces.yaml`(Namespace 2개 추가)
- Modify: `platform/namespaces/prod/test_psa.bats`(카운트 6→8 + per-ns 단언)

**Step 1: 실제 PSA baseline 리허설 (적대적 리뷰 Pass3 #1 — preflight가 baseline-거부 필드 전체·미래 pod 템플릿 커버)**

baseline PSA가 거부하는 필드: hostNetwork·hostPID·hostIPC·hostPath 볼륨·hostPort·privileged·capabilities.add(baseline 허용분 외)·procMount≠Default·SELinux 부적합 등. 실행 pod만 보면 미래 operator rollout이 만들 pod 템플릿을 놓친다 → 두 단계로 리허설(메인 체크아웃):
```bash
cd /Users/ukyi/workspace/homelab && eval "$(make kubeconfig)"
# (a) dry-run 라벨 적용 — PSA가 ns의 *현재* pod를 baseline로 평가해 위반 warning/error 방출.
kubectl label ns cnpg-system pod-security.kubernetes.io/enforce=baseline --overwrite --dry-run=server
kubectl label ns cert-manager pod-security.kubernetes.io/enforce=baseline --overwrite --dry-run=server
# (b) *미래 pod 템플릿* 구조검사 — 두 ns의 전 워크로드 pod 템플릿에서 baseline-거부 필드 탐지.
for ns in cnpg-system cert-manager; do
  kubectl get deploy,statefulset,daemonset -n "$ns" -o json | yq -p=json -o=json '
    .items[] | .metadata.name as $n | .spec.template.spec |
    {("name"): $n,
     "hostNetwork": .hostNetwork, "hostPID": .hostPID, "hostIPC": .hostIPC,
     "hostPath": [(.volumes // [])[] | select(.hostPath)] | length,
     "hostPort": [(.containers // [])[].ports // [] | .[] | select(.hostPort)] | length,
     "privileged": [(.containers // [])[] | select(.securityContext.privileged == true)] | length,
     "capAdd": [(.containers // [])[].securityContext.capabilities.add // [] | .[]]}'
done
# sync-wave: namespaces(-9) < cnpg-operator/cert-manager
kubectl get applications -n argocd cnpg-operator cert-manager -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.metadata.annotations.argocd\.argoproj\.io/sync-wave}{"\n"}{end}'
```
Expected: (a) dry-run 라벨에 PSA 위반 warning 없음, (b) 전 워크로드에서 hostNetwork/hostPID/hostIPC=false·hostPath/hostPort/privileged=0·capAdd 비거나 baseline 허용분만, (c) namespaces wave < operator wave. **위반 발견 시** → 해당 ns는 baseline 대신 라벨 보류 또는 operator helm values로 위반 제거 후 적용. **CreateNamespace 충돌 주의**: cnpg-operator/cert-manager는 `CreateNamespace=true`이나 ns 소유권을 주장하지 않는다(pre-sync 생성) → platform-namespaces(-9)가 먼저 라벨 포함 ns 생성, operator CreateNamespace는 no-op. Step 4에서 라이브 확인.

**Step 2: test_psa.bats 카운트/단언 갱신 (failing)**

`test_psa.bats`의 6→8: line 9(`-eq 6`→`-eq 8`), line 16(`-eq 6`→`-eq 8`), line 34(`-eq 6`→`-eq 8`). 그리고 추가:
```bash
@test "cnpg-system enforces at least baseline PSA" {
  v="$(kustomize build platform/namespaces/prod 2>/dev/null \
    | yq e 'select(.kind=="Namespace" and .metadata.name=="cnpg-system") | .metadata.labels["pod-security.kubernetes.io/enforce"]' -)"
  [ "$v" = "baseline" ]
}

@test "cert-manager enforces at least baseline PSA" {
  v="$(kustomize build platform/namespaces/prod 2>/dev/null \
    | yq e 'select(.kind=="Namespace" and .metadata.name=="cert-manager") | .metadata.labels["pod-security.kubernetes.io/enforce"]' -)"
  [ "$v" = "baseline" ]
}
```
Run: `bats platform/namespaces/prod/test_psa.bats`
Expected: 카운트 단언 FAIL(아직 6개).

**Step 3: namespaces.yaml에 Namespace 2개 추가**

파일 끝에 추가(기존 패턴·Prune=false 동일):
```yaml
---
# cnpg-system: CNPG operator(remote helm, CreateNamespace로 생성되어 PSA 라벨 부재였음).
# baseline enforce — operator 파드가 restricted 완전 준수 보장 없어 baseline floor(admission 0 → baseline).
apiVersion: v1
kind: Namespace
metadata:
  name: cnpg-system
  annotations:
    argocd.argoproj.io/sync-options: Prune=false
  labels:
    pod-security.kubernetes.io/enforce: baseline
    pod-security.kubernetes.io/warn: restricted
    pod-security.kubernetes.io/audit: restricted
---
# cert-manager: cert-manager(remote helm, CreateNamespace로 생성). baseline enforce(controller/
# cainjector/webhook가 restricted 미보장 — baseline floor).
apiVersion: v1
kind: Namespace
metadata:
  name: cert-manager
  annotations:
    argocd.argoproj.io/sync-options: Prune=false
  labels:
    pod-security.kubernetes.io/enforce: baseline
    pod-security.kubernetes.io/warn: restricted
    pod-security.kubernetes.io/audit: restricted
```
또한 namespaces.yaml 상단 주석의 "각 컴포넌트 namespace 담당" 설명을 갱신(cnpg-system/cert-manager도 여기 소유).

**Step 4: 통과 + 라이브 ownership 무충돌 확인**

Run: `bats platform/namespaces/prod/test_psa.bats` → PASS(8개).
머지 후(또는 메인 체크아웃 라이브) 확인 사항으로 기록: `kubectl get ns cnpg-system cert-manager -o jsonpath` 로 enforce=baseline 라벨 적용 + operator/cert-manager Application이 Synced/Healthy 유지(ownership 충돌 없음). **충돌·OutOfSync 발생 시** → Namespace 매니페스트를 operator 앱 쪽으로 이동하거나 CreateNamespace 비활성 검토.

**롤백(중요 — `Prune=false`라 매니페스트 삭제로는 라벨이 안 지워진다):** PSA가 라이브 operator 업데이트를 막으면, Namespace 매니페스트를 **삭제하지 말고** 그 안의 PSA 라벨을 제거(또는 `enforce: privileged`로 완화)한 커밋을 머지한다 — 라벨 *수정*은 prune이 아니라 update라 ArgoCD가 반영한다. 검증:
```bash
kubectl get ns cnpg-system cert-manager \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.metadata.labels.pod-security\.kubernetes\.io/enforce}{"\n"}{end}'
# enforce 라벨이 사라졌거나(제거 시 <none>) privileged(완화 시)인지 확인
```

**Step 5: Commit**

```bash
git add platform/namespaces/prod/namespaces.yaml platform/namespaces/prod/test_psa.bats
git commit -m "feat: cnpg-system/cert-manager에 baseline PSA 라벨 (admission floor 부재 해소)"
```

---

## W3 — 공유 차트 하드닝 (스키마 + conftest 렌더 검사)

### Task 6: securityContext/image.tag 스키마 조이기

**Files:**
- Modify: `platform/charts/app/values.schema.json:11,78,79`
- Test: `platform/charts/app/tests/`(test_schema_fail_closed.bats 등 — 위반 values가 schema 거부됨을 단언)

**Step 1: 스키마 거부 테스트 먼저 (failing)**

차트 테스트 하네스에서 schema 검증 방식 확인 후(기존 test_schema_fail_closed.bats 패턴 재사용), 다음을 거부하는 케이스 추가: `securityContext.privileged: true`, `securityContext.runAsUser: 0`, `securityContext.allowPrivilegeEscalation: true`, `securityContext.readOnlyRootFilesystem: false`, `image.tag: latest`. (helm/ajv 검증 경로는 기존 테스트와 동일하게.)

**Step 2: 스키마 수정**

`image.tag` 패턴에서 catch-all 제거(불변 핀 강제):
```json
"tag": { "type": "string", "pattern": "^$|^sha-[0-9a-f]{7,40}$" },
```
(주의: create-app은 항상 digest 핀 + tag 동반이라 tag는 cosmetic. 비-sha 태그가 필요한 정당 케이스가 있으면 digest 동반 필수로 별도 검토 — 현재 인-레포 앱 0이라 영향 없음.)

securityContext/podSecurityContext의 위험필드 거부(bare object → 약화 필드 금지). draft-07 패턴:
```json
"podSecurityContext": {
  "type": "object",
  "properties": { "runAsNonRoot": { "const": true } },
  "not": { "anyOf": [ { "properties": { "runAsUser": { "const": 0 } }, "required": ["runAsUser"] } ] }
},
"securityContext": {
  "type": "object",
  "not": { "anyOf": [
    { "properties": { "privileged": { "const": true } }, "required": ["privileged"] },
    { "properties": { "allowPrivilegeEscalation": { "const": true } }, "required": ["allowPrivilegeEscalation"] },
    { "properties": { "runAsUser": { "const": 0 } }, "required": ["runAsUser"] },
    { "properties": { "readOnlyRootFilesystem": { "const": false } }, "required": ["readOnlyRootFilesystem"] }
  ] }
},
```
(검증기가 draft-07 `not`/`const`를 지원하는지 chart-test로 확인. ajv/python jsonschema면 지원. 미지원 시 Task 7 conftest가 백스톱이므로 스키마는 최소 image.tag만 조이고 securityContext는 conftest에 위임 가능 — 결정은 Step 3 결과로.)

**Step 3: 통과 확인**

Run: `make chart-test`
Expected: 위반 values 거부(FAIL→차단), 정상 values 통과. 기존 차트 렌더 영향 없음.

**Step 4: Commit**

```bash
git add platform/charts/app/values.schema.json platform/charts/app/tests/
git commit -m "feat: 공유 차트 스키마 — securityContext 약화·mutable tag 거부"
```

### Task 7: chart-test에 conftest PSA-restricted 렌더 검사

**Files:**
- Create: `platform/charts/app/tests/psa-restricted.rego`(또는 `policy/` 하위 — 기존 conftest 관례 따름)
- Modify: `platform/charts/app/tests/render.sh`(helm template 출력 → conftest)
- Test: chart-test가 약화된 렌더를 거부함을 단언

**Step 1: render.sh가 conftest를 호출하도록 + red 픽스처 (failing)**

`render.sh`의 3 kind 렌더 파이프라인(helm template | kubeconform) 뒤에 conftest 추가:
```bash
helm template "$name" "$CHART" -f "$vals" | conftest test --policy "$CHART/tests/psa-restricted.rego" -
```

**PSA restricted rego — 전체 PSS Restricted 패리티** (적대적 리뷰 Pass1 #4: drop:ALL·seccomp 존재만으로는 false-green). 모든 컨테이너 타입(`containers` + `initContainers` + `ephemeralContainers`)에 대해 deny:
- `runAsNonRoot != true` (pod 또는 container 레벨)
- `privileged == true`
- `allowPrivilegeEscalation != false`
- `securityContext.capabilities.drop`에 `ALL` 부재
- **`securityContext.capabilities.add`에 `NET_BIND_SERVICE` 외 항목 존재** (restricted는 add 전면 금지에 가까움 — 보수적으로 빈 add만 허용, NET_BIND_SERVICE만 예외 허용 검토)
- **`seccompProfile.type`가 `RuntimeDefault`/`Localhost`가 아님**(부재 또는 `Unconfined` 모두 deny — pod 또는 container 레벨)
- `readOnlyRootFilesystem != true` (worker/service)
- hostPath 볼륨 / `hostNetwork`/`hostPID`/`hostIPC` 사용

**Step 2: 정상 차트 통과 + 약화 거부 확인 (negative fixtures)**

Run: `make chart-test`
Expected: 기본 차트 3 kind 전부 conftest PASS. **negative fixtures로 거부 확인**(스키마 우회 경로 백스톱): `capabilities.add: [NET_ADMIN]`, `seccompProfile.type: Unconfined`, initContainer가 위 위반 — 각각 conftest deny(스키마가 못 잡는 케이스). 정상 + 약화 픽스처 둘 다 테스트.

**Step 3: 실제 앱 values를 동일 conftest로 렌더 검사 (적대적 리뷰 Pass3 #3 — fixture만으론 앱 values 미커버)**

차트 fixture 통과 ≠ 실제 `apps/*/deploy/prod/values.yaml` 안전. 앱 values가 (스키마가 못 막는 방식으로) PSA를 약화하면 fixture conftest는 못 잡는다. 앱-렌더 게이트 추가:
- `scripts/check-app-deploy.sh`(현재 파일 존재만 검사) 또는 신규 게이트에서 `apps/*/deploy/prod/values.yaml`를 열거 → 각각 `helm template <app> platform/charts/app -f <values>` (release명=앱 디렉토리명) → 동일 `psa-restricted.rego` conftest로 검증.
- 현재 인-레포 앱 0개라 열거 0건=PASS(no-op 계약). 첫 앱부터 required gate가 강제.
- run-bats(gate) 수집되는 bats 또는 ci.yaml gate 스텝으로 배선. shellcheck clean.

Run: 앱 0개 시 PASS. 임시 약화 앱 values fixture(예: capabilities.add) → FAIL 확인(red-green).

**Step 4: Commit**

```bash
git add platform/charts/app/tests/psa-restricted.rego platform/charts/app/tests/render.sh scripts/check-app-deploy.sh tests/ .github/workflows/ci.yaml Makefile
git commit -m "feat: chart+앱values PSA-restricted conftest 검사 (라이브 admission 패리티·앱 values 커버)"
```

### Task 8: worker 기본 liveness distroless 안전화

**Files:**
- Modify: `platform/charts/app/templates/deployment.yaml:90-100`(worker liveness 분기)
- Modify: `platform/charts/app/tests/test_probe_override.bats`

**Step 1: 안전 기본 테스트로 교체 (failing)**

`test_probe_override.bats`의 "worker 기본이 /bin/true" 회귀 가드(line 13-16)를 "worker 기본은 liveness 미설정(override 없으면 probe 없음)"으로 교체:
```bash
@test "worker has NO default liveness probe (distroless-safe; override required for liveness)" {
  out="$(helm template t "$CHART" --set kind=worker | yq e 'select(.kind=="Deployment") | .spec.template.spec.containers[0].livenessProbe')"
  [ "$out" = "null" ]
}
```

**Step 2: deployment.yaml 수정**

worker 분기에서 기본 `livenessProbe: exec: [/bin/true]`를 제거(override가 있을 때만 렌더). 즉 `.Values.livenessProbe`가 설정된 경우만 출력하고, 미설정 worker는 liveness 없음. (values.yaml 주석 갱신: "distroless 워커는 liveness 미설정이 기본 — 필요 시 grpc/tcpSocket override".)

**Step 3: 통과 확인** Run: `make chart-test` → PASS(worker liveness null, service/static 영향 없음).

**Step 4: Commit**
```bash
git add platform/charts/app/templates/deployment.yaml platform/charts/app/templates/*.tpl platform/charts/app/values.yaml platform/charts/app/tests/test_probe_override.bats
git commit -m "fix: worker 기본 liveness 제거 (distroless /bin/true CrashLoop 방지)"
```

### Task 9: migrate Job memory 독립 분리 (차트 values만 — 단일 계약)

> 적대적 리뷰 Pass1 #3 + Pass2 #1: "≥128Mi 테스트 vs 앱-limit fallback" 모순 제거 **+** app-config `db`는 *배열*(바인딩명)이라 거기 객체 필드 추가 불가. **차트 values 계층에서만** 해결: migrate Job memory를 앱 런타임 limit에서 파생하지 않고 **독립 고정 기본값 `256Mi`**(차트 `values.db.migrateMemory`로 override). **app-config-schema.json/create-app 배선은 드롭**(YAGNI — 256Mi 기본이 OOM 위험을 닫음, db 배열↔객체 계약 충돌 회피). 차트 values `db`는 객체(`{enabled,host,migrateCmd}`)라 migrateMemory 추가가 안전.

**Files:**
- Modify: `platform/charts/app/templates/migrate-job.yaml:82-84`(memory를 `.Values.db.migrateMemory | default "256Mi"`로)
- Modify: `platform/charts/app/values.yaml`(`db.migrateMemory` 기본 미설정 + 주석)
- Modify: `platform/charts/app/values.schema.json`(차트 db 객체에 `migrateMemory: {type: string, minLength: 1}` 추가, additionalProperties:false 유지)
- Test: `platform/charts/app/tests/`(렌더 단언)
- **변경 안 함**: `tools/app-config-schema.json`·`tools/create-app.ts`(app-config `db`는 바인딩명 배열 — 건드리면 `db: [name]` 계약 깨짐. migrate memory override는 차트 values 전용으로 둠, owner가 필요 시 deploy/prod values에서 지정).

**Step 1: 테스트 (failing)**
- 차트: 앱 limit 64Mi + db.enabled, db.migrateMemory 미설정 → migrate Job `limits.memory == 256Mi`(앱 limit과 무관).
- db.migrateMemory=512Mi 설정 → migrate Job `limits.memory == 512Mi`.

**Step 2: 구현**
migrate-job.yaml: `memory: {{ .Values.db.migrateMemory | default "256Mi" }}` (cpu는 기존 독립값 유지). values.schema.json **차트** db 객체에 migrateMemory 추가.

**Step 3: 통과** Run: `make chart-test` → PASS.

**Step 4: Commit**
```bash
git add platform/charts/app/templates/migrate-job.yaml platform/charts/app/values.schema.json platform/charts/app/values.yaml platform/charts/app/tests/
git commit -m "fix: migrate Job memory를 독립 기본값(256Mi)으로 분리 (마이그레이션 OOM 방지)"
```

---

## W4 — 게이트 false-green / 온보딩 정합

### Task 10: sops-guard에 recipient 신원 검증 (gate enforcer)

**Files:**
- Modify: `scripts/sops-guard.sh`(recipient 신원 대조 추가)
- Modify: `scripts/verify-secrets.sh:20-22`(개수→신원, 일관성)
- Test: `tests/test_sops-guard.bats`는 .ci-exclude(age 의존)이므로, **gate-수집되는** 신규 픽스처 테스트를 `tests/gates/`에 추가하거나 기존 gate 테스트 보강

**Step 1: 신원 검증 픽스처 테스트 (failing)**

canonical 아닌 recipient 2개로 된 enc.yaml 픽스처가 sops-guard에서 FAIL함을 단언하는 gate-safe 테스트 추가(yq만 사용, age 불요). canonical: cluster `age1n3j7p70f0unl5dgrjhtr9jxrdntz2a67dtntu446qus9c3jd3fnsp8z960`, recovery `age154tu9q7922xu46x0rkfm5l9x3ulf9u5at5qvxeaqfx9sgtm7cumq75jdwc`(`.sops.yaml _recipients`).

**Step 2: sops-guard.sh에 신원 검증 추가**

각 enc.yaml의 mac/leaf 검증 후, recipient 집합을 .sops.yaml canonical과 set 비교:
```bash
# canonical recipient(공개키) — .sops.yaml _recipients 앵커. 개수가 아니라 신원을 강제(recovery 키 스왑 차단).
canon=$(yq -e '._recipients | sort | join(",")' .sops.yaml 2>/dev/null || echo "")
got=$(yq -e '[.sops.age[].recipient] | sort | join(",")' "$f" 2>/dev/null || echo "")
if [ -n "$canon" ] && [ "$got" != "$canon" ]; then
  echo "BLOCKED: $f recipient 집합이 .sops.yaml canonical(cluster+recovery)과 불일치 — recipient 신원 드리프트(스왑/recovery 드롭)." >&2
  rc=1
fi
```
(yq join 문법은 mikefarah yq 기준 확인 — 버전차 함정. 안 되면 python3 set 비교로.)

**Step 3: verify-secrets.sh 일관 강화**

`verify-secrets.sh:20-22`의 개수 검사를 동일한 신원 set 비교로 교체(owner-local 일관성). 헤더 주석의 "recipient 정확히 2개"→"canonical recipient(cluster+recovery) 정확 일치".

**Step 4: 통과 + 실파일 회귀 없음**

Run: 신규 픽스처 테스트 PASS(비-canonical FAIL, canonical PASS).
Run: `git ls-files '*.enc.yaml' | xargs -r bash scripts/sops-guard.sh` → 추적 7개 전부 OK(현재 전부 canonical — 회귀 없음).
Run: `shellcheck scripts/sops-guard.sh scripts/verify-secrets.sh` → clean.

**Step 5: Commit**
```bash
git add scripts/sops-guard.sh scripts/verify-secrets.sh tests/gates/ tests/test_sops-guard.bats
git commit -m "fix: SOPS recipient 신원 검증 (개수→신원 — recovery 키 스왑/드롭 차단)"
```

### Task 11: apps.json 구조검증 required gate 승격

**Files:**
- Create: `infra/cloudflare/test_apps_structure.bats`(jq-only — JSON 배열·host 유일성·예약어. .ci-exclude에 **넣지 않음** → gate 수집)
- Modify: `infra/cloudflare/test_apps_data.bats`(jq-only 검사를 신규 파일로 이전, terraform 의존만 잔류)
- 확인: `tests/.ci-exclude`(test_apps_data.bats는 유지, test_apps_structure.bats는 미등재)

**Step 1: 신규 jq-only 테스트 작성 (failing 우선 — 손상 픽스처로 FAIL 확인)**

`test_apps_data.bats`를 읽어 terraform 비의존 @test(JSON 배열 타입·host 전역 유일성·apex/www/home 예약어 충돌)를 식별·복사해 `test_apps_structure.bats`로. jq만 사용(terraform 불요). 손상 apps.json(host 중복) 임시 픽스처로 FAIL 확인.

**Step 2: test_apps_data.bats에서 이전한 jq-only 케이스 제거**(중복 방지, terraform 의존 케이스만 잔류). accounting 가드가 도메인 강제하므로 신규 파일이 gate 도메인 1개에 속하는지 확인.

**Step 3: 수집·통과 확인**

Run: `./scripts/run-bats.sh --list | grep apps_structure` → 수집됨.
Run: `bats infra/cloudflare/test_apps_structure.bats` → PASS(현재 apps.json=빈 배열 정상).
Run: `bash scripts/check-bats-accounting.sh` → OK.

**Step 4: Commit**
```bash
git add infra/cloudflare/test_apps_structure.bats infra/cloudflare/test_apps_data.bats
git commit -m "feat: apps.json 구조검증(host 유일성·예약어)을 required gate로 승격"
```

### Task 12: create-app SealedSecret 키 교차검증

**Files:**
- Modify: `tools/create-app.ts:143-152`
- Test: `tools/tests/test_create-app.bats`

**Step 1: 테스트 (failing)** 봉인본 encryptedData 키가 `config.secrets`(toEnvKey 변환)와 불일치(초과/누락)면 create-app이 거부함을 단언.

**Step 2: 구현** sealed 검증부(kind/ns/name 다음)에 추가: `sealedDoc.spec.encryptedData`의 키 집합 == `config.secrets.map(toEnvKey)` 집합(정확 일치, 초과·누락 모두 거부). toEnvKey는 `tools/seal-secret.mts`(또는 lib)의 함수 재사용. 키 이름만 비교(평문 — 시크릿 노출 0).

**Step 3: 통과** Run: `bun test` 또는 해당 bats → PASS.

**Step 4: Commit**
```bash
git add tools/create-app.ts tools/tests/test_create-app.bats
git commit -m "fix: create-app이 SealedSecret 키↔config.secrets 교차검증 (envFrom 섀도잉 차단)"
```

### Task 13: secret-cert-check skip 종료코드 구분

**Files:**
- Modify: `scripts/secret-cert-check.sh:21,24-27,33`
- Modify: `tests/gates/test_secret-cert-check.bats`(offline skip이 exit 2임을 단언)

**Step 1: 테스트 갱신 (failing)** offline/fetch 실패 시 `status -eq 0` 단언을 `status -eq 2`(skip)로 변경.

**Step 2: 구현** fetch 불가/파싱 실패 경로의 `exit 0` → `exit 2`(skip 신호). echo는 "⚠️ 검증 스킵(미검증)"로 명확히. stale 불일치는 기존대로 exit 1.

**Step 3: 통과** Run: 해당 bats → PASS.

**Step 4: Commit**
```bash
git add scripts/secret-cert-check.sh tests/gates/test_secret-cert-check.bats
git commit -m "fix: secret-cert-check skip을 exit 2로 구분 (검증됨/미검증 혼동 방지)"
```

---

## W5 — 문서 / 원장 드리프트 정정 (라이브 무영향)

### Task 14: 메모리 원장 정합 + 산문 교차 가드

**Files:**
- Modify: `docs/memory-ledger.md:17,23`(+ whoami 행)
- Modify: `policy/memory-limit-allowlist.txt`('범위 밖' 섹션)
- (선택) Modify: ledger 산문↔행 합계 교차 가드

**Steps:**
- observability 행 `1344 | 2688` → `1312 | 2624`(라이브 합산 일치). 산문 합계줄 `req ≈ 4419 · limit ≈ 8232` → 재계산값(whoami 행 추가 반영). whoami 행 추가: `gateway / 16 / 32`(또는 산문 예외에 명시). 합계 재계산 후 `bun run verify:ledger` GREEN 확인.
- `policy/memory-limit-allowlist.txt` '범위 밖(문서 전용)' 섹션에 추가: `edge/ts-traefik-*/tailscale`(tailscale operator proxy·ProxyClass 미지정), `database/pg-1/plugin-barman-cloud`(CNPG 주입 사이드카), local-helm 상주(traefik/argocd/sealed-secrets/tailscale-operator — values로 limit, 게이트 스캔 외).
- (선택) 산문 합계줄 == 행 합계 교차 가드: `tools/lib/ledger-totals.ts`의 `replaceTotals`/`parseLedgerRows` 재사용해 `bun run verify:ledger` 또는 신규 한 줄 검증.
- Commit: `docs: 메모리 원장 obs 행 정합·whoami 행·allowlist 사각 등재`

### Task 15: traps 원장에 자원-limit 가드 등재

**Files:**
- Modify: `docs/traps-detail.md`(신규 섹션), `docs/traps.md`(한 줄 + `> 가드:`), `AGENTS.md`(한줄 인덱스)

**Steps:**
- `docs/traps-detail.md`에 "자원(cpu+memory) limit 블라인드스팟" 섹션 추가, 가드 줄 `> 가드: scripts/check-resource-limits.sh, tests/test_resource_limits.bats`.
- `docs/traps.md` 원장에 동일 한 줄 추가.
- `AGENTS.md` 함정 한줄 인덱스에 추가(개수 41→42).
- Run: `bash scripts/verify-traps.sh` → 역방향 tie가 가드 추적, PASS.
- Commit: `docs: 자원 limit 가드를 traps 원장에 등재 (theme8 self-ref 사각 해소)`

### Task 16: AGENTS.md ts 개수 + make help + SSD 용량 정정

**Files:**
- Modify: `AGENTS.md:15`(ts 17→실제값 또는 정성표현), `Makefile`(verify help — Task 1에서 안 했으면), `infra/k3s-bootstrap/versions.env:25`, `infra/k3s-bootstrap/cloud-init.yaml:102`, `platform/victoria-stack/prod/rules/r4-storage-backup.yaml`

**Steps:**
- `git ls-files 'tools/*.ts' | grep -v /tests/ | wc -l`로 실제 수 확인 후 `AGENTS.md:15` 갱신(또는 "top-level + lib/" 정성표현).
- 내장 SSD `512GB`→`224GiB`(versions.env·cloud-init.yaml·r4 알림 주석 `255GB`도 정합), bulk `1TB`→`1.9T`. r4 알림 expr는 비율 기반이라 무영향(주석만).
- Run: `make help`로 verify 설명에 자원 limit 반영 확인.
- Commit: `docs: AGENTS.md ts 개수·내장 SSD 용량·make help 주석 정정`

---

## 최종 검증 & PR

### Task 17: 전 게이트 GREEN + PR

**Steps:**
1. Run: `make ci`(gate 미러 — typecheck·chart-test·run-bats·shellcheck·verify:ledger·skeleton·audit·actionlint·AM e2e). 전 GREEN 확인. 실패 시 해당 작업으로 복귀.
2. Run: `make verify`(skeleton·accounting·자원가드·ledger·sops 왕복) GREEN.
3. (메인 체크아웃 라이브) `make render COMP=victoria-stack`·`COMP=namespaces`로 신규 매니페스트 렌더 무오류 확인.
4. `/pr` 스킬 또는 PR 생성: 제목 `feat: 자원·게이트·문서 하드닝 (감사 후속 W1~W5)`, 본문에 워크스트림별 변경·라이브 영향(PSA baseline만, 나머지 additive/CI-only/문서)·롤백(PSA 라벨 제거) 요약.
5. **auto-merge 비활성** → push 후 `gate` watch(`gh run watch` 또는 PR checks), GREEN 확인 후 수동 squash 머지.
6. 머지 후 라이브 검증 기록: ArgoCD 18+ Application Synced/Healthy 유지, cnpg-system/cert-manager enforce=baseline 적용·operator 무충돌, 신규 알림 vmalert 로드(`vmalert:8880/api/v1/rules`), 자원 가드 gate 통과.

## 라이브 영향 요약 (롤백 포인트)
- **PSA baseline(Task 5)**: 유일한 라이브-거동 변경. 롤백 = **Namespace 매니페스트의 PSA 라벨 제거/완화 후 sync**(매니페스트 삭제 아님 — `Prune=false`라 삭제로는 라벨이 안 지워짐, Task 5 롤백 절차). baseline은 기존 파드 거부 안 함(선확인).
- **AppProject NetworkPolicy(Task 4)·알림(Task 3)**: additive, 기존 동작 불변.
- **차트/가드/스키마/문서**: 인-레포 앱 0개 + 기존 매니페스트 cpu limit 보유라 라이브 무영향.

## Adversarial review dispositions

3 패스 적대적 리뷰(codex). 총 9개 plan finding 전부 **Accepted**(반박된 것 없음). 각 패스가 직전 수정의 후속 리스크를 잡아 계획이 수렴. 최종 패스(3)는 캡 도달 시점 `needs-attention`이었으나, 3건 전부 수용·적용했고 사용자가 캡에서 "적용 후 확정(추가 리뷰 없음)"을 승인 — 미해결 high/critical 없음(전부 적용). 구현 시 TDD + `make ci`가 추가 검증.

**Pass 1** (verdict: needs-attention, "invalid rollback + widened trust boundary"):
- [Accepted·high] PSA 롤백이 `Prune=false`라 매니페스트 삭제로 라벨 미제거 → 롤백을 라벨 제거/완화+sync+검증으로 명시(Task 5).
- [Accepted·high] NetworkPolicy 화이트리스트 ns 전역 blast radius → Option A 유지하되 app-scoped 셀렉터 가드 추가(Task 4b) + netpol-rehearsal discoverability 복원.
- [Accepted·medium] migrate memory 계약 자기모순 → 독립 고정 256Mi 단일 계약(Task 9).
- [Accepted·medium] conftest false-green → 전체 PSS Restricted 패리티(Task 7).

**Pass 2** (verdict: needs-attention, "contract/selector gaps"):
- [Accepted·high] migrateMemory가 app-config `db` 배열 계약에 오배치 → app-config/create-app 배선 드롭, 차트 `values.db.migrateMemory`만(Task 9).
- [Accepted·high] netpol 셀렉터 가드가 비유니크 라벨(`app.kubernetes.io/name`=차트명) → 유니크 `app.kubernetes.io/instance`(=앱명) 강제 + 렌더 교차검증(Task 4b).

**Pass 3** (verdict: needs-attention, "false-green gates around live admission/alert validity"; 캡 도달, 전부 수용·적용, 사용자 finalize 승인):
- [Accepted·high] PSA baseline preflight가 baseline-거부 필드/미래 pod 템플릿 미커버 → dry-run 라벨 + pod 템플릿 구조검사 리허설(Task 5).
- [Accepted·medium] vmalert 수용기준 grep-only → 컨테이너화 vmalert dryRun 파서 게이트(Task 3).
- [Accepted·medium] conftest 백스톱이 실제 앱 values 미커버 → 앱 values 렌더 conftest 게이트(Task 7).

## Execution directives
- **Skill:** implement via `executing-plans` in a **separate session, in this worktree** (`.claude/worktrees/feat+resource-hardening`).
- **Run continuously:** do NOT stop between batches for routine review. Stop ONLY on a genuine blocker — missing dependency, a verification that keeps failing, an unclear/contradictory instruction, or a critical plan gap (executing-plans' "When to Stop and Ask"). Otherwise proceed through every task to completion.
- **라이브 검증 단계(Task 2·5 preflight, 최종 라이브 확인)는 메인 체크아웃**(`/Users/ukyi/workspace/homelab`)에서 `eval "$(make kubeconfig)"` 후 실행 — 워크트리는 KUBECONFIG gitignored라 부재(export 시 sealed-secrets server-dry-run hang).
- **Commits — apply these rules directly; do NOT invoke `Skill(commit)`** (interactive 확인이 연속 실행을 깸):
  - **Language:** 한국어. **AI 마커 금지**(`🤖 Generated with`·`Co-Authored-By: Claude` 등 절대 미포함 — AGENTS.md).
  - **Format:** `<type>(<scope>): 한국어 설명` (필요 시 `- 상세` 본문).
  - **Type — 다음만:** `feat`/`fix`/`refactor`/`docs`/`style`/`test`/`chore`. (`perf`/`build`/`ci` 금지.)
  - **Grouping:** 같은 디렉토리·같은 목적 → 한 커밋. 한 파일 변경이 다른 파일 없이 무의미하면 같은 커밋. 독립 설명 가능하면 별도 커밋. (각 Task의 Commit 단계 기준.)
  - **Where:** 현재 feature-branch 워크트리(`worktree-feat+resource-hardening`)에 직접 커밋(이미 main 밖).
- **머지:** auto-merge 비활성 → push 후 `make ci` 미러 GREEN 확인 + `gate` watch(로컬 green≠CI green: yq 버전차·CJK @test·bash3.2 함정) → 수동 squash. 머지 후 라이브 검증(ArgoCD Synced/Healthy·PSA 라벨·vmalert 룰 로드).
