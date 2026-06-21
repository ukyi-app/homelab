# 인프라 드리프트 + 데이터 최소권한 Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 인프라/부트스트랩 드리프트 5갭을 닫는다 — backend 드리프트 가드, cloud-init 멱등 경고, cloudflared seccomp 정합, 고아 PV 감사, prod→database egress 최소권한.

**Architecture:** 대부분 CI/owner-local(backend·cloud-init·storage 감사)·저위험 라이브(cloudflared seccomp). **★발견5(netpol narrowing)만 HIGH 라이브**(라벨 미스→DB outage) — 라이브 `--show-labels`+`make verify-posture` 머지 전 필수. 단일 PR, netpol 강한 게이트(D1).

**Tech Stack:** Terraform(backend.tf), OrbStack cloud-init(bash), Kubernetes NetworkPolicy(CNPG 라벨), bats(run-bats 게이트 + posture 라이브), kustomize.

**설계 출처:** `docs/plans/2026-06-20-infra-drift-least-privilege-design.md`(커밋 `0c5f085`). D1=단일 PR netpol 강한 게이트, D2=storage 감사 스크립트/런북, Retain 불변.

---

## 작업 전 공통 규칙 (모든 Task)

- **bats `@test` 영어**·중간 단언 `[ ]`·`test_` 접두·bash 3.2 호환(mapfile/`[[ ]]`/`cmd && n++` 금지).
- **★netpol(Task 5)은 HIGH 라이브** — 라이브 `kubectl --show-labels`로 정확 라벨 확인 **없이 머지 금지**(라벨 미스=DB 전면 차단). kube-router 룰 설치 갭(`sleep 8` 후 연결)·selfHeal app 임시 patch 원복.
- 안전 작업(1·2·3·4) 먼저 → netpol(5) 마지막(위험 격리 within PR) → 검증(6).
- **커밋**: 한국어 conventional·AI 마커 금지. type=feat/fix/refactor/docs/style/test/chore. (가드/감사=`test:`/`feat:`, seccomp/netpol=`fix:`[보안], 경고=`fix:`/`docs:`.)
- 렌더: `make render COMP=<comp>`(SOPS_AGE_KEY_FILE) 또는 `make chart-test`.

---

## Task 1: backend 드리프트 가드 (거짓 SSOT 진실화)

`_backend/backend.tf`(템플릿)와 3 root 사본이 조용히 발산하던 것을 일치 강제.

**Files:**
- Create: `tests/test_backend-drift.bats` (또는 `infra/_tests/`)
- Modify: `infra/_backend/backend.tf` (주석 명시)

**Step 1: 실패 테스트 작성**:
```bash
#!/usr/bin/env bats
# terraform backend는 root 안에 있어야 해 공유 불가 → _backend/backend.tf는 template, 각 root가 사본.
# 사본이 발산하면 거짓 SSOT → backend 블록(주석 제외) 일치 강제. ⚠️ 중간 단언 [ ]만.
setup() { ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"; cd "$ROOT" || exit 1; }

# backend 블록만 추출(주석/공백 제거) — terraform { backend "s3" { ... } }
blk() { grep -vE '^\s*#' "$1" | tr -d '[:space:]'; }

@test "all root backend.tf match the _backend template (no false-SSOT drift)" {
  tmpl="$(blk infra/_backend/backend.tf)"
  [ -n "$tmpl" ]
  for r in cloudflare github tailscale; do
    [ "$(blk infra/$r/backend.tf)" = "$tmpl" ] || { echo "FAIL: infra/$r/backend.tf가 _backend 템플릿과 발산"; false; }
  done
}
```
> ⚠️ `blk`가 주석(`#`)·공백 제거 후 비교 — 두 파일의 주석 차이는 무시, backend 블록 본문만 일치 검사. 실행 시 실제 두 파일이 본문 동일한지 확인(현재 동일).

**Step 2: 실패 확인** — `bats tests/test_backend-drift.bats` → 현재 동일하면 PASS(가드가 미래 드리프트 차단). 만약 현재 발산이면 FAIL → 발산을 먼저 해소(템플릿으로 정렬).

**Step 3: 주석 명시** — `infra/_backend/backend.tf` 상단 주석에:
```
# 이 파일은 **template** — terraform backend 블록은 root 안에 있어야 하므로 각 root(cloudflare/github/
# tailscale)가 이 backend 블록의 사본을 둔다. test_backend-drift.bats가 사본↔템플릿 일치를 강제한다(거짓 SSOT 드리프트 차단).
```

**Step 4: 통과 확인** — `bats tests/test_backend-drift.bats` PASS + accounting(신규 bats 도메인) 확인.

**Step 5: 커밋**
```bash
git add tests/test_backend-drift.bats infra/_backend/backend.tf
git commit -m "test: terraform backend 드리프트 가드(_backend 템플릿↔root 사본 일치 강제)"
```

---

## Task 2: orb-create cloud-init 멱등 경고

머신 존재 시 cloud-init skip → 편집 미적용을 명시 경고(편집→host-up→오인 차단).

**Files:**
- Modify: `infra/k3s-bootstrap/orb-create.sh:22` (skip 경고)
- Modify: `infra/k3s-bootstrap/host-up.sh` (멱등 주석에 예외)
- Test: `infra/k3s-bootstrap/tests/test_*.bats` (경고 문구 단언)

**Step 1: 실패 테스트 작성** — orb-create 관련 기존 bats 또는 신규:
```bash
@test "orb-create warns that cloud-init edits do not apply to an existing machine" {
  run grep -F 'cloud-init.yaml 편집' "$ROOT/infra/k3s-bootstrap/orb-create.sh"
  [ "$status" -eq 0 ]
  run grep -Eq '재생성|orb delete' "$ROOT/infra/k3s-bootstrap/orb-create.sh"
  [ "$status" -eq 0 ]
}
```
> 기존 orb-create 테스트가 있으면 거기에, 없으면 `infra/k3s-bootstrap/tests/test_07-orb-create.bats` 등 신규(네이밍 컨벤션 확인).

**Step 2: 실패 확인** — FAIL(경고 미존재).

**Step 3: orb-create.sh skip 경고** — L22 skip 분기 메시지에:
```bash
  echo "==> Machine '${ORB_MACHINE}' already exists — skipping create (idempotent)."
  echo "    ⚠️ cloud-init.yaml 편집은 기존 머신에 적용되지 않는다 — 반영하려면 재생성(orb delete '${ORB_MACHINE}' 후 재실행)"
  echo "       하거나 머신 내에서 수동 적용. host-up.sh의 다른 단계는 멱등하지만 cloud-init은 생성 1회뿐이다."
```

**Step 4: host-up.sh 주석 예외** — `host-up.sh:4`의 "멱등=안전" 주석에 한 줄:
```bash
# 각 단계가 개별적으로 멱등하므로 host-up.sh 재실행은 안전하다(cattle).
# ⚠️ 단, cloud-init은 머신 생성 1회만 — cloud-init.yaml 편집은 재생성 전까진 미반영(orb-create가 경고).
```

**Step 5: 통과 확인** — 해당 bats PASS + `shellcheck infra/k3s-bootstrap/orb-create.sh infra/k3s-bootstrap/host-up.sh`.

**Step 6: 커밋**
```bash
git add infra/k3s-bootstrap/orb-create.sh infra/k3s-bootstrap/host-up.sh infra/k3s-bootstrap/tests/test_*.bats
git commit -m "fix: orb-create가 cloud-init 편집 미적용을 경고(멱등=변경무시 트랩 가시화)"
```

---

## Task 3: cloudflared seccompProfile 정합 (저 라이브)

cloudflared만 seccompProfile 부재 — 표준(RuntimeDefault) 정합.

**Files:**
- Modify: `platform/cloudflared/prod/deployment.yaml` (securityContext)
- Test: `platform/cloudflared/prod/test_*.bats` (신규 또는 기존 확장)

**Step 1: 실패 테스트 작성**:
```bash
@test "cloudflared sets seccompProfile RuntimeDefault (parity with other components)" {
  D="$ROOT/platform/cloudflared/prod/deployment.yaml"
  command -v yq >/dev/null || skip "yq 미설치(CI setup-toolchain)"
  # pod 또는 container securityContext에 seccompProfile RuntimeDefault
  run yq -e '.spec.template.spec.securityContext.seccompProfile.type == "RuntimeDefault" or (.spec.template.spec.containers[].securityContext.seccompProfile.type == "RuntimeDefault")' "$D"
  [ "$status" -eq 0 ]
}
```
> yq 미설치 skip(CI는 setup-toolchain 제공). 신규 파일이면 CI-fail-closed(`${CI}`면 skip 금지) 고려.

**Step 2: 실패 확인** — FAIL(seccomp 부재).

**Step 3: seccompProfile 추가** — `cloudflared/prod/deployment.yaml`의 pod-level securityContext(`.spec.template.spec.securityContext`)에 추가(없으면 생성). 표준 패턴(homepage:25 동형):
```yaml
      securityContext:
        seccompProfile:
          type: RuntimeDefault
        # (기존 pod-level이 없으면 신설 — runAsNonRoot 등은 container-level 유지)
```
> cloudflared는 nonroot(65532)·drop ALL·RO rootfs라 RuntimeDefault 안전(userspace 터널, 특수 syscall 없음). 기존 container-level securityContext(L34-39)는 유지.

**Step 4: 통과 확인** — 해당 bats PASS + `make render COMP=cloudflared`(또는 chart-test) 렌더 성공.

**Step 5: 커밋**
```bash
git add platform/cloudflared/prod/deployment.yaml platform/cloudflared/prod/test_*.bats
git commit -m "fix: cloudflared에 seccompProfile RuntimeDefault 추가(seccomp 표준 정합)"
```

---

## Task 4: storage 고아 Released PV 감사 (D2: 스크립트/런북)

Retain(DB 보호)으로 PVC 삭제 시 PV가 Released로 잔존+디스크 누수 — 가시화 + 수동 reclaim 런북.

**Files:**
- Create: `scripts/audit-orphan-pv.sh`
- Test: `tests/gates/test_audit-orphan-pv.bats` (신규 — 구조/shellcheck)
- (로컬) 런북 `docs/runbooks/`에 reclaim 절차(gitignored — 노트만)

**Step 1: 실패 테스트 작성** — fail-closed 구분(깨진 감사 ≠ 고아 없음, F7):
```bash
@test "orphan-PV audit surfaces Released PVs and is fail-closed (broken audit != no orphans)" {
  S="$ROOT/scripts/audit-orphan-pv.sh"
  [ -x "$S" ]
  run grep -Eq 'status\.phase.*Released|"Released"' "$S"; [ "$status" -eq 0 ]      # Released 선택
  run grep -Eq 'command -v kubectl|command -v yq' "$S"; [ "$status" -eq 0 ]        # preflight
  run grep -Eq 'exit [23]' "$S"; [ "$status" -eq 0 ]                               # 실패는 비-0
  # 클러스터 없는 환경(CI)서 실행 → 비-0 + '고아 없음' 미출력(깨진 감사를 깨끗한 결과로 위장 안 함)
  run bash "$S"
  [ "$status" -ne 0 ]
  run grep -q '고아 없음' <<< "$output"
  [ "$status" -ne 0 ]   # 클러스터 부재 출력에 '고아 없음'이 있으면 실패(혼동 방지)
}
```
> `run grep <<< "$output"`은 직전 run의 출력을 검사(here-string은 run 전 전개). 깨진 감사가 '고아 없음'으로 위장하면 fail.

**Step 2: 실패 확인** — FAIL.

**Step 3: 감사 스크립트** — `scripts/audit-orphan-pv.sh`. ★**fail-closed(F7)**: 도구부재/접근실패/쿼리오류를 "고아 없음"과 혼동하지 않는다 — 깨진 감사는 비-0 종료:
```bash
#!/usr/bin/env bash
# 고아 Released PV 감사 — storageclass-standard가 Retain(DB 데이터 보호)이라 PVC 삭제 시 PV가 Released로
# 남고 hostPath 디스크가 누수된다. 나열만(파괴 없음) — reclaim은 owner 수동(런북).
# ★fail-closed(F7): 도구/접근/쿼리 실패는 비-0 종료(깨진 감사를 '고아 없음'으로 위장 금지).
set -euo pipefail
command -v kubectl >/dev/null || { echo "ERROR: kubectl 부재" >&2; exit 2; }
command -v yq >/dev/null || { echo "ERROR: yq 부재" >&2; exit 2; }
kubectl cluster-info >/dev/null 2>&1 || { echo "ERROR: 클러스터 접근 불가(KUBECONFIG/RBAC)" >&2; exit 3; }
echo "== 고아 Released PV (PVC 삭제+Retain 잔존, hostPath 디스크 누수) =="
pvs="$(kubectl get pv -o json)" || { echo "ERROR: kubectl get pv 실패" >&2; exit 3; }   # 쿼리 실패=비-0
orphans="$(printf '%s' "$pvs" | yq -r '.items[] | select(.status.phase == "Released") | .metadata.name + "\t" + (.spec.hostPath.path // .spec.local.path // "?") + "\t" + (.spec.storageClassName // "?")')"
if [ -z "$orphans" ]; then echo "고아 없음(쿼리 성공, Released 0건)"; else printf '%s\n' "$orphans"; fi
echo "== reclaim: PV 데이터 확인 후 'kubectl delete pv <name>' + 노드 hostPath 디렉토리 수동 삭제(런북) =="
```
> 비파괴(나열만). reclaim은 owner 수동(데이터 유실 위험 — Retain의 목적). 런북에 절차. exit: 2=도구부재·3=접근/쿼리실패·0=성공(고아 0 또는 나열).

**Step 4: 통과 확인** — `bats tests/gates/test_audit-orphan-pv.bats` PASS + `shellcheck scripts/audit-orphan-pv.sh`.

**Step 5: 커밋**
```bash
git add scripts/audit-orphan-pv.sh tests/gates/test_audit-orphan-pv.bats
git commit -m "feat: 고아 Released PV 감사 스크립트(Retain 디스크 누수 가시화, 비파괴)"
```

---

## Task 5: prod→database egress 최소화 (★HIGH 라이브 — 강한 게이트)

전 prod pod가 database namespace 전체:5432였던 것을 pooler/cluster pod로 최소화. **라벨 미스=DB outage**.

**Files:**
- Modify: `platform/network-policies/prod/networkpolicies.yaml` (`allow-egress-to-database`)
- Modify: `platform/network-policies/prod/test_netpol.bats` (podSelector 구조 단언)
- Modify: `tests/posture/test_networking-e2e.bats` (prod→**pg-pooler-rw**:5432 경로 추가 — 앱 런타임 경로[PgBouncer], 기존 pg-rw만 테스트하면 pooler 셀렉터 미스 미검출, F4b durable)
- Create: `scripts/netpol-rehearsal.sh` (trap 보장 복원 rehearsal, F5)

**Step 1: ★라이브 라벨 확인 (선행 필수, 머지 전)** — `eval "$(make kubeconfig)"` 후:
```bash
kubectl -n database get pods --show-labels
```
- pooler pod의 라벨(`cnpg.io/poolerName=pg-pooler-rw` 또는 실제값)·cluster pod의 라벨(`cnpg.io/cluster=pg` 또는 실제값)을 **정확히 기록**. 이 값으로 netpol을 쓴다(추측 금지 — 미스 시 DB 전면 차단).

**Step 2: 실패 테스트 작성** — `test_netpol.bats`에 **yq 구조 단언**(substring은 잔존 broad 피어 통과, F1b). 모든 database 피어가 podSelector를 갖고 namespace-only 피어가 0:
```bash
@test "database egress is structurally narrowed — every database peer has podSelector, no namespace-only peer" {
  TMP="$BATS_TEST_TMPDIR/db-egress.yaml"
  build | yq 'select(.metadata.name=="allow-egress-to-database")' > "$TMP"
  # database namespace를 가리키는데 podSelector 없는 피어(=namespace 전체) 0개여야(F1b)
  run yq '[.spec.egress[].to[] | select(.namespaceSelector.matchLabels."kubernetes.io/metadata.name" == "database" and (has("podSelector") | not))] | length' "$TMP"
  [ "$output" = "0" ]
  # podSelector로 좁힌 피어 ≥1
  run yq '[.spec.egress[].to[] | select(has("podSelector"))] | length' "$TMP"
  [ "$output" -ge 1 ]
  # ★F4: pooler+cluster 정확 셀렉터 둘 다(오타 통과 방지). Step1 라이브 확정값으로.
  run grep -q 'cnpg.io/poolerName: pg-pooler-rw' "$TMP"; [ "$status" -eq 0 ]   # pooler(앱 런타임 경로, PgBouncer)
  run grep -q 'cnpg.io/cluster: pg' "$TMP"; [ "$status" -eq 0 ]                # cluster(pg-rw→primary)
  run grep -q 'port: 5432' "$TMP"; [ "$status" -eq 0 ]
}
```
> `build`는 test_netpol.bats의 kustomize build 헬퍼. 임시파일로 yq(변수 주입 회피). 정확 구조는 `make render`/build 출력으로 확정.

**Step 3: 실패 확인** — FAIL(현재 podSelector 없음).

**Step 4: netpol narrowing** — `allow-egress-to-database`의 `to`를 (Step1 라이브 라벨로):
```yaml
  egress:
    - to:
        # pooler(pg-pooler-rw) — 앱의 권장 경로
        - namespaceSelector: { matchLabels: { kubernetes.io/metadata.name: database } }
          podSelector: { matchLabels: { cnpg.io/poolerName: pg-pooler-rw } }   # ★Step1 확정 라벨
        # cnpg 클러스터 pod(pg-rw→primary, pg-ro→replica)
        - namespaceSelector: { matchLabels: { kubernetes.io/metadata.name: database } }
          podSelector: { matchLabels: { cnpg.io/cluster: pg } }                # ★Step1 확정 라벨
      ports:
        - { protocol: TCP, port: 5432 }
```
> ⚠️ namespaceSelector+podSelector는 **같은 to 항목**(AND) — 별 항목이면 OR이 돼 의도 깨짐. 각 to 항목에 namespaceSelector**와** podSelector 둘 다.

**Step 5: 정적 통과 + posture suite 확장 (F4b)** — `bats platform/network-policies/prod/test_netpol.bats` PASS + `make render COMP=network-policies` 렌더. **`tests/posture/test_networking-e2e.bats`에 prod→`pg-pooler-rw.database.svc.cluster.local:5432` 연결 @test 추가**(기존 pg-rw 옆 — 앱 런타임 경로[PgBouncer]라 미래 netpol 변경도 pooler 경로 검증). 라이브 실행은 Step6 rehearsal의 `make verify-posture`.

**Step 6: ★netpol candidate rehearsal — 머지 전 필수 (라벨 미스=DB outage, F1a/F2)** — GitOps(ArgoCD main 싱크·selfHeal)라 pre-merge `make verify-posture`는 main(broad)을 테스트, candidate(narrowed)가 아니다 → **candidate를 라이브에서 실연(rehearsal)해 증명한 뒤에만 머지**. ★**post-merge-only 금지**(라벨 미스가 prod DB outage로만 드러남):
1. **pre-merge 정적**: Step1 라이브 라벨로 작성 + Step2 구조 정적테스트 green.
2. **candidate rehearsal (필수) = `scripts/netpol-rehearsal.sh`** — ★복원은 **`trap`으로 보장**(중간 실패/STOP/hang에도 prod 복원, F5). 연결성은 **verify-posture**(F4b: pg-rw + pg-pooler-rw, bats fail-closed — 느슨한 `&& echo OK || echo BLOCKED`는 exit 0이라 금지, F6). 워크트리(candidate)서 실행:
   ```bash
   #!/usr/bin/env bash
   # netpol candidate rehearsal — selfHeal off→candidate apply→verify-posture→ALWAYS restore(trap).
   # 라벨 미스가 prod로 안 새게: 어떤 종료에도 trap이 selfHeal/main 복원. owner-local(라이브 클러스터·워크트리서).
   set -euo pipefail
   APP=network-policies-prod; NS=prod
   restore() {   # trap: 성공/실패/STOP 어떤 EXIT에도 복원(F5)
     echo "==> [trap] 복원: selfHeal on + main(broad) 재싱크"
     kubectl -n argocd patch app "$APP" --type merge \
       -p '{"spec":{"syncPolicy":{"automated":{"selfHeal":true}}},"operation":{"sync":{}}}' || true
     for _ in $(seq 1 30); do   # Synced/Healthy 대기(~60s)
       s="$(kubectl -n argocd get app "$APP" -o jsonpath='{.status.sync.status}' 2>/dev/null || true)"
       h="$(kubectl -n argocd get app "$APP" -o jsonpath='{.status.health.status}' 2>/dev/null || true)"
       [ "$s" = Synced ] && [ "$h" = Healthy ] && break; sleep 2
     done
     if kubectl -n "$NS" get netpol allow-egress-to-database -o yaml | grep -q 'cnpg.io/poolerName'; then
       echo "⚠️ 복원 후에도 candidate 잔존 — 수동 점검(selfHeal/sync)"; else echo "==> 복원 확인(broad)"; fi
   }
   trap restore EXIT
   kubectl -n argocd get app "$APP" >/dev/null                                  # 앱 존재(F3; 없으면 set -e→trap)
   kubectl -n argocd patch app "$APP" --type merge -p '{"spec":{"syncPolicy":{"automated":{"selfHeal":false}}}}'
   [ "$(kubectl -n argocd get app "$APP" -o jsonpath='{.spec.syncPolicy.automated.selfHeal}')" = false ]  # 확인(F3)
   make render COMP=network-policies | kubectl apply -f -                       # candidate 적용
   kubectl -n "$NS" get netpol allow-egress-to-database -o yaml | grep -q 'cnpg.io/poolerName'  # 반영 확인(F3)
   sleep 8                                                                      # kube-router 룰 갭(검증 함정)
   make verify-posture                                                          # pg-rw + pg-pooler-rw(F4b, fail-closed)
   echo "==> rehearsal PASS — candidate 안전(trap이 곧 main 복원)"
   ```
   ★`set -euo pipefail`+`trap restore EXIT`라 **어떤 실패에도 selfHeal/main 복원**(F5 — 라벨 미스가 prod로 안 샘). verify-posture가 pooler까지 fail-closed 검증(F6). 스크립트 exit 0(rehearsal PASS) 전 머지 금지.
3. **post-merge smoke (추가 안전망)**: 머지 후 ArgoCD 싱크 즉시 `make verify-posture` 재확인 + 실패 시 `git revert`(rehearsal로 이미 입증, 보조).

**Step 7: 커밋**
```bash
git add platform/network-policies/prod/networkpolicies.yaml platform/network-policies/prod/test_netpol.bats \
        tests/posture/test_networking-e2e.bats scripts/netpol-rehearsal.sh
git commit -m "fix: prod→database egress를 pooler/cluster pod로 최소화(namespace 전체→최소권한)

- 라이브 --show-labels로 CNPG 라벨 확인 후 podSelector로 한정
- posture e2e(verify-posture)로 앱→DB 연결 정상 검증(라벨 미스 outage 방지)"
```

---

## Task 6: 전체 검증

**Files:** 없음(검증만)

**Step 1: 정적 게이트** — `bats tests/test_backend-drift.bats tests/gates/test_audit-orphan-pv.bats platform/network-policies/prod/test_netpol.bats platform/cloudflared/prod/test_*.bats infra/k3s-bootstrap/tests/test_*.bats` 0 failures + `make ci`(run-bats·chart-test·accounting·shellcheck).

**Step 2: 렌더** — `make render COMP=network-policies` + `make render COMP=cloudflared` 성공(SOPS_AGE_KEY_FILE).

**Step 3: ★netpol 안전 게이트 (발견3)** — pre-merge: Step1 라이브 라벨 검증 + 구조 정적테스트(broad 피어 0 + pooler·cluster 정확 셀렉터) + **candidate rehearsal 필수 = `scripts/netpol-rehearsal.sh`**(app `network-policies-prod`·`trap` 보장 복원·verify-posture가 pg-rw+pg-pooler-rw **fail-closed**, F3/F4/F5/F6). ★**스크립트 PASS(exit 0) 전 머지 금지**. post-merge smoke는 보조. pre-merge verify-posture(rehearsal 없이)는 GitOps라 main(broad)을 테스트 — candidate 미증명.

**Step 4: PR 준비** — `git log --oneline origin/main..HEAD` 요약. ★**netpol(Task5)은 라이브 라벨검증+posture green 후에만 머지**(라벨 미스=DB outage). cloudflared는 라이브 싱크(저위험). 나머지(backend·cloud-init·storage 감사)는 CI/owner-local. PR/머지 owner.

---

## 실행 순서 메모

- **순서: Task 1(backend) → 2(cloud-init) → 3(cloudflared) → 4(storage 감사) → 5(netpol ★) → 6(검증)**. 안전 작업 먼저, netpol 마지막(위험 격리 within PR).
- **★netpol(Task 5)은 라이브 게이트** — Step1 `--show-labels`로 정확 CNPG 라벨 확인 **없이 작성/머지 금지**(라벨 미스=DB 전면 차단). ★candidate **rehearsal 필수**(selfHeal off→apply→`sleep 8`→posture→복원, green 전 머지 금지) — pre-merge verify-posture는 GitOps라 main(broad) 검증이라 candidate를 못 봄. post-merge smoke는 보조(F1a/F2).
- 라이브 영향: 1·2·4=무(CI/owner-local), 3·5=ArgoCD 싱크(5=HIGH). cloudflared seccomp는 저위험.

---

## Adversarial review dispositions

hardened-planning 4-pass codex 적대 리뷰. **7발견(F1~F7) 전부 Accept·반영**. 각 게이트 AskUserQuestion 승인. Pass 3에서 nominal cap(3) 도달, 사용자 승인으로 Pass 4 1회 추가, Pass 4 후 **확정**(Pass 5 미실행). 7발견 중 6건이 **Task 5(netpol, ★HIGH 라이브)** — netpol을 단일 PR서 안전하게 배포하는 게 이 테마의 난점.

| Pass | # | 발견 | Sev | Disposition |
|---|---|---|---|---|
| 1 | F1a | pre-merge verify-posture가 candidate 아닌 현재 main(broad) 검증 → false green | high | **Accepted** — 라이브 라벨검증 1차방어 + candidate rehearsal + post-merge smoke(GitOps selfHeal 한계 명시) |
| 1 | F1b | substring 정적테스트가 잔존 broad 피어 통과 | high | **Accepted** — yq 구조 단언(database 피어 전부 podSelector·namespace-only 0) |
| 2 | F2 | candidate rehearsal optional·post-merge-only 허용 → 미증명 netpol 머지 | high | **Accepted** — rehearsal 머지 전 **필수**, post-merge smoke는 보조 |
| 3 | F3 | rehearsal이 `app network-policies` patch — 실제 `network-policies-prod`(appset.yaml:30) | high | **Accepted** — 앱명 교정 + 어서션(app 존재·selfHeal=false·candidate 라이브 반영) |
| 3 | F4 | 정적테스트가 pooler 오타 통과·posture가 pg-rw만(앱은 pooler 경유) | high | **Accepted** — pooler+cluster 정확 셀렉터 둘 다 단언 + posture에 pg-pooler-rw 경로 추가 |
| 4 | F5 | rehearsal 선형 복원 → 중간 실패 시 prod에 candidate+selfHeal off 잔존(outage+무복구) | high | **Accepted** — `scripts/netpol-rehearsal.sh`(`set -e` + `trap restore EXIT` 보장 복원) |
| 4 | F6 | pooler `nc && echo OK \|\| echo BLOCKED`는 차단돼도 exit 0 | high | **Accepted** — 느슨한 echo 제거, pooler는 verify-posture(bats fail-closed)가 검증 |
| 4 | F7 | 감사 스크립트가 도구부재/접근실패를 "고아 없음"과 혼동 | medium | **Accepted** — preflight 분리·실패 시 비-0·성공+0건만 "고아 없음" |

**최종 패스(4) verdict:** `needs-attention`(F5/F6/F7) — 반영. 사용자 합의로 Pass 4에서 확정. ★★핵심 교훈: **GitOps selfHeal에서 HIGH-위험 netpol을 단일 PR로 안전 배포** = ①pre-merge verify-posture는 main(broad) 검증이라 candidate 미증명(F1a) → ②candidate rehearsal **필수**(selfHeal off→apply→posture→복원, F2) → ③**`trap`으로 복원 보장**(중간 실패가 prod outage+무복구로 새지 않게, F5) → ④검증은 **앱 런타임 경로(pg-pooler-rw, PgBouncer)**까지 fail-closed(pg-rw만이면 pooler 미스 미검출, F4/F6) → ⑤정적은 **정확 셀렉터 구조 단언**(substring/오타 통과 방지, F1b/F4) → ⑥appset 명명 `<comp>-prod`(F3). 부수: fail-closed는 알림·게이트뿐 아니라 **운영 감사 스크립트**도(깨진 감사≠깨끗한 결과, F7).

## Execution directives
- **Skill:** implement via `executing-plans` in a **separate session, in this worktree** (`.claude/worktrees/feat+infra-drift-least-privilege`).
- **Run continuously:** 라우틴 리뷰로 멈추지 말 것. 진짜 블로커에서만 정지. **순서: Task 1→2→3→4→5(netpol ★)→6.** 안전 작업 먼저, netpol 마지막.
- **★Task 5(netpol)는 HIGH 라이브** — Step1 라이브 `--show-labels`로 정확 CNPG 라벨 확인 **없이 작성/머지 금지**(라벨 미스=DB 전면 차단). candidate **rehearsal(`scripts/netpol-rehearsal.sh`) PASS 전 머지 금지**(trap 복원 보장). 나머지(backend·cloud-init·storage 감사=CI/owner-local, cloudflared seccomp=저위험 라이브).
- **Commits — 직접 적용; `Skill(commit)` 미사용**:
  - **한국어**·**AI 마커 금지**. Format `<type>(<scope>): 한국어 설명`. Type만 `feat`/`fix`/`refactor`/`docs`/`style`/`test`/`chore`. (가드/감사=`test:`/`feat:`, seccomp/netpol=`fix:`, 경고=`fix:`.) Task별 자체 커밋.
  - **Where:** 현재 feature 워크트리(`worktree-feat+infra-drift-least-privilege`) 직접 커밋.
- **Push/PR:** owner 판단. ★netpol은 rehearsal PASS 후에만. cloudflared 머지 후 ArgoCD 싱크 관찰.
