# ArgoCD UI 인터널 노출 — 구현 플랜

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.
> 라이브 검증/디버그는 `argo`·`observability` 스킬(read-only) 참고. 설계 근거는
> `docs/plans/2026-06-16-argocd-ui-internal-design.md`. 본 플랜은 codex 어드버서리얼 리뷰 5패스 +
> #53/#54 머지 후 재검토 1패스를 거쳐 강화됐다(말미 **Adversarial review dispositions** 감사 기록).

**Goal:** ArgoCD 웹 UI를 `argocd.home.ukyi.app`(tailnet/LAN 내부 전용)로 노출하고, 커스텀 로컬 계정
`ukkiee`(풀 어드민, 비밀번호는 `.env.secrets`)로 로그인. built-in admin은 노출 전에 비활성화한다.

**Architecture:** self-managed ArgoCD(argo-helm 7.7.11)에 ① 비밀 아닌 설정(`accounts.ukkiee`+RBAC+
`admin.enabled:false`)은 `bootstrap-values.yaml`의 `configs.cm`/`configs.rbac`(차트 단독 소유), ② 비밀번호는
patch-mode SealedSecret로 차트 관리 `argocd-secret`에 머지, ③ 노출은 별도 Application
`platform/argocd/extras`(HTTPRoute, `web-internal-tls`)로 배선. DNS/TLS cert/NetworkPolicy 변경 없음.

**Tech Stack:** Kubernetes(k3s), ArgoCD(argo-helm 7.7.11), Gateway API(Traefik), SealedSecrets
(controller 0.37.0, `sealed-secrets-controller`/ns `sealed-secrets`), kustomize, kubeseal, argocd CLI,
bats, yq(mikefarah v4).

**2단계 롤아웃 (F15/F17 — 노출은 자격이 입증된 마지막 단계):**
- **Phase 1 / PR1** — `ukkiee` 계정 + RBAC + 봉인 비밀번호 **+ `admin.enabled:false`**. **노출 없음.**
  → **port-forward**로 ukkiee 로그인 성공 + **구 admin 거부**를 입증. 외부 노출 0.
- **Phase 2 / PR2** — HTTPRoute 노출 **만**. admin은 PR1에서 이미 off·입증됐고 route는 별도 Application이라,
  노출 시점에 admin은 확실히 꺼져 있다("admin 켜진 채 노출" 윈도우 원천 제거 — same-PR 원자성에 의존하지 않음).

**역할:** 대부분 에이전트 수행. **`[OWNER]`는 라이브 클러스터+시크릿 필요**(봉인·라이브 검증).
작업 브랜치 `feat/argocd-ui-internal`(origin/main #55 `796324c` 위에 rebase).

---

## 사전 조건 (실행 전 확인)

- 브랜치 `feat/argocd-ui-internal`(현재 origin/main `796324c`=#55 위에 rebase, 설계 문서 커밋 포함),
  워킹트리 clean. (#53 디렉토리 리팩터 + #54 CI/CD 하드닝 반영; #55 차트 kind 축소는 무관.)
- 라이브 확인됨: Service `argocd-server`는 `80→8080(http)`, `argocd` ns엔 default-deny NetworkPolicy 없음,
  `argocd-secret`은 차트가 **data 블록 없이** 생성(런타임 키만), AdGuard 와일드카드가 `argocd.home.ukyi.app`
  해석, `argocd-cm.url=https://argocd.home.ukyi.app`, `server.insecure=true`.
- SYNC-WAVES.md 현재 shape: edge는 wave `0`(상류 #53 리팩터에서 `-6`→`0`).
- **#54 게이트**: `scripts/run-bats.sh`가 tracked `test_*.bats` 전수=gate(SSOT), `check-bats-accounting.sh`가
  미배정/이중소유 차단. 신규 `test_*.bats`는 CI-safe면 자동 gate(별도 등록 불요).
- 도구: `kustomize`·`yq`·`bats`. `[OWNER]`엔 추가로 `argocd` CLI·`kubeseal`·`KUBECONFIG`·`.env.secrets`.

---
---

# Phase 1 (PR1) — 자격·계정·admin off (노출 없음)

## Task 1: bootstrap-values — ukkiee 계정 + RBAC + admin 비활성화 (+ 구조 가드)

**Files:**
- Modify: `platform/argocd/bootstrap-values.yaml`
- Modify: `platform/argocd/test_argocd_values.bats` (기존 — #54가 추가; @test 5개 append, 신규 파일 X)

**Step 1: `configs.cm`에 계정 + admin off 추가** (기존 `kustomize.buildOptions`/`resource.exclusions` 블록)

```yaml
    # 로컬 계정 ukkiee 활성화 — UI/CLI 비밀번호 로그인(login capability). apiKey 미부여(token 발급 불가, 의도).
    # 비밀번호(bcrypt)는 argocd-secret에 patch-mode SealedSecret로 머지(platform/argocd/extras).
    accounts.ukkiee: login
    # built-in admin 비활성화 — ukkiee 단일 어드민(F12). 노출(PR2) 전에 PR1에서 끄고 port-forward로
    # 입증해 'admin 켜진 채 노출' 윈도우를 원천 제거(F17 — same-PR은 두 Application 독립 sync라 비원자적).
    admin.enabled: "false"
```

**Step 2: `configs.rbac` 블록 신규** (`configs:` 하위, `cm`와 같은 레벨)

```yaml
  rbac:
    # ukkiee에 직접 subject 정책(p-policy)으로 전체 권한 부여. group 바인딩(g, ukkiee, role:admin)이 아니라
    # p-policy를 쓰는 이유: 추후 SSO(dex) 도입 시 동명 scope/group이 롤을 상속하는 충돌 에스컬레이션 차단(F4).
    # policy.default는 라이브 현재 미설정이며 내장 기본과 동일 — 명시화일 뿐 narrowing 아님.
    policy.default: role:readonly
    policy.csv: |
      p, ukkiee, *, *, *, allow
```

**Step 3: 2-writer 안전 불변식 가드 주석** (`configs:` 위 또는 `server.insecure` 근처)

```yaml
  # ⚠️ configs.secret.* (argocdServerAdminPassword 등) 추가 금지 — 추가하면 차트가 argocd-secret에
  #    data 블록을 렌더해 SSA가 data.*를 소유하고, sealed-secrets 컨트롤러가 머지한 accounts.ukkiee.* 키를
  #    prune할 수 있다. ukkiee 비밀번호는 extras의 patch-mode SealedSecret이 additive로 공급한다.
```

**Step 4: 구조 가드 확장 (network-free pre-merge gate — F3)** — 기존 `platform/argocd/test_argocd_values.bats`에 @test append

#54의 `scripts/run-bats.sh` gate가 tracked `test_*.bats`를 전수 실행하므로, 이 **기존 파일**에 ukkiee/RBAC/
admin-off/불변식 단언을 **append**한다(별도 파일 신설 금지 — accounting 중복/이중소유 회피). 러너는 repo
root에서 돌므로 경로는 root-상대(기존 파일 스타일과 일치):

```bash
# ↓ platform/argocd/test_argocd_values.bats 끝에 추가 (V= 는 파일에 한 번만)
V="platform/argocd/bootstrap-values.yaml"

@test "ukkiee account is enabled with login capability in configs.cm" {
  run yq '.configs.cm."accounts.ukkiee"' "$V"; [ "$output" = "login" ]
}

@test "ukkiee gets admin via a collision-resistant p-policy; default is readonly" {
  run yq '.configs.rbac."policy.default"' "$V"; [ "$output" = "role:readonly" ]
  run yq '.configs.rbac."policy.csv"' "$V"; [ "$status" -eq 0 ]
  echo "$output" | grep -qE 'p, ukkiee, [*], [*], [*], allow'
}

@test "built-in admin is disabled (ukkiee is the sole admin path)" {
  run yq '.configs.cm."admin.enabled"' "$V"; [ "$output" = "false" ]
}

@test "no configs.secret block (preserves argocd-secret two-writer safety invariant)" {
  run yq '.configs.secret' "$V"; [ "$output" = "null" ]
}

@test "server.insecure stays true (TLS terminated upstream)" {
  run yq '.configs.params."server.insecure"' "$V"; [ "$output" = "true" ]
}
```

**Step 5: 게이트**

Run: `bats platform/argocd/test_argocd_values.bats`
Expected: PASS (기존 3 + 신규 5 tests).

**Step 6: Commit**
```bash
git add platform/argocd/bootstrap-values.yaml platform/argocd/test_argocd_values.bats
git commit -m "feat: argocd ukkiee 계정(p-policy admin) + built-in admin 비활성화 + 구조 가드"
```

---

## Task 2: extras 디렉토리 — SealedSecret 자리 (route는 PR2)

**Files:**
- Create: `platform/argocd/extras/kustomization.yaml`
- Create: `platform/argocd/extras/test_argocd_extras.bats`

**Step 1: kustomization** (sealed 파일을 미리 등재 — KSOPS generator 없음=일반 CR)

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: argocd # argocd-extras Application의 권위 있는 대상 namespace
resources:
  - argocd-accounts.sealed.yaml # Task 3(OWNER 봉인)이 생성. httproute.yaml은 PR2(Task 9)에서 추가.
```

> ⚠️ **#54 `scripts/run-bats.sh` gate는 tracked `test_*.bats`를 전수 실행 — 커밋마다 green이어야 한다.**
> kustomization이 아직 없는 sealed 파일을 참조하면 `kustomize build`가 실패하므로, **Task 2는 파일만
> 작성하고 커밋하지 않는다.** Task 3(OWNER)이 봉인 후 kustomization+sealed+bats를 **한 커밋**으로 묶어
> tracked 상태가 항상 consistent하게 한다. untracked `test_*.bats`는 gate가 수집하지 않으므로 무해.

**Step 2: bats (Task 3 이후 통과)** (`platform/argocd/extras/test_argocd_extras.bats`)

```bash
#!/usr/bin/env bats
# argocd-extras 가드. PR1: SealedSecret(patch-mode). PR2(Task 9)에서 HTTPRoute 단언 추가.
# (@test 이름 영어. 중간 단언 [ ]/단순 명령, 최종 명령 status만 신뢰.)

D="$BATS_TEST_DIRNAME"
S="$D/argocd-accounts.sealed.yaml"

@test "kustomize build succeeds and renders exactly one SealedSecret" {
  run kustomize build "$D"
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | grep -c '^kind: SealedSecret')" -eq 1 ]
}

@test "SealedSecret patch-merges into argocd-secret with patch annotation in template metadata" {
  run yq '.metadata.name' "$S"; [ "$output" = "argocd-secret" ]
  run yq '.metadata.namespace' "$S"; [ "$output" = "argocd" ]
  run yq '.spec.template.metadata.name' "$S"; [ "$output" = "argocd-secret" ]
  run yq '.spec.template.metadata.namespace' "$S"; [ "$output" = "argocd" ]
  run yq '.spec.template.metadata.annotations."sealedsecrets.bitnami.com/patch"' "$S"; [ "$output" = "true" ]
  run yq '.spec.encryptedData."accounts.ukkiee.password"' "$S"; [ "$output" != "null" ]
}

@test "no passwordMtime is sealed (avoids RFC3339 settings-load failure)" {
  run yq '.spec.encryptedData."accounts.ukkiee.passwordMtime"' "$S"; [ "$output" = "null" ]
}

@test "kustomization has no KSOPS generator (plain SealedSecret CR)" {
  run grep -q 'generators:' "$D/kustomization.yaml"; [ "$status" -ne 0 ]
}
```

**Step 3: 커밋하지 않는다** — `kustomization.yaml` + `test_argocd_extras.bats`를 **작성만** 한다(untracked 유지).
sealed 파일이 없어 `kustomize build`가 실패하므로, 봉인(Task 3) 후 Task 3 Step 6에서 셋을 **함께 커밋**한다.

---

## Task 3: 비밀번호 봉인 — patch-mode SealedSecret `[OWNER]`

> 라이브 sealed-secrets 컨트롤러 cert + `.env.secrets` + `argocd`/`kubeseal` CLI 필요. 평문/해시를
> 채팅·로그·디스크에 남기지 않는다.

**Step 1: `.env.secrets`에 비밀번호 설정** (8–32자 — 추후 `argocd account update-password` 회전 호환)

`.env.secrets`(gitignored)에 `export ARGOCD_PASSWORD="<비밀번호>"` 추가(별도 에디터 창).

**Step 2: 봉인 전 cert staleness — hard-fail 확인 (F5)**

`secret-cert-check.sh`는 fetch/파싱 실패 시 **exit 0(soft-skip)**(스크립트 확인됨). OK 토큰을 강제 확인:
```bash
bash scripts/secret-cert-check.sh 2>&1 | tee /dev/stderr | grep -q '^secret-cert-check OK:' \
  || { echo "ABORT: cert preflight가 OK를 증명하지 못함(soft-skip/불일치) — 봉인 중단"; exit 1; }
```
skip/불일치 시 갱신·재커밋·전파 후 재시도:
`kubeseal --controller-namespace sealed-secrets --controller-name sealed-secrets-controller --fetch-cert > tools/sealed-secrets-cert.pem`

**Step 3: bcrypt 해시 생성 + 봉인** (가드된 블록으로 실행 — line-by-line 금지; F1/F8/F10)

```bash
set -euo pipefail
[ -f .env.secrets ] || { echo "no .env.secrets"; exit 1; }
# .env.secrets 전체를 export하지 않는다(F8) — 서브셸에서 소스해 ARGOCD_PASSWORD만 회수
ARGOCD_PASSWORD="$( . ./.env.secrets >/dev/null 2>&1; printf '%s' "${ARGOCD_PASSWORD:-}" )"
[ -n "$ARGOCD_PASSWORD" ] || { echo "ARGOCD_PASSWORD가 .env.secrets에 없음"; exit 1; }
[ "${#ARGOCD_PASSWORD}" -ge 8 ] && [ "${#ARGOCD_PASSWORD}" -le 32 ] \
  || { echo "ARGOCD_PASSWORD must be 8-32 chars"; exit 1; }
# bcrypt는 stdin에 개행 필요(없으면 fatal EOF)하고 'Password:' 프롬프트를 stdout에 섞으므로
# 60자 bcrypt 토큰만 정규식 추출(F10 — 실측 검증). 평문은 derive 직후 unset(F8).
HASH="$(printf '%s\n' "$ARGOCD_PASSWORD" | argocd account bcrypt 2>/dev/null \
  | grep -oE '[$]2[ayb][$][0-9]{2}[$][./A-Za-z0-9]{53}' || true)"
unset ARGOCD_PASSWORD
case "$HASH" in
  '$2a$'*) : ;;
  *) echo "bcrypt 해시 추출 실패(EOF/프롬프트/형식) — 봉인 중단"; exit 1 ;;
esac
# patch 주석은 평문 Secret metadata에 두면 kubeseal이 spec.template.metadata.annotations로 운반한다
# (컨트롤러가 거기서 읽음). passwordMtime은 봉인하지 않는다(불필요 + 잘못된 RFC3339면 전역 settings 실패).
printf '%s\n' \
'apiVersion: v1' \
'kind: Secret' \
'metadata:' \
'  name: argocd-secret' \
'  namespace: argocd' \
'  annotations:' \
'    sealedsecrets.bitnami.com/patch: "true"' \
'type: Opaque' \
'stringData:' \
"  accounts.ukkiee.password: \"$HASH\"" \
| kubeseal --cert tools/sealed-secrets-cert.pem --format yaml \
  > platform/argocd/extras/argocd-accounts.sealed.yaml
unset HASH
```

**Step 4: 봉인 결과 구조 검증** (patch 주석 위치 = 최대 실패 표면)
```bash
yq '.metadata.name' platform/argocd/extras/argocd-accounts.sealed.yaml            # argocd-secret
yq '.metadata.namespace' platform/argocd/extras/argocd-accounts.sealed.yaml       # argocd
yq '.spec.template.metadata.annotations."sealedsecrets.bitnami.com/patch"' platform/argocd/extras/argocd-accounts.sealed.yaml  # true
yq '.spec.encryptedData."accounts.ukkiee.password"' platform/argocd/extras/argocd-accounts.sealed.yaml  # 암호문(null 아님)
```
주석이 `spec.template.metadata.annotations`가 아니라 SealedSecret 자체 metadata에 있으면 조용히 무시→
full-replace 거부된다. 그 경우 `kubeseal --raw --namespace argocd --name argocd-secret`로 암호문만 얻어
`platform/adguard/prod/adguard-auth.sealed.yaml` 형식 래퍼에 넣되 **patch 주석을 `spec.template.metadata.annotations`에 명시**한다.

**Step 5: kustomization 확인** — `argocd-accounts.sealed.yaml`은 Task 2에서 이미 `resources:`에 등재됨.
이제 sealed 파일이 존재하므로 `kustomize build platform/argocd/extras`가 성공한다(다음 Step 검증).

**Step 6: 게이트 + 일괄 커밋 + 정리** (extras dir를 consistent한 **한 커밋**으로 — Task 2 파일 포함)
```bash
bats platform/argocd/extras/test_argocd_extras.bats && kustomize build platform/argocd/extras >/dev/null && echo OK
git add platform/argocd/extras/   # kustomization + argocd-accounts.sealed.yaml + test_argocd_extras.bats
git commit -m "feat: ukkiee 비밀번호 patch-mode SealedSecret(argocd-secret 머지)"
unset HASH
```

---

## Task 4: argocd-extras Application 배선 + sync-wave 원장

**Files:**
- Create: `platform/argocd/root/apps/argocd-extras.yaml`
- Modify: `platform/argocd/root/SYNC-WAVES.md`
- Modify: `platform/argocd/root/test_root_app.bats` (기존 — #54가 추가; @test 2개 append, 신규 파일 X)

**Step 1: Application** (`platform/argocd/root/apps/argocd-extras.yaml`)

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: argocd-extras
  namespace: argocd
  annotations:
    # PR1: argocd-secret에 ukkiee 비밀번호 패치(SealedSecret). PR2: argocd UI HTTPRoute 추가.
    # gateway(-8)·sealed-secrets 컨트롤러(-8)·argocd 차트 app(-10)이 먼저 떠 있어야 머지/attach → wave 1.
    # (Application 경계 health 게이트는 없어 eventual — retry 소진 시 명시 sync로 복구: Task 8 참조.)
    argocd.argoproj.io/sync-wave: "1"
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  source:
    repoURL: https://github.com/ukyi-app/homelab.git
    targetRevision: main
    path: platform/argocd/extras
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:
    automated: { prune: true, selfHeal: true }
    syncOptions:
      - CreateNamespace=false # argocd ns는 argocd 차트 app(-10)이 소유
      - ServerSideApply=true  # HTTPRoute atomic-list 함정 회피(PR2)
    retry:
      limit: 5
      backoff: { duration: 15s, factor: 2, maxDuration: 5m }
```

**Step 2: 원장 행 추가** (`SYNC-WAVES.md` top 테이블의 `0`(edge) 행과 `+2`(observability) 행 사이 — 현재 shape)
```
|   1  | argocd-extras: ukkiee 계정 패치 SealedSecret (PR2: argocd UI HTTPRoute web-internal-tls) | (argocd-ui) |
```

**Step 3: 원장 가드**

Run: `bats platform/argocd/root/test_sync_wave_ledger.bats`
Expected: PASS (manifest wave "1"이 원장 행과 매칭).

**Step 4: apps 렌더 가드 확장 (F9)** — 기존 `platform/argocd/root/test_root_app.bats`에 @test append

`test_render.bats`는 `appset.yaml`만, `test_root_app.bats`는 root-app/argocd-app만 본다 —
`root/apps/*.yaml`은 미파싱이라 malformed Application이 통과한다. 기존 파일(root-상대 경로 스타일)에 append:
```bash
# ↓ platform/argocd/root/test_root_app.bats 끝에 추가
@test "every root/apps yaml is valid and is an Application" {
  for f in platform/argocd/root/apps/*.yaml; do
    run yq e 'true' "$f"; [ "$status" -eq 0 ]
    run yq '.kind' "$f"; [ "$output" = "Application" ]
  done
}

@test "argocd-extras Application targets the right path/namespace with SSA + CreateNamespace=false" {
  A="platform/argocd/root/apps/argocd-extras.yaml"
  run yq '.spec.source.path' "$A"; [ "$output" = "platform/argocd/extras" ]
  run yq '.spec.destination.namespace' "$A"; [ "$output" = "argocd" ]
  run grep -q 'ServerSideApply=true' "$A"; [ "$status" -eq 0 ]
  run grep -q 'CreateNamespace=false' "$A"; [ "$status" -eq 0 ]
}
```

**Step 5: 렌더+원장 가드**

Run: `bats platform/argocd/root/test_render.bats platform/argocd/root/test_root_app.bats platform/argocd/root/test_sync_wave_ledger.bats`
Expected: 전부 PASS.

**Step 6: Commit**
```bash
git add platform/argocd/root/apps/argocd-extras.yaml platform/argocd/root/SYNC-WAVES.md platform/argocd/root/test_root_app.bats
git commit -m "feat: argocd-extras Application 배선 + sync-wave 원장 + apps 렌더 가드"
```

---

## Task 5: `.env.secrets.example`에 ARGOCD_PASSWORD 항목

**Files:** Modify `.env.secrets.example` (마지막 항목 뒤, 실제 값 금지)

```bash
# ── ⑨ ArgoCD UI 로컬 계정 ukkiee 비밀번호 (8–32자) ──────────────────────────────
# argocd UI(argocd.home.ukyi.app) 로그인 계정 ukkiee의 비밀번호. argocd account bcrypt로 해시 →
# patch-mode SealedSecret(argocd-secret)로 봉인. 값을 채팅/로그에 붙여넣지 말 것.
export ARGOCD_PASSWORD=""
```
```bash
git add .env.secrets.example
git commit -m "docs: .env.secrets.example에 ARGOCD_PASSWORD 추가"
```

---

## Task 6: 기반 게이트 (PR1)

```bash
# 신규/확장 테스트만 빠르게 (dev):
bats platform/argocd/test_argocd_values.bats platform/argocd/extras/ platform/argocd/root/   # 전부 PASS
# 권위 게이트(#54 SSOT):
make verify   # 스켈레톤 + bats accounting(신규 extras 테스트가 정확히 1도메인인지) + 배포계약 + 원장 + sops
make ci       # ci.yaml 'gate' 로컬 재현 — scripts/run-bats.sh로 tracked test_*.bats 전수 + chart-test
```
> 커밋 없음(검증만). 신규 `test_argocd_extras.bats`는 CI-safe(`kustomize build`만, KSOPS/helm/cluster 없음)라
> run-bats gate에 자동 편입되고 accounting을 통과한다(.ci-exclude 불요). argocd helm-app은 CI 렌더 대상이
> 아니므로 values는 Task 1 구조 가드(확장) + Task 8 라이브로 커버.

---

## Task 7: PR1 생성·머지

`pr` 스킬로 PR 생성(한국어). 본문: 설계 문서 링크 + "노출 없음; ukkiee+admin off; Task 8 port-forward
검증 예정(ukkiee 로그인 OK + 구 admin 거부)". required check `gate` 통과 후 머지.

---

## Task 8: PR1 라이브 검증 — port-forward로 ukkiee 증명 + admin off 입증 `[OWNER]` (머지·sync 후)

> `KUBECONFIG=$PWD/infra/k3s-bootstrap/kubeconfig`. **노출 전이라 port-forward로만 접근**(외부 노출 0).
> admin은 PR1에서 비활성화되므로 이 단계의 fallback은 cluster(kubectl) 접근이다.

**Step 1: Application 동기화 + retry 소진 복구 (F6/F13)**
```bash
kubectl -n argocd get app argocd-extras       # Synced / Healthy
kubectl -n argocd get app argocd              # 여전히 Synced/Healthy (argocd-secret churn 없음; admin off 반영)
# retry 소진으로 Failed면 repo 타깃으로 복구:
make argo-sync APP=argocd-extras        # 명시 sync 트리거(retry 소진 후 재시도)
make argo-terminate APP=argocd-extras   # 멈춘 operation 종료(phase=Terminating, --subresource status 내장)
```

**Step 2: 비밀번호 머지 + 기존 키 생존 (값/해시 미출력 — F2)**
```bash
kubectl -n argocd get secret argocd-secret -o jsonpath='{.data.accounts\.ukkiee\.password}' \
  | base64 -d | grep -q '^\$2a\$' && echo "ukkiee password sealed OK"
kubectl -n argocd get secret argocd-secret -o json | yq -p=json '.data | keys'   # server.secretkey 등 생존(이름만)
kubectl -n argocd get secret argocd-secret -o yaml | yq '.metadata.managedFields[].manager'  # sealed-secrets-controller 포함
```

**Step 3: port-forward로 ukkiee 증명 + 구 admin off 입증 (hermetic, fail-closed — F18/F20)**

캐시 컨텍스트 거짓통과 방지(격리 `--config`) + 각 단계 exit 단언 + admin off는 **`argocd-cm.admin.enabled==false`
설정 단언**(권위적, fail-closed; 로그인 거부는 보조). 가드된 블록으로 실행:
```bash
set -euo pipefail
CFG="$(mktemp -u)"   # 격리 config — 캐시 컨텍스트 yes 오염 차단(F18)
kubectl -n argocd port-forward svc/argocd-server 8080:80 >/dev/null 2>&1 &
PF=$!; trap 'kill $PF 2>/dev/null; rm -f "$CFG"' EXIT
sleep 2
UKPW="$( . ./.env.secrets >/dev/null 2>&1; printf '%s' "${ARGOCD_PASSWORD:-}" )"
# ukkiee: 로그인 성공(exit 0) + 신원 확인 후에만 권한 단언 (캐시 yes 방지)
argocd --config "$CFG" login localhost:8080 --plaintext --grpc-web --username ukkiee --password "$UKPW"
argocd --config "$CFG" account get-user-info -o json | yq -p=json -e '.loggedIn == true and .username == "ukkiee"'
argocd --config "$CFG" account can-i sync applications '*' | grep -qx yes
unset UKPW
# admin off는 '설정 사실'로 fail-closed 단언 — 로그인-시도 추론보다 권위적(F20).
# yq -e: admin.enabled가 "false"가 아니면(true/빈값/부재) 비0 종료 → set -e로 게이트 차단.
kubectl -n argocd get cm argocd-cm -o json | yq -p=json -e '.data."admin.enabled" == "false"'
# (보조) 현재 admin 비밀번호를 알 수 있으면 그것으로 거부 재확인 — 모르면 위 설정 단언이 권위
ADMINPW="$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || true)"
if [ -n "$ADMINPW" ]; then
  ! argocd --config "$CFG" login localhost:8080 --plaintext --grpc-web --username admin --password "$ADMINPW" 2>/dev/null \
    || { echo "FAIL: admin이 현재 비밀번호로 로그인됨 — 노출 금지"; exit 1; }
fi
unset ADMINPW
```
> ✅ ukkiee 로그인+권한 + 구 admin 거부가 모두 통과해야 Phase 2 진행. admin이 현재 비밀번호로 로그인되면
> argocd self-app sync/reload 점검(`make argo-sync APP=argocd`) 후 재확인 — **노출 금지**.

**Step 4: 구 admin 자격 state 폐기 + 초기 시크릿 제거 (F19 — 노출 전, ukkiee 입증 후)**

`admin.enabled:false`만으론 `admin.password`/`passwordMtime` 해시가 argocd-secret에 잔존 → 나중에
admin 재활성/드리프트/DR/긴급경로에서 **옛 비밀번호 부활**. 노출 전에 state를 비운다:
```bash
kubectl -n argocd patch secret argocd-secret --type=merge \
  -p '{"data":{"admin.password":null,"admin.passwordMtime":null}}'
kubectl -n argocd rollout restart deploy/argocd-server
kubectl -n argocd rollout status deploy/argocd-server --timeout=120s
# 검증: 해시 부재 + 초기 시크릿 제거(admin off라 재생성 안 됨)
kubectl -n argocd get secret argocd-secret -o json | yq -p=json -e '.data."admin.password" == null'
kubectl -n argocd delete secret argocd-initial-admin-secret --ignore-not-found
```
> **admin break-glass 복구** (F16/F19 동시 해소): admin.password를 비웠으므로 `admin.enabled:"false"`만
> 제거(커밋·sync)하면 ArgoCD가 **새 비밀번호를 `argocd-initial-admin-secret`에 재생성**한다(옛 해시 재사용 없음):
> ```bash
> # values에서 admin.enabled:"false" 제거(커밋·sync), 또는 긴급시:
> kubectl -n argocd patch cm argocd-cm --type merge -p '{"data":{"admin.enabled":"true"}}'
> kubectl -n argocd rollout restart deploy/argocd-server
> kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d
> ```
> (cluster 접근 전제. 런북 `argocd`에 기록.)

---
---

# Phase 2 (PR2) — 노출 (admin은 PR1에서 이미 off·입증됨, F17)

## Task 9: HTTPRoute 노출 추가

**Files:**
- Create: `platform/argocd/extras/httproute.yaml`
- Modify: `platform/argocd/extras/kustomization.yaml` (+httproute.yaml)
- Modify: `platform/argocd/extras/test_argocd_extras.bats` (+HTTPRoute 단언)

**Step 1: HTTPRoute** (`platform/argocd/extras/httproute.yaml`)
```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: argocd-server
spec:
  parentRefs:
    # group/kind는 CRD 기본값이지만 명시 — SSA atomic 리스트(parentRefs) 영구 OutOfSync 함정 회피
    # (grafana/adguard 라우트 검증, AGENTS.md).
    - group: gateway.networking.k8s.io
      kind: Gateway
      name: homelab
      namespace: gateway
      sectionName: web-internal-tls # *.home.ukyi.app 와일드카드 cert로 TLS 종단
  hostnames:
    - "argocd.home.ukyi.app"
  rules:
    - matches:
        - path: { type: PathPrefix, value: / }
      backendRefs:
        # argocd-server Service:80(→8080)은 server.insecure=true라 평문 HTTP. 443 아님(TLS-on-TLS 회피).
        # 같은 argocd 네임스페이스라 ReferenceGrant 불필요.
        - group: ""
          kind: Service
          name: argocd-server
          port: 80
          weight: 1
```

**Step 2: kustomization `resources:`에 추가**
```yaml
  - httproute.yaml # argocd UI를 argocd.home.ukyi.app로 노출(web-internal-tls)
```

**Step 3: bats에 HTTPRoute 단언 추가** (`test_argocd_extras.bats`)
```bash
@test "kustomize build also renders exactly one HTTPRoute" {
  run kustomize build "$D"
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | grep -c '^kind: HTTPRoute')" -eq 1 ]
}

@test "HTTPRoute exposes argocd UI on web-internal-tls to argocd-server:80" {
  H="$D/httproute.yaml"
  run grep -q 'argocd.home.ukyi.app' "$H"; [ "$status" -eq 0 ]
  run grep -q 'sectionName: web-internal-tls' "$H"; [ "$status" -eq 0 ]
  run grep -q 'name: argocd-server' "$H"; [ "$status" -eq 0 ]
  run grep -qE 'port: 80' "$H"; [ "$status" -eq 0 ]
  run grep -q 'kind: Gateway' "$H"; [ "$status" -eq 0 ]
  run grep -qE 'weight: 1' "$H"; [ "$status" -eq 0 ]
}
```

**Step 4: 게이트 + 커밋** (노출 전 admin off 입증=Task 8 통과가 전제 — F17)
```bash
bats platform/argocd/extras/ && kustomize build platform/argocd/extras >/dev/null && echo OK
git add platform/argocd/extras/httproute.yaml platform/argocd/extras/kustomization.yaml platform/argocd/extras/test_argocd_extras.bats
git commit -m "feat: argocd UI HTTPRoute — argocd.home.ukyi.app(web-internal-tls)"
```

---

## Task 10: PR2 생성·머지

`pr` 스킬로 PR 생성(한국어). 본문: **선행 조건 = Task 8에서 admin off가 라이브로 입증됨**(노출은 그 뒤).
PR2는 HTTPRoute만. required check `gate` 통과 후 머지.

---

## Task 11: PR2 라이브 검증 `[OWNER]` (머지·sync 후)

**Step 1: route attach**
```bash
kubectl -n argocd get httproute argocd-server -o yaml \
  | yq '.status.parents[].conditions[] | {(.type): .status}'   # Accepted/ResolvedRefs = True
```
`ResolvedRefs=False`(BackendNotFound)면 Service 이름/포트 불일치 — `kubectl -n argocd get svc argocd-server`.

**Step 2: UI 로그인** (admin은 PR1에서 이미 off — 여기선 ukkiee만 확인)
- 브라우저: `https://argocd.home.ukyi.app` → ukkiee 로그인 성공.
- CLI(**`--grpc-web` 필수** — native gRPC는 TLS-terminate 통과 불가):
```bash
argocd login argocd.home.ukyi.app --grpc-web --username ukkiee \
  && argocd account can-i sync applications '*'                   # ukkiee 정상(admin 권한)
argocd login argocd.home.ukyi.app --grpc-web --username admin    # 실패해야 정상(노출 경로에서도 admin off 재확인)
```

---

## Task 12: 롤백 / 자격 폐기 (Rollback & Revocation) `[OWNER]` — F7/F11

> patch-mode SealedSecret은 CR을 지워도 argocd-secret에 머지된 키를 **자동 제거하지 않는다**(additive,
> ownerRef 없음). 폐기는 아래 명시 절차로만(순서·멱등성 중요). 런북 `argocd`에 기록.

```bash
# 1. 계정/RBAC 비활성: bootstrap-values에서 configs.cm."accounts.ukkiee" + configs.rbac 제거(커밋·sync)
#    (admin 재활성화가 필요하면 admin.enabled:"false"도 제거 — break-glass 복구는 Task 8 참조)
# 2. 노출/시크릿 CR 제거: platform/argocd/extras 또는 argocd-extras Application 삭제(커밋·sync)
# 3. SealedSecret CR이 prune됐는지 먼저 확인 — 남아있으면 컨트롤러가 키를 재주입한다(race):
kubectl -n argocd get sealedsecret argocd-secret 2>/dev/null \
  && { echo "WAIT: sealedsecret 잔존 — prune 완료까지 대기/강제 sync"; exit 1; }
kubectl -n argocd get application argocd-extras 2>/dev/null \
  && { echo "WAIT: argocd-extras Application 잔존 — prune 완료까지 대기"; exit 1; }
# 4. 잔존 키 멱등 삭제(merge-patch null — 키 부재여도 실패 안 함):
kubectl -n argocd patch secret argocd-secret --type=merge \
  -p '{"data":{"accounts.ukkiee.password":null}}'
# 5. settings 재적용:
kubectl -n argocd rollout restart deploy/argocd-server
kubectl -n argocd rollout status deploy/argocd-server --timeout=120s
# 6. 라이브 state 직접 단언(route 제거와 무관 — F21): 키 부재 + 계정 config 제거
kubectl -n argocd get secret argocd-secret -o json | yq -p=json -e '.data."accounts.ukkiee.password" == null'
kubectl -n argocd get cm argocd-cm -o json | yq -p=json -e '(.data."accounts.ukkiee" // "") == ""'
# 7. 로그인 거부는 노출과 무관한 port-forward 경로로 입증(route는 이미 제거됨 — 노출 부재로 인한 false-pass 방지, F21)
OLDPW="$( . ./.env.secrets >/dev/null 2>&1; printf '%s' "${ARGOCD_PASSWORD:-}" )"
kubectl -n argocd port-forward svc/argocd-server 8080:80 >/dev/null 2>&1 & PF=$!
CFG="$(mktemp -u)"; trap 'kill $PF 2>/dev/null; rm -f "$CFG"' EXIT; sleep 2
! argocd --config "$CFG" login localhost:8080 --plaintext --grpc-web --username ukkiee --password "$OLDPW" 2>/dev/null \
  || { echo "FAIL: ukkiee가 옛 비밀번호로 여전히 로그인됨 — 폐기 미완"; exit 1; }
unset OLDPW; echo "revocation OK (port-forward 경로에서 거부 확인)"
```

---

## 완료 기준 (Definition of Done)

- [ ] (PR1) `make ci` GREEN(`scripts/run-bats.sh`가 tracked test_*.bats 전수 + chart-test), `make verify` PASS(bats accounting 포함)
- [ ] (PR1) `kustomize build platform/argocd/extras`가 SealedSecret 1 렌더
- [ ] (PR1) 라이브 **port-forward(격리 `--config`)**로 ukkiee 로그인+신원+권한 성공 **+ 구 admin을 현재 비밀번호로 거부 입증**(F18); argocd-secret 기존 키 생존
- [ ] (PR1) **`admin.password`/`passwordMtime` null 폐기 + 부재 검증**(F19) + initial-admin-secret 제거 — 노출 전, ukkiee 입증 후
- [ ] (PR2) `kustomize build`가 HTTPRoute 1 + SealedSecret 1; route Accepted+ResolvedRefs; `argocd.home.ukyi.app` ukkiee 로그인
- [ ] **노출(PR2)은 admin off가 PR1에서 라이브 입증된 뒤에만** 적용 — same-PR 원자성에 의존하지 않음 (F15/F17)
- [ ] 런북에 `--grpc-web`·admin break-glass(admin.password 폐기로 재활성=새 자격 생성, F16/F19)·DR cold-start 복구(`make argo-sync`/`argo-terminate`)·폐기 절차 기록
- [ ] 플랜이 현재 origin/main(#55 `796324c`) 위에 rebase됨; values/apps 가드는 기존 `test_argocd_values.bats`/`test_root_app.bats` **확장**(신규 파일 X); 선례 경로 갱신(victoria-stack `prod/`, `adguard-auth.sealed.yaml`) (재검토)

---

## Adversarial review dispositions (감사 기록)

본 플랜은 codex 어드버서리얼 리뷰 **5패스** + #53/#54 머지 후 **재검토 1패스**를 거쳤다(모두 `ok:true`·
`planInDiff:true`). 핵심 산출물은 검증됐고, 사용자가 잔여 open-items를 본 뒤 결정/승인하며 강화. 추가로
설계 단계 어드버서리얼 검증(5렌즈+critic, 52 findings)도 선행됐다.

| ID | Pass | Severity | 제목 | 판정 |
|----|------|----------|------|------|
| F1 | 1 | high | 봉인 스니펫이 빈/무효 자격 조용히 생성 | Accepted — `set -euo pipefail`+검증(Task 3) |
| F2 | 1 | high | 라이브 검증이 bcrypt 해시 stdout 출력 | Accepted — 비출력 검사(Task 8 Step 2) |
| F3 | 1 | high | argocd auth values가 pre-merge 렌더 게이트 우회 | Accepted — 구조 bats(Task 1; 재검토에서 기존 파일 확장) |
| F4 | 1 | medium | RBAC group 바인딩이 SSO 충돌 함정 내장 | Accepted — p-policy로 교체(Task 1) |
| F5 | 2 | high | cert preflight soft-skip | Accepted — OK 토큰 hard-fail(Task 3 Step 2) |
| F6 | 2 | high | retry 소진 후 콜드스타트 비-eventual | Accepted — `make argo-sync` 복구(Task 8 Step 1) |
| F7 | 2 | high | 롤백이 full-admin 자격 미폐기 | Accepted — 폐기 태스크(Task 12) |
| F8 | 2 | medium | 비밀번호 argv/env 과다 노출 | Accepted — stdin+서브셸 소스(Task 3 Step 3) |
| F9 | 2 | medium | root 렌더 테스트가 신규 app 미커버 | Accepted — apps 렌더 가드(Task 4; 재검토에서 기존 파일 확장) |
| F10 | 3 | high | bcrypt 명령이 실행 전 abort(EOF/프롬프트) | Accepted — 개행+grep 추출(실측 검증, Task 3) |
| F11 | 3 | medium | 폐기가 SealedSecret과 race·비멱등 | Accepted — prune 선행 + merge-patch null(Task 12) |
| F12 | 4 | high | admin 존치 = 관리 밖 두 번째 풀-어드민 경로 | Accepted(설계 변경) — admin.enabled:false(Task 1, PR1) |
| F13 | 4 | medium | 멈춘 op 종료가 status 서브리소스 누락 | Accepted — `make argo-terminate`(Task 8 Step 1) |
| F14 | 4 | medium | 플랜 전제(브랜치/원장) 이미 거짓 | Accepted — origin/main rebase + SYNC-WAVES 현재 shape |
| F15 | 5 | high | admin 비활성화 전에 UI 노출 | Accepted(설계 변경) — 2단계 롤아웃 |
| F16 | 5 | medium | break-glass가 admin.password state 미처리 | Accepted — state 비우기 복구(Task 8) |
| F17 | 재검토1 | high | same-PR이 admin-off/노출을 원자화 못 함 | Accepted(설계 변경) — **admin off를 PR1로 이동, 노출(PR2)은 admin off 라이브 입증 후** |
| F18 | 재검토2 | high | Phase 게이트가 캐시 컨텍스트·틀린 비밀번호로 거짓 통과 | Accepted — hermetic 검증(격리 `--config`+exit 단언+신원 확인+**알려진 admin 비밀번호로 거부 입증**, Task 8 Step 3) |
| F19 | 재검토2 | high | 구 admin 해시(admin.password) 미폐기 → 부활 위험 | Accepted — 노출 전 `admin.password`/`passwordMtime` null 폐기+부재 검증(Task 8 Step 4); break-glass=재활성 시 새 자격 생성 |
| F20 | 재검토3 | high | admin-off 증명이 stale/없는 자격으로 거짓 통과 | Accepted — **권위적 fail-closed `argocd-cm.admin.enabled==false` 단언**(`yq -e`); 로그인 거부는 보조로 강등(Task 8 Step 3) |
| F21 | 재검토3 | medium | 폐기 검증이 route 제거 때문에 통과(노출 부재 ≠ 폐기) | Accepted — port-forward 경로 + 라이브 state 직접 단언(키·계정 config 부재 + 옛 비밀번호 거부, Task 12) |

### 재검토 (2026-06-17) — origin/main #53/#54 머지 후

finalize 후 origin/main에 **#53(디렉토리 리팩터)·#54(CI/CD 하드닝)**가 머지돼, feat 브랜치를 `96d0f23`에
rebase하고 구조 정합화(코드 산출물 무변경 — 참조·게이트·테스트 배선 정합):
- **R1/R2**: 신규 values/apps 가드 파일 폐기 → #54가 추가한 **기존 `test_argocd_values.bats`/`test_root_app.bats`에 @test append**(중복/이중소유 회피).
- **R3**: 게이트를 `make ci`/`scripts/run-bats.sh`(tracked test_*.bats 전수 + accounting)로 명시; extras 테스트=CI-safe 자동 gate; 커밋마다 green 보장(extras dir는 OWNER 봉인 후 일괄 커밋).
- **R4**: 선례 경로 갱신 — victoria-stack→`prod/`, `auth-sealed.yaml`→`adguard-auth.sealed.yaml`.
- **R5**: retry 복구를 `make argo-sync`/`argo-terminate`(--subresource status) 타깃으로.

재검토 codex 패스들이 realign(R1–R5)엔 finding 0(구조 정합화는 깨끗). 이후 패스들은 노출 전 PR1 검증 계층을
연속 강화(설계 표면 무변경): 패스1=**F17**(same-PR 비원자성)→admin off를 PR1로 이동. 패스2=**F18/F19**(게이트
거짓통과·구 admin 해시 부활)→hermetic 검증+admin.password 폐기. 패스3=**F20/F21**(admin-off 증명 fail-closed화·
폐기 검증 route-독립화)→권위적 `argocd-cm` 단언 + port-forward 폐기 검증. 사용자가 8패스째 수렴을 확인하고
F20/F21 반영 후 **finalize 승인**(추가 리뷰 없이). 미해결 high 없음, 기각된 finding 없음.
