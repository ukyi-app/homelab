# Homepage 대시보드 변경 Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 운영자 대시보드(gethomepage, `dash.home.ukyi.app`)에 설정 개선 11건 + Glances 호스트 메트릭 위젯을 GitOps로 추가한다.

**Architecture:** 대부분 `platform/homepage/prod/config/*` 변경(configMapGenerator 해시 → Deployment 자동 rollout). 로고/배경 이미지는 별도 `homepage-assets` ConfigMap을 `/app/public/images`에 RO 디렉토리 마운트(subPath 금지 가드 회피·EROFS 안전). Glances는 `platform/victoria-stack/prod`(observability ns, 이미 PSA privileged)에 strict-nonroot Deployment+Service로 동거하고, ingress NetworkPolicy로 `:61208`을 homepage ns에서만 허용한다.

**Tech Stack:** gethomepage v1.13.2, k3s(OrbStack VM), kustomize(+configMapGenerator binaryData), ArgoCD, bats, conftest(memory-ledger), nicolargo/glances v4.

**Base:** `f84fd87`(#67) · 워크트리 `feat+homepage-dashboard-changes` · 설계 `docs/plans/2026-06-19-homepage-dashboard-changes-design.md`(A.5 반영 `2a26041`)

**커밋 규칙(이 워크트리에서 직접):** 한국어 `<type>(scope): 설명`, AI 마커 금지. 타입은 feat/fix/refactor/docs/style/test/chore만.

**테스트 모델:** 매니페스트는 bats grep 가드(정적) + `kustomize build` 렌더 + (가능 시) kubeconform. 라이브 검증(rollout·위젯 데이터·Glances nonroot 실증)은 **PR 머지 후** ArgoCD 싱크 시점 — Task 12 체크포인트. 작은 변경에 로컬 전체 run-bats 금지(영향분 + CI 위임). `KUBECONFIG`가 export돼 있으면 background bats가 sealed-secrets dry-run에서 hang → `unset KUBECONFIG`.

---

## Task 1: 이미지 워크트리 반입 + 로고 리사이즈

사용자가 `platform/homepage/prod/public/`(main 체크아웃, untracked)에 `background.jpg`(440KB) + `logo.png`(2.6MB)를 두었다. 워크트리로 복사하고 로고를 ConfigMap 1MiB 한도에 맞게 리사이즈한다(배경은 그대로).

**Files:**
- Create: `platform/homepage/prod/public/background.jpg` (복사)
- Create: `platform/homepage/prod/public/logo.png` (복사 후 in-place 리사이즈)

**Step 1: 이미지 복사**

```bash
mkdir -p platform/homepage/prod/public
cp /Users/ukyi/workspace/homelab/platform/homepage/prod/public/background.jpg platform/homepage/prod/public/
cp /Users/ukyi/workspace/homelab/platform/homepage/prod/public/logo.png       platform/homepage/prod/public/
```

**Step 2: 로고 리사이즈(헤더 표시 크기, macOS sips)**

Run:
```bash
sips -Z 256 platform/homepage/prod/public/logo.png --out platform/homepage/prod/public/logo.png
du -h platform/homepage/prod/public/logo.png platform/homepage/prod/public/background.jpg
```
Expected: `logo.png` ≲ 150KB (1122x1402 → 205x256), `background.jpg` 440KB. **합계 raw < 600KB** (base64 ~800KB < 1MiB).
- logo가 여전히 150KB 초과면 `sips -Z 192` 또는 추가 압축. 합계 raw가 ~700KB를 넘으면 **STOP**(1MiB ConfigMap 위험) — 사용자에게 보고.

**Step 3: 커밋**

```bash
git add platform/homepage/prod/public/background.jpg platform/homepage/prod/public/logo.png
git commit -m "chore(homepage): 대시보드 로고/배경 이미지 추가(로고 256px 리사이즈)"
```

---

## Task 2: settings.yaml — 헤더/검색/배경/title + 추천 extras

**Files:**
- Modify: `platform/homepage/prod/config/settings.yaml`
- Test: `platform/homepage/prod/test_homepage_config.bats`

**Step 1: 실패하는 가드 작성 + 기존 title 단언 수정**

`test_homepage_config.bats`의 기존 `@test "settings declare the dashboard title"`를 아래로 교체하고, 신규 가드를 추가한다(@test 이름은 영어 — 한글 인코딩 깨짐):

```bash
@test "settings declare the dashboard title as ukyi" {
  run grep -qE '^title:[[:space:]]*ukyi$' "$C/settings.yaml"; [ "$status" -eq 0 ]
}

@test "settings apply header/target/search/background tweaks" {
  run grep -qE '^headerStyle:[[:space:]]*boxedWidgets' "$C/settings.yaml"; [ "$status" -eq 0 ]
  run grep -qE '^target:[[:space:]]*_blank' "$C/settings.yaml"; [ "$status" -eq 0 ]
  run grep -q 'searchDescriptions: true' "$C/settings.yaml"; [ "$status" -eq 0 ]
  run grep -q '/images/background.jpg' "$C/settings.yaml"; [ "$status" -eq 0 ]
  run grep -q 'hideVersion: true' "$C/settings.yaml"; [ "$status" -eq 0 ]
  run grep -q 'statusStyle: dot' "$C/settings.yaml"; [ "$status" -eq 0 ]
}
```

**Step 2: 실패 확인**

Run: `bats platform/homepage/prod/test_homepage_config.bats`
Expected: 신규 2개 FAIL(아직 settings 미변경).

**Step 3: settings.yaml 작성**

`platform/homepage/prod/config/settings.yaml` 전체를 아래로 교체:

```yaml
title: ukyi
headerStyle: boxedWidgets
target: _blank
quicklaunch:
  searchDescriptions: true
background:
  image: /images/background.jpg   # homepage-assets ConfigMap → /app/public/images (Task 5)
  blur: sm
  brightness: 75
  opacity: 50
hideVersion: true
statusStyle: dot
useEqualHeights: true
layout:
  Infra:
    style: row
    columns: 4
  Platform:
    style: row
    columns: 4
  Apps:
    style: row
    columns: 4
```

**Step 4: 통과 확인**

Run: `bats platform/homepage/prod/test_homepage_config.bats`
Expected: 전부 PASS.

**Step 5: 커밋**

```bash
git add platform/homepage/prod/config/settings.yaml platform/homepage/prod/test_homepage_config.bats
git commit -m "feat(homepage): settings 헤더/검색/배경/title(ukyi)·추천 옵션 적용"
```

---

## Task 3: widgets.yaml — 로고 아이콘 + datetime hourCycle

**Files:**
- Modify: `platform/homepage/prod/config/widgets.yaml`
- Test: `platform/homepage/prod/test_homepage_config.bats`

**Step 1: 실패하는 가드 추가**

```bash
@test "widgets add the logo and h23 time format" {
  run grep -qE '^[[:space:]]*-[[:space:]]*logo:' "$C/widgets.yaml"; [ "$status" -eq 0 ]
  run grep -q '/images/logo.png' "$C/widgets.yaml"; [ "$status" -eq 0 ]
  run grep -q 'hourCycle: h23' "$C/widgets.yaml"; [ "$status" -eq 0 ]
  run grep -q 'timeStyle: short' "$C/widgets.yaml"; [ "$status" -eq 0 ]
}
```

**Step 2: 실패 확인**

Run: `bats platform/homepage/prod/test_homepage_config.bats`
Expected: 신규 FAIL.

**Step 3: widgets.yaml 작성**

`platform/homepage/prod/config/widgets.yaml` 전체를 아래로 교체:

```yaml
- logo:
    icon: /images/logo.png          # homepage-assets ConfigMap → /app/public/images (Task 5). 클라이언트 로드, 클릭 링크 없음
- greeting:
    text_size: xl
    text: Homelab
- datetime:
    format:
      timeStyle: short
      hourCycle: h23
```

**Step 4: 통과 확인 → 커밋**

Run: `bats platform/homepage/prod/test_homepage_config.bats` → PASS
```bash
git add platform/homepage/prod/config/widgets.yaml platform/homepage/prod/test_homepage_config.bats
git commit -m "feat(homepage): 로고 아이콘 위젯 + datetime h23 시간 포맷"
```

---

## Task 4: bookmarks.yaml 재도입 + kustomization

#67이 삭제한 bookmarks.yaml을 GitHub/Instagram 외부 소셜 링크로 재도입(자동발견 Platform 타일과 중복 아님). `target: _blank`(Task 2)로 새 탭.

**Files:**
- Create: `platform/homepage/prod/config/bookmarks.yaml`
- Modify: `platform/homepage/prod/kustomization.yaml`
- Test: `platform/homepage/prod/test_homepage_config.bats`

**Step 1: 실패하는 가드 추가**

```bash
@test "bookmarks expose github and instagram profiles" {
  run grep -q 'https://github.com/ukkiee' "$C/bookmarks.yaml"; [ "$status" -eq 0 ]
  run grep -q 'https://instagram.com/ukyi_' "$C/bookmarks.yaml"; [ "$status" -eq 0 ]
}
```

**Step 2: 실패 확인** → `bats platform/homepage/prod/test_homepage_config.bats` → 신규 FAIL(파일 없음).

**Step 3: bookmarks.yaml 작성**

`platform/homepage/prod/config/bookmarks.yaml`:
```yaml
- Links:
    - GitHub:
        - abbr: GH
          icon: si-github
          href: https://github.com/ukkiee
    - Instagram:
        - abbr: IG
          icon: si-instagram
          href: https://instagram.com/ukyi_
```

**Step 4: kustomization configMapGenerator에 bookmarks 추가**

`platform/homepage/prod/kustomization.yaml`의 `configMapGenerator[name=homepage].files`에 추가하고 #67 주석 갱신:
```yaml
configMapGenerator:
  - name: homepage
    files:
      - config/kubernetes.yaml
      - config/settings.yaml
      - config/services.yaml
      - config/widgets.yaml
      - config/bookmarks.yaml   # 외부 소셜 링크(GitHub/Instagram) — 자동발견 Platform 타일과 중복 아님
```
(주석 줄 "Ops 북마크는 ... 제거" 문구는 "외부 소셜 링크 bookmarks는 자동발견과 무관"으로 수정.)

**Step 5: 통과 확인 → 커밋**

Run: `bats platform/homepage/prod/test_homepage_config.bats` → PASS
```bash
git add platform/homepage/prod/config/bookmarks.yaml platform/homepage/prod/kustomization.yaml platform/homepage/prod/test_homepage_config.bats
git commit -m "feat(homepage): GitHub/Instagram 북마크 재도입"
```

---

## Task 5: homepage-assets ConfigMap → /app/public/images RO 마운트

로고/배경을 별도 ConfigMap으로 `/app/public/images`에 **디렉토리 RO 마운트**한다. **subPath 금지**(deployment.bats EROFS 가드) — 전체 디렉토리 마운트. gethomepage는 거기에 write하지 않으므로 RO 안전. configMapGenerator binaryData 해시 → 이미지 변경 시 자동 rollout.

**Files:**
- Modify: `platform/homepage/prod/kustomization.yaml` (configMapGenerator 추가)
- Modify: `platform/homepage/prod/deployment.yaml` (volume + mount)
- Test: `platform/homepage/prod/test_homepage_deployment.bats`

**Step 0: 라이브 사전 점검(섀도잉 확인) — 체크포인트**

라이브 pod에서 `/app/public/images`가 gethomepage 필수 파일을 담지 않는지 확인(담으면 RO 디렉토리 마운트가 가림). `KUBECONFIG` 설정 후:
```bash
POD=$(kubectl -n homepage get pod -l app.kubernetes.io/name=homepage -o name | head -1)
kubectl -n homepage exec "$POD" -- ls -la /app/public/images 2>/dev/null || echo "dir absent/empty"
```
Expected: 비어 있거나 사용자 이미지 디렉토리(필수 UI 자산 없음) → RO 디렉토리 마운트 안전. **필수 파일이 있으면 STOP** → emptyDir+seed initContainer 방식으로 폴백(설계 §C 대안)하고 사용자에게 보고.

**Step 1: 실패하는 가드 추가**

`test_homepage_deployment.bats`에:
```bash
@test "assets configmap is mounted read-only at public images (no subPath)" {
  run grep -qE 'mountPath: /app/public/images\b' "$D"; [ "$status" -eq 0 ]
  run grep -q 'name: assets' "$D"; [ "$status" -eq 0 ]
  run grep -q 'homepage-assets' "$D"; [ "$status" -eq 0 ]
  # subPath 전면 금지 가드(기존 @test)와 양립 — 디렉토리 마운트라 subPath 불필요
}
```

**Step 2: 실패 확인** → `bats platform/homepage/prod/test_homepage_deployment.bats` → 신규 FAIL.

**Step 3: kustomization에 homepage-assets configMapGenerator 추가**

`platform/homepage/prod/kustomization.yaml`:
```yaml
configMapGenerator:
  - name: homepage
    files:
      - config/kubernetes.yaml
      - config/settings.yaml
      - config/services.yaml
      - config/widgets.yaml
      - config/bookmarks.yaml
  - name: homepage-assets        # 로고/배경(바이너리 → binaryData). 1MiB 한도 내(Task 1에서 검증)
    files:
      - public/background.jpg
      - public/logo.png
```

**Step 4: deployment.yaml에 volume + RO 마운트 추가**

`platform/homepage/prod/deployment.yaml`:
- `containers[homepage].volumeMounts`에 추가:
  ```yaml
            - { name: assets, mountPath: /app/public/images, readOnly: true }
  ```
- `volumes`에 추가:
  ```yaml
        - name: assets
          configMap:
            name: homepage-assets   # kustomize가 해시 접미사 자동 치환
  ```

**Step 5: 통과 확인 + 렌더 + ConfigMap 크기 검증**

```bash
bats platform/homepage/prod/test_homepage_deployment.bats   # PASS
kustomize build platform/homepage/prod > /tmp/hp.yaml && echo OK
# homepage-assets 렌더 크기 < 1MiB 확인
awk '/name: homepage-assets/{f=1} f{print} /^---/{if(f)exit}' /tmp/hp.yaml | wc -c
```
Expected: 렌더 성공, homepage-assets 블록 < 1048576 bytes(여유 충분).

**Step 6: 커밋**

```bash
git add platform/homepage/prod/kustomization.yaml platform/homepage/prod/deployment.yaml platform/homepage/prod/test_homepage_deployment.bats
git commit -m "feat(homepage): 로고/배경 자산 ConfigMap을 public/images에 RO 마운트"
```

---

## Task 6: Glances Deployment + Service (victoria-stack 동거)

observability ns(PSA privileged)에 strict-nonroot Glances를 배포. node-exporter 패턴 미러. **root fallback 금지**(A.5#2).

**Files:**
- Create: `platform/victoria-stack/prod/glances.yaml`
- Modify: `platform/victoria-stack/prod/kustomization.yaml`
- Test: `platform/victoria-stack/prod/test_glances.bats`

**Step 1: 실패하는 보안 가드 작성**

`platform/victoria-stack/prod/test_glances.bats` (setup: `G="${BATS_TEST_DIRNAME}/glances.yaml"`; @test 영어):
```bash
#!/usr/bin/env bats
# Glances host-introspection Deployment 보안 경계 가드(A.5). @test 이름은 영어.
setup() { G="${BATS_TEST_DIRNAME}/glances.yaml"; }

@test "glances runs strict nonroot with caps dropped (A.5 hardening)" {
  run grep -q 'runAsNonRoot: true' "$G"; [ "$status" -eq 0 ]
  run grep -qE 'runAsUser: 65534' "$G"; [ "$status" -eq 0 ]
  run grep -q 'allowPrivilegeEscalation: false' "$G"; [ "$status" -eq 0 ]
  run grep -qE 'drop:\s*\[?\s*"?ALL"?' "$G"; [ "$status" -eq 0 ]
}

@test "glances does not mount the host root filesystem by default (A.5 minimal mounts)" {
  # host '/' (path: /) 마운트 금지 — fs metric 채택 시에만 별도 PR로 추가.
  run grep -qE 'hostPath:\s*\{\s*path:\s*/\s*\}' "$G"; [ "$status" -ne 0 ]
  run grep -qE 'path:\s*/$' "$G"; [ "$status" -ne 0 ]
}

@test "glances serves the api on 61208 in observability" {
  run grep -q 'containerPort: 61208' "$G"; [ "$status" -eq 0 ]
  run grep -q 'namespace: observability' "$G"; [ "$status" -eq 0 ]
  run grep -q 'hostPID: true' "$G"; [ "$status" -eq 0 ]
}

@test "glances does not mount a kubernetes api token (Pass2 hardening)" {
  run grep -q 'automountServiceAccountToken: false' "$G"; [ "$status" -eq 0 ]
}
```

**Step 2: 실패 확인** → `bats platform/victoria-stack/prod/test_glances.bats` → FAIL(파일 없음).

**Step 3: glances.yaml 작성**

`platform/victoria-stack/prod/glances.yaml`:
```yaml
# Glances 호스트 메트릭 API(homepage 위젯 전용). observability ns(PSA privileged) 동거.
# A.5: strict nonroot(65534)·root fallback 금지·최소 마운트(host / 미마운트)·ingress NP(Task 7).
apiVersion: apps/v1
kind: Deployment
metadata:
  name: glances
  namespace: observability
  labels: { app.kubernetes.io/name: glances }
spec:
  replicas: 1                 # 단일 노드 — DaemonSet 불요
  selector:
    matchLabels: { app.kubernetes.io/name: glances }
  template:
    metadata:
      labels: { app.kubernetes.io/name: glances }
    spec:
      automountServiceAccountToken: false   # ★ Pass2: Glances는 k8s API 불요 — SA 토큰 마운트 금지(공격면 축소)
      hostPID: true           # 호스트 CPU/메모리/프로세스 가시성(/proc가 호스트 PID ns 반영)
      securityContext:
        runAsNonRoot: true    # ★ A.5: 하드 요구. root fallback 금지
        runAsUser: 65534
        runAsGroup: 65534
        seccompProfile: { type: RuntimeDefault }
      containers:
        - name: glances
          image: nicolargo/glances:4.3.1   # ★ 실행 시 최신 stable 4.x 태그 확인·핀(digest는 Renovate 후속)
          env:
            - { name: GLANCES_OPT, value: "-w" }   # 웹서버 모드(REST API @ :61208). 필요 시 "--disable-webui" 추가
            - { name: TMPDIR, value: /tmp }
          ports:
            - { name: api, containerPort: 61208 }
          resources:
            requests: { cpu: 25m, memory: 64Mi }
            limits: { memory: 192Mi }     # 메모리 원장 glances 행(Task 10)과 일치
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true  # /tmp emptyDir로 쓰기 경로 제공
            capabilities: { drop: ["ALL"] }
          volumeMounts:
            - { name: tmp, mountPath: /tmp }
            - { name: os-release, mountPath: /etc/os-release, readOnly: true }
            # host '/proc','/sys'는 hostPID + 런타임 기본 RO /sys로 커버 시도 — Task 12 live-proof로
            # 부족한 metric 확인 후 최소 마운트만 추가(host / 는 금지).
      volumes:
        - { name: tmp, emptyDir: {} }
        - { name: os-release, hostPath: { path: /etc/os-release, type: File } }
---
apiVersion: v1
kind: Service
metadata:
  name: glances
  namespace: observability
  labels: { app.kubernetes.io/name: glances }
spec:
  selector: { app.kubernetes.io/name: glances }
  ports:
    - { name: api, port: 61208, targetPort: 61208 }
```

**Step 4: kustomization에 추가**

`platform/victoria-stack/prod/kustomization.yaml`의 `resources:`에 `- glances.yaml` 추가(node-exporter 인근).

**Step 5: 통과 확인 + 렌더 → 커밋**

```bash
bats platform/victoria-stack/prod/test_glances.bats   # PASS
kustomize build platform/victoria-stack/prod >/dev/null && echo OK   # KSOPS 시크릿 generator 있으면 SOPS 키 필요
git add platform/victoria-stack/prod/glances.yaml platform/victoria-stack/prod/kustomization.yaml platform/victoria-stack/prod/test_glances.bats
git commit -m "feat(observability): Glances 호스트 메트릭 배포(strict nonroot, hostPID)"
```
> KSOPS 풀 렌더가 SOPS 키를 요구하면 `export SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt` 후 `kustomize build --enable-helm --enable-alpha-plugins --enable-exec`.

---

## Task 7: Glances ingress NetworkPolicy (A.5#1 — homepage ns에서만 61208)

observability ns엔 default-deny ingress가 없어 glances `:61208`이 노출된다. glances pod를 선택하는 NP로 차단.

**Files:**
- Create: `platform/victoria-stack/prod/glances-netpol.yaml`
- Modify: `platform/victoria-stack/prod/kustomization.yaml`
- Test: `platform/victoria-stack/prod/test_glances.bats`

**Step 1: 실패하는 가드 추가**

```bash
@test "glances ingress is restricted to the homepage namespace (A.5 isolation)" {
  N="${BATS_TEST_DIRNAME}/glances-netpol.yaml"
  run grep -q 'kind: NetworkPolicy' "$N"; [ "$status" -eq 0 ]
  run grep -q 'app.kubernetes.io/name: glances' "$N"; [ "$status" -eq 0 ]
  run grep -q 'kubernetes.io/metadata.name: homepage' "$N"; [ "$status" -eq 0 ]
  run grep -q '61208' "$N"; [ "$status" -eq 0 ]
}
```

**Step 2: 실패 확인** → FAIL.

**Step 3: glances-netpol.yaml 작성**

```yaml
# A.5#1: glances :61208을 homepage ns에서만 허용(NP가 glances pod 선택 → 그 외 ingress default-deny).
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: glances-allow-homepage
  namespace: observability
spec:
  podSelector:
    matchLabels: { app.kubernetes.io/name: glances }
  policyTypes: [Ingress]
  ingress:
    - from:
        - namespaceSelector:
            matchLabels: { kubernetes.io/metadata.name: homepage }
      ports:
        - { protocol: TCP, port: 61208 }
```

**Step 4: kustomization `resources:`에 `- glances-netpol.yaml` 추가.**

**Step 5: 통과 확인 → 커밋**

```bash
bats platform/victoria-stack/prod/test_glances.bats   # PASS
git add platform/victoria-stack/prod/glances-netpol.yaml platform/victoria-stack/prod/kustomization.yaml platform/victoria-stack/prod/test_glances.bats
git commit -m "feat(observability): Glances ingress를 homepage ns로 제한(A.5 격리)"
```

---

## Task 8: homepage egress → observability:61208 — ★ PR-B(Task 9와 함께)

> **GATE(Pass3#1):** 이 egress는 데이터 패스를 여는 단계라 **PR-B**다(PR-A 제외). PR-A의 Glances health 증명(Task 12 · 2·2b) 후 Task 9 위젯과 함께 머지한다.

homepage는 default-deny egress라 Glances API 호출을 위해 egress 허용이 필요.

**Files:**
- Modify: `platform/homepage/prod/networkpolicy.yaml`
- Test: `platform/homepage/prod/test_homepage_netpol.bats`

**Step 1: 실패하는 가드 추가 (Pass1#2 — 라벨까지 단언)**

```bash
@test "egress to glances is scoped to glances pods on 61208" {
  run grep -q '61208' "$P"; [ "$status" -eq 0 ]
  run grep -q 'app.kubernetes.io/name: glances' "$P"; [ "$status" -eq 0 ]
  run grep -q 'kubernetes.io/metadata.name: observability' "$P"; [ "$status" -eq 0 ]
}
```

**Step 2: 실패 확인** → FAIL.

**Step 3: networkpolicy.yaml에 egress rule 추가 (Pass1#2 — podSelector AND)**

`platform/homepage/prod/networkpolicy.yaml` 끝에. **`to` 한 항목 안에 namespaceSelector + podSelector를 함께** 두어 AND(observability ns의 glances pod만) — observability 전체로 넓히지 않는다(privileged ns 경계 최소화):
```yaml
---
# Glances 호스트 메트릭 위젯 — homepage가 서버사이드로 observability의 glances pod:61208 호출.
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-egress-to-glances
  namespace: homepage
spec:
  podSelector: {}
  policyTypes: [Egress]
  egress:
    - to:
        - namespaceSelector:                  # 같은 '-' 항목 → namespace AND pod
            matchLabels: { kubernetes.io/metadata.name: observability }
          podSelector:
            matchLabels: { app.kubernetes.io/name: glances }
      ports:
        - { protocol: TCP, port: 61208 }
```

**Step 4: 통과 확인(전체 netpol 가드 회귀 포함) → 커밋**

```bash
bats platform/homepage/prod/test_homepage_netpol.bats   # PASS(0.0.0.0/0·pod CIDR 금지 가드 유지 확인)
git add platform/homepage/prod/networkpolicy.yaml platform/homepage/prod/test_homepage_netpol.bats
git commit -m "feat(homepage): Glances egress(observability:61208) 허용"
```

---

## Task 9: Glances 위젯 (services.yaml) — ★ PR-B 전용(게이트)

> **GATE(Pass2#1·Pass3#1):** 이 Task는 **Task 8과 함께 PR-B**다. PR-A(Task 1~7·10)가 머지되고 **Glances 라이브 health가 증명된 뒤에만**(Task 12의 2·2b GREEN) 구현·PR한다. executor는 PR-A를 연 뒤 이 게이트에서 정지하고, 라이브 health 확인 후 Task 8+9(PR-B)를 진행한다.

**Files:**
- Modify: `platform/homepage/prod/config/services.yaml`
- Test: `platform/homepage/prod/test_homepage_config.bats`

**Step 1: 실패하는 가드 추가**

```bash
@test "infra group includes the glances host widget" {
  run grep -q 'type: glances' "$C/services.yaml"; [ "$status" -eq 0 ]
  run grep -q 'glances.observability.svc.cluster.local:61208' "$C/services.yaml"; [ "$status" -eq 0 ]
}
```

**Step 2: 실패 확인** → FAIL.

**Step 3: services.yaml의 Infra 그룹에 Glances 위젯 추가**

기존 `- Infra:` 리스트의 `Cluster` 항목 뒤에 추가(들여쓰기 일치):
```yaml
    - Host:
        icon: mdi-gauge
        description: 호스트 라이브 메트릭(Glances)
        widget:
          type: glances
          url: http://glances.observability.svc.cluster.local:61208
          version: 4
          metric: cpu          # 카드별 metric — memory/sensor 등은 라이브 미세조정(Task 12)
          refreshInterval: 5000
```

**Step 4: 통과 확인 → 커밋**

```bash
bats platform/homepage/prod/test_homepage_config.bats   # PASS
git add platform/homepage/prod/config/services.yaml platform/homepage/prod/test_homepage_config.bats
git commit -m "feat(homepage): Glances 호스트 메트릭 위젯 추가"
```

---

## Task 10: 메모리 원장 glances 행

ledger 검증기는 limit 총합 ≤ budget(8704) + 행별 limit≥req만 검사(ns 그룹/렌더 교차검증 없음). glances 전용 행 추가(총 limit 7848+192=8040 ≤ 8704).

**Files:**
- Modify: `docs/memory-ledger.md`
- Test: 기존 `bun run verify:ledger`

**Step 1: glances 행 추가**

`docs/memory-ledger.md` 표의 homepage 행 아래에:
```
| <!-- ledger:row --> glances        | observability  |     64 |      192 |
```
그리고 **합계** 줄을 갱신: `req ≈ 4291 Mi · limit ≈ 8040 Mi (반드시 ≤ 8704 Mi 유지)`.

**Step 2: 검증**

Run: `bun run verify:ledger`
Expected: PASS(예산 내, limit≥req). (CI `make verify`도 동일 검사.)

**Step 3: 커밋**

```bash
git add docs/memory-ledger.md
git commit -m "chore(ledger): Glances 메모리 예산 행 추가(observability +192Mi limit)"
```

---

## Task 11: 통합 렌더 + 게이트 검증

**Step 1: 두 컴포넌트 풀 렌더**

```bash
kustomize build platform/homepage/prod > /tmp/hp.yaml && echo "homepage OK"
export SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt
kustomize build --enable-helm --enable-alpha-plugins --enable-exec platform/victoria-stack/prod > /tmp/vs.yaml && echo "victoria-stack OK"
```
Expected: 둘 다 렌더 성공. homepage-assets ConfigMap < 1MiB.

**Step 2: 영향 영역 bats(전체 run-bats 금지)**

```bash
unset KUBECONFIG   # background/dry-run hang 회피
bats platform/homepage/prod/test_homepage_config.bats \
     platform/homepage/prod/test_homepage_deployment.bats \
     platform/homepage/prod/test_homepage_netpol.bats \
     platform/victoria-stack/prod/test_glances.bats
```
Expected: 전부 PASS.

**Step 3: 기반 게이트**

```bash
make verify   # skeleton + 원장(conftest) + sops 라운드트립
```
Expected: PASS. (나머지 게이트는 CI에 위임.)

**Step 4: (선택) kubeconform**

```bash
command -v kubeconform >/dev/null && kubeconform -ignore-missing-schemas /tmp/hp.yaml /tmp/vs.yaml || echo "kubeconform skip"
```

이 Task는 새 파일 생성 없음 — 검증만. 실패 시 해당 Task로 돌아가 수정.

---

## Task 12: 라이브 검증 체크포인트 (PR 머지 후 — executor가 ArgoCD 싱크 후 단계적으로 수행)

> 이 Task는 **머지 전 코드 변경이 아니라** 머지 후 라이브 검증 절차다. PR 생성·머지(auto-merge 비활성 레포 → gate watch 후 수동 머지) 후 ArgoCD가 main을 싱크하면 수행. selfHeal Application이라 임시 patch 금지 — 문제 시 아래 롤백 섹션을 PR로.

**Blast radius(bounded, Pass1#1)**: Glances Deployment가 실패해도 ① `victoria-stack` Application만 Degraded(타 컴포넌트·클러스터 무영향, 이미 Healthy), ② homepage는 위젯 **카드별 에러만 graceful 표시**(대시보드 전체 실패 아님). 즉 최악도 제한적이지만, 아래 **순서**로 검증해 위젯을 마지막에 신뢰한다.

**필수 — 2-PR 분리(Pass2#1·Pass3#1)**: 위젯과 **데이터 패스(homepage egress)** 는 Glances 라이브 health가 증명된 뒤에만 연다. **단일 PR 금지**(같은 ArgoCD sync에 미검증 nonroot Glances + 사용자 가시 위젯이 함께 올라가는 foot-gun — 사후 관찰은 gate가 아니다):
- **PR-A**: Task 1~7 + 10 (config 변경 + Glances 배포 + **glances ingress NP(Task7, homepage-only 잠금)** + ledger, **homepage egress Task8·위젯 Task9 제외**) → 머지 → 아래 1·2·2b 검증으로 Glances 라이브 health **증명(gate)**.
  - Pass3#1: Task8(homepage egress)을 PR-A에서 빼면 데이터 패스(ingress+egress 둘 다 필요)가 닫혀, health 증명 前 homepage→glances 실제 도달이 불가능하다. health는 `kubectl exec`(localhost)로 증명하므로 cross-ns 접근이 필요 없다. Task7은 PR-A 유지(glances를 처음부터 homepage-only로 잠금, A.5#1).
- **PR-B**: **Task 8(homepage egress) + Task 9(위젯)** 은 **PR-A의 2·2b 검증이 GREEN인 뒤에만** 생성·머지 → 아래 3·4 검증.
- executor는 PR-A를 연 뒤 **이 라이브 게이트에서 정지**한다(머지·라이브 검증은 사람/CI 단계 — executing-plans의 정당한 stop 조건).

**검증 순서(#64·#65·#66 교훈 — Ready 윈도만 보지 말 것):**

**[PR-A 검증 — 머지 후]**
1. `kubectl -n homepage rollout status deploy/homepage` + **restart count 0 유지·시간 경과**(EROFS/CrashLoop 회귀 없음).
1b. **(Pass3#2) homepage 비주얼 smoke**: 브라우저 `dash.home.ukyi.app`(Mac DNS 미경유 시 `--resolve dash.home.ukyi.app:443:<traefik-ts VIP>`) — **배경 렌더·로고 아이콘·GitHub/Instagram 북마크(새 탭)·title=ukyi·시간 23시간제·boxedWidgets 헤더** 확인 + 자산 200: `curl -so /dev/null -w '%{http_code}' https://dash.home.ukyi.app/images/background.jpg`(및 `/images/logo.png`)가 **200**. 자동발견 로그 정상("Error getting namespaces" 없음). 깨지면 → 아래 **config 롤백**.
2. **Glances pod health(localhost — cross-ns 불요)**: `kubectl -n observability get deploy glances`(Ready, restart 0), 로그에 nonroot 권한 오류 없음.
2b. `kubectl -n observability exec deploy/glances -- wget -qO- localhost:61208/api/4/cpu`로 **API 응답 확인**(원하는 metric 포함).
   - ★ **A.5#2: glances가 65534로 기동 실패하거나 원하는 metric을 못 얻으면 STOP** — root fallback 금지. 사용자에게 보고 후 (a) 필요한 최소 hostPath 마운트(/proc·/sys, **host / 제외**) 추가 또는 (b) metric 축소를 PR로. Glances가 끝내 nonroot 불가면 **Glances 롤백**(아래).

**[PR-B 검증 — 1b·2·2b GREEN 확인 후 PR-B 머지하고 수행]**
3. 브라우저 `dash.home.ukyi.app`에서 **Glances 위젯 CPU 데이터 표시** 확인.
4. 위젯이 빈 값이면: homepage egress(glances pod:61208)·glances ingress NP·Glances API 순으로 점검. metric 카드(memory/sensor/fs) 라이브 미세조정 후 services.yaml PR.

## 롤백 절차 (Pass1#1·Pass3#2 — 순서 고정, 모두 PR로)

### A) config/asset 롤백 (PR-A의 1b smoke 실패 시 — Pass3#2)
homepage 설정·자산 변경이 화면을 깨면(잘못된 settings 키·asset 경로·배경/로고 미렌더) **즉시 되돌린다**:
1. 깨진 항목만 revert: `settings.yaml`(Task2)·`widgets.yaml`(Task3)·`bookmarks.yaml`+kustomization(Task4)·`deployment.yaml` assets 마운트+`homepage-assets` generator(Task5) 중 해당 변경을 이전 상태로. asset 경로 문제면 `homepage-assets` 마운트/파일명 점검.
2. 확인: `kubectl -n homepage rollout status deploy/homepage`(restart 0) + 1b smoke 재확인 + `kubectl -n argocd get app homepage`가 Synced·Healthy.
> config 변경은 Glances와 독립 — Glances 롤백과 무관하게 단독 revert 가능.

### B) Glances 롤백 (라이브 실패: nonroot 불가·CrashLoop·위젯 영구 에러 — 의존 역순, selfHeal 즉시 수렴)
1. **(PR-B가 이미 머지된 경우) 위젯·egress 먼저 비활성**: `services.yaml`의 Glances 위젯 블록(Task 9) 제거 + `networkpolicy.yaml`의 `allow-egress-to-glances`(Task 8) 제거. → homepage 위젯 에러 즉시 해소.
2. **Glances 리소스 제거**: `glances.yaml`·`glances-netpol.yaml`(Task 6·7)를 victoria-stack `kustomization.yaml` `resources`에서 빼고 파일 삭제. → `victoria-stack` Application Degraded 해소(prune).
3. **ledger 복원**: `docs/memory-ledger.md`의 glances 행 + 합계(Task 10) 되돌림 → `bun run verify:ledger` GREEN.
4. **확인**: `kubectl -n argocd get app victoria-stack homepage`가 Synced·Healthy.

---

## 의식적 제외 (재확인)
- healthchecks 위젯(외부 egress/시크릿) · 클릭형 헤더 로고(custom.js) · weather/외부 검색 위젯 — no-external-egress 자세 유지.

## Adversarial review dispositions

codex 적대 리뷰(launcher `adversarial-review.mjs`). 설계 리뷰 1패스(A.5) + 플랜 리뷰 3패스(캡). **모든 발견 Accepted·반영**. 미해결 high/critical 0. 캡(3패스) 도달 후 사용자 인가로 Pass 4 없이 확정.

**A.5 설계 리뷰** (verdict: needs-attention, 2 findings) — §9 참조:
- A.5#1 (high) Glances ingress 미격리 → **Accepted**: glances ingress NP(homepage-only).
- A.5#2 (high) host root 마운트 + root fallback → **Accepted**: strict nonroot(65534)·최소 마운트.

**플랜 리뷰 Pass 1** (verdict: needs-attention):
- P1#1 (high) 머지 후 실증에 롤백 경로 없음 → **Accepted**: 순서 고정 롤백 절차 + Task12 단계화 + 2-PR 권장.
- P1#2 (medium) homepage egress가 Glances-only보다 넓음 → **Accepted**: egress에 podSelector(glances) AND + 가드 강화.

**플랜 리뷰 Pass 2** (verdict: needs-attention):
- P2#1 (medium) 단일-PR이 health 증명 전 위젯 배포 → **Accepted**: 2-PR 분리 **필수화**.
- P2#2 (medium) Glances pod에 불필요 SA 토큰 → **Accepted**: `automountServiceAccountToken: false` + 가드.

**플랜 리뷰 Pass 3** (verdict: needs-attention, summary: "staged rollout still opens the Glances trust boundary too early and lacks a PR-A validation/rollback gate for the homepage config changes"):
- P3#1 (medium) PR-A가 위젯 전 Glances 네트워크 데이터 패스를 엶 → **Accepted**: Task8(egress)을 PR-B로 이동(PR-A=Task1~7·10, PR-B=Task8·9), health는 localhost exec로 증명.
- P3#2 (medium) PR-A config 변경에 smoke/롤백 없음 → **Accepted**: PR-A homepage 비주얼 smoke(1b) + config 롤백(A) 추가.

> 캡(3패스) 도달. Pass 3의 2 medium 발견을 수용·반영했으나 **재리뷰(Pass 4)는 캡으로 미수행** — 사용자 인가로 확정. 잔여 위험은 모두 medium 이하이며 반영 완료.

## Execution directives
- **Skill:** `executing-plans`로 이 워크트리에서 구현. (goal: compact 후 executing-plans로 전 배치 구현·테스트·커밋·PR 머지·최종 확인.)
- **연속 실행:** 배치 간 루틴 정지 없이 진행. **정지는 진짜 블로커에서만** — 누락 의존성, 반복 실패하는 검증, 모순된 지시, critical plan gap, **그리고 Task 9의 PR-A 라이브 게이트**(PR-A 머지+Glances health 증명 전엔 Task8·9 진행 불가 — executing-plans의 정당한 stop). 그 외엔 PR-A 배치를 끝까지.
- **커밋 — 직접 수행, `Skill(commit)` 호출 금지**(인터랙티브 확인이 연속 실행을 깸):
  - **언어:** 한국어. **AI 마커 금지**(`🤖 Generated with`·`Co-Authored-By: Claude` 등 절대 금지).
  - **형식:** `<type>(<scope>): 한국어 설명` (필요 시 `- 상세` 본문).
  - **타입:** feat/fix/refactor/docs/style/test/chore만. (perf/build/ci 금지.)
  - **그룹화:** ① 같은 기능/모듈 디렉토리 함께 ② 목적별 분리(refactor vs fix vs feature) ③ 서로 참조 파일 함께 ④ config/test/docs/style 각각 별도 커밋. 각 Task의 Commit 스텝에서 커밋.
  - **위치:** 현재 feature 워크트리 브랜치에 직접(이미 main 밖 — 새 브랜치 불요).
- **PR/머지:** PR-A(Task1~7·10) 먼저 push+PR 생성(`pr` 스킬 또는 gh) → gate watch 후 머지(auto-merge 비활성 레포 가능성 — `gh pr merge --auto || gh pr merge`) → ArgoCD 싱크 → Task12 [PR-A 검증]. GREEN이면 PR-B(Task8·9) → 머지 → [PR-B 검증].
- **테스트:** 영향 영역 bats만(전체 run-bats 금지) + `make verify` + kustomize 렌더. `KUBECONFIG` export 시 background bats hang → `unset`. 라이브 접근 KUBECONFIG=`$PWD/infra/k3s-bootstrap/kubeconfig`.
- **최종 확인:** Task 12 전 검증 GREEN + ArgoCD `homepage`·`victoria-stack` Synced·Healthy.
