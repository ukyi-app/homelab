# 시크릿 관리 하이브리드 명료화 Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** SOPS/SealedSecrets 하이브리드를 통일하지 않고, 정합성/명료성만 높이는 저비용 정리 3종(appset 앱-시크릿 주석 일관화 + onboard-app v1 deprecation 포인터 / sealing-key DR fail-closed 게이트 / KSOPS 핀·alpha 리스크 명문화)을 수행한다.

**Architecture:** 작업 1·3은 주석/문서만 바꾸는 무동작 변경(렌더·실행 영향 0). 작업 2는 dr-drill.sh가 sourcing하는 sourceable 게이트 라이브러리(`scripts/sealing-key-dr-gate.sh`)를 신설해, (a) 파괴 전 도구 존재+키 연속성(committed cert 포함) 실복원 증명, (b) 재구축 후 sealing key 복원, (c) committed cert == 라이브 cert 일치(항상), (d) 전 SealedSecret 소비자 unseal 검증을 단계별로 강제한다. **모든 권위 소스 조회/파싱 실패는 fail-closed**(파괴/PASS 거부, `SEALED_DR_ALLOW_OFFLINE=1` 명시 예외만). 소비자 검출은 라이브(`kubectl -o jsonpath`) ∪ `origin/main`(yq 파싱). 로직은 bats로 단위 검증한다.

**Tech Stack:** bash(bats, bash 3.2 호환), kubectl, kubeseal, sops(age, binary 모드), **yq(toolchain 핀 — DR 런타임 YAML 파서)**, openssl(fingerprint+modulus), sealed-secrets, kustomize, ArgoCD ApplicationSet, Node.js(테스트 보조).

**설계 근거:** `docs/plans/2026-06-15-secret-management-hybrid-clarification-design.md`.

**비목표 (절대 건드리지 않음):** SOPS/KSOPS 제거 · 7개 `*.enc.yaml` 재봉인/이동 · ArgoCD repo-server KSOPS 배선 제거 · age 2-recipient 모델 변경 · onboard v1 워크플로 전면 폐기 · 7개 platform 시크릿의 SealedSecrets 전환.

**전역 규약 (AGENTS.md):** 커밋 한국어 conventional·AI 마커 금지·`/commit` 스킬 / bats `@test` 영어 / 중간 단언 `[ ]` / 주석 한국어(고유명사 영문) / **DR 런타임 YAML 파싱은 yq**(PyYAML·Node yaml은 toolchain 밖, `kubectl --dry-run=client`는 오프라인 CRD 파싱 불가 — 실측).

---

## Task 1: appset 앱-시크릿 주석 일관화 + onboard-app v1 deprecation 포인터

표준 앱-시크릿 경로는 create-app(v2) + SealedSecret이나 appset 주석·onboard-app(v1)은 KSOPS 모델을 기술/생성. 동작은 그대로, **주석만** 단일 진실로 정렬.

**Files:** Modify `platform/argocd/root/appset.yaml`, `tools/onboard-app.mjs`; Test `platform/argocd/root/test_render.bats`

**Step 1:** `sed -n '78,92p' platform/argocd/root/appset.yaml` 로 source #3 주석 확인.

**Step 2: appset 주석 교체 (동작 무변경)**

기존:
```yaml
        # source #3: 앱의 deploy 디렉토리를 KUSTOMIZE source로 — 앱의 KSOPS
        # secret-generator(envFrom용 *.enc.yaml)를 렌더한다. Helm 차트(source #1)는 앱의
        # secret을 담지 않으므로, 이것이 없으면 Deployment/migration의 envFrom secret이 누락된다.
        - repoURL: https://github.com/ukyi-app/homelab.git
          targetRevision: main
          path: '{{ .path.path }}' # apps/<name>/deploy/prod: kustomization.yaml + secret-generator.yaml + *.enc.yaml
```
신규:
```yaml
        # source #3: 앱의 deploy 디렉토리를 KUSTOMIZE source로 렌더한다. Helm 차트(source #1)는
        # 앱의 secret을 담지 않으므로, 이것이 없으면 Deployment/migration의 envFrom secret이 누락된다.
        # 앱 시크릿 표준 경로는 create-app(v2) + SealedSecret(`<app>-secrets.sealed.yaml`을 resources:에).
        # (legacy: onboard-app v1은 KSOPS secret-generator + *.enc.yaml을 냈다 — deprecated, 신규는 SealedSecret)
        - repoURL: https://github.com/ukyi-app/homelab.git
          targetRevision: main
          path: '{{ .path.path }}' # apps/<name>/deploy/prod: kustomization.yaml + (v2) <app>-secrets.sealed.yaml
```

**Step 3: onboard-app v1 deprecation 포인터** — `if (secrets.length) {`(현재 142행 부근) 바로 위:
```javascript
  // [deprecated] v1 KSOPS 앱-시크릿 경로. 앱 시크릿 표준은 create-app(v2) + SealedSecret이다
  // (tools/create-app.mjs, --sealed <app>-secrets.sealed.yaml). 신규 앱은 KSOPS를 쓰지 말 것.
  // 이 분기는 기존 v1 온보딩 호환용으로만 남긴다 — 동작 변경 금지(비목표).
```

**Step 4: 회귀 가드** — `platform/argocd/root/test_render.bats` 생성:
```bash
#!/usr/bin/env bats
setup() { ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"; F="$ROOT/platform/argocd/root/appset.yaml"; }

@test "appset.yaml is valid yaml" {
  run yq e 'true' "$F"
  [ "$status" -eq 0 ]
}
@test "appset.yaml has exactly two ApplicationSets" {
  run bash -c "grep -c '^kind: ApplicationSet' '$F'"
  [ "$status" -eq 0 ]
  [ "$output" = "2" ]
}
@test "appset source paths are unchanged after comment edit" {
  run grep -c "apps/\*/deploy/prod" "$F"
  [ "$status" -eq 0 ]
}
```

**Step 5:** `bats platform/argocd/root/test_render.bats` → PASS. `bats tools/test/onboard.bats` → PASS.

**Step 6: 커밋(`/commit`)** — `docs: 앱-시크릿 표준 경로 명료화 — appset 주석 v2 SealedSecret 기준, onboard v1 KSOPS deprecated 표기`

---

## Task 2: sealing-key DR fail-closed 게이트

- **[0.6] 파괴 전:** 도구 존재 + fail-closed 검출 + (소비자 ≥1 **또는** committed cert 존재) 시 백업 신선도+실복원(키쌍) 증명. 권위 소스 실패 ABORT.
- **[3.5] 재구축 후:** 컨트롤러 대기 → 키 복원 → committed cert==라이브 cert(항상).
- **[4.5] 수렴 후:** 라이브 ∪ origin/main 전수 unseal 검증, live 조회 실패 시 fail-closed.

### 설계 메모 (codex Pass 1·2·3 반영)

- **(P1-F1/P3-1) committed cert = standing consumer.** cert가 stale하면 향후 봉인본 복호 불능(PR #9). 따라서 **소비자 0이어도 committed cert가 있으면 파괴 전에 백업+실복원을 강제**한다(cert 연속성을 파괴 후가 아니라 파괴 전에 증명). dormant는 소비자 0 **그리고** committed cert 없을 때만.
- **(P2-1/P3-2) 검출·파싱 fail-CLOSED.** `consumers_from_ref`는 ref 누락·`git show` 실패·yq 실패·null name/namespace를 **rc≠0**으로 올리고 "파일 0"(rc 0)과 "파싱 실패"(rc 4)를 구분. `merge_consumers`는 ref·live 양쪽 rc를 전파. `git fetch`/kubectl 실패도 ABORT(`SEALED_DR_ALLOW_OFFLINE=1` 예외).
- **(P2-2) 복원 전 컨트롤러 존재.** `wait_for_controller`로 sealed-secrets Deployment 비동기 생성 대기 후 `rollout status`.
- **(P2-3/P3-3) 전수 검증 = 라이브 ∪ origin/main, live 실패 fail-closed.** `verify_all_sealedsecrets_unsealed`는 merge rc를 전파해 kubectl 실패 시 DR PASS를 막는다.
- **(P2-4) 파서 = yq(핀) + kubectl jsonpath(live).** 파괴 전 `assert_dr_tools_present`로 도구 부재가 파괴 후 터지지 않게.
- **(P2-5/P3-4) 백업 실복원 = 키쌍 암호 증명.** `--verify`는 이름만 비교. `prove_backup_restorable`는 백업의 각 Secret에서 (tls.crt,tls.key) 쌍을 꺼내, **tls.crt fingerprint == committed cert** 이면서 **tls.crt modulus == tls.key modulus**(유효 키쌍)인 항목이 있어야 통과. cert만 맞고 키 손상인 백업을 거른다.
- **(P4-1) 키 유효성 ≠ 복원 경로 동작.** 암호 증명에 더해 파괴 전 **비파괴 라이브 리허설**(`rehearse_restore_on_live`): 복호 백업 `kubectl apply --dry-run=server`(List 적용성, invalid metadata 조기 포착) + committed cert로 봉인한 canary SealedSecret을 임시 ns에 적용→라이브 컨트롤러 unseal 확인 후 정리. 드릴의 "[0.5] 파괴 전 복구 증명" 철학과 정합(격리 클러스터는 과함이라 라이브 비파괴 리허설로 비례 적용).
- **(P4-2) [4.5] 전 소비자 App 수렴 대기.** 기존 [4]는 root/cnpg-operator/cnpg-data만 대기 — data-conn-prod·앱 Application은 미대기라 CR 미싱크 시 false fail. **[4.4]에서 전체 ArgoCD Application Healthy 대기**(`wait_all_applications_healthy`) 후 [4.5] 전수 검증.
- **(P5-1) offline override는 [4.5] PASS 게이트에 적용 안 함.** 재구축 후엔 클러스터가 살아있어야 정상이므로 [4.5]에서 live 조회 실패는 `SEALED_DR_ALLOW_OFFLINE` 여부와 무관하게 무조건 FAIL(false PASS 차단).
- **(P5-2) canary는 run-unique 이름 + 랜덤 값 + 디코드 값 검증.** 존재만 보면 이전 중단 run의 stale Secret로 false pass — 매 run 고유 이름/값을 봉인하고 unseal된 값이 그 값과 일치해야 통과.
- **(P5-3) 복원/리허설 전 서버관리 메타 sanitize.** 백업은 `kubectl get -o yaml`이라 uid·resourceVersion·creationTimestamp·managedFields·ownerReferences 포함 — fresh-cluster create에서 거부될 수 있다. `sanitize_backup_yaml`(yq)로 strip 후 apply(restore와 dry-run 리허설 모두).

**복원 메커니즘:** 백업은 `kubectl get secret -l <label> -o yaml`(항상 `kind: List`)를 sops binary 봉인한 `ss-keys.<epoch>.enc.yaml`. 복원 = `sops -d` → `kubectl apply -f -` → `deploy/sealed-secrets-controller` 재시작.

**Files:** Create `scripts/sealing-key-dr-gate.sh`; Modify `scripts/dr-drill.sh`; Test `tests/sealed-secrets-restore.bats`

### Step 1: 검출·병합·fail-closed 실패 테스트 작성

`tests/sealed-secrets-restore.bats` 끝에 추가:
```bash
@test "sealed_consumers_count_local is zero on empty repo" {
  REPO="$TMP/repo-empty"; mkdir -p "$REPO"; (cd "$REPO" && git init -q && git commit -q --allow-empty -m init)
  . "$ROOT/scripts/sealing-key-dr-gate.sh"
  run sealed_consumers_count_local "$REPO"; [ "$status" -eq 0 ]; [ "$output" = "0" ]
}
@test "consumers_from_ref parses ns/name and returns 0 on a clean parse" {
  REPO="$TMP/repo-ref"; mkdir -p "$REPO/apps/foo/deploy/prod"
  printf 'kind: SealedSecret\nmetadata:\n  name: foo-secrets\n  namespace: prod\n' > "$REPO/apps/foo/deploy/prod/foo-secrets.sealed.yaml"
  (cd "$REPO" && git init -q && git add -A && git commit -q -m seed)
  . "$ROOT/scripts/sealing-key-dr-gate.sh"
  run consumers_from_ref "$REPO" "HEAD"; [ "$status" -eq 0 ]
  echo "$output" | grep -q "prod/foo-secrets"
}
@test "consumers_from_ref fails closed on malformed metadata" {
  REPO="$TMP/repo-bad"; mkdir -p "$REPO/apps/bad/deploy/prod"
  printf 'kind: SealedSecret\nmetadata:\n  name: bad\n' > "$REPO/apps/bad/deploy/prod/bad.sealed.yaml"  # namespace 누락
  (cd "$REPO" && git init -q && git add -A && git commit -q -m seed)
  . "$ROOT/scripts/sealing-key-dr-gate.sh"
  run consumers_from_ref "$REPO" "HEAD"; [ "$status" -ne 0 ]
}
@test "merge_consumers unions ref and live without duplicates" {
  REPO="$TMP/repo-m"; mkdir -p "$REPO/apps/a/deploy/prod"
  printf 'kind: SealedSecret\nmetadata:\n  name: a-secrets\n  namespace: prod\n' > "$REPO/apps/a/deploy/prod/a-secrets.sealed.yaml"
  (cd "$REPO" && git init -q && git add -A && git commit -q -m seed)
  printf '#!/bin/sh\nprintf "prod/a-secrets\\nedge/live-only\\n"\n' > "$STUB/kubectl"; chmod +x "$STUB/kubectl"
  . "$ROOT/scripts/sealing-key-dr-gate.sh"
  PATH="$STUB:$PATH" run merge_consumers "$REPO" "HEAD"; [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | grep -c .)" = "2" ]
  echo "$output" | grep -q "prod/a-secrets"; echo "$output" | grep -q "edge/live-only"
}
```

### Step 2: 실패 확인 — `bats tests/sealed-secrets-restore.bats -f "consumers_from_ref|merge_consumers"` → FAIL(lib 없음).

### Step 3: 게이트 라이브러리 생성

Create `scripts/sealing-key-dr-gate.sh`:
```bash
#!/usr/bin/env bash
# sealing-key DR 게이트 (sourceable lib). top-level 실행 없음(source-safe).
# 불변식: SealedSecret 소비자(라이브 ∪ origin/main) 또는 committed cert가 있으면 DR 드릴은
#   파괴 전에 백업·실복원(키쌍)을 증명하고, 재구축 후 전수 unseal + cert 일치를 검증한다.
# fail-closed: 권위 소스(kubectl/git/yq) 조회·파싱 실패 시 0으로 단정하지 않고 ABORT/FAIL
#   (SEALED_DR_ALLOW_OFFLINE=1 명시 오버라이드만 예외). 파서: yq(핀) + kubectl jsonpath(live).
CERT_REL="tools/sealed-secrets-cert.pem"
SS_NS="sealed-secrets"; SS_DEPLOY="deploy/sealed-secrets-controller"
UNSEAL_RETRIES="${SEALED_UNSEAL_RETRIES:-40}"; CTRL_WAIT_RETRIES="${SEALED_CTRL_WAIT_RETRIES:-60}"

assert_dr_tools_present() {
  local missing="" t
  for t in kubectl kubeseal sops openssl yq git; do command -v "$t" >/dev/null 2>&1 || missing="$missing $t"; done
  [ -z "$missing" ] || { echo "DR ABORT: DR 경로 필수 도구 부재 →$missing"; return 1; }
}

sealed_consumers_count_local() { git -C "${1:?}" ls-files -- '*.sealed.yaml' 2>/dev/null | grep -c . || true; }

# 백업 List의 서버관리 메타 제거(fresh-cluster create 견고 — P5-3). stdin→stdout.
sanitize_backup_yaml() {
  yq e '(.items[].metadata) |= (del(.uid) | del(.resourceVersion) | del(.creationTimestamp) | del(.managedFields) | del(.ownerReferences) | del(.selfLink) | del(.generation))' -
}

# git ref의 SealedSecret → ns/name(stdout). 파싱 실패는 rc=4(fail-closed), 파일 0은 rc=0.
consumers_from_ref() {
  local repo="$1" ref="${2:-origin/main}" files f doc ns nm rc=0
  files="$(git -C "$repo" ls-tree -r --name-only "$ref" -- '*.sealed.yaml' 2>/dev/null)" || return 4  # ref 누락 등
  [ -n "$files" ] || return 0
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    doc="$(git -C "$repo" show "$ref:$f" 2>/dev/null)" || { echo "ref parse 실패(git show): $f" >&2; rc=4; continue; }
    ns="$(printf '%s' "$doc" | yq e '.metadata.namespace' - 2>/dev/null)" || { echo "ref parse 실패(yq ns): $f" >&2; rc=4; continue; }
    nm="$(printf '%s' "$doc" | yq e '.metadata.name' - 2>/dev/null)" || { echo "ref parse 실패(yq name): $f" >&2; rc=4; continue; }
    if [ -z "$ns" ] || [ "$ns" = "null" ] || [ -z "$nm" ] || [ "$nm" = "null" ]; then
      echo "ref parse 실패(메타 null/누락): $f" >&2; rc=4; continue; fi
    printf '%s/%s\n' "$ns" "$nm"
  done <<< "$files"
  return "$rc"
}

# 라이브 SealedSecret → ns/name(stdout). kubectl 실패 시 rc=3.
consumers_from_live() {
  local out
  out="$(kubectl get sealedsecrets.bitnami.com -A \
        -o jsonpath='{range .items[*]}{.metadata.namespace}{"/"}{.metadata.name}{"\n"}{end}' 2>/dev/null)" || return 3
  printf '%s\n' "$out" | grep -E '.+/.+' || true
}

# 합집합(정렬·중복제거). ref(4)/live(3) 실패를 전파(fail-closed).
merge_consumers() {
  local repo="$1" ref="${2:-origin/main}" ref_list live_list rc_ref=0 rc_live=0
  ref_list="$(consumers_from_ref "$repo" "$ref")" || rc_ref=$?
  live_list="$(consumers_from_live)" || rc_live=$?
  printf '%s\n%s\n' "$ref_list" "$live_list" | grep -E '.+/.+' | sort -u || true
  [ "$rc_ref" -ne 0 ] && return "$rc_ref"; [ "$rc_live" -ne 0 ] && return "$rc_live"; return 0
}

# 파괴 전: 도구 + fail-closed 검출 + (소비자 ≥1 또는 committed cert) 시 --verify + 키쌍 실복원 증명.
assert_recoverable_before_destroy() {
  local repo="$1" backup_dir="${2:-}" ref="${3:-origin/main}"
  assert_dr_tools_present || return 1
  if ! git -C "$repo" fetch -q origin main 2>/dev/null; then
    [ "${SEALED_DR_ALLOW_OFFLINE:-0}" = "1" ] || { echo "DR ABORT: git fetch origin main 실패(fail-closed; SEALED_DR_ALLOW_OFFLINE=1로 오버라이드)"; return 1; }
    echo "    (오프라인 오버라이드: git fetch 생략)"
  fi
  local merged rc=0; merged="$(merge_consumers "$repo" "$ref")" || rc=$?
  if [ "$rc" -ne 0 ] && [ "${SEALED_DR_ALLOW_OFFLINE:-0}" != "1" ]; then
    echo "DR ABORT: 권위 소스 조회/파싱 실패(kubectl 또는 origin/main yq) — fail-closed(소비자 0 단정 안 함)"; return 1; fi
  local n cert=0; n="$(printf '%s' "$merged" | grep -c . || true)"; [ -f "$repo/$CERT_REL" ] && cert=1
  echo "    sealing-key DR 검출(라이브 ∪ $ref): 소비자 $n개, committed_cert=$cert"
  if [ "$n" -eq 0 ] && [ "$cert" -eq 0 ]; then
    echo "    sealing-key DR: dormant (소비자 0 + committed cert 없음)"; return 0; fi
  # 소비자 ≥1 또는 cert 존재 → 파괴 전 키 연속성 증명 강제
  [ -n "$backup_dir" ] || { echo "DR ABORT: 키 연속성 필요(소비자 $n, cert $cert) — export SEALED_KEY_BACKUP_DIR=<git 밖 디렉토리>"; return 1; }
  "$repo/scripts/backup-sealed-secrets-key.sh" --verify "$backup_dir" || { echo "DR ABORT: 백업이 라이브와 불일치/부재"; return 1; }
  prove_backup_restorable "$repo" "$backup_dir" || { echo "DR ABORT: 백업 키쌍 실복원 증명 실패"; return 1; }
  rehearse_restore_on_live "$repo" "$backup_dir" || { echo "DR ABORT: 라이브 canary 복원 리허설 실패"; return 1; }
}

# 비파괴 키쌍 증명: committed cert와 fingerprint 일치 + 그 항목의 tls.crt modulus == tls.key modulus.
prove_backup_restorable() {
  local repo="$1" backup_dir="$2"
  local latest; latest="$(ls -1 "$backup_dir"/ss-keys.*.enc.yaml 2>/dev/null | sort | tail -1)"
  [ -n "$latest" ] || { echo "    실복원 증명: 백업 없음"; return 1; }
  local decrypted; decrypted="$(sops -d --input-type binary --output-type binary "$latest" 2>/dev/null)" \
    || { echo "    실복원 증명: 백업 복호 실패"; return 1; }
  local fp_committed; fp_committed="$(openssl x509 -in "$repo/$CERT_REL" -noout -fingerprint -sha256 2>/dev/null || true)"
  [ -n "$fp_committed" ] || { echo "    실복원 증명: committed cert($CERT_REL) 읽기 실패"; return 1; }
  local match=0 crt key fp mod_c mod_k
  while IFS=$'\t' read -r crt key; do
    [ -n "$crt" ] && [ "$crt" != "null" ] && [ -n "$key" ] && [ "$key" != "null" ] || continue
    fp="$(printf '%s' "$crt" | base64 -d 2>/dev/null | openssl x509 -noout -fingerprint -sha256 2>/dev/null || true)"
    [ "$fp" = "$fp_committed" ] || continue
    mod_c="$(printf '%s' "$crt" | base64 -d 2>/dev/null | openssl x509 -noout -modulus 2>/dev/null || true)"
    mod_k="$(printf '%s' "$key" | base64 -d 2>/dev/null | openssl rsa -noout -modulus 2>/dev/null || true)"
    if [ -n "$mod_c" ] && [ "$mod_c" = "$mod_k" ]; then match=1; break; fi
    echo "    실복원 증명: cert는 일치하나 tls.key modulus 불일치(키쌍 손상)" >&2
  done < <(printf '%s' "$decrypted" | yq e '.items[] | select(.kind=="Secret") | (.data["tls.crt"] + "\t" + .data["tls.key"])' - 2>/dev/null || true)
  [ "$match" -eq 1 ] || { echo "    실복원 증명: committed cert와 일치하고 키쌍(modulus)도 맞는 백업 키 없음"; return 1; }
  echo "    실복원 증명 OK: committed cert 일치 + tls.key/tls.crt modulus 일치(유효 키쌍)"
}

# 비파괴 라이브 리허설(파괴 전, 라이브 클러스터 생존 시): 백업 List 적용성 + committed cert canary unseal.
rehearse_restore_on_live() {
  local repo="$1" backup_dir="$2"
  local latest; latest="$(ls -1 "$backup_dir"/ss-keys.*.enc.yaml 2>/dev/null | sort | tail -1)"
  [ -n "$latest" ] || { echo "    리허설: 백업 없음"; return 1; }
  # (1) sanitize 후 복호 백업 List가 fresh-cluster에 create 가능한지 비변경 검증(P5-3)
  sops -d --input-type binary --output-type binary "$latest" | sanitize_backup_yaml \
    | kubectl apply --dry-run=server -f - >/dev/null 2>&1 \
    || { echo "    리허설: 백업 List가 server dry-run apply 실패(메타데이터 등)"; return 1; }
  # (2) committed cert로 run-unique 랜덤 canary 봉인 → 임시 ns → 라이브 컨트롤러가 그 값을 unseal하는지(P5-2)
  local ns="sealed-dr-rehearsal" rnd name want
  rnd="$(head -c8 /dev/urandom | od -An -tx1 | tr -d ' \n')"; name="dr-canary-$rnd"; want="v-$rnd"
  kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f - >/dev/null 2>&1 || true
  trap 'kubectl delete namespace "sealed-dr-rehearsal" --ignore-not-found --wait=false >/dev/null 2>&1' RETURN
  kubectl -n "$ns" create secret generic "$name" --from-literal=v="$want" --dry-run=client -o yaml \
    | kubeseal --cert "$repo/$CERT_REL" --format yaml 2>/dev/null | kubectl apply -f - >/dev/null 2>&1 \
    || { echo "    리허설: committed cert로 canary 봉인/적용 실패"; return 1; }
  local i got=""
  for i in $(seq 1 24); do
    got="$(kubectl -n "$ns" get secret "$name" -o jsonpath='{.data.v}' 2>/dev/null | base64 -d 2>/dev/null || true)"
    [ "$got" = "$want" ] && break
    sleep 5
  done
  [ "$got" = "$want" ] || { echo "    리허설: 라이브 컨트롤러가 이번 run canary 값을 unseal 못 함(stale/단절)"; return 1; }
  echo "    리허설 OK: 백업(sanitized) apply 가능 + run-unique canary가 라이브에서 값 일치 unseal"
}

wait_for_controller() {
  local i
  for i in $(seq 1 "$CTRL_WAIT_RETRIES"); do kubectl -n "$SS_NS" get "$SS_DEPLOY" >/dev/null 2>&1 && break; sleep 5; done
  kubectl -n "$SS_NS" get "$SS_DEPLOY" >/dev/null 2>&1 || { echo "DR DRILL FAIL: sealed-secrets 컨트롤러 Deployment 미생성"; return 1; }
  kubectl -n "$SS_NS" rollout status "$SS_DEPLOY" --timeout=300s
}

# [4.5] 전: 모든 ArgoCD Application Healthy 대기(소비자 App data-conn·apps의 SealedSecret CR 싱크 보장).
wait_all_applications_healthy() {
  kubectl -n argocd wait --for=jsonpath='{.status.health.status}'=Healthy application --all --timeout="${1:-900s}"
}

restore_sealing_key() {
  local repo="$1" backup_dir="${2:-}"
  wait_for_controller || return 1
  local latest=""; [ -n "$backup_dir" ] && latest="$(ls -1 "$backup_dir"/ss-keys.*.enc.yaml 2>/dev/null | sort | tail -1)"
  [ -n "$latest" ] || { echo "    sealing-key DR: 복원할 백업 없음 — skip(cert 검증이 stale 판단)"; return 0; }
  echo "    sealing-key 복원: $latest"
  sops -d --input-type binary --output-type binary "$latest" | sanitize_backup_yaml | kubectl apply -f - || { echo "DR DRILL FAIL: 복호/sanitize/apply 실패"; return 1; }
  kubectl -n "$SS_NS" rollout restart "$SS_DEPLOY"; kubectl -n "$SS_NS" rollout status "$SS_DEPLOY" --timeout=300s
}

assert_committed_cert_matches_live() {
  local repo="$1" committed="$1/$CERT_REL"
  [ -f "$committed" ] || { echo "    cert 검증: committed cert 없음 — skip"; return 0; }
  local live; live="$(kubeseal --controller-namespace "$SS_NS" --fetch-cert 2>/dev/null)" || { echo "DR DRILL FAIL: 라이브 cert fetch 실패"; return 1; }
  local fp_live fp_have
  fp_live="$(printf '%s' "$live" | openssl x509 -noout -fingerprint -sha256 2>/dev/null || true)"
  fp_have="$(openssl x509 -in "$committed" -noout -fingerprint -sha256 2>/dev/null || true)"
  if [ -z "$fp_live" ] || [ "$fp_live" != "$fp_have" ]; then
    echo "DR DRILL FAIL: committed cert($CERT_REL)가 라이브 컨트롤러 cert와 불일치(stale)."
    echo "  → 향후 secret:seal/provision-db/provision-cache 봉인본을 새 컨트롤러가 복호 못 한다(PR #9)."
    echo "  복구책: (a) 백업 키 복원으로 active 승격, 또는 (b) kubeseal --fetch-cert > $CERT_REL 갱신·재커밋·전파."
    return 1; fi
  echo "    cert 검증 OK: committed cert == 라이브 cert"
}

# 수렴 후 전수 검증. live 조회 실패는 fail-closed(PASS 금지).
verify_all_sealedsecrets_unsealed() {
  local repo="$1" ref="${2:-origin/main}" merged rc=0
  merged="$(merge_consumers "$repo" "$ref")" || rc=$?
  if [ "$rc" -ne 0 ]; then   # 재구축 후엔 클러스터 생존 전제 — offline override 무관 무조건 fail-closed(P5-1)
    echo "DR DRILL FAIL: [4.5] 소비자 목록 조회 실패(kubectl/ref) — PASS 금지(offline override 미적용)"; return 1; fi
  [ -n "$merged" ] || { echo "    unseal 검증: 소비자 0개 — skip"; return 0; }
  local fail=0 line ns name i ok
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    ns="${line%%/*}"; name="${line#*/}"; ok=0
    for i in $(seq 1 "$UNSEAL_RETRIES"); do kubectl -n "$ns" get secret "$name" >/dev/null 2>&1 && { ok=1; break; }; sleep 5; done
    if [ "$ok" -eq 1 ]; then echo "    unseal OK: $ns/$name"; else echo "DR DRILL FAIL: $ns/$name 미생성"; fail=1; fi
  done <<< "$merged"
  return "$fail"
}
```

### Step 4: 검출·병합 테스트 통과 — `bats tests/sealed-secrets-restore.bats -f "consumers_from_ref|merge_consumers|sealed_consumers_count_local"` → PASS.

### Step 5: 게이트/cert/검증/실복원 분기 테스트 작성 (stub)

`tests/sealed-secrets-restore.bats`에 추가:
```bash
@test "before-destroy aborts on n=0 with committed cert but no backup dir" {
  REPO="$TMP/repo-cert0"; mkdir -p "$REPO/tools"; (cd "$REPO" && git init -q && git commit -q --allow-empty -m init)
  printf 'CERT\n' > "$REPO/tools/sealed-secrets-cert.pem"
  printf '#!/bin/sh\nexit 0\n' > "$STUB/kubectl"  # live 0
  printf '#!/bin/sh\nif [ "$1" = fetch ]; then exit 0; fi\nexec /usr/bin/git "$@"\n' > "$STUB/git"
  chmod +x "$STUB/kubectl" "$STUB/git"
  . "$ROOT/scripts/sealing-key-dr-gate.sh"
  PATH="$STUB:$PATH" run assert_recoverable_before_destroy "$REPO" "" "HEAD"
  [ "$status" -ne 0 ]; echo "$output" | grep -q "키 연속성 필요"
}
@test "before-destroy fails closed when live lookup fails" {
  REPO="$TMP/repo-fc"; mkdir -p "$REPO"; (cd "$REPO" && git init -q && git commit -q --allow-empty -m init)
  printf '#!/bin/sh\nexit 7\n' > "$STUB/kubectl"
  printf '#!/bin/sh\nif [ "$1" = fetch ]; then exit 0; fi\nexec /usr/bin/git "$@"\n' > "$STUB/git"
  chmod +x "$STUB/kubectl" "$STUB/git"
  . "$ROOT/scripts/sealing-key-dr-gate.sh"
  PATH="$STUB:$PATH" run assert_recoverable_before_destroy "$REPO" "" "HEAD"
  [ "$status" -ne 0 ]; echo "$output" | grep -q "fail-closed"
}
@test "assert_dr_tools_present aborts when a tool is missing" {
  printf '#!/bin/sh\nexit 0\n' > "$STUB/kubectl"; chmod +x "$STUB/kubectl"
  . "$ROOT/scripts/sealing-key-dr-gate.sh"
  PATH="$STUB" run assert_dr_tools_present
  [ "$status" -ne 0 ]; echo "$output" | grep -q "도구 부재"
}
@test "cert check fails loudly when committed cert mismatches live" {
  REPO="$TMP/repo-c"; mkdir -p "$REPO/tools"; printf 'COMMITTED\n' > "$REPO/tools/sealed-secrets-cert.pem"
  printf '#!/bin/sh\necho LIVE\n' > "$STUB/kubeseal"
  cat > "$STUB/openssl" <<'EOF'
#!/bin/sh
for a in "$@"; do case "$a" in -in) echo "Fingerprint=COMMITTED"; exit 0;; esac; done
echo "Fingerprint=LIVE"; exit 0
EOF
  chmod +x "$STUB/kubeseal" "$STUB/openssl"
  . "$ROOT/scripts/sealing-key-dr-gate.sh"
  PATH="$STUB:$PATH" run assert_committed_cert_matches_live "$REPO"
  [ "$status" -ne 0 ]; echo "$output" | grep -q "stale"
}
@test "prove_backup_restorable fails when key modulus does not match the matching cert" {
  REPO="$TMP/repo-pb"; mkdir -p "$REPO/tools" "$TMP/bk"; printf 'COMMITTED\n' > "$REPO/tools/sealed-secrets-cert.pem"
  printf 'dummy' > "$TMP/bk/ss-keys.111.enc.yaml"
  printf '#!/bin/sh\nprintf "apiVersion: v1\\nkind: List\\nitems:\\n- kind: Secret\\n  data:\\n    tls.crt: QQ==\\n    tls.key: Qg==\\n"\n' > "$STUB/sops"
  # openssl: committed cert fp == 백업 crt fp(일치) 이나 modulus는 crt=MODA, key=MODB(불일치)
  cat > "$STUB/openssl" <<'EOF'
#!/bin/sh
kind=x509; for a in "$@"; do [ "$a" = rsa ] && kind=rsa; done
case "$*" in
  *-fingerprint*) echo "Fingerprint=SAME"; exit 0;;
  *-modulus*) if [ "$kind" = rsa ]; then echo "Modulus=MODB"; else echo "Modulus=MODA"; fi; exit 0;;
esac
exit 0
EOF
  printf '#!/bin/sh\ncat\n' > "$STUB/base64"   # base64 -d 패스스루(테스트 단순화)
  chmod +x "$STUB/sops" "$STUB/openssl" "$STUB/base64"
  . "$ROOT/scripts/sealing-key-dr-gate.sh"
  PATH="$STUB:$PATH" run prove_backup_restorable "$REPO" "$TMP/bk"
  [ "$status" -ne 0 ]; echo "$output" | grep -q "키쌍"
}
@test "verify_all fails closed when live lookup fails" {
  REPO="$TMP/repo-vf"; mkdir -p "$REPO"; (cd "$REPO" && git init -q && git commit -q --allow-empty -m init)
  printf '#!/bin/sh\ncase "$*" in *"get sealedsecrets"*) exit 9;; esac\nexit 0\n' > "$STUB/kubectl"; chmod +x "$STUB/kubectl"
  . "$ROOT/scripts/sealing-key-dr-gate.sh"
  PATH="$STUB:$PATH" run verify_all_sealedsecrets_unsealed "$REPO" "HEAD"
  [ "$status" -ne 0 ]; echo "$output" | grep -q "fail-closed"
}
@test "verify_all iterates every consumer and fails on a missing Secret" {
  REPO="$TMP/repo-v"; mkdir -p "$REPO/apps/a/deploy/prod" "$REPO/apps/b/deploy/prod"
  printf 'kind: SealedSecret\nmetadata:\n  name: a-secrets\n  namespace: prod\n' > "$REPO/apps/a/deploy/prod/a-secrets.sealed.yaml"
  printf 'kind: SealedSecret\nmetadata:\n  name: b-secrets\n  namespace: prod\n' > "$REPO/apps/b/deploy/prod/b-secrets.sealed.yaml"
  (cd "$REPO" && git init -q && git add -A && git commit -q -m seed)
  cat > "$STUB/kubectl" <<'EOF'
#!/bin/sh
case "$*" in *"get sealedsecrets"*) exit 0;; esac
last=""; for a in "$@"; do last="$a"; done
case "$last" in a-secrets) exit 0;; *) exit 1;; esac
EOF
  chmod +x "$STUB/kubectl"
  . "$ROOT/scripts/sealing-key-dr-gate.sh"
  PATH="$STUB:$PATH" SEALED_UNSEAL_RETRIES=1 run verify_all_sealedsecrets_unsealed "$REPO" "HEAD"
  [ "$status" -ne 0 ]; echo "$output" | grep -q "a-secrets"; echo "$output" | grep -q "b-secrets 미생성"
}
@test "rehearse_restore_on_live fails when backup List server-dry-run apply fails" {
  REPO="$TMP/repo-rh"; mkdir -p "$REPO/tools" "$TMP/bk"; printf 'CERT\n' > "$REPO/tools/sealed-secrets-cert.pem"
  printf 'dummy' > "$TMP/bk/ss-keys.111.enc.yaml"
  printf '#!/bin/sh\ncat\n' > "$STUB/sops"
  printf '#!/bin/sh\ncase "$*" in *"--dry-run=server"*) exit 1;; esac\nexit 0\n' > "$STUB/kubectl"
  chmod +x "$STUB/sops" "$STUB/kubectl"
  . "$ROOT/scripts/sealing-key-dr-gate.sh"
  PATH="$STUB:$PATH" run rehearse_restore_on_live "$REPO" "$TMP/bk"
  [ "$status" -ne 0 ]; echo "$output" | grep -q "dry-run apply 실패"
}
@test "sanitize_backup_yaml strips server-managed metadata (P5-3)" {
  . "$ROOT/scripts/sealing-key-dr-gate.sh"
  out="$(printf 'apiVersion: v1\nkind: List\nitems:\n- kind: Secret\n  metadata:\n    name: k\n    namespace: sealed-secrets\n    uid: u1\n    resourceVersion: "9"\n    managedFields: [{manager: x}]\n  data: {tls.key: QQ==}\n' | sanitize_backup_yaml)"
  echo "$out" | grep -q "name: k"
  run bash -c "printf '%s' \"$out\" | grep -E 'uid:|resourceVersion:|managedFields:'"
  [ "$status" -ne 0 ]   # 서버관리 메타 0건
}
@test "verify_all stays fail-closed even with SEALED_DR_ALLOW_OFFLINE=1 (P5-1)" {
  REPO="$TMP/repo-vfo"; mkdir -p "$REPO"; (cd "$REPO" && git init -q && git commit -q --allow-empty -m init)
  printf '#!/bin/sh\ncase "$*" in *"get sealedsecrets"*) exit 9;; esac\nexit 0\n' > "$STUB/kubectl"; chmod +x "$STUB/kubectl"
  . "$ROOT/scripts/sealing-key-dr-gate.sh"
  PATH="$STUB:$PATH" SEALED_DR_ALLOW_OFFLINE=1 run verify_all_sealedsecrets_unsealed "$REPO" "HEAD"
  [ "$status" -ne 0 ]
}
```

### Step 6: 분기 테스트 통과 — `bats tests/sealed-secrets-restore.bats` → PASS(전 분기).

### Step 7: dr-drill.sh 배선

(7a) `cd "$REPO_ROOT"`(15행) 직후:
```bash
# shellcheck disable=SC1091
. "$REPO_ROOT/scripts/sealing-key-dr-gate.sh"
SEALED_KEY_BACKUP_DIR="${SEALED_KEY_BACKUP_DIR:-}"  # 소비자 ≥1 또는 committed cert 존재 시 필요(git 밖 백업)
```
(7b) `echo "==> [1] VM 파괴..."`(90행) 위:
```bash
echo "==> [0.6] sealing-key DR: 도구 + fail-closed 검출 + 키 연속성(--verify·키쌍 암호·라이브 canary 리허설) 증명"
assert_recoverable_before_destroy "$REPO_ROOT" "$SEALED_KEY_BACKUP_DIR" "origin/main" \
  || { echo "DR ABORT: sealing key 복구 가능성 미증명 — 라이브 노드 파괴 거부"; exit 1; }
```
(7c) `echo "==> [4] 플랫폼 계층 수렴 대기..."`(100행) 위:
```bash
echo "==> [3.5] sealing-key DR: 컨트롤러 대기 → 백업 키 복원 + committed cert 일치(항상)"
restore_sealing_key "$REPO_ROOT" "$SEALED_KEY_BACKUP_DIR" || { echo "DR DRILL FAIL: 복원 실패"; exit 1; }
assert_committed_cert_matches_live "$REPO_ROOT" || { echo "DR DRILL FAIL: cert stale — 복구책 후 재시도"; exit 1; }
```
(7d) `echo "==> [5] 재구축된 노드에서 R2로 DB 복구..."`(105행) 위:
```bash
echo "==> [4.4] 모든 ArgoCD Application Healthy 대기 (소비자 App data-conn·apps의 SealedSecret CR 싱크 보장)"
wait_all_applications_healthy 900s || { echo "DR DRILL FAIL: 일부 Application Healthy 수렴 실패"; exit 1; }
echo "==> [4.5] sealing-key DR: 라이브 ∪ origin/main 전수 unseal 검증(수렴 후)"
verify_all_sealedsecrets_unsealed "$REPO_ROOT" "origin/main" || { echo "DR DRILL FAIL: 일부 unseal 실패"; exit 1; }
```
> 배치 근거(P4-2): [4.4]가 data-conn-prod·앱 Application까지 Healthy(=SealedSecret CR 싱크)를 기다린 뒤 [4.5] 전수 검증 → ArgoCD lag로 인한 false fail 제거. 단 `wait --all`은 커밋된 모든 App이 Healthy로 수렴함을 전제(불량 App 있으면 timeout — DR은 main에서 전량 수렴 가정).

### Step 8: 문법 + 배선 순서 + dormant 동작

Run: `bash -n scripts/dr-drill.sh && bash -n scripts/sealing-key-dr-gate.sh && echo OK` → `OK`.

Run(순서 가드, P4-2): `bash -c 'S=scripts/dr-drill.sh; a=$(grep -n "\[4.4\]" $S|head -1|cut -d: -f1); b=$(grep -n "\[4.5\]" $S|head -1|cut -d: -f1); echo "$a < $b"; [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ] && echo ORDER_OK'`
Expected: `ORDER_OK` ([4.4] all-App 대기가 [4.5] 전수 검증보다 먼저).

Run: `bash -c '. scripts/sealing-key-dr-gate.sh && consumers_from_ref "$PWD" HEAD; echo rc=$?'` → 빈 출력 + `rc=0`.

### Step 9: restore.md 갱신(로컬 전용, 존재 시) — 복원 순서·cert 갱신(PR #9)·파괴 전 키쌍 실복원 증명·`SEALED_DR_ALLOW_OFFLINE`/`SEALED_KEY_BACKUP_DIR`/yq 파서 명문화. (gitignored → PR diff 미포함.)

### Step 10: 회귀 — `bats tests/sealed-secrets-restore.bats tools/test/onboard.bats` → PASS. `make verify` → PASS(SOPS 게이트 보존).

### Step 11: 커밋(`/commit`) — `feat: sealing-key DR fail-closed 게이트 — 키 연속성 실복원(키쌍) 증명·전수 unseal·cert 일치` 대상 `scripts/sealing-key-dr-gate.sh` `scripts/dr-drill.sh` `tests/sealed-secrets-restore.bats`.

---

## Task 3: KSOPS 핀/alpha 리스크 명문화

`bootstrap-values.yaml` 인라인 주석(무동작).

**Step 1:** `sed -n '28,40p;88,95p' platform/argocd/bootstrap-values.yaml`.

**Step 2:** `# ksops 바이너리 + exec 지원 kustomize를 repo-server에 설치한다.`(28행) 아래:
```yaml
  # ⚠️ 이 initContainer는 ksops뿐 아니라 repo-server가 쓰는 kustomize 바이너리 자체를 공급한다
  #    (/custom-tools → /usr/local/bin/kustomize subPath 마운트). KSOPS를 제거하더라도 이 컨테이너를
  #    통째로 지우면 안 된다 — kustomize(helm inflation용 --enable-helm)를 먼저 대체해야 한다.
  #    하이브리드 명료화(2026-06-15)에서 KSOPS 제거는 비목표.
```

**Step 3:** `# 렌더 시점 kustomize 기반 복호화를 위해 KSOPS exec 플러그인을 활성화한다.`(92행) 아래, `kustomize.buildOptions:` 위:
```yaml
    # ⚠️ --enable-exec는 kustomize alpha 기능. ArgoCD/kustomize가 exec 플러그인을 폐기하면 KSOPS
    #    렌더가 깨진다(platform 7개 SOPS 복호화 중단). 폐기 신호 관측 시 좁게 대응(해당 시크릿만
    #    SealedSecrets 이전). 선제 마이그레이션은 비목표.
```

**Step 4:** `yq e 'true' platform/argocd/bootstrap-values.yaml >/dev/null && echo OK` → `OK`.

**Step 5: 커밋(`/commit`)** — `docs: bootstrap-values에 KSOPS 핀/alpha 리스크 명문화 (kustomize 공급·exec 폐기 footgun)`.

---

## 최종 검증

`bats tests/sealed-secrets-restore.bats tools/test/onboard.bats platform/argocd/root/test_render.bats` → PASS.
`make verify` → PASS(SOPS 게이트 보존). `bash -n scripts/dr-drill.sh && bash -n scripts/sealing-key-dr-gate.sh && echo OK`.

수동 확인: 게이트 권위 = origin/main ∪ 라이브, 모든 권위/파싱 실패 fail-closed(파괴/PASS 거부). committed cert는 standing consumer라 소비자 0이어도 파괴 전 키쌍 실복원을 강제. 파서 yq(핀), 도구는 [0.6]에서 파괴 전 검사. 주석 변경은 렌더 무영향.

---

## Adversarial review dispositions (감사 추적)

codex(`adversarial-review.mjs`, `--scope working-tree`) 5회 패스. 3패스 캡 도달 후 사용자가 새 정보 기반으로 캡 연장(Pass 4) → 수확체감 판단 후 Pass 5 findings 반영 후 finalize 결정. **전 패스 findings 전부 Accept·반영**, 미해결 high/critical 0건. 단 Pass 5 반영분은 확인 리뷰(Pass 6)를 돌리지 않았다(사용자 결정).

| Pass | Verdict | findings | 처리 |
|---|---|---|---|
| 1 | needs-attention | 4 high | 전부 Accept |
| 2 | needs-attention | 5 (1 crit, 4 high) | 전부 Accept |
| 3 | needs-attention | 4 high | 전부 Accept |
| 4 | needs-attention | 2 high | 전부 Accept |
| 5 | needs-attention | 3 high | 전부 Accept |

**Pass 1 (전부 Accept):** ① dormant가 committed cert 연속성 무시 → cert도 트리거로. ② 검출이 로컬 git(≠ ArgoCD origin/main) → 라이브∪origin/main. ③ unseal 검증이 소비자 App apply 전 → 복원/검증 분리. ④ 첫 SealedSecret만 확인 → 전수.

**Pass 2 (전부 Accept):** ① 권위 소스 부재 시 fail-open → fail-closed(ABORT). ② 복원이 컨트롤러 생성 전 → `wait_for_controller`. ③ union 주장하나 ref만 → 라이브 병합. ④ PyYAML 미핀 → yq(toolchain 핀; `kubectl --dry-run` 오프라인 CRD 파싱 불가 실측). ⑤ `--verify`는 이름만 → 실복원 증명.

**Pass 3 (전부 Accept):** ① cert standing consumer인데 백업 요구가 n>0뿐 → cert 존재 시 파괴 전 강제. ② `consumers_from_ref` `|| true`로 fail-open → 파싱 실패 rc≠0. ③ `verify_all`이 live 실패 무시 → fail-closed. ④ 키쌍 미검증 → tls.crt↔tls.key modulus 일치.

**Pass 4 (전부 Accept):** ① 암호 증명 ≠ 복원 경로 동작 → 비파괴 라이브 canary 리허설(격리 클러스터 권고는 과함이라 비례 적용). ② [4.5]가 소비자 App 수렴 전 → [4.4] 전체 App Healthy 대기.

**Pass 5 (전부 Accept):** ① offline override가 [4.5] PASS까지 무력화 → [4.5]는 override 미적용 무조건 fail-closed. ② 고정 canary 존재만 확인 → run-unique 이름+랜덤 값+디코드 값 검증. ③ 리허설이 fresh-cluster create 미검증 → `sanitize_backup_yaml`로 서버관리 메타 strip(restore·리허설 공통; 격리 kind 클러스터 권고는 과함이라 sanitize로 비례 적용).

**Rejected:** 없음. (Pass 4-①·5-③의 "격리 disposable 클러스터" 권고는 개념을 Accept하되 구현은 라이브 비파괴 리허설/메타 sanitize로 비례 적용 — finding 자체는 수용.)

**Finalize 근거:** 3패스 캡 초과는 사용자의 명시적 정보 기반 결정(열린 항목 제시 후). DR 게이트는 파괴적 작업이라 적대자가 매 패스 새 엣지를 내는 수확체감 구간에 진입했고, 핵심 안전(fail-closed 검출·키쌍 암호 증명·복원·cert 일치·전 App 대기·전수 unseal·메타 sanitize)은 견고하며, 현재 sealed 소비자 0개라 게이트는 실전 dormant(첫 실 소비자 + 소비자 있는 첫 드릴이 추가 강화 트리거). 구현(executing-plans) 시 Task 2 bats가 fail-closed/분기를 강제 검증한다.
