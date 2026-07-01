# files 배포 (platform/files/prod 베스포크 컴포넌트) Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 완성된 Rust 파일스토어 앱 `files`(stateful bulk-ssd PVC + 2리스너)를 홈랩에 `platform/files/prod/` 베스포크 플랫폼 컴포넌트로 배포한다(internal 먼저 → public 스테이징).

**Architecture:** `platform/adguard/prod`(2 Service·PVC·Recreate·self-isolating netpol) + `platform/cache/prod/trip-mate`(secret 파일마운트·restricted securityContext) 스켈레톤을 복제한 raw kustomize 디렉토리. `platform-components` ApplicationSet가 `platform/*/prod` glob으로 자동 발견 → Application `files-prod`(project `platform`). 전용 `files` 네임스페이스(PSA restricted). durability=로컬 2TB 외장 SSD + PV-Retain 가드(R2 백업 없음).

**Tech Stack:** Kubernetes(k3s), ArgoCD ApplicationSet, kustomize, Gateway API(Traefik), SealedSecrets(bitnami), bats(매니페스트 grep), kubeconform, `bulk-ssd` local-path StorageClass.

**설계 SSOT:** `docs/plans/2026-07-01-files-deploy-design.md` (승인·커밋 `0490cb2`).

---

## 실행 규율 (executing-plans)

- **OWNER-LOCAL 표시** 단계(�而)는 owner의 자격/클러스터 접근이 필요해 자동 실행 불가 — 매니페스트/스크립트/테스트를 **작성**하되, **봉인·라이브검증·PR머지·terraform apply·PV패치**는 owner가 수행. 해당 단계에서 멈추지 말고 작성만 완료 후 다음으로 진행하며, 계획 말미 "OWNER 체크리스트"에 모은다.
- **AUTOMATABLE** 단계는 워크트리에서 즉시 실행(매니페스트 작성 + bats + kustomize 렌더 + `check-resource-limits` + `verify:ledger`).
- 커밋은 워크트리 브랜치(`worktree-files-deploy`)에 직접. 한국어 conventional, AI 마커 금지.
- 게이트 명령:
  ```bash
  export SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt   # sops 필요 시
  bats platform/files/prod/                               # 매니페스트 grep 테스트
  kustomize build --enable-helm --enable-alpha-plugins --enable-exec platform/files/prod | kubeconform -strict -ignore-missing-schemas -schema-location default -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.Kind}}_{{.ResourcesName}}.json'
  bash scripts/check-resource-limits.sh
  bun run verify:ledger
  ```
  ※ `kustomize build`의 kubeconform Gateway API CRD 스키마는 `-ignore-missing-schemas` 또는 CRDs-catalog로 처리(HTTPRoute/SealedSecret은 CRD).

---

## Phase 0 — 사전조건 (🔒 OWNER-LOCAL, 배포 전 확인)

**Files:** 없음(확인만).

**Step 0-1:** [발견 #12] `files` 앱 이미지 provenance 확정 — **머지된 앱 commit에서** APP_SHA + 그 태그의 digest를 정확히 뽑는다(latest `.[0]` 추정 금지). 현재 앱은 워크트리 `~/workspace/files/.worktrees/files-store`(브랜치 `feat/files-store`)라 **아직 main 미머지·이미지 미빌드**일 수 있음.
```bash
# 1) 앱 레포 main HEAD = 배포할 정확한 commit
APP_SHA=$(gh api repos/ukyi-app/files/commits/main --jq '.sha')
# 2) release.yaml가 sha-$APP_SHA를 push했는지 + 그 digest(reviewed main revision과 일치 보장)
IMAGE_DIGEST=$(crane digest "ghcr.io/ukyi-app/files:sha-$APP_SHA")   # 또는: skopeo inspect --format '{{.Digest}}' docker://ghcr.io/ukyi-app/files:sha-$APP_SHA
echo "APP_SHA=$APP_SHA  IMAGE_DIGEST=$IMAGE_DIGEST"
```
→ 태그가 없으면 **선행**: files 앱을 레포 main에 머지 → release.yaml 완료 후 재실행. 이 정확한 `sha-$APP_SHA` + `$IMAGE_DIGEST`를 Step 9-3 이미지 핀에 사용.

**Step 0-2:** 봉인 도구 확인: `kubeseal` 설치, `tools/sealed-secrets-cert.pem` 존재, sealed-secrets 컨트롤러 라이브(`make secret-cert-check`).

**Step 0-3:** `.env.secrets`(gitignored)에 `GHCR_PULL_TOKEN`(read:packages) 존재 확인 + files admin API 토큰 준비(keys.json용, Task 3).

**Step 0-4:** [발견 #13] pull 자격 사전검증 — 봉인·PR-A 전에 ghcr-pull 토큰이 핀 이미지를 실제 pull 가능한지 확인(잘못된 자격→머지 후 ImagePullBackOff 조기 차단). ※ seal-ghcr-pull은 기존 prod 패턴(gh user + `GHCR_PULL_TOKEN`) 미러 — GHCR PAT는 토큰으로 인증(username 비-인증 요소)이나 유효성은 실제 pull로 확인:
```bash
echo "$GHCR_PULL_TOKEN" | docker login ghcr.io -u "$(gh api user --jq .login)" --password-stdin
docker manifest inspect "ghcr.io/ukyi-app/files:sha-$APP_SHA" >/dev/null && echo "pull OK"
```

---

## PR-A0 (namespace 선행) — files ns 먼저 생성·싱크 [발견 #1 수정]

> **발견 #1:** platform ApplicationSet은 `platform/*/prod`를 namespaces Application과 **독립 발견**한다. ns와 컴포넌트를 한 PR에 두면 `files-prod`가 files ns 생성 전 싱크→"namespace not found", retry 소진 시 교착. **ns를 선행 PR로 분리**해 라이브 확인 후 컴포넌트 PR(PR-A)를 연다. (대안: files ns를 `platform/files/prod/namespace.yaml`에 sync-wave "-1"로 두어 intra-Application 순서로 해결 — cnpg/victoria 선례. 여기선 컨벤션(공유 namespaces.yaml)을 따르는 선행 PR 방식 채택.)

### Task 1: files 네임스페이스 (선행 PR-A0)

> **발견 7·8:** PR-A0는 **`platform/files/prod/`를 절대 만들지 않는다**(appset이 kustomization 없는 files-prod를 생성해 GitOps 파손). ns 테스트는 appset-제외인 `platform/namespaces/prod/`에 둔다(`test_homepage_ns.bats` 선례). 또 기존 `test_psa.bats`가 owned ns 개수를 9로 하드코딩하므로 files 추가 시 10으로 갱신해야 게이트 통과.

**Files:**
- Modify: `platform/namespaces/prod/namespaces.yaml` (파일 끝에 files ns 추가)
- Create: `platform/namespaces/prod/test_files_ns.bats` (`test_homepage_ns.bats` 미러 — **`platform/files/prod` 아님**)
- Modify: `platform/namespaces/prod/test_psa.bats` (하드코딩 개수 9 → 10)

**Step 1-1 (bats 먼저):** `platform/namespaces/prod/test_files_ns.bats` 생성(co-located, homepage 테스트 미러):
```bash
#!/usr/bin/env bats
setup() { N="${BATS_TEST_DIRNAME}/namespaces.yaml"; }

@test "files namespace enforces restricted PSA" {
  run yq ea 'select(.kind=="Namespace" and .metadata.name=="files") | .metadata.labels."pod-security.kubernetes.io/enforce"' "$N"
  [ "$output" = "restricted" ]
}

@test "files namespace has Prune=false" {
  run yq ea 'select(.kind=="Namespace" and .metadata.name=="files") | .metadata.annotations."argocd.argoproj.io/sync-options"' "$N"
  [ "$output" = "Prune=false" ]
}
```

**Step 1-2:** 실패 확인 — `bats platform/namespaces/prod/test_files_ns.bats` → FAIL(ns 없음).

**Step 1-3:** `namespaces.yaml` 끝에 추가(homepage 블록과 동일 restricted 패턴):
```yaml
---
# files: 자기-호스팅 파일 스토어(platform/files) — bulk-ssd PVC + 2리스너, 비루트·RO루트·drop ALL·
# 포트>1024·setcap 불요 → restricted 완전 준수(homepage와 동급). Prune=false로 ns 삭제 방지.
apiVersion: v1
kind: Namespace
metadata:
  name: files
  annotations:
    argocd.argoproj.io/sync-options: Prune=false
  labels:
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/warn: restricted
    pod-security.kubernetes.io/audit: restricted
```

**Step 1-3.5:** `test_psa.bats` 하드코딩 개수 갱신 — files는 **10번째 owned ns**(enforce=restricted·warn=restricted·audit=restricted 전부 보유). 파일을 읽어 **owned ns 전체를 세는 카운트를 9→10**으로: `renders all nine owned namespaces`(제목 nine→ten + `-eq 9`→`-eq 10`), `enforce:` present 개수 `-eq 9`→`-eq 10`, `warn: restricted` 개수 `-eq 9`→`-eq 10`, (audit=restricted 등 전체-ns 카운트가 더 있으면 동일하게 +1). ※ files가 더하지 않는 부분집합 카운트(예: baseline enforce 개수)는 건드리지 않는다.

**Step 1-4:** 검증 — `bats platform/namespaces/prod/` 전체 PASS(test_files_ns + test_psa + test_homepage_ns) + `make verify`(skeleton+원장+sops) 통과.

**Step 1-5 (Commit):**
```bash
git add platform/namespaces/prod/namespaces.yaml platform/namespaces/prod/test_files_ns.bats platform/namespaces/prod/test_psa.bats
git commit -m "feat: files 네임스페이스(restricted PSA·Prune=false) 선행 추가"
```

**Step 1-6 (🔒 OWNER-LOCAL — PR-A0 머지 + ns 라이브 확인, PR-A 전 필수):**
```bash
# ns 커밋만 담은 선행 PR로 연다(컴포넌트 커밋과 분리 — 예: ns 커밋을 별도 브랜치로 cherry-pick).
gh pr create --base main --title "feat: files 네임스페이스 선행(PR-A0)" --body "PR-A(컴포넌트) 전 ns 먼저 — 발견 #1"
# 머지 후 라이브 확인:
export KUBECONFIG=$PWD/infra/k3s-bootstrap/kubeconfig
kubectl get ns files -o jsonpath='{.metadata.labels.pod-security\.kubernetes\.io/enforce}'   # => restricted
```
→ **ns가 restricted 라벨로 라이브 확인된 뒤에만** PR-A(컴포넌트)로 진행(교착 회피).

---

## PR-A (internal) — 스토어 배포 + 내부 API + 라이브검증

### Task 2: PVC (bulk-ssd 100Gi)

**Files:**
- Create: `platform/files/prod/pvc.yaml`
- Create: `platform/files/prod/test_files_storage.bats`

**Step 2-1 (bats):** `test_files_storage.bats`:
```bash
#!/usr/bin/env bats
PVC="$BATS_TEST_DIRNAME/pvc.yaml"

@test "pvc uses bulk-ssd storageClass explicitly" {
  run yq '.spec.storageClassName' "$PVC"
  [ "$output" = "bulk-ssd" ]
}

@test "pvc is ReadWriteOnce" {
  run yq '.spec.accessModes[0]' "$PVC"
  [ "$output" = "ReadWriteOnce" ]
}

@test "pvc carries Prune=false to resist accidental prune" {
  run yq '.metadata.annotations."argocd.argoproj.io/sync-options"' "$PVC"
  [ "$output" = "Prune=false" ]
}
```

**Step 2-2:** 실패 확인.

**Step 2-3:** `pvc.yaml`(cnpg basebackup-pvc.yaml 미러 + Prune=false):
```yaml
# 사용자 파일 저장 — 2TB 외장 SSD(bulk-ssd, virtiofs). storageClassName 명시 필수(opt-in;
# 누락 시 standard=VM 디스크로 조용히 착지). Prune=false + (라이브)PV-Retain 패치로 삭제민감 데이터 보호.
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: files-data
  namespace: files
  annotations:
    argocd.argoproj.io/sync-options: Prune=false
spec:
  accessModes: ["ReadWriteOnce"]
  storageClassName: bulk-ssd
  resources:
    requests:
      storage: 100Gi
```

**Step 2-4:** `bats platform/files/prod/test_files_storage.bats` PASS.

**Step 2-5 (Commit):**
```bash
git add platform/files/prod/pvc.yaml platform/files/prod/test_files_storage.bats
git commit -m "feat: files-data PVC(bulk-ssd 100Gi RWO, Prune=false)"
```

---

### Task 3: SealedSecrets 봉인 스크립트 (keys 레지스트리 + files-ns ghcr-pull)

**Files:**
- Create: `scripts/seal-files-secrets.sh`
- Modify: `Makefile` (타겟 `seal-files-secrets`)
- Create: `platform/files/prod/test_files_secrets.bats`
- (🔒 owner 산출) `platform/files/prod/files-keys.sealed.yaml`, `platform/files/prod/ghcr-pull.sealed.yaml`

**Step 3-1:** `scripts/seal-files-secrets.sh` — keys 레지스트리 JSON + files-ns ghcr-pull 둘 다 봉인. 평문은 stdin으로만, 출력 안 함.
```bash
#!/usr/bin/env bash
# files 컴포넌트 SealedSecret 2종 봉인(owner-local):
#   1) files-keys      : API 키 레지스트리 JSON(keys.json) — secret 파일마운트용
#   2) ghcr-pull(files): private GHCR pull dockerconfigjson(files ns 전용; prod 것은 strict-scope라 재사용 불가)
# 사용: set -a; . .env.secrets; set +a; make seal-files-secrets
#   .env.secrets 필요: GHCR_PULL_TOKEN(read:packages), FILES_KEYS_JSON(키 레지스트리 JSON 한 줄)
# 평문/해시는 stdout/로그에 절대 출력하지 않는다 — 봉인 파일만 산출.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; cd "$ROOT"
CERT="tools/sealed-secrets-cert.pem"
NS="files"
: "${GHCR_PULL_TOKEN:?set GHCR_PULL_TOKEN in .env.secrets}"
: "${FILES_KEYS_JSON:?set FILES_KEYS_JSON in .env.secrets (키 레지스트리 JSON)}"
# 봉인 전 keys.json 계약 검증(camelCase·필수필드) — 오타/snake_case 조기 차단(발견 #11)
printf '%s' "$FILES_KEYS_JSON" | jq -e 'type=="array" and all(.[]; has("id") and has("sha256") and has("service"))' >/dev/null \
  || { echo "seal-files-secrets: FILES_KEYS_JSON 형식 오류(배열·id/sha256/service 필수)" >&2; exit 1; }
[ -f "$CERT" ] || { echo "seal-files-secrets: $CERT 없음" >&2; exit 1; }
command -v kubeseal >/dev/null || { echo "kubeseal 필요" >&2; exit 1; }

# 1) files-keys: keys.json을 stringData 단일 키로 → 파일마운트
printf 'apiVersion: v1\nkind: Secret\nmetadata:\n  name: files-keys\n  namespace: %s\ntype: Opaque\nstringData:\n  keys.json: |\n%s\n' \
  "$NS" "$(printf '%s' "$FILES_KEYS_JSON" | sed 's/^/    /')" \
  | kubeseal --cert "$CERT" --scope strict --format yaml > platform/files/prod/files-keys.sealed.yaml

# 2) files-ns ghcr-pull dockerconfigjson
user="$(gh api user --jq .login)"
kubectl create secret docker-registry ghcr-pull \
  --docker-server=ghcr.io --docker-username="$user" --docker-password="$GHCR_PULL_TOKEN" \
  --namespace "$NS" --dry-run=client -o yaml \
  | kubeseal --cert "$CERT" --scope strict --format yaml > platform/files/prod/ghcr-pull.sealed.yaml

echo "sealed -> platform/files/prod/{files-keys,ghcr-pull}.sealed.yaml (ns=$NS, scope=strict)"
```

**Step 3-2:** `Makefile`에 타겟 추가(seal-ghcr-pull 근처):
```make
seal-files-secrets: secret-cert-check ## files 컴포넌트 SealedSecret 2종 봉인(owner-local)
	bash scripts/seal-files-secrets.sh
```

**Step 3-3 (bats):** `test_files_secrets.bats` — 봉인 파일이 존재하면 평문 부재 + kustomization 포함을 검증(파일 부재 시 skip).
```bash
#!/usr/bin/env bats
D="$BATS_TEST_DIRNAME"

@test "files-keys sealed secret has no plaintext data field" {
  [ -f "$D/files-keys.sealed.yaml" ] || skip "not sealed yet (owner-local)"
  run yq '.spec.encryptedData."keys.json" != null and .spec.template.type == "Opaque"' "$D/files-keys.sealed.yaml"
  [ "$output" = "true" ]
  # 발견 #3 수정: grep '[^n]data:'는 'metadata:'를 오탐 → 구조적 yq로 평문(data/stringData) 부재 검증
  run yq '(.data == null) and (.stringData == null) and ((.spec.template.data // null) == null) and ((.spec.template.stringData // null) == null)' "$D/files-keys.sealed.yaml"
  [ "$output" = "true" ]
}

@test "ghcr-pull sealed secret targets files namespace" {
  [ -f "$D/ghcr-pull.sealed.yaml" ] || skip "not sealed yet (owner-local)"
  run yq '.spec.template.metadata.namespace // .metadata.namespace' "$D/ghcr-pull.sealed.yaml"
  [ "$output" = "files" ]
}
```

**Step 3-4:** `bats platform/files/prod/test_files_secrets.bats` — 봉인 전이라 skip PASS. shellcheck 스크립트.

**Step 3-5 (Commit):**
```bash
git add scripts/seal-files-secrets.sh Makefile platform/files/prod/test_files_secrets.bats
git commit -m "feat: files SealedSecret 봉인 스크립트(keys 레지스트리 + files-ns ghcr-pull)"
```

**Step 3-6 (🔒 OWNER-LOCAL, 배포 전):** `.env.secrets`에 `FILES_KEYS_JSON`(admin 키 최소 1개; sha256=토큰의 SHA-256) + `GHCR_PULL_TOKEN` 채우고 `make seal-files-secrets` → 산출된 2개 `*.sealed.yaml`을 커밋. **keys.json 스키마는 앱 계약**(`ukyi-app/files` `src/auth.rs`의 `ApiKey` 필드: `id, sha256, service, write_buckets, read_buckets, admin`)을 따를 것 — 예:
```json
[
  {"id":"admin","sha256":"<sha256(admin-token)>","service":"ops","admin":true},
  {"id":"page","sha256":"<sha256(page-token)>","service":"page","writeBuckets":["skills"],"readBuckets":["skills"]}
]
```

---

### Task 4: Deployment

**Files:**
- Create: `platform/files/prod/deployment.yaml`
- Create: `platform/files/prod/test_files_deployment.bats`

**Step 4-1 (bats):** `test_files_deployment.bats`:
```bash
#!/usr/bin/env bats
D="$BATS_TEST_DIRNAME/deployment.yaml"

@test "deployment uses Recreate strategy (RWO PVC)" {
  run yq '.spec.strategy.type' "$D"; [ "$output" = "Recreate" ]
}
@test "container is restricted: readOnlyRootFilesystem + drop ALL + non-root" {
  run yq '.spec.template.spec.containers[0].securityContext.readOnlyRootFilesystem' "$D"; [ "$output" = "true" ]
  run yq '.spec.template.spec.containers[0].securityContext.capabilities.drop[0]' "$D"; [ "$output" = "ALL" ]
  run yq '.spec.template.spec.securityContext.runAsNonRoot' "$D"; [ "$output" = "true" ]
}
@test "pod fsGroup 65532 lets non-root write /data" {
  run yq '.spec.template.spec.securityContext.fsGroup' "$D"; [ "$output" = "65532" ]
}
@test "two container ports 8080 and 8081" {
  run yq '[.spec.template.spec.containers[0].ports[].containerPort] | sort | join(",")' "$D"
  [ "$output" = "8080,8081" ]
}
@test "keys secret is mounted as a FILE, not envFrom" {
  run yq '.spec.template.spec.containers[0].volumeMounts[] | select(.mountPath=="/etc/files-keys") | .readOnly' "$D"
  [ "$output" = "true" ]
  run yq '.spec.template.spec.containers[0].envFrom' "$D"; [ "$output" = "null" ]
}
@test "FILES_KEYS_PATH points at the mounted file" {
  run yq '.spec.template.spec.containers[0].env[] | select(.name=="FILES_KEYS_PATH") | .value' "$D"
  [ "$output" = "/etc/files-keys/keys.json" ]
}
@test "resource requests(cpu+mem) + memory limit present (CI gate)" {
  run yq '.spec.template.spec.containers[0].resources.requests.cpu' "$D"; [ -n "$output" ] && [ "$output" != "null" ]
  run yq '.spec.template.spec.containers[0].resources.requests.memory' "$D"; [ "$output" != "null" ]
  run yq '.spec.template.spec.containers[0].resources.limits.memory' "$D"; [ "$output" != "null" ]
}
@test "imagePullSecrets ghcr-pull + no SA token" {
  run yq '.spec.template.spec.imagePullSecrets[0].name' "$D"; [ "$output" = "ghcr-pull" ]
  run yq '.spec.template.spec.automountServiceAccountToken' "$D"; [ "$output" = "false" ]
}
@test "probes hit internal :8080 (public :8081 has no health handler)" {
  run yq '.spec.template.spec.containers[0].readinessProbe.httpGet.port' "$D"; [ "$output" = "internal" ]
  run yq '.spec.template.spec.containers[0].livenessProbe.httpGet.path' "$D"; [ "$output" = "/healthz" ]
}
@test "image is digest-pinned (@sha256:) — immutable, not a bare mutable tag" {
  run yq '.spec.template.spec.containers[0].image' "$D"
  [[ "$output" == *"@sha256:"* ]]
}
```

**Step 4-2:** 실패 확인.

**Step 4-3:** `deployment.yaml`:
```yaml
# files 파일 스토어 — 단일 파드 2리스너. 이미지는 kustomization.yaml images:로 핀(Task 8).
# securityContext는 trip-mate(restricted) + fsGroup(adguard) 복제. 쓰기는 /data(PVC)·/tmp(emptyDir)뿐.
apiVersion: apps/v1
kind: Deployment
metadata:
  name: files
  labels:
    app.kubernetes.io/name: files
spec:
  replicas: 1
  strategy: { type: Recreate }   # RWO PVC — 단일 노드, 신구 파드 볼륨 교착 회피
  selector:
    matchLabels: { app.kubernetes.io/name: files }
  template:
    metadata:
      labels: { app.kubernetes.io/name: files }
    spec:
      automountServiceAccountToken: false   # k8s API 미사용
      imagePullSecrets: [{ name: ghcr-pull }]   # private GHCR
      securityContext:
        runAsNonRoot: true
        runAsUser: 65532          # distroless nonroot
        runAsGroup: 65532
        fsGroup: 65532            # 비루트의 RWO /data 쓰기 허용
        seccompProfile: { type: RuntimeDefault }
      containers:
        - name: files
          image: ghcr.io/ukyi-app/files:sha-<GITSHA>@sha256:<DIGEST>   # 태그+digest 인라인 핀(불변). Step 9-3에서 실제값 치환
          ports:
            - { name: internal, containerPort: 8080 }
            - { name: public, containerPort: 8081 }
          env:
            - { name: FILES_DATA_DIR, value: /data }
            - { name: FILES_KEYS_PATH, value: /etc/files-keys/keys.json }
            - { name: FILES_INTERNAL_PORT, value: "8080" }
            - { name: FILES_PUBLIC_PORT, value: "8081" }
            - { name: FILES_PUBLIC_BASE_URL, value: "https://files.ukyi.app" }
          resources:
            requests: { cpu: 25m, memory: 32Mi }
            limits: { memory: 128Mi }   # cpu limit 미설정(CFS throttling 회피 — 홈랩 규약)
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities: { drop: ["ALL"] }
          livenessProbe:
            httpGet: { path: /healthz, port: internal }
            initialDelaySeconds: 5
            periodSeconds: 10
          readinessProbe:
            # /readyz = /data 실제 write 프로브 + free-space 확인 → 스토리지 저하 시 NotReady
            httpGet: { path: /readyz, port: internal }
            initialDelaySeconds: 3
            periodSeconds: 5
          volumeMounts:
            - { name: keys, mountPath: /etc/files-keys, readOnly: true }
            - { name: data, mountPath: /data }
            - { name: tmp, mountPath: /tmp }
      volumes:
        - name: keys
          secret:
            secretName: files-keys
            items: [{ key: keys.json, path: keys.json }]
        - name: data
          persistentVolumeClaim: { claimName: files-data }
        - name: tmp
          emptyDir: {}
```

**Step 4-4:** `bats platform/files/prod/test_files_deployment.bats` PASS + `bash scripts/check-resource-limits.sh` PASS.

**Step 4-5:** 메모리 원장 행 추가(Deployment 예산 동반) — `docs/memory-ledger.md` 표에:
```
| <!-- ledger:row --> files          | files          |     32 |      128 |
```
**합계 라인 갱신**: `limit ≈ 8764` → `8892`, `req ≈ 4719` → `4751`. ≤ 9216 확인 → `bun run verify:ledger` PASS.

**Step 4-6 (Commit):**
```bash
git add platform/files/prod/deployment.yaml platform/files/prod/test_files_deployment.bats docs/memory-ledger.md
git commit -m "feat: files Deployment(2리스너·restricted·fsGroup·secret 파일마운트) + 원장 행"
```

---

### Task 5: Services (internal + public)

**Files:**
- Create: `platform/files/prod/service.yaml`
- Create: `platform/files/prod/test_files_service.bats`

**Step 5-1 (bats):**
```bash
#!/usr/bin/env bats
S="$BATS_TEST_DIRNAME/service.yaml"

@test "files-internal Service exposes 8080 → internal port" {
  run yq ea 'select(.metadata.name=="files-internal") | .spec.ports[0].port' "$S"; [ "$output" = "8080" ]
  run yq ea 'select(.metadata.name=="files-internal") | .spec.ports[0].targetPort' "$S"; [ "$output" = "internal" ]
}
@test "files-public Service exposes 8081 → public port" {
  run yq ea 'select(.metadata.name=="files-public") | .spec.ports[0].port' "$S"; [ "$output" = "8081" ]
  run yq ea 'select(.metadata.name=="files-public") | .spec.ports[0].targetPort' "$S"; [ "$output" = "public" ]
}
```

**Step 5-2:** 실패 확인.

**Step 5-3:** `service.yaml`(adguard 2-Service-in-one-file 미러):
```yaml
# internal(write/admin API)과 public(읽기전용 다운로드)을 물리적으로 다른 Service로 분리 —
# 각 HTTPRoute가 정확한 포트를 겨냥, 표면 분리 가시화.
apiVersion: v1
kind: Service
metadata: { name: files-internal, namespace: files }
spec:
  selector: { app.kubernetes.io/name: files }
  ports: [{ name: internal, port: 8080, targetPort: internal }]
---
apiVersion: v1
kind: Service
metadata: { name: files-public, namespace: files }
spec:
  selector: { app.kubernetes.io/name: files }
  ports: [{ name: public, port: 8081, targetPort: public }]
```

**Step 5-4:** bats PASS.

**Step 5-5 (Commit):**
```bash
git add platform/files/prod/service.yaml platform/files/prod/test_files_service.bats
git commit -m "feat: files Service 2종(internal 8080 / public 8081)"
```

---

### Task 6: HTTPRoute 2개 (internal + public) + 표면 경계 가드

**Files:**
- Create: `platform/files/prod/httproute-internal.yaml`
- Create: `platform/files/prod/httproute-public.yaml`
- Create: `platform/files/prod/test_files_route.bats`

**Step 6-1 (bats):**
```bash
#!/usr/bin/env bats
I="$BATS_TEST_DIRNAME/httproute-internal.yaml"
P="$BATS_TEST_DIRNAME/httproute-public.yaml"

@test "internal route: web-internal-tls, files.home host, backend files-internal:8080" {
  run yq '.spec.parentRefs[0].sectionName' "$I"; [ "$output" = "web-internal-tls" ]
  run yq '.spec.hostnames[0]' "$I"; [ "$output" = "files.home.ukyi.app" ]
  run yq '.spec.rules[0].backendRefs[0].port' "$I"; [ "$output" = "8080" ]
}
@test "internal route parentRefs spell out group/kind (SSA atomic-list guard)" {
  run yq '.spec.parentRefs[0].group' "$I"; [ "$output" = "gateway.networking.k8s.io" ]
  run yq '.spec.parentRefs[0].kind' "$I"; [ "$output" = "Gateway" ]
}
@test "public route: web-public, files.ukyi.app host" {
  run yq '.spec.parentRefs[0].sectionName' "$P"; [ "$output" = "web-public" ]
  run yq '.spec.hostnames[0]' "$P"; [ "$output" = "files.ukyi.app" ]
}
@test "PUBLIC BOUNDARY: public route backend is files-public:8081, NEVER 8080" {
  run yq '.spec.rules[0].backendRefs[0].port' "$P"; [ "$output" = "8081" ]
  run yq '.spec.rules[0].backendRefs[0].name' "$P"; [ "$output" = "files-public" ]
}
@test "PUBLIC BOUNDARY: public route matches GET only (defense-in-depth)" {
  run yq '.spec.rules[0].matches[0].method' "$P"; [ "$output" = "GET" ]
}
```

**Step 6-2:** 실패 확인.

**Step 6-3:** `httproute-internal.yaml`(adguard httproute 미러):
```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata: { name: files-internal, namespace: files }
spec:
  parentRefs:
    # group/kind 명시 — SSA atomic 리스트 영구 OutOfSync 회피
    - group: gateway.networking.k8s.io
      kind: Gateway
      name: homelab
      namespace: gateway
      sectionName: web-internal-tls   # *.home.ukyi.app 와일드카드 cert, tailscale 경유
  hostnames: ["files.home.ukyi.app"]
  rules:
    - matches: [{ path: { type: PathPrefix, value: / } }]   # 전체 /api + /healthz + /readyz
      backendRefs:
        - { group: "", kind: Service, name: files-internal, port: 8080, weight: 1 }
```

**Step 6-4:** `httproute-public.yaml`(argocd-webhook web-public 미러 + method GET):
```yaml
# 공개 표면: files.ukyi.app → files-public:8081(읽기전용 리스너). Gateway core는 /{bucket}/{key}
# 경로 템플릿 불가라 경계는 앱 :8081 프로세스가 유일(/api 핸들러 물리 부재) — method:GET로 방어심화.
# ⚠️ backendRef.port는 절대 8080 금지(write/admin API 인터넷 노출). test_files_route.bats가 강제.
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata: { name: files-public, namespace: files }
spec:
  parentRefs:
    - group: gateway.networking.k8s.io
      kind: Gateway
      name: homelab
      namespace: gateway
      sectionName: web-public   # *.ukyi.app, plaintext(edge-TLS), cloudflared 터널
  hostnames: ["files.ukyi.app"]
  rules:
    - matches: [{ path: { type: PathPrefix, value: / }, method: GET }]
      backendRefs:
        - { group: "", kind: Service, name: files-public, port: 8081, weight: 1 }
```

**Step 6-5:** bats PASS.

**Step 6-6 (Commit):**
```bash
git add platform/files/prod/httproute-internal.yaml platform/files/prod/httproute-public.yaml platform/files/prod/test_files_route.bats
git commit -m "feat: files HTTPRoute 2종(internal web-internal-tls / public web-public GET·8081)"
```

---

### Task 7: NetworkPolicy (자기격리)

**Files:**
- Create: `platform/files/prod/networkpolicy.yaml`
- Create: `platform/files/prod/test_files_netpol.bats`

**Step 7-1 (bats):**
```bash
#!/usr/bin/env bats
N="$BATS_TEST_DIRNAME/networkpolicy.yaml"

@test "default-deny-egress present for files pod" {
  run yq ea 'select(.metadata.name=="files-default-deny-egress") | .spec.policyTypes[0]' "$N"; [ "$output" = "Egress" ]
  run yq ea 'select(.metadata.name=="files-default-deny-egress") | .spec.egress' "$N"; [ "$output" = "null" ]
}
@test "DNS egress allowed to kube-dns only" {
  run yq ea 'select(.metadata.name=="files-allow-dns-egress") | .spec.egress[0].to[0].namespaceSelector.matchLabels."kubernetes.io/metadata.name"' "$N"
  [ "$output" = "kube-system" ]
}
@test "NO DB/cache egress (security payoff of dedicated ns)" {
  run grep -c "5432\|6379" "$N"; [ "$output" = "0" ]
}
@test "ingress from gateway on BOTH 8080 and 8081" {
  run yq ea 'select(.metadata.name=="files-allow-ingress-from-gateway") | [.spec.ingress[0].ports[].port] | sort | join(",")' "$N"
  [ "$output" = "8080,8081" ]
}
@test "no pod-CIDR ipBlock (deny-nullifying trap)" {
  run grep -c "10.42\." "$N"; [ "$output" = "0" ]
}
```

**Step 7-2:** 실패 확인.

**Step 7-3:** `networkpolicy.yaml`(adguard self-isolation 패턴; DB/cache egress 없음):
```yaml
# files 워크로드 자기격리(컴포넌트 내부 소유 — cross-app 싱크 레이스 회피, adguard 패턴).
# egress=DNS만(파일스토어는 DB/캐시/외부 불요). ingress=gateway ns에서 8080·8081만(intra-ns :8080 없음
# → write/admin API를 형제 앱에서 도달 불가). pod-CIDR ipBlock 금지.
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: { name: files-default-deny-egress, namespace: files }
spec:
  podSelector: { matchLabels: { app.kubernetes.io/name: files } }
  policyTypes: [Egress]
  # egress 규칙 없음 => 전 egress 거부(아래 DNS만 재개방)
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: { name: files-allow-dns-egress, namespace: files }
spec:
  podSelector: { matchLabels: { app.kubernetes.io/name: files } }
  policyTypes: [Egress]
  egress:
    - to:
        - namespaceSelector: { matchLabels: { kubernetes.io/metadata.name: kube-system } }
          podSelector: { matchLabels: { k8s-app: kube-dns } }
      ports:
        - { protocol: UDP, port: 53 }
        - { protocol: TCP, port: 53 }
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: { name: files-allow-ingress-from-gateway, namespace: files }
spec:
  podSelector: { matchLabels: { app.kubernetes.io/name: files } }
  policyTypes: [Ingress]
  ingress:
    - from:
        - namespaceSelector: { matchLabels: { kubernetes.io/metadata.name: gateway } }
      ports:
        - { protocol: TCP, port: 8080 }   # internal(files.home.ukyi.app, tailscale→traefik)
        - { protocol: TCP, port: 8081 }   # public(files.ukyi.app, cloudflared→traefik)
```

**Step 7-4:** bats PASS.

**Step 7-5 (Commit):**
```bash
git add platform/files/prod/networkpolicy.yaml platform/files/prod/test_files_netpol.bats
git commit -m "feat: files NetworkPolicy(자기격리·DNS만·gateway ingress 8080·8081)"
```

---

### Task 8: kustomization + 이미지 핀 + 전체 렌더

**Files:**
- Create: `platform/files/prod/kustomization.yaml`

**Step 8-1:** `kustomization.yaml`(adguard 미러; 이미지는 Task 4 deployment.yaml에 인라인 핀):
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: files   # files-prod Application의 권위 대상 namespace(appset destination.namespace 부재)
resources:
  - pvc.yaml
  - files-keys.sealed.yaml
  - ghcr-pull.sealed.yaml
  - deployment.yaml
  - service.yaml
  - httproute-internal.yaml
  - httproute-public.yaml
  - networkpolicy.yaml
# 이미지는 deployment.yaml에 repo:sha-<gitsha>@sha256:<digest> 인라인 핀(태그+digest 불변, 홈랩
# first-party 규약; 설계 §9의 "kustomize images" 기법을 인라인으로 정정 — kustomize images는 newTag+
# digest 동시 지정 불가). bump-poll 미적용(apps/ 전용) → 릴리스마다 deployment.yaml 이미지 라인 갱신 PR.
```

**Step 8-1b:** [발견 #10] `README.md` 디렉토리 지도에 files 행 추가(`check-skeleton.sh:42-45`가 모든 `platform/*/`를 README에서 grep 강제 — 누락 시 skeleton 게이트 FAIL). 기존 컴포넌트 표(`| adguard | ... |` 근처)에:
```
| `files` | 자기-호스팅 파일 스토어 — internal API 업로드 + public 다운로드/카탈로그(bulk-ssd) |
```

**Step 8-2 (자동 검증 — 봉인 전 가능):** [발견 #2 수정] `kustomize build`는 sealed 파일 2개(owner-local 산출)가 있어야 성공하므로, 자동 단계에서는 **비-secret 매니페스트를 파일별 kubeconform** + bats + 게이트로 검증한다. 전체 `kustomize build` 게이트는 봉인 후 owner-local(Task 9-2.5)로 이동.
```bash
# 파일별 검증(봉인 파일 불요) — PVC/Deployment/Service/HTTPRoute×2/NetworkPolicy
for f in pvc deployment service httproute-internal httproute-public networkpolicy; do
  kubeconform -strict -ignore-missing-schemas -schema-location default "platform/files/prod/$f.yaml"
done
bats platform/files/prod/            # 봉인 미완 → secret 테스트는 skip
bash scripts/check-resource-limits.sh
bun run verify:ledger
make verify                          # [발견 #10] skeleton(README 지도) + 원장 + sops
```
Expected: 파일별 kubeconform PASS(HTTPRoute는 CRD → ignore-missing), bats PASS(secret skip), 게이트 PASS(skeleton 포함). **전체 kustomize build는 Task 9-2.5(봉인 후)에서.**

**Step 8-3 (bats 러너 확인):** platform 컴포넌트 bats가 CI `gate`에 포함되는지 확인 — adguard bats(`test_adguard_*.bats`)가 어떻게 실행되는지 grep:
```bash
grep -rn "test_adguard\|platform.*\.bats\|run-bats" scripts/ Makefile .github/workflows/ | head
```
→ files bats가 같은 경로로 발견되게(디렉토리 스캔/러너 목록) 필요 시 러너에 `platform/files/prod` 추가.

**Step 8-4 (Commit):**
```bash
git add platform/files/prod/kustomization.yaml README.md
git commit -m "feat: files kustomization + README 디렉토리 지도 등재"
```

---

### Task 9: 🔒 OWNER-LOCAL — 봉인·PR-A·라이브검증·PV-Retain

**Step 9-1:** Phase 0 완료 확인(이미지 존재, .env.secrets 채움).

**Step 9-2:** 봉인: `make seal-files-secrets` → `files-keys.sealed.yaml`·`ghcr-pull.sealed.yaml` 커밋. `bats platform/files/prod/test_files_secrets.bats` 이제 실제 PASS.

**Step 9-2.5 (전체 렌더 게이트 — 봉인 후 필수):** [발견 #2] 이제 sealed 파일이 존재하므로 전체 kustomize build로 최종 검증(PR-A 열기 전):
```bash
kustomize build --enable-helm --enable-alpha-plugins --enable-exec platform/files/prod > /tmp/files-render.yaml
kubeconform -strict -ignore-missing-schemas -schema-location default /tmp/files-render.yaml   # 8 리소스 + 봉인 2
bats platform/files/prod/    # secret 테스트도 이제 실제 PASS
```

**Step 9-3:** 이미지 핀 갱신: `deployment.yaml`의 `ghcr.io/ukyi-app/files:sha-<GITSHA>@sha256:<DIGEST>`를 Phase 0의 실제 SHA+digest로 치환. **가드**: `! grep -q '<' platform/files/prod/deployment.yaml`(플레이스홀더 잔존 0) + 이미지에 `@sha256:` 존재 확인(불변 핀).

**Step 9-4:** PR-A 열기(브랜치 → main). `gate` 통과 확인 후 머지(홈랩 규약: PR-first).
```bash
git push -u origin worktree-files-deploy
gh pr create --base main --title "feat: files 파일스토어 배포(PR-A internal)" --body "..."
```

**Step 9-5 (배포 + PV-Retain 먼저, KUBECONFIG 필요):** [발견 #4] 머지 후 ArgoCD 싱크 → **데이터를 쓰기 전에 PV-Retain을 먼저 적용**(Bound~Retain 창의 데이터 손실 방지).
```bash
export KUBECONFIG=$PWD/infra/k3s-bootstrap/kubeconfig
kubectl -n files get pvc files-data          # STATUS Bound 대기
kubectl -n files get pod -l app.kubernetes.io/name=files   # Running + READY 1/1
# ★ PV-Retain을 스모크 쓰기·사용자 트래픽 전에 먼저(bulk-ssd Delete 클래스 데이터 가드):
PV=$(kubectl -n files get pvc files-data -o jsonpath='{.spec.volumeName}')
kubectl patch pv "$PV" -p '{"spec":{"persistentVolumeReclaimPolicy":"Retain"}}'
kubectl get pv "$PV" -o jsonpath='{.spec.persistentVolumeReclaimPolicy}'   # => Retain (게이트: Retain 확인 전 쓰기 금지)
```
※ out-of-GitOps라 VM 재구축 후 재적용 필요 — DR 런북 등재. 물리 SSD 고장은 미방어(설계 §5 수용 잔여). **롤백 규율**: Retain 적용 전이면 사용자 데이터 쓰지 말 것(먼저 revert/비활성).
※ [발견 #6] **불가피한 프리-Retain 창**: `WaitForFirstConsumer`는 PVC 바인딩을 파드 스케줄에 결합하므로 "파드 전 PVC 바인딩·Retain"이 물리적으로 불가(codex 처방 replicas 0은 소비자 부재→PVC 미바인딩→패치할 PV 없음이라 실행 불가). 파드 기동~Retain 사이 write는 **빈 구조 디렉토리(`.objects`)·일시 readyz 프로브뿐 — 사용자 데이터 0**(사용자/스모크 write는 위 게이트로 Retain 후). 즉 이 창의 손실 노출은 빈 PV뿐이며, 위 순서(Bound 직후 즉시 Retain)로 최소화된다.

**Step 9-6 (실제 write 라이브검증 — Retain 확인 후):** 스토리지 라이브 증명(readyz/CrashLoop만 믿지 말 것).
```bash
TOKEN=<admin-token>
curl -fsS -X PUT -H "Authorization: Bearer $TOKEN" -H "Content-Type: text/plain" \
  --data "hello-files" https://files.home.ukyi.app/api/files/smoke/hello.txt
curl -fsS -H "Authorization: Bearer $TOKEN" https://files.home.ukyi.app/api/files/smoke/hello.txt   # == hello-files
curl -fsS https://files.home.ukyi.app/readyz    # 200
```
※ 파드 CrashLoop(build_state가 `/data/.objects` 생성 실패)거나 readyz 503이면 **virtiofs fsGroup 미존중** → 프로비저너 `mkdir -m 0777`로 대개 정상이나, 문제 시 트러블슈팅(설계 §5; root initContainer는 restricted 위반이라 금지 — provisioner/mount 레벨에서 해결).

---

## PR-B (public) — files.ukyi.app 인터넷 노출

### Task 10: apps.json + public 라이브검증

**Files:**
- Modify: `infra/cloudflare/apps.json`

**Step 10-1:** `apps.json`에 files 엔트리 추가(스키마 `[{name, host, public, active}]`):
```json
{ "name": "files", "host": "files.ukyi.app", "public": true, "active": true }
```

**Step 10-2 (Commit):**
```bash
git add infra/cloudflare/apps.json
git commit -m "feat: files.ukyi.app 공개 노출(apps.json — PR-B)"
```

**Step 10-3 (🔒 OWNER-LOCAL):** PR-B 머지 → `iac.yaml`(push apply) 또는 `tf-reconcile`가 proxied CNAME + tunnel ingress 배선(cloudflared ConfigMap 편집 불요). terraform apply가 `cloudflare_dns_record.app` + tunnel ingress 생성.

**Step 10-4 (라이브검증):** public 버킷 하나를 만들고 다운로드 + 공개 표면 `/api` 404 증명.
```bash
# admin으로 public 버킷 생성 + 파일 업로드(internal 경유)
curl -fsS -X PUT -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  --data '{"visibility":"public"}' https://files.home.ukyi.app/api/buckets/downloads
curl -fsS -X PUT -H "Authorization: Bearer $TOKEN" --data-binary @some.zip \
  https://files.home.ukyi.app/api/files/downloads/some.zip
# public 다운로드 (GET-only 라우트 — HEAD 대신 GET으로 헤더 캡처, 발견 #5)
curl -fsS -D - -o /dev/null https://files.ukyi.app/downloads/some.zip   # 200 + Content-Disposition: attachment + X-Content-Type-Options: nosniff
curl -fsS https://files.ukyi.app/ | grep downloads       # 카탈로그에 노출
# 공개 표면에 write/admin 부재 증명
curl -s -o /dev/null -w "%{http_code}" https://files.ukyi.app/api/files/downloads/some.zip   # 404
curl -s -o /dev/null -w "%{http_code}" -X PUT https://files.ukyi.app/api/files/downloads/x    # 404/405
```

---

## OWNER 체크리스트 (🔒 배포 시 owner 수행)

1. Phase 0: files 앱 main 머지 + release.yaml로 `ghcr.io/ukyi-app/files:sha-<gitsha>` 빌드, SHA/digest 확보.
2. **PR-A0(ns) 먼저 머지 → `kubectl get ns files`로 restricted 라이브 확인**(발견 #1).
3. `.env.secrets`: `FILES_KEYS_JSON`(admin 키), `GHCR_PULL_TOKEN`. `make seal-files-secrets` → 봉인 2파일 커밋 → **전체 `kustomize build` 게이트 통과 확인**(발견 #2).
4. `kustomization.yaml` `newTag`를 실제 SHA로.
5. PR-A(컴포넌트) 머지 → ArgoCD 싱크 → PVC Bound → **PV-Retain 먼저** → 실제 PUT→GET 라이브검증.
6. PR-B 머지 → terraform apply → public 다운로드 + `/api` 404 검증.

## Fast-follow (별도, 배포 비차단)

- **files 앱 레포 (SIGTERM, 발견 #14)**: `main.rs`가 `ctrl_c`(SIGINT)만 트랩 → k8s SIGTERM 미처리. 롤아웃/축출 시 진행중 업로드 중단(**손상 아님** — atomic+reconciliation; 클라이언트 실패→재시도). **PR-B 공개와 무관**: public 리스너(:8081)는 **다운로드 전용**이라 업로드 중단 노출 0 — 중단은 internal 업로더(자기 서비스)에만. Recreate+RWO라 긴 `terminationGracePeriodSeconds`는 롤아웃 다운타임을 유발해 부적절 → **깔끔한 해법은 앱-측 SIGTERM graceful drain**(`tokio::signal::unix::SignalKind::terminate()`; 새 요청 차단→in-flight 완료→종료). 내부 업로드 의존이 커지기 전 fast-follow 권장(배포 비차단).
- 이미지 빈도 아프면 files 전용 격리 bump 미니워크플로(공유 `apps/` 파이프라인 불변경).

## 검증 요약 (Definition of Done)

- [ ] PR-A0: files ns restricted 라이브(`kubectl get ns files`).
- [ ] PR-A: 8 매니페스트 + 봉인 2 전체 `kustomize build` 성공, 전 bats PASS, check-resource-limits·verify:ledger PASS, `gate` green.
- [ ] 라이브: PVC Bound, 파드 Ready 1/1, **실제 PUT→GET 왕복 성공**, readyz 200, PV Retain.
- [ ] PR-B: files.ukyi.app 다운로드 200(attachment·nosniff), 카탈로그 노출, 공개 `/api` 404.

## Adversarial review dispositions (codex, 5 passes, 2026-07-01)

5패스 진행. HIGH 발견이 "GitOps 파손(구조)"→"절차 정밀도(폴리시)"로 수렴, 아키텍처 이슈 0. 최종 pass 5 `verdict: needs-attention`(codex 적대적 특성상 폴리시는 계속 나옴) — 사용자 결정으로 **수렴 지점에서 확정**. 실질 발견 전부 반영.

| # | pass | 발견 | 판정 | 반영 |
|---|---|---|---|---|
| 1 | 1 | 단일 PR-A가 ns 경합("namespace not found" 교착) | Accept | ns를 선행 PR-A0로 분리(Task 1) |
| 2 | 1 | 봉인 파일 전 전체 kustomize build 불가 | Accept | 자동=파일별 kubeconform, 전체 build는 봉인 후(Task 8-2·9-2.5) |
| 3 | 1 | sealed 평문 grep이 `metadata:` 오탐 | Accept | 구조적 yq 체크(Task 3) |
| 4 | 2 | PV-Retain을 쓰기 후 적용 | Accept | Bound 직후·PUT 전으로 이동(Task 9-5) |
| 5 | 2 | public smoke HEAD가 GET-only 라우트 미매치 | Accept | GET 헤더 캡처(`curl -D -`)(Task 10-4) |
| 6 | 3 | 파드 기동 write가 PV-Retain 전 | Accept(부분) | 불가피 창 명시(WaitForFirstConsumer·빈 구조 write뿐·사용자 데이터 post-Retain)(Task 9-5) |
| 7 | 3 | PR-A0가 `platform/files/prod/` 조기 생성→appset 파손 | Accept | ns 테스트를 appset-제외 `platform/namespaces/prod/`로(Task 1) |
| 8 | 3 | test_psa.bats ns 개수 9 하드코딩 | Accept | 9→10 갱신(Task 1-3.5) |
| 9 | 4 | 이미지 digest 누락(가변 태그) | Accept | deployment.yaml 인라인 `repo:tag@digest` + `@sha256:` bats 가드(Task 4·8) |
| 10 | 4 | README skeleton 게이트 미갱신 | Accept | README 디렉토리 지도 files 행 + `make verify`(Task 8-1b) |
| 11 | 4 | keys.json casing skew | Accept | auth.rs `rename_all=camelCase` 확인→`writeBuckets`/`readBuckets` + 봉인 전 jq 검증(Task 3) |
| 12 | 5 | Phase 0 이미지 provenance 부정확(`.[0]`) | Accept | APP_SHA(앱 main commit)+`crane digest`로 정밀화(Step 0-1) |
| 13 | 5 | pull secret 자격 혼합(gh user↔token) | Accept(부분) | username 주장 기각(prod 미러·GHCR PAT 토큰 인증), pull 사전검증 추가(Step 0-4) |
| 14 | 5 | SIGTERM 업로드 중단 연기 | Accept(부분) | PR-B 게이팅 기각(public=다운로드 전용), 잔여 노트 정밀화 + 앱-측 drain fast-follow |

## Execution directives
- **Skill:** implement via `executing-plans` in a **separate session, in this worktree**(`.claude/worktrees/files-deploy`).
- **Run continuously:** 배치 사이에서 루틴 리뷰로 멈추지 말 것. 진짜 블로커(의존성 부재, 반복 실패하는 검증, 불명확/모순 지시, 치명적 계획 공백)에서만 멈춘다. 특히 🔒 OWNER-LOCAL 단계(Phase 0·Task 3-6·Task 9·Task 10 owner 단계)는 owner 자격/클러스터가 필요하니 **매니페스트/스크립트/테스트만 작성**하고 진행, "OWNER 체크리스트"로 남긴다.
- **Commits — 아래 규칙을 직접 적용, `Skill(commit)` 호출 금지**(대화형 확인이 연속 실행을 깨뜨림):
  - **언어:** 커밋 메시지 **한국어**. **AI 마커 금지**(`🤖 Generated with`·`Co-Authored-By: Claude` 등 절대 금지).
  - **형식:** `<type>(<scope>): 한국어 설명`(필요 시 `- 상세` body).
  - **Type — 이 7가지만:** `feat`·`fix`·`refactor`·`docs`·`style`·`test`·`chore`. (`perf`/`build`/`ci` 등 사용 금지.)
  - **그룹화(우선순위):** ① 같은 기능/모듈 디렉토리 ② 목적별 분리(refactor vs fix vs feature) ③ 서로 참조하는 파일은 함께 ④ config·test·docs·style은 각각 별도 커밋.
  - **판단:** 같은 dir+같은 목적→한 커밋; 다른 파일 없인 무의미한 변경→같은 커밋; 독립 설명 가능→별도 커밋.
  - **위치:** 각 계획 `Commit` 단계에서 현재 feature-branch 워크트리(`worktree-files-deploy`)에 직접 커밋(이미 main 밖이라 새 브랜치 불요).
  - **주의:** 이 계획은 PR-A0/PR-A/PR-B 3-PR 구조 — ns 커밋(Task 1)은 컴포넌트 커밋과 분리 가능하게 별도로.
