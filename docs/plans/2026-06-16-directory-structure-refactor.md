# 디렉토리 구조 정합화 구현 플랜

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.
> 설계 근거: `docs/plans/2026-06-16-directory-structure-refactor-design.md`. 라이브/시크릿 검증은
> `argo`·`observability` 스킬(read-only) 참고. 작업은 전용 worktree(`refactor/dirstructure-plan`)에서.

**Goal:** 홈랩 GitOps 모노레포의 테스트 조직·platform 레이아웃·발견성·네이밍을 단일 규약으로 정합화하되,
ArgoCD 경로 커플링과 "조용한 커버리지 손실" 위험을 안전망(단일 러너·render-parity·드리프트 가드)으로 봉쇄한다.

**Architecture:** 7개 독립 워크스트림(각 PR-first + auto-merge). 핵심 안전 전제는 **W0 단일 테스트 러너**
(`**/test_*.bats` 글롭 − `tests/.ci-exclude`)를 먼저 깔고 그 위에서 테스트 rename/이동을 수행하는 것. 고위험
경로 변경(W2 victoria-stack)은 `kustomize build` **render-parity**(이동 전/후 바이트 동일)로 격리 검증한다.

**Tech Stack:** Kubernetes(k3s), ArgoCD(appset + root/apps 수동 Application), kustomize + KSOPS(exec),
SOPS(age), SealedSecrets, GitHub Actions, bats(+yq mikefarah v4, shellcheck, conftest), Make.

---

## 규약 · 안전 프로토콜 (모든 태스크 공통)

- **`[OWNER]` 마커**: 라이브 클러스터(`KUBECONFIG`) 또는 age 키(`SOPS_AGE_KEY_FILE`)가 필요한 태스크.
  에이전트는 준비만 하고 OWNER가 로컬에서 실행한다. (KSOPS 렌더·라이브 sync 확인이 해당.)
- **커밋**: 한국어 conventional(`feat:`/`fix:`/`refactor:`/`docs:`/`test:`), **AI 마커 금지**.
- **bats `@test` 이름은 영어** (디렉토리 단위 실행 시 한글 인코딩 깨짐 — 검증된 버그).
- **bash 3.2 함정**: 새 bats/셸의 중간 단언은 `[[ ]]`가 아니라 `[ ]`(단순 명령) 또는 grep 파이프로.
  `[[ ]]` 실패가 macOS bash 3.2에서 침묵 통과한다.
- **`*.enc.yaml` 직접 수정 금지**: 평문 메타데이터도 SOPS MAC에 포함. 본 플랜은 enc.yaml을 **`git mv`로만**
  이동하고 내용은 건드리지 않는다(W2 alerting.enc.yaml은 애초에 이동 대상 아님 — 이미 prod/).
- **required check은 `gate` 단일**(`infra/github/repo.tf:43` `contexts = ["gate"]`). ci.yaml의 **job 이름
  `gate`를 절대 바꾸지 않는다** — 바뀌면 모든 PR이 영구 pending.
- **render-parity 프로토콜** (경로 이동 워크스트림): **raw `sort` 금지** — 줄 정렬은 YAML 문서 경계·필드
  연관을 파괴해 서로 다른 manifest가 같은 정렬결과를 내는 false negative를 만든다(rollback 게이트 무력화).
  대신 **(1) unsorted 직접 비교 우선**: kustomize 출력은 리소스 순서가 결정적이므로 이동 전/후 출력이
  보통 그대로 동일하다 —
  `kustomize build --enable-helm --enable-alpha-plugins --enable-exec <old-path> > /tmp/before.yaml`,
  `<new-path> > /tmp/after.yaml`, `diff /tmp/before.yaml /tmp/after.yaml` 빈 출력. **(2) 순서 노이즈가
  있으면** 문서별 정규화: `yq -s '.kind + "/" + (.metadata.namespace // "") + "/" + .metadata.name'`
  (또는 apiVersion/kind/ns/name 키로 split·정렬)로 객체 단위 비교 — 줄 단위 정렬이 아니라 객체 단위.
- **rename/move 안전 프로토콜 (모든 파일 이동·개명 태스크에 무조건 적용)**: 어떤 파일/디렉토리를 옮기거나
  이름을 바꾸기 **전에**, 옮길 basename·경로 전부에 대해 `git grep -n <basename> -- ':!docs/plans/*'`로
  **소비자를 전수 확정**하고(테스트·Makefile·워크플로·`docs/traps.md`·`docs/decisions/*`·`*NOTES.md`·`scripts/*.sh`·
  `AGENTS.md`·`README.md`·`.claude/**` 포함), 같은 PR에서 전 참조를 갱신한다. 머지 전 **no-stale 단언**:
  구이름 잔존 `git grep` 0 + `make verify-traps` + `make verify` PASS. *(이 원칙이 F3/F5/F9 같은 '인벤토리
  누락' 클래스를 통째로 닫는다 — 각 태스크의 명시 목록은 출발점일 뿐, 권위는 git grep.)*
- **PR 경계**: 각 워크스트림 = 1 PR. **W0→W1→W2 순서 의존**(W2의 Task 2.5/2.7이 W1 후에만 존재하는
  `tests/gates/` 경로를 쓴다 — W2 독립 실행 금지). W2는 전용 PR(최고위험 격리)이되 W1 머지 후.
  **W3~W7도 W1에 의존**(tools/tests/·tests/gates/ 등 W1-생성 경로 참조) → **W1 머지 후** 병렬. W1 전 실행 금지.
  **단 W6·W7은 상호 병렬 금지** — W6가 `verify.yml`→`verify.yaml` rename, W7이 `verify.yml` 편집 → **W7을 W6보다
  먼저** 머지(W6의 소비자 스윕이 W7 잔여 참조를 흡수). 병렬/역순 시 rename+edit 충돌로 후속 auto-merge가 막힌다.
- **검증 베이스라인**: 각 PR 머지 전 `make verify` + `make chart-test` + `scripts/run-bats.sh`(W0 이후) green.

---

# W0 — 단일 테스트 러너 + bats 네이밍 통일 (PR 1, 선행 필수)

**목적:** 테스트 수집을 Makefile·ci.yaml 이중 SSOT(6글롭)에서 단일 러너로 통합하고, `test_` 접두를 전
bats에 통일해 수집을 `**/test_*.bats` − `.ci-exclude` 단일 글롭으로 단순화한다. **이게 이후 모든 테스트
이동(W1)의 안전 전제** — 러너가 디렉토리·파일명 변화에 무관하게 전수 수집하므로 누락이 불가능해진다.

> **순서 핵심:** 네이밍 통일(Task 0.1)을 **기존 글롭 하에서 먼저** 한다. 현 글롭은 `ls tools/test/*.bats`·
> `ls tests/*.bats`(둘 다 `*.bats`라 접두 추가에 무영향)와 `find platform -name 'test_*.bats'`(platform은
> 이미 100% 접두)라, 비-platform 파일에 접두를 붙여도 기존 수집이 깨지지 않는다. 그 다음 러너로 전환한다.

### Task 0.1: 전 bats에 `test_` 접두 통일 (84개, 기존 글롭 하)

**규약:** `test_`로 시작하지 않는 모든 `*.bats`에 **`test_` 접두만 prepend**(basename 스타일 보존:
`create-app.bats`→`test_create-app.bats`, `00-harness.bats`→`test_00-harness.bats`(NN 순서 보존),
`argocd_values.bats`→`test_argocd_values.bats`).

**Files (rename 대상 그룹, `git mv`):**
- `tools/test/*.bats` 48개 (접두 0/48)
- `tests/*.bats` 7개 + `tests/posture/*.bats` 3개
- `infra/k3s-bootstrap/test/NN-*.bats` 11개 (→ `test_NN-*.bats`, 정렬 순서 유지)
- `infra/_test/*.bats` 5개
- `platform/charts/app/tests/*.bats` 7개
- (platform 컴포넌트 25개는 이미 `test_` 접두 — 제외)

**하드코딩 참조 동기 수정** (⚠️ **iac.yaml만이 아니다** — rename될 basename 전부를 `git grep`로 전수 확정).
이동 전 필수: `for b in <renamed basenames>; do git grep -n "$b" -- ':!docs/plans/*'; done`로 소비자를 찾아
갱신한다. **검증된 소비자(최소 전체):**
- `.github/workflows/iac.yaml:39-42` (4줄, infra/_test argocd/tf 테스트 — Task 1.2/1.3에서 디렉토리·경로 재갱신)
- `Makefile:40` `@bats tests/sops-roundtrip.bats` → `tests/test_sops-roundtrip.bats`
- **`docs/traps.md` ~22개 가드 경로**(L14~35: `tools/test/*.bats`·`tests/*.bats`·`platform/*`·`infra/_test/*` —
  비접두 다수, 예: `tools/test/vmalert-config.bats`, `dispatcher.bats`, `workflow-yaml.bats`, `ledger-gate.bats`,
  `manifest-guard.bats`, `verify-secrets.bats`, `make-ci-parity.bats`, `claude-harness-tracked.bats`,
  `tests/sops-roundtrip.bats`, `tests/dr-drill.bats`, `tests/reset-pg-r2-archive.bats`,
  `tests/sealed-secrets-restore.bats`). **`make verify-traps`가 이 경로 파일 존재를 검사 → 미갱신 시 즉시 실패.**
  (이 경로들은 W1 tests/gates 이동·디렉토리 rename에서 다시 갱신되니 traps.md를 그때마다 동기.)
- `docs/decisions/0001-*.md:27`(`tests/sealed-secrets-restore.bats`), `0002-*.md:4`(`infra/_test/tf_reconcile.bats`),
  `0003-*.md:4,23`(`tools/test/make-ci-parity.bats`)
- `platform/network-policies/prod/NOTES.md:42`(`tests/posture/network-policy.bats`)
- `infra/k3s-bootstrap/bulk-gate-probe.sh:4`(`test/08-bulk-gate.bats` — 상대; Task 1.2 dir rename도 동반)
- `scripts/backup-sealed-secrets-key.sh:14`(`tests/sealed-secrets-restore.bats`)
- `.claude/skills/argo/SKILL.md:26`(`test_sync_wave_ledger.bats` — 이미 접두, 무영향 확인만)
- `Makefile:104,106,107-109`·`ci.yaml` 수집 글롭은 Task 0.5에서 러너로 치환(여기선 무영향).

**Step 1: rename 스크립트 작성·실행 (한 번에, git mv)**

```bash
cd /Users/ukyi/workspace/homelab-dirstructure-plan
for f in $(git ls-files '*.bats'); do
  b=$(basename "$f"); d=$(dirname "$f")
  case "$b" in test_*) continue;; esac          # 이미 접두면 skip
  git mv "$f" "$d/test_$b"
done
```

**Step 2: 소비자 전수 갱신** — 위 검증된 소비자 목록(iac.yaml·Makefile:40·docs/traps.md ~22·decisions 3·
NOTES.md·bulk-gate-probe.sh·backup-sealed-secrets-key.sh)을 새 `test_` 접두 경로로 Edit. 각 rename된 basename에
대해 `git grep -n <old-basename> -- ':!docs/plans/*'` 잔여 0 확인.

**Step 3: no-stale-path 단언 (W0 머지 전 게이트)**

Run (구이름 잔존 0): `git grep -nE '(tools/test|tests)/[a-z0-9-]+\.bats' -- ':!docs/plans/*' ':!*.bats' | grep -v '/test_'`
→ **빈 출력**(비접두 bats 경로 참조가 코드/문서에 하나도 안 남아야).
Run: `make verify-traps` → **PASS**(traps.md 가드 경로가 새 이름과 일치).
Run (오프라인 일부): `bats $(ls tools/test/test_*.bats | grep -v dev-postgres | head)` → PASS.

**Step 4: Commit**

```bash
git add -A && git commit -m "refactor: bats 파일명 test_ 접두 통일(84) + 전 소비자(traps.md·Makefile·decisions 등) 동기"
```

### Task 0.2: `tests/.ci-exclude` 데이터 파일 신설

**Files:** Create `tests/.ci-exclude`

라이브/도커/age 의존이라 `gate`에서 제외할 bats를 **사유별 그룹 + 주석**으로 1곳에 수렴(현재 Makefile·ci.yaml
3곳 인라인 제외를 대체). 각 줄 = 레포 루트 상대 경로(Task 0.1 후 이름).

```
# 라이브 클러스터 의존 (수동: make verify-posture)
tests/posture/test_internal-by-default.bats
tests/posture/test_network-policy.bats
tests/posture/test_networking-e2e.bats
# docker 의존
tools/test/test_dev-postgres.bats
# 실 age 키 의존 (verify.yml의 ephemeral 키 셸이 대체 커버)
tests/test_sops-roundtrip.bats
tests/test_sops-guard.bats
tests/test_makefile.bats
# KSOPS 실 age 시드 복호 의존
platform/cnpg/prod/test_creds_reference.bats
platform/cnpg/prod/test_drill_alerting.bats
platform/cnpg/prod/test_kustomize_build.bats
# terraform 의존 (gate엔 terraform 미설치 — iac.yaml advisory가 실행)
infra/_test/test_tf_validate.bats
infra/_test/test_tf_reconcile.bats
infra/cloudflare/test_apps_data.bats
# 라이브 전용 (infra 부트스트랩 — make bootstrap)
infra/_test/test_bootstrap.bats
```

> **.ci-exclude = not-CI-safe 테스트의 단일 레지스트리**(사유별 주석 + 실행처). `platform/charts/*`만 러너가
> 도메인 prune(별도 harness). **infra/는 prune 안 함** — k3s-bootstrap(hermetic, bats+yq)은 gate에서 돌고
> (required 보호), **terraform 의존(cloudflare test_apps_data·tf_validate·tf_reconcile)·live는 위에 등재**(gate
> 불가, iac advisory). 경로는 W0 시점 이름(`infra/_test/`); W1 Task 1.2 디렉토리 rename 시 `infra/_tests/`로 동기.

> 주의: `tools/test/test_dev-data.bats`는 dry-run 테스트는 CI-safe, docker 시드 모드는 아님 — 현재도
> `tools/test/*.bats` 글롭에 포함돼 돌고 있으므로 제외 목록에 넣지 않는다(기존 동작 보존; 별도 점검은 W1 범위 밖).

**Commit:** `git add tests/.ci-exclude && git commit -m "feat: tests/.ci-exclude — CI 제외 bats SSOT (사유별)"`

### Task 0.3: `scripts/run-bats.sh` 단일 러너 (TDD)

**Files:** Create `scripts/run-bats.sh`, Test `tools/test/test_run-bats.bats`

**Step 1: 실패하는 테스트 작성** (`tools/test/test_run-bats.bats`)

```bash
#!/usr/bin/env bats
# 단일 러너의 수집 집합 불변식. bash 3.2 함정 회피 — 단언은 grep 파이프/[ ]로.
setup() { ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"; }

@test "run-bats.sh lists every test_*.bats except .ci-exclude entries" {
  run bash "$ROOT/scripts/run-bats.sh" --list
  [ "$status" -eq 0 ]
  # 포함: 일반 게이트 테스트
  echo "$output" | grep -q 'platform/argocd/root/test_render.bats'
  # 제외: .ci-exclude 멤버
  ! echo "$output" | grep -q 'tests/posture/test_internal-by-default.bats'
  ! echo "$output" | grep -q 'tools/test/test_dev-postgres.bats'
}

@test "run-bats.sh --list = all test_*.bats minus platform/charts minus .ci-exclude" {
  gate=$(git -C "$ROOT" ls-files '*test_*.bats' | grep -vE '^platform/charts/' | wc -l | tr -d ' ')
  excl=$(grep -vcE '^\s*(#|$)' "$ROOT/tests/.ci-exclude")
  listed=$(bash "$ROOT/scripts/run-bats.sh" --list | grep -c '\.bats$')
  [ "$listed" -eq "$((gate - excl))" ]   # infra prune 없음 — CI-safe infra는 gate
}

@test "run-bats.sh runs under macOS default /bin/bash 3.2 (no mapfile/set -u)" {
  # AGENTS.md bash3.2 함정: 러너가 owner macOS의 /bin/bash로 반드시 동작해야 한다.
  run /bin/bash "$ROOT/scripts/run-bats.sh" --list
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'test_.*\.bats'
}

@test "run-bats.sh has executable bit (Makefile/CI invoke ./scripts/run-bats.sh directly)" {
  # Task 0.5가 make ci·ci.yaml에서 ./scripts/run-bats.sh 직접 호출 → exec 비트 없으면 깨진다.
  [ -x "$ROOT/scripts/run-bats.sh" ]
}
```

**Step 2: 실패 확인** — Run: `bats tools/test/test_run-bats.bats` → FAIL (run-bats.sh 없음).

**Step 3: 러너 구현** (`scripts/run-bats.sh`)

```bash
#!/usr/bin/env bash
# 단일 테스트 수집·실행기 (required GATE). Makefile ci 와 ci.yaml gate 가 공통 호출 → 이중 SSOT 제거.
# **모델: gate = 모든 CI-safe test_*.bats** (정적 infra 가드 포함 — required 게이트라야 실제로 보호된다).
# 스코프 = git-tracked test_*.bats − platform/charts/*(chart-test 별도 harness) − tests/.ci-exclude.
#   - platform/charts/* 만 prune(차트 fixtures 필요한 별도 harness, make chart-test).
#   - **infra/는 prune하지 않는다** — k3s-bootstrap(hermetic, bats+yq)은 CI-safe라 gate에서 보호.
#     단 terraform 의존 infra 테스트(cloudflare test_apps_data·tf_validate·tf_reconcile)는 .ci-exclude(아래).
#   - .ci-exclude = not-CI-safe 단일 레지스트리(라이브/도커/age/terraform): posture·dev-postgres·sops·cnpg KSOPS·
#     tf_validate/tf_reconcile/cloudflare-apps-data(terraform 의존, iac.yaml advisory)·bootstrap(live). 사유+실행처 주석.
# **bash 3.2(macOS 기본) 호환 필수** — mapfile(bash4+)·set -u 빈배열 확장 금지. (AGENTS.md bash3.2 함정)
set -e
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# 제외 목록을 공백 구분 문자열로 (배열/ mapfile 미사용 — bash 3.2 안전)
EXCL=" "
while IFS= read -r line; do
  case "$line" in ''|\#*) continue;; esac
  EXCL="$EXCL$line "
done < tests/.ci-exclude
is_excluded() { case "$EXCL" in *" $1 "*) return 0;; *) return 1;; esac; }

SELECTED=()
while IFS= read -r f; do
  case "$f" in
    platform/charts/*) continue;;   # chart-test 별도 harness (infra/는 prune 안 함 — CI-safe면 gate)
  esac
  is_excluded "$f" || SELECTED+=("$f")
done < <(git ls-files '*test_*.bats' | sort)

if [ "${1:-}" = "--list" ]; then printf '%s\n' "${SELECTED[@]}"; exit 0; fi
[ "${#SELECTED[@]}" -gt 0 ] && bats "${SELECTED[@]}"
```

> **bash 3.2 주의**: `mapfile` 미사용(3.2 부재), `set -u` 미사용(빈 배열 `"${arr[@]}"` 확장이 3.2에서
> unbound 에러). 프로세스 치환 `< <(...)`·배열 append `+=`는 3.2 지원.

**Step 4: 통과 확인** — Run: `bats tools/test/test_run-bats.bats` → PASS.

**Step 5: exec 비트 부여 + Commit** —
```bash
chmod +x scripts/run-bats.sh && git update-index --chmod=+x scripts/run-bats.sh
bats tools/test/test_run-bats.bats   # exec-bit 단언 포함 PASS
git add scripts/run-bats.sh tools/test/test_run-bats.bats
git commit -m "feat: scripts/run-bats.sh — 단일 테스트 러너 (수집 SSOT, +x)"
```

### Task 0.4: bats 네이밍 가드 (TDD) — 접두 누락을 시끄럽게 실패시킴

**Files:** Modify `scripts/check-skeleton.sh` (또는 신규 `scripts/check-bats-naming.sh`), Test `tools/test/test_bats-naming.bats`

**Step 1: 실패 테스트**

```bash
@test "every tracked *.bats starts with test_ (collection convention guard)" {
  run bash -c "git -C '$ROOT' ls-files '*.bats' | grep -vE '(^|/)test_[^/]*\.bats$' || true"
  [ -z "$output" ]   # 접두 없는 bats가 하나라도 있으면 실패
}
```

**Step 2~4:** 가드 스크립트에 위 검사를 추가하고 `make verify`(또는 run-bats)가 부르게. 통과 확인.
**Step 5: Commit** — `git commit -m "test: bats test_ 접두 가드 — 미접두 시 게이트 실패(조용한 누락 차단)"`

### Task 0.5: Makefile `ci` + ci.yaml `gate`를 러너 호출로 치환 (parity 유지)

**Files:** Create `scripts/list-current-ci-bats.sh`(임시·치환 후 제거), Modify `Makefile:100-111`,
`.github/workflows/ci.yaml:41-79`, `tools/test/test_make-ci-parity.bats`

**Step 1: 현재 수집 집합의 *실제* 스냅샷** — ⚠️ `make -n ci`는 `$(ls/find)` **명령치환을 실행하지 않아**
파일목록이 아니라 리터럴 문자열만 출력한다(가짜 parity). 대신 현 수집기를 **실제 실행**하는 임시 스크립트로
정확한 before-set을 만든다.

`scripts/list-current-ci-bats.sh` (현 Makefile/ci.yaml gate가 *실제로* 도는 bats를 그대로 열거):
```bash
#!/usr/bin/env bash
set -e
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$ROOT"
{ ls tools/test/test_*.bats | grep -v '/test_dev-postgres\.bats$'
  ls tests/test_*.bats | grep -vE '/test_(sops-roundtrip|sops-guard|makefile)\.bats$'
  find platform -name 'test_*.bats' -not -path '*/charts/*' \
    -not -name test_creds_reference.bats -not -name test_drill_alerting.bats -not -name test_kustomize_build.bats
} | sort -u
```
Run: `bash scripts/list-current-ci-bats.sh > /tmp/ci-bats-before.txt` (Task 0.1 rename 후 이름 기준 — 현 글롭이
`*.bats`/`test_*.bats`라 새 이름 전수 포착). 이게 **권위 회귀 기준**.

**Step 2: Makefile `ci` 치환** — `Makefile:104-109`의 `ls tools/test/*.bats|grep`, `ls tests/*.bats|grep -vE`,
`find platform ...` 3블록을 단일 `@./scripts/run-bats.sh`로 교체. shellcheck(L105)·chart-test·docker e2e(L110-111)는 유지.
KSOPS 제외(cnpg 3종)는 이제 `.ci-exclude`가 담당하므로 `find`의 `-not -name` 3개 제거.

**Step 3: ci.yaml `gate` job 치환** — `ci.yaml:41-74`의 tools/test·tests·platform 수집 3스텝을 단일
`run: ./scripts/run-bats.sh` 스텝으로. **job 이름 `gate` 불변**. shellcheck(L47-50)·chart-test(L33-34)·
telegram e2e(L75-79)는 유지.

**Step 4: `test_make-ci-parity.bats` 갱신** — 7개 grep 토큰(`tools/test`/`find platform`/`charts/app/tests`
등) 미러 검증을, **`make ci`와 ci.yaml gate가 동일하게 `run-bats.sh`를 호출**하는지로 단순화(러너-동치 가드).

**Step 5: parity 회귀 검증 (no-drop 단언 — 조용한 커버리지 손실 봉쇄)**

Run: `./scripts/run-bats.sh --list | sort -u > /tmp/ci-bats-after.txt`.
Run (**드롭 0 단언, 핵심 안전 게이트**): `comm -23 /tmp/ci-bats-before.txt /tmp/ci-bats-after.txt` → **빈 출력**
(before에 있는데 after에 없는 = 조용히 드롭된 게이트 테스트가 0이어야). 비어있지 않으면 STOP.
Run (추가분 확인): `comm -13 /tmp/ci-bats-before.txt /tmp/ci-bats-after.txt` → **새로 gate에 보호되는 CI-safe
infra 정적 가드**(k3s-bootstrap hermetic·cloudflare apps.json·infra/_test argocd 등)가 나온다 — gate=all-CI-safe
모델의 의도된 추가(죽은 커버리지 해소). **각 추가 파일을 오프라인 실행 검증**(`bats <f>` PASS)하고, 라이브/
terraform 의존이 섞였으면 즉시 `.ci-exclude`에 사유와 함께 추가(예: tf_validate/tf_reconcile/bootstrap은 이미 등재).
Run: `make ci`(오프라인 범위) → PASS. Run: `bats tools/test/test_make-ci-parity.bats` → PASS.
치환 검증 후 `scripts/list-current-ci-bats.sh`는 `git rm`(일회성 회귀 도구).

**Step 6: Commit** — `git commit -m "refactor: make ci·ci.yaml gate를 run-bats.sh 단일 호출로 (이중 SSOT 제거)"`

### Task 0.6: W0 통합 검증 + PR

Run: `make verify && make chart-test && ./scripts/run-bats.sh`(오프라인 범위) → 전부 green.
PR 생성(`/pr` 스킬), required check `gate` 통과 확인 후 auto-merge.

---

# W1 — 테스트 조직 정합: tests/gates 이동 + 디렉토리 통일 + 죽은 커버리지 배선 (PR 2, W0 의존)

**목적:** W0 러너 위에서 (a) 오분류된 전역 게이트를 `tests/gates/`로, (b) 전용 디렉토리 단복수 통일,
(c) infra/_test의 platform 검증 테스트를 계층 정합, (d) 죽은 커버리지(k3s-bootstrap·posture) 배선.

> 러너가 `**/test_*.bats`로 전수 수집하므로 이동 후에도 자동 포함 — 단 `.ci-exclude` 경로는 이동에 맞춰 갱신.

### Task 1.1: 전역 정적 게이트 → `tests/gates/` 이동 (26개)

**Files:** `git mv tools/test/test_<x>.bats tests/gates/` (26개) + 비-bats 자산.

**이동 대상(전역 게이트 — 주 SUT가 tools/*.mjs 아님):**
`test_auth`, `test_ci-build`, `test_ci-gate`, `test_dispatcher`, `test_homelab-token`, `test_telegram-callsites`,
`test_telegram-notify`, `test_workflow-yaml`, `test_ci-toolchain-pin`, `test_setup-toolchain-composite`,
`test_renovate`, `test_make-ci-parity`, `test_make-help`, `test_make-ops-targets`, `test_make-runbooks`,
`test_make-secret-targets`, `test_manifest-guard`, `test_claude-harness-tracked`, `test_debug-skills`,
`test_alertmanager-template`, `test_cache-backup`, `test_vmalert-config`, `test_telegram-alert-korean`,
`test_restore-drill-notify`, `test_secret-cert-check`, `test_verify-secrets`, `test_verify-traps`.
**비-bats 자산 동반 이동:** `tools/test/alertmanager-render-e2e.sh`, `e2e-api.sh`, `mock-telegram.py`,
`fixtures/alerts-*.json` 3개 → `tests/gates/` (+ fixtures/).

**잔류(tools/*.mjs 단위 — `tools/tests/`로 Task 1.2에서 rename):** activate-app, audit-orphans, bump,
cli-flag-guard, create-app, dev-data, dev-postgres, onboard, pg-tools, poll-ghcr, provision-cache, provision-db,
seal-secret, teardown, tool-discoverability, validate-mutation, app-config, examples, workspace.

> **경계 케이스 판단**(혼합 SUT): `test_onboard`·`test_pg-tools`·`test_homelab-token`·`test_tool-discoverability`는
> 주 SUT 비중으로 분류 — onboard/pg-tools/tool-discoverability는 tools 단위 비중이 커 **잔류**, homelab-token은
> `.github/actions/`만 검증해 **이동**. `test_examples`·`test_workspace`는 tools 단위도 전역 게이트도 아닌 제3범주
> (차트 fixtures·레포 루트) — 잔류(tools/tests/)로 두되 분류 근거를 파일 상단 주석에 1줄.

**Step 1: 이동** — `mkdir -p tests/gates/fixtures` 후 위 26 bats + 3 .sh/.py + fixtures `git mv`.
**Step 2: 참조 동기** — 이동 bats 내부의 `$BATS_TEST_DIRNAME` 상대 참조 검증(루트 기준이면 무영향).
`tools/test/alertmanager-render-e2e.sh`를 호출하던 `Makefile:110-111`·`ci.yaml:79`·`test_alertmanager-template.bats`
경로를 `tests/gates/`로 갱신. `mock-telegram.py`·fixtures 참조하는 e2e 스크립트 경로 갱신.
**Step 3: 러너 자동 수집 확인** — Run: `./scripts/run-bats.sh --list | grep tests/gates` → 26개 등장.
**Step 4: 검증** — Run: `make ci`(오프라인 범위) → PASS. **Step 5: Commit** —
`git commit -m "refactor: 전역 정적 게이트 → tests/gates/ (tools/test 이름-의미 정합)"`

### Task 1.2: 전용 테스트 디렉토리 단복수 통일 (`tests/`)

**Files (`git mv` 디렉토리):**
- `tools/test/` → `tools/tests/` (잔류 tools 단위 bats + dev-postgres/ 등)
- `infra/k3s-bootstrap/test/` → `infra/k3s-bootstrap/tests/`
- `infra/_test/` → `infra/_tests/` (underscore "infra 보조 디렉토리" 의미 보존 + 복수화)
- `tests/`·`platform/charts/app/tests/`는 이미 복수 — 유지.

**동기 수정:**
- `tests/.ci-exclude` — `tools/test/test_dev-postgres.bats`→`tools/tests/...`, `infra/_test/test_bootstrap.bats`
  →`infra/_tests/...` 경로 갱신.
- `.github/workflows/iac.yaml:39-42` — `infra/_test/`→`infra/_tests/` (4줄).
- `infra/k3s-bootstrap/tests/test_helper.bash` 상대경로(`dirname/..`) 유효성 확인(디렉토리 한 단계 동일 깊이라 무영향).
- `AGENTS.md:27` 핵심명령 `bats tools/test/ infra/k3s-bootstrap/test/` → `tools/tests/`·`infra/k3s-bootstrap/tests/`.

**Step 1~2:** `git mv` 디렉토리 + 위 참조 Edit.
**Step 3:** Run: `./scripts/run-bats.sh --list` → 경로가 새 디렉토리로 바뀌어도 전수 수집 유지(글롭 `**/test_*.bats`).
**Step 4:** `make verify`(check-skeleton의 dirs 배열에 `tools/test` 등 있으면 `tools/tests`로 동기 — `scripts/check-skeleton.sh` 확인).
**Step 5: Commit** — `git commit -m "refactor: 전용 테스트 디렉토리 복수 tests/ 통일 + 참조 동기"`

### Task 1.3: infra/_tests의 platform/argocd 검증 테스트 → platform/argocd (계층 정합)

**Files:** `git mv infra/_tests/test_argocd_values.bats platform/argocd/`,
`git mv infra/_tests/test_root_app.bats platform/argocd/root/`

(이 2개는 `platform/argocd/bootstrap-values.yaml`·`root/root-app.yaml`을 grep — infra 아닌 platform 대상.)
`infra/_tests/`엔 진짜 infra만 잔류: `test_tf_validate.bats`, `test_tf_reconcile.bats`, `test_bootstrap.bats`.

**동기 수정:** `.github/workflows/iac.yaml:39-40` 의 `infra/_tests/test_argocd_values.bats`·`test_root_app.bats`
호출을 새 경로(`platform/argocd/test_argocd_values.bats`·`platform/argocd/root/test_root_app.bats`)로.
**주의(중복 실행):** 이 2개가 `platform/`로 가면 `ci.yaml` gate의 러너(`**/test_*.bats`)가 자동 수집한다 →
iac.yaml에서도 호출하면 **이중 실행**. iac.yaml에서는 이 2줄을 **제거**하고 gate 러너에 위임(또는 둘 중 하나만).
권장: iac.yaml은 tf 전용(`test_tf_validate`·`test_tf_reconcile`)만, argocd 2개는 gate 러너가 담당.

**Step 1~2:** mv + iac.yaml 수정(argocd 2줄 제거, 경로 갱신).
**Step 3:** Run: `./scripts/run-bats.sh --list | grep -E 'platform/argocd/(root/)?test_(argocd_values|root_app)'` → 등장(gate가 수집).
**Step 4:** `bats platform/argocd/test_argocd_values.bats platform/argocd/root/test_root_app.bats` → PASS(상대 grep 경로 유효).
**Step 5: Commit** — `git commit -m "refactor: argocd 검증 bats를 infra/_tests→platform/argocd (계층 정합)"`

### Task 1.4: 죽은 커버리지 배선 — k3s-bootstrap offline + posture make 타깃

**(a) k3s-bootstrap 오프라인 테스트(11) — W0에서 이미 gate 보호(추가 배선 불필요).** gate=all-CI-safe 모델이라
`test_NN-*.bats`(hermetic)는 W0 러너가 **자동 수집·required gate에서 실행**(W0 Task 0.5 Step5 additions에서
파일별 오프라인 검증 완료). W1에선 (i) **iac.yaml 정리**: iac-validate 잡은 **terraform 의존 set**(`test_tf_validate`·`test_tf_reconcile`·
`test_apps_data`(c))을 실행(argocd 2개는 Task 1.3에서 platform/argocd→gate로, k3s-bootstrap은 gate로 이동 완료).
iac.yaml의 명시 호출 라인에서 argocd_values/root_app 제거. (ii) `.ci-exclude`의 infra/_test→infra/_tests
경로는 Task 1.2에서 동기.
**Step:** `iac.yaml` 스텝을 terraform 2개로 정리 → `make verify`(accounting 가드 포함) PASS → Commit
`git commit -m "refactor: iac.yaml을 terraform 테스트 전용으로 정리(infra 정적 가드는 gate로 이관)"`

**(b) posture 라이브 스위트에 `make verify-posture` 진입점.**

**Files:** Modify `Makefile` (신규 타깃), `AGENTS.md:21-31`(핵심명령 등재)

**Step 1: 실패 테스트** (`tools/tests/test_make-ops-targets.bats` 또는 신규에 추가)

```bash
@test "make verify-posture target exists and is live-guarded" {
  run grep -E '^verify-posture:' Makefile
  [ "$status" -eq 0 ]
  run grep -A4 '^verify-posture:' Makefile
  echo "$output" | grep -q 'KUBECONFIG'   # 라이브 가드
  echo "$output" | grep -q 'tests/posture'
}
```

**Step 2~3:** `verify-posture` 타깃 추가 — `verify-runbooks` 패턴 차용(KUBECONFIG 부재 시 깔끔히 skip,
있으면 `bats tests/posture/test_*.bats`). `make help`에 라이브 전용 표기. AGENTS.md 핵심명령에 1줄.
**Step 4:** Run: `bats tools/tests/test_make-ops-targets.bats` → PASS. `make verify-posture`(KUBECONFIG 없이) → skip 메시지.
**Step 5: Commit** — `git commit -m "feat: make verify-posture — posture 라이브 스위트 진입점(고아 해소)"`

**(c) infra/cloudflare DNS/tunnel 가드 배선 (iac advisory — terraform 결합).** `infra/cloudflare/test_apps_data.bats`
("apps.json DNS/tunnel SSOT 게이트" — active/public 게이팅·ingress 순서·host 유일성)는 **현재 미배선**이고,
`@test "terraform validate ..."`(L11-12 `terraform validate`)를 포함해 **gate(terraform 미설치)에 못 넣는다** →
`.ci-exclude`(terraform) 등재 + `iac.yaml`(terraform 설치됨, advisory)에 배선해 **최소한 돌게** 한다(미배선 해소).
**Step:** `iac.yaml` iac-validate에 `bats infra/cloudflare/test_apps_data.bats` 추가 → PASS → Commit
`git commit -m "test: cloudflare apps.json DNS 가드 iac 배선(미배선 해소; terraform 결합으로 advisory)"`.
**선택적 하드닝(별도 결정):** 정적 jq/grep 불변식(host 유일성·public&&active·no-apex)만 별도 파일로 분리해
gate(required)에서 돌리면 프로덕션 노출 가드를 required로 승격 가능 — terraform @test는 iac 잔류. 본 플랜 범위 밖,
필요 시 후속.

### Task 1.5: 전 bats 도메인 accounting 가드 (TDD) — 미배정 테스트를 시끄럽게 실패

**목적:** F6 클래스(테스트가 어느 harness에도 안 묶여 조용히 죽음)를 구조적으로 차단. 모든 tracked
`test_*.bats`는 **정확히 한 도메인**에 배정돼야 한다: **gate**(`run-bats.sh --list`) · **chart-test**
(`platform/charts/app/tests/`) · **.ci-exclude**(not-CI-safe 레지스트리 — 주석이 실행처 iac/manual 명시).

**Files:** Create `scripts/check-bats-accounting.sh`, Test `tools/tests/test_bats-accounting.bats`, Modify `Makefile`(verify에 편입)

**Step 1: 실패 테스트** — 미배정 bats가 있으면 실패.
```bash
@test "every tracked test_*.bats is assigned to gate/chart-test/iac/live (no orphan)" {
  run bash "$ROOT/scripts/check-bats-accounting.sh"
  [ "$status" -eq 0 ]   # 미배정 1개라도 있으면 exit 1 + 목록 출력
}
```
**Step 2~3:** `check-bats-accounting.sh` 구현 — **3 도메인 exactly-one ownership**(grep-iac.yaml 같은 brittle
매칭 없음 — terraform/live는 `.ci-exclude`가 등재). `git ls-files '*test_*.bats'` 각 파일 f의 도메인 매치 수를 센다:
①**gate**(`run-bats.sh --list` 포함) ②**chart-test**(`platform/charts/app/tests/` 하위) ③**.ci-exclude**(레지스트리
멤버 — 사유+실행처 주석이 iac/manual을 명시). **매치 수 ≠ 1이면 실패**(0=고아, 2+=이중 소유). 추가 **`.ci-exclude`
유효성**: 각 항목이 (a) git-tracked 실재 파일, (b) `run-bats.sh --list`에 **미포함**(제외인데 gate에 들어가면 모순).
위반 시 목록 출력+exit 1. (bash 3.2 호환: `case`/`grep`/카운터, mapfile·`[[ ]]` 금지.)
`make verify`가 호출하게 편입.
**Step 4:** `bats tools/tests/test_bats-accounting.bats` → PASS(이 시점엔 test_apps_data·k3s-bootstrap 전부 배정됨).
**Step 5: Commit** — `git commit -m "test: 전 bats 도메인 accounting 가드 — 미배정(고아) 테스트 차단"`

### Task 1.6: W1 통합 검증 + PR
`make verify && make chart-test && ./scripts/run-bats.sh` green. `test_make-ci-parity` PASS(러너 동치).
PR 생성 → gate 통과 → merge.

---

# W2 — victoria-stack flat→prod/ 표준화 (PR 3, **W1 의존**·최고위험, render-parity 게이트)

**목적:** 19개 flat manifest + kustomization + secret-generator + rules/ + co-located test를
`platform/victoria-stack/prod/`로 이동해 12 컴포넌트 `<comp>/prod/` 단일 규약에 수렴. alerting.enc.yaml은 이미
prod/이므로 이동 대상 아님.

> **enc.yaml 불변**: `alerting.enc.yaml`은 건드리지 않음(이미 prod/). `secret-generator.yaml`(평문)만 1줄 편집.

### Task 2.1: [OWNER] 이동 전 render-parity 베이스라인 캡처

```bash
export SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt
kustomize build --enable-helm --enable-alpha-plugins --enable-exec \
  platform/victoria-stack > /tmp/vs-before.yaml   # raw, sort 없음(문서 경계 보존)
wc -l /tmp/vs-before.yaml   # 비어있지 않아야(KSOPS 복호 성공)
```

### Task 2.2: manifest·kustomization·secret-generator·rules·co-located test를 prod/로 이동

**Files (`git mv`, alerting.enc.yaml 제외 전부):**
```
platform/victoria-stack/{alertmanager,deadmanswitch-relay,digest-exporter,grafana-dashboards,
  grafana-provisioning,grafana,httproute-grafana,kube-state-metrics,namespace,node-exporter,
  vector,victorialogs,vmagent-scrape-config,vmagent,vmalert,vmsingle}.yaml  → prod/
platform/victoria-stack/kustomization.yaml         → prod/
platform/victoria-stack/secret-generator.yaml      → prod/
platform/victoria-stack/rules/                      → prod/rules/
platform/victoria-stack/test_relay.bats            → prod/
platform/victoria-stack/NOTES.md                   → prod/  (또는 README로 — W4와 조율)
```
이동 명령:
```bash
cd platform/victoria-stack
mkdir -p prod
git mv alertmanager.yaml deadmanswitch-relay.yaml digest-exporter.yaml grafana-dashboards.yaml \
  grafana-provisioning.yaml grafana.yaml httproute-grafana.yaml kube-state-metrics.yaml \
  namespace.yaml node-exporter.yaml vector.yaml victorialogs.yaml vmagent-scrape-config.yaml \
  vmagent.yaml vmalert.yaml vmsingle.yaml kustomization.yaml secret-generator.yaml test_relay.bats prod/
git mv rules prod/rules
```
kustomization.yaml의 `resources:`(L5-24, 20개)·`generators:`(L26-27)는 manifest를 함께 옮겼으므로
**상대경로 불변**(전부 같은 prod/ 기준). `rules/core.yaml` 등도 `prod/rules/`로 함께 이동하여 상대경로 유지.

### Task 2.3: secret-generator KSOPS 상대경로 수정 (유일한 manifest-내부 참조)

**Files:** Modify `platform/victoria-stack/prod/secret-generator.yaml:9`
- `- ./prod/alerting.enc.yaml` → `- ./alerting.enc.yaml` (이제 secret-generator도 prod/ 안 → 동일 디렉토리)

### Task 2.4: ArgoCD Application source.path 갱신

**Files:** Modify `platform/argocd/root/apps/victoria-stack.yaml:15`
- `path: platform/victoria-stack` → `path: platform/victoria-stack/prod`
- **appset exclude(`appset.yaml:25` `platform/victoria-stack/*`)는 유지**(victoria-stack은 수동 Application
  계속 유지, 이중소유 방지). 변경 금지.

### Task 2.5: victoria-stack 경로 소비자 전수 갱신 (`git grep` authoritative)

> **이동 전 필수**: 편집 목록을 enumeration이 아니라 `git grep`으로 확정한다(이전 enum이 cnpg·traps.md를
> 누락했던 교훈). **단일 가공 정렬되지 않은 객체 비교 위해** 아래를 authoritative edit list로 삼는다:
> ```bash
> git grep -n 'platform/victoria-stack/\(rules\|alertmanager\|vmagent\|vmalert\|vmsingle\|vector\|...\)' \
>   -- ':!docs/plans/*' ':!*.md'        # 경로 소비자 전수
> git grep -rln 'platform/victoria-stack' -- ':!docs/plans/*'   # 광역 확인
> ```

**Files (경로 prefix `platform/victoria-stack/` → `platform/victoria-stack/prod/`):**
- `tests/gates/test_alertmanager-template.bats:10,79,98` (alertmanager.yaml, rules/core.yaml)
- `tests/gates/alertmanager-render-e2e.sh:24` (alertmanager.yaml)
- `tests/gates/test_vmalert-config.bats:9,18,24,28,40,47,58,72,83,91,96,97`
  (vmalert.yaml, vmagent.yaml, vmagent-scrape-config.yaml, rules/{core,r4,r5}.yaml, `$comp.yaml` base)
- `tests/gates/test_telegram-alert-korean.bats:10` (rules/ 디렉토리)
- **`platform/cnpg/prod/test_breadcrumb_metrics.bats:33,35,40,41,43,50,52`** (7줄, **enum 누락분** —
  `platform/victoria-stack/rules/r4-storage-backup.yaml`을 cross-component로 grep. `rules/`가 `prod/rules/`로
  옮겨지면 이 7줄이 깨진다 → `platform/victoria-stack/prod/rules/r4-storage-backup.yaml`로 갱신).

> 위 bats 파일들은 W1에서 `tests/gates/`로 이동됨 — 경로는 `$ROOT/platform/victoria-stack/...` 형태이므로
> `platform/victoria-stack/` 다음에 `prod/`만 삽입(`rules/`→`prod/rules/`). cnpg breadcrumb는 `platform/cnpg/prod/`에
> 그대로 co-located(이동 안 함) — 내부 경로 문자열만 갱신.
> **W2는 W1에 의존(W0→W1→W2 강제)** — `tests/gates/` 경로는 W1 머지 후에만 존재한다. W2를 독립/선행 실행하지 않는다.

### Task 2.5b: docs/traps.md 트랩 원장 경로 갱신 (enum 누락분)

**Files:** Modify `docs/traps.md:20`
- `| busybox 1.36 nc에 -q 없음(relay 리스너) | gate | \`platform/victoria-stack/test_relay.bats\` |`
  → `\`platform/victoria-stack/prod/test_relay.bats\`` (test_relay.bats가 prod/로 이동하므로). 미갱신 시
  **`make verify-traps`가 가드 파일 소실로 실패**(원장 stale).

**Step:** traps.md:20 경로 Edit → Run: `make verify-traps` → PASS(가드 파일 존재 확인).

### Task 2.6: [OWNER] render-parity 검증 (이동 후)

```bash
export SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt
kustomize build --enable-helm --enable-alpha-plugins --enable-exec \
  platform/victoria-stack/prod > /tmp/vs-after.yaml   # raw, sort 없음
diff /tmp/vs-before.yaml /tmp/vs-after.yaml   # 빈 출력 = 렌더 동일(성공 게이트)
```
**Expected:** diff 빈 출력. **순서 노이즈로만 diff가 나면**(내용 동일·순서만) **전체 내용 정규화** diff로 재비교
(식별자 키만이 아니라 **객체 전체 내용**을 비교 — 필드 변경 누락 방지):
```bash
canon() { # 각 문서를 식별자 키명 파일로 분할 저장 (mikefarah yq -s) → 순서 무관·내용 완전
  rm -rf "$2"; mkdir -p "$2"
  yq -s '"'"$2"'/" + (.apiVersion|sub("/";"_")) + "_" + .kind + "_" + (.metadata.namespace // "_") + "_" + .metadata.name' "$1"
}
canon /tmp/vs-before.yaml /tmp/vs-b
canon /tmp/vs-after.yaml /tmp/vs-a
diff -r /tmp/vs-b /tmp/vs-a   # 객체별 파일(키명) 전체 내용 비교 — 빈 출력이어야
```
**전체 내용 diff가 비어야 통과. 한 필드라도 다르면 STOP** — 상대경로/secret-generator(`./alerting.enc.yaml`) 수정 누락 점검.

### Task 2.7: 영향 테스트 실행 + 커밋

Run: `bats tests/gates/test_vmalert-config.bats tests/gates/test_alertmanager-template.bats
platform/victoria-stack/prod/test_relay.bats platform/cnpg/prod/test_breadcrumb_metrics.bats` → PASS
(**breadcrumb 포함** — rules/ 이동 경로 갱신 검증).
Run: `make verify-traps` → PASS (traps.md:20 경로 갱신 확인).
Run: `./scripts/run-bats.sh`(오프라인 범위) → PASS.
Run: `make verify` (check-skeleton dirs에 `platform/victoria-stack` 있음 — 디렉토리 자체 존재라 통과).
**Commit:** `git commit -m "refactor: victoria-stack flat→prod/ 표준화 + source.path·테스트 경로 동기"`

### Task 2.8: [OWNER] 라이브 sync 확인 + PR

PR 생성 → gate 통과 → merge. 머지 후:
```bash
export KUBECONFIG=$PWD/infra/k3s-bootstrap/kubeconfig
kubectl -n argocd patch app victoria-stack --type merge -p '{"operation":{"sync":{}}}'  # 명시 sync
kubectl -n argocd get app victoria-stack -o jsonpath='{.status.sync.status} {.status.health.status}'
# 기대: Synced Healthy
```
회귀 시 PR revert(전용 PR이라 격리). `argo` 스킬로 진단.

---

# W3 — apps/pg-tools → ops/ (PR 4)

**목적:** 빌드-전용 ops 이미지를 apps/(배포-전용 계약)에서 분리해 apps/·build.yaml 양쪽을 정직화.
ArgoCD appset(`apps/*/deploy/prod`)은 pg-tools를 애초에 안 잡으므로 라이브 무영향.

### Task 3.1: 디렉토리 이동 + 빌드 컨텍스트 경로 3곳 갱신 (TDD)

**Files:**
- `git mv apps/pg-tools ops/pg-tools` (Dockerfile + README.md)
- Modify `.github/workflows/build.yaml`: L6 `"apps/**"`→`"ops/**"`, L7 `"!apps/**/deploy/**"` 제거(ops엔 deploy 없음),
  L52-53 `^apps/${APP}/`·`^apps/${APP}/deploy/` → `^ops/${APP}/`(deploy 분기 제거), L74 `context: apps/${{ matrix.app }}`→`ops/${{ matrix.app }}`.
- matrix(L24 `app: [pg-tools]`)·태그 분기(L58/66/67)·이미지명(`ghcr.io/.../pg-tools`)은 **이름 기반 — 불변**.
- Modify `tools/tests/test_pg-tools.bats:2` `DF="apps/pg-tools/Dockerfile"`→`ops/pg-tools/Dockerfile`.
  (L12-13 matrix 단언은 불변.)
- `tools/tests/test_ci-build.bats` — matrix.app·태그만 단언 → 불변(확인만).
- 주석 정확성(선택): `appset.yaml:60` 주석, `platform/cnpg/prod/pgdump-hedge-cronjob.yaml:26` `(apps/pg-tools/)`→`(ops/pg-tools/)`.

**Step 1: 테스트 먼저(경로 단언 업데이트)** — `test_pg-tools.bats:2` DF 경로를 ops로 바꾸고 실행 → FAIL(파일 아직 apps/).
**Step 2: 이동 + build.yaml 3곳 수정.**
**Step 3:** Run: `bats tools/tests/test_pg-tools.bats tools/tests/test_ci-build.bats` → PASS.
Run: `yq '.on.push.paths' .github/workflows/build.yaml` → `ops/**` 확인. `yq '.jobs.build.steps[]|select(.with.context)|.with.context'`(또는 grep `context:`) → `ops/${{ matrix.app }}`.
**Step 4: Commit** — `git commit -m "refactor: pg-tools를 apps/→ops/ (배포-전용 계약 정합 + build.yaml 경로)"`

### Task 3.2: deploy/prod 계약 schema SSOT + apps/README (TDD)

**Files:** Create `tools/app-deploy-schema.json`, Modify `scripts/check-skeleton.sh`(또는 verify 게이트),
Create `apps/README.md`, Modify `ops/pg-tools/README.md`

**Step 1: 실패 테스트** (`tools/tests/test_app-deploy.bats`) — `apps/*/deploy/prod/`가 **완전한 계약**
(`values.yaml` · `.bindings.json` · **`source-repo`**)을 만족하는지 검증. **source-repo는 필수**(poll-ghcr가
source-repo 있는 앱 디렉토리만 update-image 폴링 — 누락 시 그 앱은 영영 폴링 밖). **양성+음성 fixture**:
(a) 3파일 모두 있는 양성 → PASS, (b) source-repo 누락 음성 → FAIL, (c) schema-valid fixture가
**poll-ghcr 발견 경로**(`tools/poll-ghcr.mjs`의 source-repo 스캔)에 잡히는지 단언. (in-repo 배포앱 0개라 fixture.)
**Step 2~3:** `app-deploy-schema.json`(create-app.mjs 암묵 계약 명문화 — values.yaml·.bindings.json·source-repo
3파일 required) + verify 게이트(check-skeleton 또는 신규). `apps/README.md`('배포앱=deploy/prod의 3파일 보유;
빌드-전용 ops 이미지는 ops/'). `ops/pg-tools/README.md` 정체성 1줄.
**Step 4~5:** 양성 PASS·음성 FAIL 확인 → Commit `git commit -m "feat: deploy/prod 계약 schema SSOT(source-repo 포함) + apps/ops README"`

### Task 3.3: W3 검증 + PR — `make verify && make chart-test && ./scripts/run-bats.sh` green → PR → merge.

---

# W4 — 발견성 (PR 5, 순수 가산·저위험)

### Task 4.1: README.md 디렉토리 지도 드리프트 수정 (TDD 가드)

**Files:** Modify `README.md:20`, `scripts/check-skeleton.sh`(드리프트 가드), Test `tools/tests/test_dirmap.bats`

**Step 1: 실패 가드 테스트** — `platform/` 실제 서브디렉토리(check-skeleton의 `dirs` 배열, L3-11 = SSOT)와
README.md·AGENTS.md 지도 나열의 정합을 단언. (현재 README:20은 'edge' 가상명 + cache/data-conn/sealed-secrets/
namespaces 누락 → FAIL.)
```bash
@test "README platform map lists every real platform component" {
  for c in $(ls -d platform/*/ | xargs -n1 basename | grep -vE '^(charts)$'); do
    grep -q "$c" README.md || { echo "missing in README: $c"; return 1; }
  done
}
```
**Step 2~3:** README.md:20을 AGENTS.md:12 표기에 맞춰 정합화('edge 3종=adguard/cloudflared/tailscale' 풀어쓰기 +
누락 컴포넌트 추가). check-skeleton에 위 cross-check 가드 추가(새 컴포넌트 추가 시 지도 갱신 강제).
**Step 4:** `bats tools/tests/test_dirmap.bats` → PASS. **Step 5:** Commit `git commit -m "docs+test: README 디렉토리 지도 드리프트 수정 + check-skeleton 정합 가드"`

### Task 4.2: 컴포넌트 README (platform 12 + infra 4) + 기존 코드근접 문서 링크업

**Files:** Create `platform/<comp>/README.md` (adguard, argocd, cache, cloudflared, cnpg, data-conn, namespaces,
network-policies, sealed-secrets, tailscale, traefik, victoria-stack), `infra/<comp>/README.md`
(cloudflare, github, k3s-bootstrap, tailscale). 각 5-10줄: **역할 / 싱크 Application·sync-wave / 라이브 디버그
스킬·런북 / 함정 SSOT(AGENTS.md 해당 줄)**.
- 기존 문서 링크업: `platform/victoria-stack/prod/NOTES.md`·`platform/network-policies/prod/NOTES.md`·
  `platform/argocd/root/SYNC-WAVES.md`를 해당 README에서 상대링크.

**Step:** README 작성(가산만 — 코드/CI/ArgoCD 무영향). 선택: README 존재 가드를 check-skeleton에 추가(stale 위험 vs 강제 트레이드오프 — 본 플랜은 가드 없이 1회 작성, 드리프트는 W4 가드(4.1)가 지도 차원만 커버).
**Commit:** `git commit -m "docs: platform 12 + infra 4 컴포넌트 README + NOTES/SYNC-WAVES 링크업"`

### Task 4.3: runbook 깨진 링크 해소 + tools/scripts 인덱스

**Files:** Create `docs/runbooks-public/toolchain-setup.md`(또는 CONTRIBUTING에 인라인) — 추적되는 toolchain
설치 최소본(도구·핀 버전)으로 온보딩 0단계 자기완결. Modify `README.md`/`CONTRIBUTING.md`에 'runbooks gitignored —
owner 로컬 전용' 경고를 링크 옆에. Create `tools/README.md`·`scripts/README.md`(스크립트별 1줄: 직접실행 vs
워크플로전용 / 호출 make타깃·reusable / 입력 계약; `app-config-schema.json` vs `homelab-app-schema.json` 구분).
**Commit:** `git commit -m "docs: runbook 깨진 링크 스텁/toolchain 공개본 + tools·scripts README 인덱스"`

### Task 4.4: W4 PR — `make verify` green → PR → merge.

---

# W5 — scripts ↔ tools ↔ infra 경계 명문화 (PR 6, 저위험)

### Task 5.1: AGENTS.md 디렉토리 지도에 scripts/ 행 추가 + 3-way 경계 (TDD 가드)

**Files:** Modify `AGENTS.md:9-19`(지도 테이블), Test `tools/tests/test_dirmap.bats`(4.1 확장)

**Step 1: 실패 가드** — 지도 테이블에 `scripts/` 행이 있는지 단언(현재 부재 → FAIL).
```bash
@test "AGENTS directory map includes scripts/ row" {
  run sed -n '9,19p' AGENTS.md
  echo "$output" | grep -qE '`scripts/`'
}
```
**Step 2~3:** AGENTS.md 지도에 `scripts/` 행 추가 + 경계 규칙 기술: `tools/`=앱플랫폼 DX(Node CLI),
`scripts/`=클러스터/DR 운영·시크릿 셸, `infra/k3s-bootstrap/*.sh`=VM·k3s·스토리지 substrate 부트스트랩.
**Step 4~5:** PASS → Commit `git commit -m "docs+test: AGENTS 지도에 scripts/ 행 + tools/scripts/k3s-bootstrap 3-way 경계 명문화"`

### Task 5.2: W5 PR — `make verify` green → PR → merge.
(infra/_tests argocd 테스트 이동은 W1 Task 1.3에서 처리됨 — W5는 문서 경계만.)

---

# W6 — 네이밍 미세 정합 (PR 7, 저위험 일괄)

> **순서 — W6은 W7 다음**: W6이 `verify.yml`→`verify.yaml` rename하는데 W7 Task 7.1이 `verify.yml`을 편집한다.
> **W7을 먼저 머지**해야 충돌이 없고, W6의 소비자 스윕(Task 6.1 Step 2)이 W7 잔여 `verify.yml` 참조를 흡수한다.

### Task 6.1: .github/workflows .yml → .yaml 통일 (11개) + 내부 uses 동기

**Files:** `git mv` 11개 `.yml`→`.yaml`: `_audit`, `_create-app`, `_create-cache`, `_create-database`,
`_teardown`, `_update-secrets`, `bump-poll`, `dispatch-mutation`, `renovate`, `tf-reconcile`, `verify`.
**예외 — `reusable-app-build.yaml` 불변**(cross-repo `@main` full-ref 계약, 외부 caller 의존).

**소비자 전수 갱신 (rename 안전 프로토콜 — 11 basename 전부 `git grep`):** ⚠️ 워크플로 파일+dispatch uses만이
**아니다**. 검증된 소비자(최소): `dispatch-mutation.yaml` L64,76,87,97,107,115,125의 `uses: ./.github/workflows/_*.yml`(7줄);
**테스트** `tests/gates/test_dispatcher.bats`(dispatch-mutation.yml), `tests/gates/test_renovate.bats`(renovate.yml),
`tests/gates/test_ci-gate.bats`(verify.yml), `tests/gates/test_ci-toolchain-pin.bats`(create-app.yml 등);
**AGENTS.md**(bump-poll.yml·renovate.yml×2·tf-reconcile.yml — L155,158,162,166 부근); **`docs/decisions/0002-*.md:4`**(tf-reconcile.yml).
빈도: `tf-reconcile.yml`→7파일·`bump-poll.yml`→6·`_create-app/_create-database`→4 등. **required check `gate`는
job명이라 무영향**(파일명 무관). (app-config.yml·action.yml·alertmanager.yml은 rename 대상 아님 — 혼동 주의.)

**Step 1: 테스트** — `tests/gates/test_workflow-yaml.bats`에 **stale .yml 가드** 추가:
`[ -z "$(git ls-files '.github/workflows/*.yml')" ]`(reusable 제외 후 .yml 0개 — `git ls-files`는 매치 0에도 exit 0이라 `! git ls-files`는 항상 FAIL, **출력-비어있음**으로 검사) **AND** `! git grep -lE '(_audit|_create-app|_create-cache|_create-database|_teardown|_update-secrets|bump-poll|dispatch-mutation|renovate|tf-reconcile|verify)\.yml' -- ':!docs/plans/*'`(구 .yml 참조 0). 먼저 FAIL.
**Step 2:** `git mv` 11개 + **11 basename 전부 `git grep -n '<wf>\.yml' -- ':!docs/plans/*'`로 소비자 찾아 전 참조를 `.yaml`로 Edit**(dispatch uses 7 + 테스트 + AGENTS.md + decisions).
**Step 3 (no-stale):** Run: `git ls-files '.github/workflows/*.yml'` → 빈 출력. 위 Step 1 가드 → PASS.
`yq '.jobs' .github/workflows/dispatch-mutation.yaml` 파싱 OK. `make verify` PASS.
**Step 4: Commit** — `git commit -m "refactor: .github/workflows .yml→.yaml 통일(11) + 전 소비자(테스트·AGENTS·decisions) 동기"`

### Task 6.2: SealedSecret 파일명 `*.sealed.yaml` 정합

**Files:** `git mv platform/adguard/prod/auth-sealed.yaml platform/adguard/prod/adguard-auth.sealed.yaml`
- 동기 4지점: `platform/adguard/prod/kustomization.yaml:7`(resources), `scripts/seal-adguard-auth.sh:11`(OUT,
  +주석:3), `platform/adguard/prod/test_adguard_auth.bats:8`(S=)+`:39`(grep), `.env.secrets.example:85`(주석).

**Step 1:** `test_adguard_auth.bats:8,39`를 새 파일명으로 먼저 수정 → 실행 FAIL(파일 아직 옛 이름).
**Step 2:** `git mv` + kustomization·seal-adguard-auth.sh·.env.secrets.example 동기.
**Step 3:** `bats platform/adguard/prod/test_adguard_auth.bats` → PASS. **[OWNER] 선택:** 라이브 adguard sync 무영향
확인(kustomization이 새 파일명 흡수, 봉인값 무변경 → sync 영향 없음).
**Step 4: Commit** — `git commit -m "refactor: adguard auth-sealed.yaml→adguard-auth.sealed.yaml (*.sealed.yaml 정합)"`

### Task 6.3: 셰뱅/exec 비트 정책 통일

**Files:** `tools/*.mjs` 16개 — 항상 `node` 호출이므로 **셰뱅(`#!/usr/bin/env node`) 제거**(dead marker 정리).
`scripts/sealing-key-dr-gate.sh` — `chmod +x`(나머지 12개 scripts와 정합; source-only라 기능 무영향).

**Step 1: 테스트** — `tools/tests/test_workspace.bats`(또는 신규)에 단언: `tools/*.mjs` 첫 줄이 셰뱅 아님 +
`scripts/*.sh` 전부 exec 비트. 먼저 FAIL.
**Step 2~3:** 16 .mjs 셰뱅 제거 + `git update-index --chmod=+x scripts/sealing-key-dr-gate.sh`(또는 `chmod +x`).
**Step 4~5:** PASS → Commit `git commit -m "refactor: .mjs dead 셰뱅 제거 + sealing-key-dr-gate.sh +x 정합"`

### Task 6.4: 네이밍 규약 문서화 (코드 변경 0)

**Files:** Modify `AGENTS.md` 컨벤션 절 — `_*`(내부 reusable, dispatch만 호출) vs `reusable-*`(cross-repo 공개),
`*-schema.json`(tools 계약) vs `values.schema.json`(Helm 고정) 규약 1-2줄 명문화.
**Commit:** `git commit -m "docs: 워크플로 _*/reusable-* + schema 네이밍 규약 명문화"`

### Task 6.5: W6 PR — `make verify && ./scripts/run-bats.sh` green → PR → merge.

---

# W7 — CI 게이트 중복 정리 (PR 8, 저위험)

> **순서 — W7은 W6보다 먼저 머지**: W6 Task 6.1이 `verify.yml`을 `verify.yaml`로 rename한다. W7(verify.yml 편집)이
> 뒤/병렬이면 stale 경로·rename+edit 충돌. W7→W6면 W6의 git-grep 소비자 스윕이 W7의 `verify.yml` 참조를 `.yaml`로 흡수.

### Task 7.1: 메모리 원장 게이트 단일화

**현황:** ledger 검사가 `ci.yaml:35-36`(`pnpm verify:ledger`, job `gate`=required)과 `verify.yml:32-35`
(`ledger-to-json.sh | conftest policy/ledger.rego`, job `verify`=비-required) 양쪽 중복.

**Files:** Modify `.github/workflows/verify.yml` — ledger 스텝(L32-35) **제거**(권위 게이트는 required `gate`에
일원화). verify.yml은 고유 책임(skeleton·sops 라운드트립 ephemeral)만 유지. ci.yaml의 어느 워크플로가 무엇을
권위 게이트하는지 `ci.yaml` 상단 주석 1줄.

**Step 1: 테스트** — `tests/gates/test_make-ci-parity.bats` 또는 신규에 'ledger 게이트는 ci.yaml gate 한 곳'
단언(verify.yml에 conftest ledger 없음). 먼저 FAIL.
**Step 2~3:** verify.yml L32-35 제거 + ci.yaml 주석. **주의:** verify.yml job명 `verify`·ci.yaml job명 `gate`
불변(repo.tf contexts).
**Step 4:** `yq '.jobs.verify.steps[].name' .github/workflows/verify.yml` → ledger 스텝 없음. `bats` 가드 PASS.
**Step 5: Commit** — `git commit -m "refactor: 메모리 원장 게이트를 required gate 한 곳으로 일원화(verify.yml 중복 제거)"`

### Task 7.2: W7 PR — `make verify` green → PR → merge.

---

## 최종 통합 검증 (전 워크스트림 머지 후)

1. **오프라인:** `make verify && make chart-test && ./scripts/run-bats.sh` 전부 green.
2. **네이밍 가드** (`git ls-files`는 매치 0에도 exit 0 → `!` 부정은 항상 FAIL이므로 **출력-비어있음** `[ -z … ]`로 검사):
   `[ -z "$(git ls-files '*.bats' | grep -vE '(^|/)test_')" ]`(전 bats 접두) ·
   `[ -z "$(git ls-files '.github/workflows/*.yml')" ]`(reusable 제외 .yaml 통일).
3. **수집 SSOT (gate-도메인 공식 — Task 0.3와 동일):**
   `./scripts/run-bats.sh --list | sort -u` == `git ls-files '*test_*.bats' | grep -vE '^platform/charts/'`에서
   `.ci-exclude` 멤버를 뺀 집합. (**charts만 prune**, infra는 미prune — CI-safe infra는 gate.)
   chart-test 도메인(`platform/charts/app/tests/`)은 `make chart-test` 별도 검증.
   추가: `scripts/check-bats-accounting.sh` PASS(전 bats가 gate/chart-test/.ci-exclude 중 정확히 한 도메인).
4. **[OWNER] 라이브:** `KUBECONFIG`로 victoria-stack·adguard Application `Synced Healthy` 확인. `argo` 스킬로 sync 상태 스윕.
5. **AGENTS.md 갱신:** 디렉토리 지도(scripts/ 행·README 정합)·핵심명령(verify-posture·새 테스트 경로)·네이밍 규약 반영.

## 시퀀싱 요약
```
W0 (러너+네이밍)  ──►  W1 (이동+죽은커버리지+accounting)  ──►  W2 (victoria-stack)   [엄격 순서]
W3 · W4 · W5  ── W1 이후 병렬 (tools/tests/·tests/gates/ 등 W1 경로 의존)   [저위험]
W7 ──► W6     ── W1 이후, W7 먼저 (W6가 verify.yml→verify.yaml rename · W7은 verify.yml 편집 → 병렬/역순 시 rename+edit 충돌)   [저위험]
```
> **W2는 W1에 강하게 의존**(Task 2.5/2.7이 `tests/gates/` 경로 사용 — W1 머지 후에만 존재) → W0→W1→W2 순서
> 강제, W2 독립 실행 금지. render-parity + 라이브 sync 게이트로 최고위험 격리.
>
> **W6·W7은 상호 병렬 금지 — W7 먼저**: W6 Task 6.1이 `verify.yml`을 `verify.yaml`로 rename하고 W7 Task 7.1이
> `verify.yml`을 편집한다. W7을 먼저 머지하면 W6의 git-grep 소비자 스윕(Task 6.1 Step 2)이 W7이 남긴
> `verify.yml` 참조까지 `.yaml`로 흡수하므로 W7 내용 변경이 불필요. 병렬/역순이면 PR-first auto-merge에서
> rename+edit 충돌로 후속 PR 머지가 막힌다.

---

## Adversarial review dispositions (감사 트레일 — bookkeeping)

이 플랜은 codex adversarial review를 **5-pass**(번들 `adversarial-review.mjs --scope working-tree`) 거쳤다.
총 **17 findings 전부 Accepted**(0 Rejected — 전건 사실 검증·승인 scope 내·위험 실질 감소). **핵심 설계(7
워크스트림·접근)는 5-pass 내내 한 번도 도전받지 않음**. 마무리는 캡(3) 2회 초과 시점에 사용자의 informed
decision(open-items 제시 후 "반영+finalize")으로 확정 — 최종 pass는 `needs-attention`이었고 그 3건(P5)을
반영 후 재리뷰하지 않음(Phase D 규약: dispositions는 사후 감사로 재리뷰 대상 아님).

| Pass | Finding | Sev | Decision | 반영 |
|---|---|---|---|---|
| 1 | 러너 `mapfile`이 bash 3.2(/bin/bash 3.2.57) 비호환 | H | Accept | `while read` 재작성 + /bin/bash 테스트 (Task 0.3) |
| 1 | `make -n ci` parity 스냅샷이 가짜(명령치환 미실행) | H | Accept | `list-current-ci-bats.sh` 실제 수집기 + comm no-drop (Task 0.5) |
| 1 | W2 소비자 누락(cnpg breadcrumb 7줄·traps.md) | H | Accept | git grep authoritative + breadcrumb·traps.md·verify-traps (Task 2.5/2.5b/2.7) |
| 1 | `sort` 기반 render-parity 불건전 | M | Accept | unsorted 우선 + 전체 정규화 diff (preamble/Task 2.6) |
| 2 | bats rename 인벤토리가 Makefile/traps.md/decisions/NOTES/scripts 누락 | H | Accept | 전수 git grep + no-stale 단언 + verify-traps (Task 0.1) |
| 2 | cloudflare DNS 가드 미배선 + accounting 부재 | H | Accept | iac 배선 + 도메인 accounting 가드 (Task 1.4c/1.5) |
| 2 | W2 "독립" ↔ W1 경로 의존 모순 | M | Accept | W2를 W1 명시 의존 (preamble/W2/시퀀싱) |
| 3 | W3~W7 "W0 후 병렬" ↔ W1 경로 의존 | H | Accept | W3~W7도 W1 의존 + 일반 원칙 (preamble/시퀀싱) |
| 3 | W6 워크플로 rename 인벤토리 불완전 | H | Accept | 11 basename 전수 grep + stale .yml 가드 (Task 6.1) |
| 3 | accounting 가드 any-match(exactly-one 아님) | H | Accept | count==1 + .ci-exclude 유효성 (Task 1.5) |
| 3 | 최종 §3 수집 불변식이 도메인 prune 무시 | M | Accept | gate-도메인 공식 정합 (최종 §3) |
| 4 | 정적 infra 가드를 non-required iac에 → 미보호 | H | Accept | 모델 단순화 gate=all-CI-safe (러너/.ci-exclude) |
| 4 | accounting iac 소유권 grep-basename이 glob과 모순 | M | Accept | 3-도메인(gate/chart-test/.ci-exclude) (Task 1.5) |
| 4 | 러너를 `./run-bats.sh` 직접 호출하나 exec 비트 미설정 | M | Accept | chmod +x + exec-비트 단언 (Task 0.3) |
| 5 | cloudflare 테스트가 `terraform validate` 의존(P4 분류 정정) | H | Accept | .ci-exclude(terraform)+iac advisory + 선택적 분리 (.ci-exclude/Task 1.4c) |
| 5 | render-parity fallback이 식별자 키만 비교 | H | Accept | per-object 전체 내용 정규화 diff (Task 2.6) |
| 5 | deploy schema가 source-repo 누락(poll-ghcr 발견 계약) | M | Accept | source-repo 필수 + 음성 fixture + 발견 테스트 (Task 3.2) |

**최종 pass(5) verdict:** `needs-attention` — *summary:* "No-ship: the plan can break the required gate and its
highest-risk render-parity gate can miss real drift." → 해당 3건(P5) 반영 완료. **잔여 위험**은 플랜에 내장한
per-task 게이트(TDD·render-parity·accounting 가드·no-stale 단언·verify-traps·도메인 accounting)가 실행 중 포착.
