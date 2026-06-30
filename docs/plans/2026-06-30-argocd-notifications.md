# ArgoCD Notifications — 배포 완료/저하 telegram 알림 구현 계획

> **For Claude:** REQUIRED SUB-SKILL: superpowers:executing-plans 로 task 단위 구현.

**Goal:** ArgoCD가 앱·데이터서비스를 실제 Healthy로 수렴(`on-deployed`)하거나 Degraded(`on-health-degraded`)될 때 telegram 알림을 보낸다.

**Architecture:** argo-cd 차트 10.0.1 notifications 서브차트를 켜고(values), 봇 토큰은 argocd ns SealedSecret이 단독 소유(`secret.create: false`), cm(notifiers/templates/triggers/**subscriptions**)는 기존 line1 메시지 계약 재사용. 구독은 **cm 중앙 `subscriptions` + label `selector`** 한 곳에서 chatId를 잡고, 대상 Application에는 **라벨**만 — `apps` appset 정적 라벨 + platform appset **`templatePatch`** 조건부(data-conn/cache) + 수동 `cnpg-data` 정적 라벨. 컨트롤러 egress는 default-deny + 검증된 의존(DNS/telegram/apiserver)만 allow.

**Tech Stack:** Helm(argo-cd 10.0.1), ArgoCD Notifications, SealedSecrets, kustomize/ApplicationSet(goTemplate·templatePatch), NetworkPolicy(kube-router), bats/yq/kubeconform.

**설계 근거:** `docs/plans/2026-06-30-argocd-notifications-design.md`(A.5 반영). **Phase C 반영:** 패스1 F1(라벨+templatePatch·chatId 선확정·실렌더)·F2(canary); 패스2 F1(selfHeal:false+progressDeadline로 결정적 Degraded)·F2(라이브 라벨 하드게이트)·F3(bats 단언 가드).

> **⚠️ bats 단언 규약(레포 트랩):** bash 3.2에서 **중간 `[[ ]]`/`[ ]`는 실패해도 침묵 통과**한다.
> 모든 단언은 **명시적 실패 가드**로: 부분일치=`printf '%s' "$output" | grep -qF 'NEEDLE' || { echo "miss NEEDLE"; false; }`,
> 동등=`[ "$output" = "x" ] || { echo "want x got $output"; false; }`. @test 이름은 영어.

---

## 롤아웃 순서 (canary-first — 패스3 F2)

알림은 비-critical 사이드채널이지만, recipient/템플릿 결함이 프로덕션 전체에 먼저 새지 않도록 **canary를 게이트로** 둔다:
- **PR1 (canary 게이트)**: Task 1·2·3·5 + smoke 디렉토리(Task 6.3 source). 프로덕션 라벨(Task 4)은 **미포함**.
  머지·싱크 후 **Task 6.3–6.5 canary 검증**(Healthy/Degraded/recipient 파싱) 통과가 게이트.
- **PR2 (프로덕션 확대)**: Task 4(apps/data-conn/cache/cnpg-data 라벨) + Task 6.2 라이브 라벨 하드게이트.
- **롤백**: PR2 revert(라벨 제거)로 즉시 구독 해제, 또는 `notifications.enabled: false`/cm `subscriptions` 비움으로
  컨트롤러·발송 중단(앱 동작엔 무영향 — 사이드채널).
- **부트스트랩 순서(패스4 F2 → 패스5 F1 해결)**: **netpol은 차트 `extraObjects`(sync-wave -1)**라 컨트롤러보다 먼저
  적용 → RBAC-exfil egress 창 없음(Task 5). secret(extras, wave 1)이 늦으면 컨트롤러는 토큰 없이 idle(발송 대상 없음)일
  뿐 — **netpol이 이미 egress를 잠근 상태**라 안전. PR1 완료 전 `kubectl -n argocd get networkpolicy | grep notifications` +
  `get secret argocd-notifications-secret`로 확인.

---

## Task 0: 환경/스키마 사전 확인

**Step 0.1** argo-cd 차트 10.0.1 notifications values 스키마 확인:
```bash
helm show values argo/argo-cd --version $(cat platform/argocd/CHART_VERSION) 2>/dev/null \
  | sed -n '/^notifications:/,/^[a-z]/p' | head -160
```
Expected: `enabled`/`secret.create`/`notifiers`/`templates`/`triggers`/`subscriptions` 키 확인(다르면 보정).
또한 차트 최상위 **`extraObjects`** 지원 확인(`helm show values ... | grep -E '^extraObjects'`) — Task 5 netpol을 여기 둠.

**Step 0.2** 컨트롤러/repo-server 파드 라벨 확인(netpol·egress용):
```bash
helm template argo/argo-cd --version $(cat platform/argocd/CHART_VERSION) --set notifications.enabled=true 2>/dev/null \
  | yq 'select(.kind=="Deployment" and (.metadata.name|test("notifications|repo-server"))) | {name: .metadata.name, labels: .spec.template.metadata.labels}'
```
Expected: notifications-controller 파드 라벨(예 `app.kubernetes.io/name: argocd-notifications-controller`) 기록.

---

## Task 1: notifications 컨트롤러 ON + Secret 단독 소유 + 자원/원장 (A.5 F1 · 패스4 F1)

**Files:** Modify `platform/argocd/bootstrap-values.yaml:86-87` · Modify `docs/memory-ledger.md` · Test `platform/argocd/test_argocd_values.bats`

**Step 1.1 — 실패 테스트:**
```bash
@test "notifications controller is enabled, owns no secret, and has resource limits" {
  run yq '.notifications.enabled' platform/argocd/bootstrap-values.yaml
  [ "$output" = "true" ] || { echo "enabled != true: $output"; false; }
  run yq '.notifications.secret.create' platform/argocd/bootstrap-values.yaml
  [ "$output" = "false" ] || { echo "secret.create != false: $output"; false; }
  # 상주 워크로드 자원 limit 필수(원장 블라인드스팟 트랩 — 원격 차트라 source-scanner 미포착)
  run yq '.notifications.resources.limits.memory' platform/argocd/bootstrap-values.yaml
  [ "$output" != "null" ] || { echo "notifications.resources.limits.memory 미설정"; false; }
}
```
**Step 1.2 — 실패 확인:** `bats platform/argocd/test_argocd_values.bats -f "notifications controller is enabled"` → FAIL
**Step 1.3 — 구현**(`notifications:` 블록):
```yaml
notifications:
  enabled: true
  # 봇 토큰 Secret은 SealedSecret(extras)이 단독 소유 — 차트가 빈 Secret을 만들면 이중 소유 충돌(트랩).
  secret:
    create: false
  # 상주 워크로드 — 자원 limit 필수(원장 SSOT·CI 강제). GOMEMLIMIT 연동 워크로드 아님(Go지만 알림 컨트롤러 소형).
  resources:
    requests: { cpu: 10m, memory: 64Mi }
    limits: { memory: 128Mi }
```
**Step 1.4 — 통과:** 동일 bats → PASS
**Step 1.5 — 원장 반영(패스4 F1):** `docs/memory-ledger.md`의 argocd 항목/합계에 notifications-controller(limit **128Mi**) 추가.
합계 ≤9216Mi 유지 확인 → `bun run verify:ledger` 통과.
**Step 1.6 — 렌더 단언:** 컨트롤러 Deployment에 자원이 실제 렌더되는지:
```bash
helm template argo/argo-cd --version $(cat platform/argocd/CHART_VERSION) -f platform/argocd/bootstrap-values.yaml \
  | yq 'select(.kind=="Deployment" and (.metadata.name|test("notifications"))) | .spec.template.spec.containers[0].resources | has("limits")'
```
Expected: `true`.
**Step 1.7 — Commit:** `git commit -m "feat(argocd): notifications 컨트롤러 활성화 + Secret 단독 소유 + 자원 limit/원장 반영"`

---

## Task 2: 봇 토큰 SealedSecret(argocd ns) + seal 타깃 (A.5 F1)

**Files:** Create `scripts/seal-argocd-notify.sh` · Modify `Makefile` · Create `platform/argocd/extras/argocd-notifications-secret.sealed.yaml`(owner가 make로) · Modify `platform/argocd/extras/kustomization.yaml` · Test `platform/argocd/extras/test_argocd_extras.bats`

**Step 2.1 — seal 스크립트**(`scripts/seal-argocd-notify.sh`, `seal-ghcr-pull.sh` 미러):
```bash
#!/usr/bin/env bash
# telegram 봇 토큰+chatId(.env.secrets)를 argocd ns SealedSecret(argocd-notifications-secret)로 봉인.
# 사용: set -a; . .env.secrets; set +a; make seal-argocd-notify
set -euo pipefail
: "${TELEGRAM_BOT_TOKEN:?set TELEGRAM_BOT_TOKEN in .env.secrets}"
: "${TELEGRAM_CHAT_ID:?set TELEGRAM_CHAT_ID in .env.secrets}"
out="platform/argocd/extras/argocd-notifications-secret.sealed.yaml"
kubectl create secret generic argocd-notifications-secret \
  --namespace argocd \
  --from-literal=telegram-token="$TELEGRAM_BOT_TOKEN" \
  --from-literal=telegram-chat-id="$TELEGRAM_CHAT_ID" \
  --dry-run=client -o yaml \
  | kubeseal --cert tools/sealed-secrets-cert.pem --scope strict --format yaml >"$out"
echo "sealed -> $out (argocd-notifications-secret, ns argocd)"
```
**Step 2.2 — Makefile**(`seal-ghcr-pull` 다음):
```makefile
.PHONY: seal-argocd-notify
seal-argocd-notify: ## telegram 봇 토큰/chatId(.env.secrets)를 argocd-notifications-secret SealedSecret로 봉인(argocd NS)
	@scripts/seal-argocd-notify.sh
```
**Step 2.3 — kustomization**(`extras/kustomization.yaml` resources):
```yaml
  - argocd-notifications-secret.sealed.yaml # telegram 봇 토큰/chatId(argocd-notifications 컨트롤러)
```
**Step 2.4 — 실패 테스트:**
```bash
@test "argocd-notifications-secret is wired and sealed for argocd ns" {
  grep -q 'argocd-notifications-secret.sealed.yaml' platform/argocd/extras/kustomization.yaml \
    || { echo "kustomization 미등록"; false; }
  run yq 'select(.kind=="SealedSecret") | .metadata.name' platform/argocd/extras/argocd-notifications-secret.sealed.yaml
  [ "$output" = "argocd-notifications-secret" ] || { echo "name=$output"; false; }
  run yq 'select(.kind=="SealedSecret") | .metadata.namespace' platform/argocd/extras/argocd-notifications-secret.sealed.yaml
  [ "$output" = "argocd" ] || { echo "ns=$output"; false; }
}
```
**Step 2.5 — owner 봉인**(라이브 cert — owner-local): `set -a; . .env.secrets; set +a; make seal-argocd-notify`
**Step 2.6 — 통과 + Commit:** bats PASS → `git commit -m "feat(argocd): argocd-notifications-secret 봉인 + seal-argocd-notify 타깃"`

---

## Task 3: notifications cm — telegram·템플릿·트리거·subscriptions(chatId 확정) (패스1 F1)

> **chatId 결정:** chatId는 credential이 아님(봇 토큰만 credential→SealedSecret). cm `subscriptions` recipient에
> **한 곳에서** 둔다 — `telegram:$telegram-chat-id`(secret-ref) 우선, 컨트롤러가 미해석이면 chatId 리터럴 수용(저민감, 주석 문서화).
> 어느 쪽이든 **appset/Application엔 chatId가 들어가지 않는다**(라벨만, Task 4).

**Files:** Modify `platform/argocd/bootstrap-values.yaml`(`notifications:` 확장) · Test `platform/argocd/test_argocd_values.bats`

**Step 3.1 — 실패 테스트**(가드 단언):
```bash
@test "notifications cm has telegram service, line1 templates, deployed+degraded triggers, central selector subscription" {
  has() { printf '%s' "$1" | grep -qF "$2" || { echo "miss: $2"; false; }; }
  run yq '.notifications.notifiers."service.telegram"' platform/argocd/bootstrap-values.yaml
  has "$output" 'token: $telegram-token'
  run yq '.notifications.templates."template.app-deployed"' platform/argocd/bootstrap-values.yaml
  has "$output" '✅ <b>배포 완료</b>'
  run yq '.notifications.templates."template.app-degraded"' platform/argocd/bootstrap-values.yaml
  has "$output" '🔴 <b>앱 저하</b>'
  run yq '.notifications.triggers."trigger.on-deployed"' platform/argocd/bootstrap-values.yaml
  has "$output" 'Healthy'; has "$output" 'oncePer'
  run yq '.notifications.triggers."trigger.on-health-degraded"' platform/argocd/bootstrap-values.yaml
  has "$output" 'Degraded'
  run yq '.notifications.subscriptions | tag' platform/argocd/bootstrap-values.yaml
  [ "$output" = "!!seq" ] || { echo "subscriptions must be a YAML list, got $output"; false; }
  run yq '.notifications.subscriptions[0].selector' platform/argocd/bootstrap-values.yaml
  has "$output" 'notify.homelab/telegram'
  run yq '.notifications.subscriptions[0].triggers | tag' platform/argocd/bootstrap-values.yaml
  [ "$output" = "!!seq" ] || { echo "triggers must be a list, got $output"; false; }
}
```
**Step 3.2 — 실패 확인:** bats → FAIL
**Step 3.3 — 구현**(`notifications:` 블록에 추가):
```yaml
  notifiers:
    service.telegram: |
      token: $telegram-token
  templates:
    template.app-deployed: |
      message: "✅ <b>배포 완료</b> — {{.app.metadata.name}} (Healthy)"
      telegram:
        parseMode: HTML
    template.app-degraded: |
      message: "🔴 <b>앱 저하</b> — {{.app.metadata.name}} (Degraded)"
      telegram:
        parseMode: HTML
  triggers:
    trigger.on-deployed: |
      # ⚠️ 멀티소스 appset(apps)은 status.sync.revision(단수)이 비거나 불안정 → 멀티소스 호환 oncePer.
      #    최종 표현식은 Task 6.4b에서 라이브 app-prod의 status.sync.revisions(복수)로 확정/검증.
      - when: app.status.operationState.phase in ['Succeeded'] and app.status.health.status == 'Healthy'
        oncePer: 'app.status.sync.revisions != nil ? join(app.status.sync.revisions, ",") : app.status.sync.revision'
        send: [app-deployed]
    trigger.on-health-degraded: |
      - when: app.status.health.status == 'Degraded'
        send: [app-degraded]
  subscriptions:                       # ⚠️ YAML 리스트 — 블록 스칼라 `|` 금지(차트가 cm.data.subscriptions로 래핑; `|`면 중첩되어 무효)
    - recipients:
        - telegram:$telegram-chat-id   # $ 미해석 시 chatId 리터럴로 보정(Task 6.5)
      triggers: [on-deployed, on-health-degraded]
      selector: notify.homelab/telegram=true
```
> ⚠️ Task 0.1 스키마에 맞춘다(차트 버전에 따라 `subscriptions`가 `defaultSubscriptions`일 수 있음).
**Step 3.4 — 통과 + 렌더 하드게이트(패스3 F1):** bats PASS. 렌더된 cm의 `data.subscriptions`를 **YAML로 재파싱**해 구조 단언(블록 스칼라 중첩이면 파싱 실패):
```bash
helm template argo/argo-cd --version $(cat platform/argocd/CHART_VERSION) -f platform/argocd/bootstrap-values.yaml \
  | yq 'select(.metadata.name=="argocd-notifications-cm") | .data.subscriptions' \
  | yq -e '.[0] | has("recipients") and has("triggers") and has("selector")' -
```
Expected: `true` (cm.data.subscriptions가 유효 리스트, 첫 항목에 recipients/triggers/selector).
**Step 3.5 — Commit:** `git commit -m "feat(argocd): notifications cm — telegram·line1 템플릿·트리거·중앙 selector 구독(list)"`

---

## Task 4: 구독 라벨 배선 — apps 정적 + platform templatePatch + cnpg-data (PR2 — canary 검증 후)

> 구독 대상 = **라벨 `notify.homelab/telegram=true`**(chatId는 Task 3 cm). appset annotations에 미정의 `.X`/inline `{{if}}`
> 금지(missingkey=error 치명) — 정적 라벨 + **templatePatch**(조건부 정식 메커니즘).

**Files:** Modify `platform/argocd/root/appset.yaml` · Modify `platform/argocd/root/apps/cnpg-data.yaml` · Test `platform/argocd/root/test_render.bats`

**Step 4.1 — 실패 테스트**(정적 단언; 실렌더는 라이브 Task 6.6 하드게이트로 보강):
```bash
@test "telegram-notify label is wired on apps appset, platform templatePatch, and cnpg-data" {
  has() { printf '%s' "$1" | grep -qF "$2" || { echo "miss: $2"; false; }; }
  run yq 'select(.kind=="ApplicationSet" and .metadata.name=="apps") | .spec.template.metadata.labels."notify.homelab/telegram"' platform/argocd/root/appset.yaml
  [ "$output" = "true" ] || { echo "apps label=$output"; false; }
  run yq '.metadata.labels."notify.homelab/telegram"' platform/argocd/root/apps/cnpg-data.yaml
  [ "$output" = "true" ] || { echo "cnpg-data label=$output"; false; }
  run yq 'select(.kind=="ApplicationSet" and .metadata.name=="platform-components") | .spec.templatePatch' platform/argocd/root/appset.yaml
  has "$output" 'data-conn'; has "$output" 'cache'; has "$output" 'notify.homelab/telegram'
}
```
**Step 4.2 — 실패 확인:** bats → FAIL
**Step 4.3 — apps appset 정적 라벨**(`apps` ApplicationSet `template.metadata.labels`):
```yaml
      labels:
        homelab.env: '{{ .path.basename }}'
        notify.homelab/telegram: "true"
```
**Step 4.4 — platform-components appset templatePatch**(spec에 추가):
```yaml
  # data-conn/cache Application에만 알림 라벨 — templatePatch(문자열 템플릿)라 inline-YAML if 함정 없음.
  templatePatch: |
    {{- if has (index .path.segments 1) (list "data-conn" "cache") }}
    metadata:
      labels:
        notify.homelab/telegram: "true"
    {{- end }}
```
**Step 4.5 — cnpg-data 정적 라벨**(`cnpg-data.yaml` metadata.labels 신설):
```yaml
  labels:
    notify.homelab/telegram: "true"
```
**Step 4.6 — 통과:** bats PASS
**Step 4.7 — Commit:** `git commit -m "feat(argocd): 알림 구독 라벨 — apps 정적 + platform templatePatch(data-conn/cache) + cnpg-data"`

---

## Task 5: 컨트롤러 스코프 egress NetworkPolicy — 차트 extraObjects(선행) (A.5 F3 · 패스5 F1)

> **부트스트랩 순서(패스5 F1):** netpol을 extras(wave 1)가 아니라 **argocd 차트 `extraObjects`**(컨트롤러와 같은
> Application)에 두고 **sync-wave를 컨트롤러보다 앞(-1)**으로 → 콜드스타트에도 netpol이 컨트롤러보다 먼저 적용돼
> RBAC-exfil 창이 없다. (cross-app 순서 갭 제거.) Task 0.1에서 차트 `extraObjects` 지원 확인.

**Files:** Modify `platform/argocd/bootstrap-values.yaml`(`extraObjects`) · Test `platform/argocd/test_argocd_values.bats`

**Step 5.1 — 의존 목록 확정(순환 회피 — 패스4 F3).** 컨트롤러가 아직 안 떠 있으므로 **라이브 로그로 도출하지 않는다**(순환).
argocd-notifications의 **알려진 의존**으로 allow-list 결정: DNS(kube-dns) + apiserver(Application/Secret watch) + telegram(외부 443).
repo-server는 기본 배포에서 미사용 → **기본 제외**(Task 6 연결 테스트가 막히면 추가). 검증은 구현 **후** 능동 연결 테스트(Task 6.1·6.4)로.
> 불확실하면 리허설: 컨트롤러를 netpol 없이(또는 audit 정책) 먼저 띄워 실제 flow를 captures한 뒤 정책을 잠근다.
**Step 5.2 — 실패 테스트**(`test_argocd_values.bats` — extraObjects에서 추출):
```bash
@test "notifications netpol is in chart extraObjects, syncs before controller, default-deny + allows" {
  v=platform/argocd/bootstrap-values.yaml
  run yq '.extraObjects[] | select(.metadata.name=="argocd-notifications-default-deny-egress") | .metadata.annotations."argocd.argoproj.io/sync-wave"' "$v"
  [ "$output" = "-1" ] || { echo "default-deny sync-wave != -1: $output"; false; }
  run yq '.extraObjects[] | select(.metadata.name=="argocd-notifications-default-deny-egress") | .spec.policyTypes[]' "$v"
  printf '%s' "$output" | grep -qF 'Egress' || { echo "default-deny egress 없음"; false; }
  run yq '.extraObjects[] | select(.metadata.name=="argocd-notifications-allow-egress")' "$v"
  for n in '0.0.0.0/0' '192.168.0.0/16' '192.168.139.0/24' '6443'; do
    printf '%s' "$output" | grep -qF "$n" || { echo "miss in netpol: $n"; false; }
  done
}
```
**Step 5.3 — 실패 확인:** bats → FAIL
**Step 5.4 — 구현**(`bootstrap-values.yaml`의 `extraObjects:` 리스트에 추가 — sync-wave -1로 컨트롤러 선행; alertmanager+homepage 패턴):
```yaml
extraObjects:
  - apiVersion: networking.k8s.io/v1
    kind: NetworkPolicy
    metadata:
      name: argocd-notifications-default-deny-egress
      namespace: argocd
      annotations: { argocd.argoproj.io/sync-wave: "-1" }   # 컨트롤러보다 먼저 적용(부트스트랩 exfil 창 제거)
    spec:
      podSelector:
        matchLabels: { app.kubernetes.io/name: argocd-notifications-controller }
      policyTypes: [Egress]
      # 규칙 없음 => 컨트롤러 egress 전부 거부; 아래 allow가 최소만 재개방.
  - apiVersion: networking.k8s.io/v1
    kind: NetworkPolicy
    metadata:
      name: argocd-notifications-allow-egress
      namespace: argocd
      annotations: { argocd.argoproj.io/sync-wave: "-1" }
    spec:
      podSelector:
        matchLabels: { app.kubernetes.io/name: argocd-notifications-controller }
      policyTypes: [Egress]
      egress:
        - to: # DNS — api.telegram.org 해석(CoreDNS)
            - namespaceSelector: { matchLabels: { kubernetes.io/metadata.name: kube-system } }
              podSelector: { matchLabels: { k8s-app: kube-dns } }
          ports: [{ protocol: UDP, port: 53 }, { protocol: TCP, port: 53 }]
        - to: # apiserver — Application/Secret watch. ClusterIP 아닌 node-subnet:6443(DNAT-후 트랩)
            - ipBlock: { cidr: 192.168.139.0/24 }
          ports: [{ protocol: TCP, port: 6443 }]
        - to: # 외부 telegram(api.telegram.org:443) — 사설대역 except로 내부 lateral 차단
            - ipBlock: { cidr: 0.0.0.0/0, except: [10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16] }
          ports: [{ protocol: TCP, port: 443 }]
        # (Step 5.1에서 repo-server 필요 확인 시에만 추가)
        # - to: [{ podSelector: { matchLabels: { app.kubernetes.io/name: argocd-repo-server } } }]
        #   ports: [{ protocol: TCP, port: 8081 }]
```
> ⚠️ apiserver allow를 **별도 to 블록**으로 — telegram except의 192.168.0.0/16이 apiserver(192.168.139.x)도 제외하기 때문.
**Step 5.5 — 통과 + 렌더 확인:** bats PASS; `helm template ... -f bootstrap-values.yaml | yq 'select(.kind=="NetworkPolicy" and (.metadata.name|test("notifications")))'` → 2개 netpol 렌더(sync-wave -1).
**Step 5.6 — Commit:** `git commit -m "feat(argocd): notifications 컨트롤러 egress netpol(extraObjects·sync-wave 선행·DNS/telegram/apiserver)"`

---

## Task 5b: notify-smoke 소스 디렉토리 (PR1 — 패스5 F3)

> canary 워크로드를 **정확히 명세**하고, argocd-extras가 이걸 **상주 워크로드로 싱크하지 않게** 가드(extras/kustomization 미포함).

**Files:** Create `platform/argocd/extras/smoke/kustomization.yaml` · Create `platform/argocd/extras/smoke/deployment.yaml` · Test `platform/argocd/extras/test_argocd_extras.bats`

**Step 5b.1 — deployment.yaml**(container 이름 `app`·`progressDeadlineSeconds: 60`):
```yaml
apiVersion: apps/v1
kind: Deployment
metadata: { name: notify-smoke }
spec:
  progressDeadlineSeconds: 60        # Degraded가 ≤~90s에 결정적으로 표면화
  replicas: 1
  selector: { matchLabels: { app: notify-smoke } }
  template:
    metadata: { labels: { app: notify-smoke } }
    spec:
      containers:
        - name: app                   # ⚠️ `kubectl set image deploy/notify-smoke app=...` 대상 이름
          image: registry.k8s.io/pause:3.9
          resources: { requests: { cpu: 5m, memory: 16Mi }, limits: { memory: 32Mi } }
```
**Step 5b.2 — kustomization.yaml:**
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: notify-smoke
resources: [deployment.yaml]
```
**Step 5b.3 — 가드 테스트**(빌드 가능 + 상주화 방지):
```bash
@test "notify-smoke source builds, container is app, and is NOT synced by argocd-extras" {
  kustomize build platform/argocd/extras/smoke >/dev/null || { echo "smoke build 실패"; false; }
  run yq '.metadata.name' platform/argocd/extras/smoke/deployment.yaml
  [ "$output" = "notify-smoke" ] || { echo "name=$output"; false; }
  grep -q 'name: app' platform/argocd/extras/smoke/deployment.yaml || { echo "container 이름 app 아님"; false; }
  run yq '.resources[]' platform/argocd/extras/kustomization.yaml
  if printf '%s' "$output" | grep -q 'smoke'; then echo "extras가 smoke 포함 — 상주화 위험"; false; fi
}
```
**Step 5b.4 — Commit:** `git commit -m "feat(argocd): notify-smoke canary 소스(progressDeadlineSeconds 60·extras 미포함 가드)"`

---

## Task 6: 라이브 검증 — 결정적 notify-smoke canary + 라벨/멀티소스 게이트 (패스2 F1·F2 · 패스5 F2)

> Degraded는 **실앱 절대 불가침**. canary는 **selfHeal:false**(패치 원복 방지) + Deployment **progressDeadlineSeconds:60**
> (≤~90s에 Degraded 결정). 또한 실제 구독 라벨이 **라이브 Application에 렌더됐는지**를 하드게이트로 검증(로컬 skip 의존 금지).

**Step 6.0 — 전제:** **PR1**(컨트롤러/secret/cm/netpol + smoke) 머지·싱크 상태. `export KUBECONFIG=$PWD/infra/k3s-bootstrap/kubeconfig`.

**Step 6.1 — 컨트롤러/netpol 기동(PR1):**
```bash
kubectl -n argocd get deploy argocd-notifications-controller
kubectl -n argocd get networkpolicy | grep notifications
kubectl -n argocd logs deploy/argocd-notifications-controller --tail=50 | grep -iE 'error|denied|recipient' || echo clean
```

**Step 6.2 — smoke Application 생성: Healthy 경로(PR1 canary).** `platform/argocd/extras/smoke/`에 healthy Deployment +
kustomization을 PR1에 포함(selfHeal:false). 라벨 단 Application이 Healthy 수렴 → `✅ 배포 완료 — notify-smoke (Healthy)` 1건:
```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: notify-smoke
  namespace: argocd
  labels: { notify.homelab/telegram: "true" }
spec:
  project: platform
  source: { repoURL: https://github.com/ukyi-app/homelab.git, targetRevision: main, path: platform/argocd/extras/smoke }
  destination: { server: https://kubernetes.default.svc, namespace: notify-smoke }
  syncPolicy:
    automated: { prune: true, selfHeal: false }   # ⚠️ selfHeal OFF — Degraded 유도 패치가 원복되지 않게
    syncOptions: [CreateNamespace=true]
EOF
# smoke Deployment에는 progressDeadlineSeconds: 60 (Git 매니페스트) → Degraded가 ≤~90s에 결정적으로 표면화.
```

**Step 6.3 — Degraded 경로(PR1 canary, 결정적).** selfHeal OFF라 패치가 유지됨 → 잘못된 이미지로 progress deadline 초과 → Degraded:
```bash
kubectl -n notify-smoke set image deploy/notify-smoke app=registry.k8s.io/pause:nonexistent-xyz
kubectl -n argocd wait --for=jsonpath='{.status.health.status}'=Degraded application/notify-smoke --timeout=150s
# 🔴 앱 저하 — notify-smoke (Degraded) 수신 확인 후 원복:
kubectl -n notify-smoke rollout undo deploy/notify-smoke
kubectl -n argocd wait --for=jsonpath='{.status.health.status}'=Healthy application/notify-smoke --timeout=120s
```
Expected: Degraded 알림 1건 + 원복 후 Healthy. 대상은 notify-smoke뿐(실앱 무영향).

**Step 6.4 — recipient `$` 해석 최종 확정(Task 3.5, PR1):** 로그에 recipient 파싱 에러 없으면 `$telegram-chat-id` 유지,
있으면 chatId 리터럴로 보정 후 재싱크. **← 여기까지 통과해야 PR2(프로덕션 라벨)로 진행.**

**Step 6.5 — 프로덕션 라벨 하드게이트(PR2 — Task 4 머지 후, F2 게이트).** 라이브 Application 라벨 직접 확인:
```bash
for a in $(kubectl -n argocd get applications -o name); do
  printf '%s\t%s\n' "$a" "$(kubectl -n argocd get "$a" -o jsonpath='{.metadata.labels.notify\.homelab/telegram}')"
done
# 기대: <앱>-prod / data-conn-prod / cache-prod / cnpg-data = true ; cert-manager-prod·victoria-stack-prod = (빈값)
```
Expected: 의도한 대상만 `true`, 비대상(cert-manager/victoria-stack/argocd-extras 등) 빈값. 어긋나면 Task 4 보정.

**Step 6.5b — 멀티소스 dedup 검증(PR2 — 패스5 F2).** 단일소스 smoke로는 못 잡는 멀티소스(apps appset) dedup을 **실 app-prod로** 확정:
```bash
# 라벨된 멀티소스 앱의 revisions 구조 확인(단수 revision vs 복수 revisions)
app=$(kubectl -n argocd get applications -l notify.homelab/telegram=true -o name | grep -- '-prod' | grep -vE 'data-conn|cache|cnpg' | head -1)
kubectl -n argocd get "$app" -o jsonpath='{.status.sync.revision}{"\n"}{.status.sync.revisions}{"\n"}'
```
- `revisions`(복수)가 채워지면 trigger oncePer 표현식(`join(revisions,",")`)이 맞는지 확인.
- **실증**: 그 앱에 이미지 bump 1회 → `✅ 배포 완료` **정확히 1건**(0건=억제/표현식 오류, 2건+=dedup 실패). 어긋나면 oncePer 표현식 보정 후 재싱크.

**Step 6.6 — 정리:**
```bash
kubectl delete application notify-smoke -n argocd
kubectl get ns notify-smoke 2>/dev/null && kubectl delete ns notify-smoke || true
kubectl -n argocd get application notify-smoke 2>/dev/null || echo "smoke 제거됨"
```
(smoke 디렉토리/Application은 검증 후 PR로 제거하거나, 재사용 위해 남기되 '테스트 전용' 라벨/문서 명시.)

---

## 함정 체크리스트 (라이브 검증된 것)

- **NetworkPolicy egress apiserver는 ClusterIP 불가** → node-subnet `192.168.139.0/24:6443`(DNAT-후).
- **ipBlock에 pod CIDR(10.42/16) 금지**(deny 무력화). 외부는 `0.0.0.0/0 except 사설대역`.
- **except 192.168.0.0/16 포함 시 apiserver(192.168.139.x)도 제외** → apiserver allow 별도 to 블록.
- **appset goTemplate `missingkey=error`** — 미정의 `.X` 참조 금지. 조건부는 **templatePatch**.
- **SealedSecret ns/name 스코프** — argocd ns·`argocd-notifications-secret`(`--scope strict`).
- **Helm/SealedSecrets 이중 소유** → `notifications.secret.create: false`.
- **cnpg는 appset exclude·수동 Application** → cnpg-data.yaml 직접 라벨.
- **ConfigMap 변경 파드 자동 재시작 없음** — cm 변경 후 컨트롤러 reload 여부 확인.
- **Degraded 테스트는 canary만 + selfHeal:false + progressDeadlineSeconds:60** — 실앱 불가침·결정적.
- **멀티소스 Application은 `status.sync.revisions`(복수)** — oncePer 단수 `revision` 부적합(실앱 dedup 깨짐). 실 app-prod로 검증.
- **netpol은 차트 extraObjects·sync-wave -1**(컨트롤러 선행) — extras 분리 시 부트스트랩 exfil 창. 상주 컨트롤러는 **자원 limit+원장** 필수.

---

## Adversarial review dispositions (Phase A.5 + Phase C)

codex 적대 리뷰 — 설계 1패스(A.5) + 계획 5패스(C). **모든 finding Accept·반영.** 3패스 cap 도달 후 사용자 승인으로
패스4·5 진행, 패스5 반영 후 **사용자 결정으로 확정**(approve 미도달이나 전 finding 반영 + 실행단계 라이브 게이트 보유).

- **A.5(design)**: F1 Secret 이중소유→`secret.create:false` · F2 cnpg appset exclude→cnpg-data 직접 라벨 · F3 egress 누락→apiserver node-subnet 포함 컨트롤러 egress
- **C1**: F1(H) appset .CHATID/inline-if 파손→라벨+templatePatch·chatId 선확정 · F2(H) Degraded 실앱 장애→전용 canary
- **C2**: F1(H) Degraded↔selfHeal→selfHeal:false+progressDeadline:60 · F2(M) 라벨 렌더 skip→라이브 하드게이트 · F3(M) bats `[[ ]]` false-green→가드 단언
- **C3**: F1(H) subscriptions 블록스칼라 무효→YAML 리스트+렌더 파싱 테스트 · F2(M) canary 순서→canary-first 2-PR+롤백
- **C4**: F1(H) 자원/원장 누락→limit+memory-ledger · F2(H) 부트스트랩 순서→패스5 F1로 최종해결 · F3(M) netpol 발견 순환→known-deps+사후 연결테스트
- **C5(최종)**: F1(H) egress 창 not-benign→netpol 차트 extraObjects·sync-wave -1 선행 · F2(H) 멀티소스 oncePer→revisions 호환+실 app-prod 검증 · F3(M) smoke 미명세→Task 5b 전용+상주화 가드

최종 verdict: needs-attention(C5). 전 finding 반영. 미재검토 잔여 = C5 반영분(사용자 확정).

## Execution directives
- **Skill:** `executing-plans`로 **별도 세션·이 worktree**에서 구현.
- **연속 실행:** 루틴 리뷰로 batch 사이 멈추지 않는다. 멈춤은 진짜 블로커만 — 누락 의존·반복 실패 검증·모순 지시·치명적 계획 갭.
- **롤아웃 2-PR**: PR1(Task 1·2·3·5·5b + Task 6.1–6.4 canary) → PR2(Task 4 라벨 + Task 6.5–6.5b 프로덕션 게이트). **canary 통과가 PR2 진입 게이트.**
- **Commits — 직접 적용·`Skill(commit)` 호출 금지**(대화형이라 연속 실행 깨짐):
  - 한국어. **AI 마커 금지**(`🤖 Generated with`·`Co-Authored-By` 등).
  - `<type>(<scope>): 설명`. type=`feat`/`fix`/`refactor`/`docs`/`style`/`test`/`chore`만.
  - 각 plan `Commit` 스텝에서 현재 worktree 브랜치에 직접 커밋(이미 main 밖 — 새 브랜치 불요).
- **검증 우선:** 완료 주장 전 bats/kubeconform/helm 렌더 + Task 6 라이브 수신 확인(verification-before-completion).
- **bats 단언은 가드 패턴**(`grep -qF || { echo; false; }` / `[ ] || { …; false; }`) — 중간 `[[ ]]` 금지. **@test 이름 영어**.
