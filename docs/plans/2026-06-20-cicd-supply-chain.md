# CI/CD 공급망 + gate 의미검증 Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** GitHub Actions CI/CD의 4개 공급망/gate 갭을 닫는다 — mutable 액션 SHA-pin(+가드), required gate에 actionlint, setup-bun 컴포지트 수렴, gitleaks 버전 추출 yq 구조화.

**Architecture:** `.github/`만 변경(ArgoCD 미싱크, 라이브위험0). 단 required `gate`(ci.yaml job `gate`)가 머지 권위라 깨지면 전 머지 차단 → 각 변경을 로컬에서 actionlint/yq/gitleaks 실행으로 검증. 4 수정 + 가드 테스트, 단일 PR.

**Tech Stack:** GitHub Actions(composite actions), bats(tests/gates/), mikefarah yq(setup-toolchain), actionlint(rhysd), gitleaks. 러너=ubuntu-24.04-arm(arm64).

**설계 출처:** `docs/plans/2026-06-20-cicd-supply-chain-design.md`(커밋 `ca42564`). 결정: D1=comprehensive(전 third-party SHA-pin), D2=manual 핀(Renovate 활성화 범위 밖), D3=setup-bun 컴포지트 `install:false`로 동작보존.

---

## 작업 전 공통 규칙 (모든 Task)

- **bats `@test` 이름은 영어만**(디렉토리 실행 시 한글 인코딩 깨짐). 중간 단언은 `[ ]`만(bash 3.2 `[[ ]]` 침묵통과). `test_` 접두. 위치=`tests/gates/`(run-bats.sh가 수집).
- **하네스 셸=zsh** — `bun -e`/grep의 unquoted `$var`는 non-split(필요 시 `bash -c` 또는 인용).
- **SHA-pin 시 placeholder 금지** — mutable 태그가 가리키는 **실제 commit SHA**를 해석해 핀(`gh api`). 잘못된 SHA는 액션 resolve 실패로 즉시 red(안전하지만 머지 차단).
- **gate=유일 required check** — actionlint/yq/gitleaks 변경은 PR 전 로컬 실행으로 green 증명(러너 도구는 setup-toolchain 경로 또는 로컬 설치).
- **커밋**: 한국어 conventional, AI 마커 금지. type=feat/fix/refactor/docs/style/test/chore. (핀·yq·컴포지트=`refactor:` 또는 `fix:`[보안/취약], actionlint 신규 게이트=`feat:` 또는 `chore:`.)

---

## Task 1: gitleaks 버전 추출을 yq 구조 쿼리로 (수정4)

`grep -A2` 라인오프셋 의존을 제거. yq는 같은 gate 잡(setup-toolchain)이 이미 설치.

**Files:**
- Modify: `.github/workflows/ci.yaml:39`
- Modify: `tests/gates/test_gate-secret-guard.bats:13` (기존 grep 단언 → yq, **F6**: 안 고치면 yq 변경이 이 required-gate 테스트를 red로)
- Test: `tests/gates/test_gitleaks-version-extract.bats` (신규)

**Step 1: 실패 테스트 작성** — `.pre-commit-config.yaml`에서 yq가 정확한 버전을 뽑고, ci.yaml이 `grep -A2`를 안 쓰는지:

```bash
#!/usr/bin/env bats
# gitleaks 버전 추출이 라인오프셋(grep -A2) 아니라 yq 구조 쿼리인지. ⚠️ 중간 단언 [ ]만.
setup() { ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"; cd "$ROOT" || exit 1; }

@test "yq extracts gitleaks rev structurally (line-offset independent, no hardcoded version)" {
  command -v yq >/dev/null || skip "yq 미설치(CI setup-toolchain가 제공)"
  TMP="$(mktemp -d)"
  # gitleaks 블록을 일부러 첫 위치가 아니게(앞에 다른 repo) + 임의 버전 — 라인오프셋 의존이면 깨짐.
  # 실제 .pre-commit-config 버전을 하드코딩하지 않음(F5: 제2 SSOT·bump red 회피).
  printf '%s\n' 'repos:' \
    '  - repo: https://github.com/pre-commit/pre-commit-hooks' \
    '    rev: v4.5.0' \
    '    hooks:' \
    '      - id: end-of-file-fixer' \
    '  - repo: https://github.com/gitleaks/gitleaks' \
    '    rev: v9.9.9' \
    '    hooks:' \
    '      - id: gitleaks' > "$TMP/.pre-commit-config.yaml"
  run bash -c "yq '.repos[] | select(.repo == \"https://github.com/gitleaks/gitleaks\") | .rev' '$TMP/.pre-commit-config.yaml' | sed 's/^v//'"
  [ "$status" -eq 0 ]
  [ "$output" = "9.9.9" ]   # 픽스처 임의 버전 — 실제 버전 무관(구조 추출 증명)
}

@test "ci.yaml gitleaks step no longer uses grep -A2 line-offset extraction" {
  run grep -nE "grep -A2 'gitleaks/gitleaks'" .github/workflows/ci.yaml
  [ "$status" -ne 0 ]
  run grep -Fq 'select(.repo' .github/workflows/ci.yaml
  [ "$status" -eq 0 ]
}
```

**Step 2: 실패 확인** — `bats tests/gates/test_gitleaks-version-extract.bats` → 2번째 FAIL(아직 grep -A2).

**Step 3: ci.yaml 수정** — L39를 yq 구조 쿼리로:
```bash
# 현재:
#   ver=$(grep -A2 'gitleaks/gitleaks' .pre-commit-config.yaml | grep -oE 'rev: v[0-9.]+' | grep -oE '[0-9.]+')
# 교체:
ver=$(yq '.repos[] | select(.repo == "https://github.com/gitleaks/gitleaks") | .rev' .pre-commit-config.yaml | sed 's/^v//')
[ -n "$ver" ] || { echo "::error::gitleaks rev를 .pre-commit-config.yaml에서 못 찾음"; exit 1; }   # fail-loud(빈 버전 차단)
```
> yq는 setup-toolchain(L24-33, gitleaks 스텝 앞)이 설치 — 순서 OK. mikefarah yq 문법.

**Step 4: 기존 secret-guard 테스트 갱신 (F6)** — `tests/gates/test_gate-secret-guard.bats:13`이 ci.yaml에 grep 추출이 있는지 단언하므로 yq 변경 시 red. 그 단언을 yq 유도로 교체(의도 보존=gitleaks rev를 `.pre-commit-config.yaml`에서 런타임 유도):
```bash
# L13 현재: run grep -qE 'grep .*gitleaks/gitleaks.*\.pre-commit-config\.yaml' "$CI"
# 교체:     run grep -qE 'yq .*\.pre-commit-config\.yaml|select\(\.repo.*gitleaks' "$CI"
# (L9-10 주석의 'grep해' 문구도 'yq로 구조 유도'로 갱신. L11의 테스트 자체 rev 추출은 PRECOMMIT 직접 grep이라 동작 무관 — 선택적으로 yq화.)
```

**Step 5: 통과 확인** — `bats tests/gates/test_gitleaks-version-extract.bats tests/gates/test_gate-secret-guard.bats` → 둘 다 PASS(yq 설치 환경; 미설치면 신규는 skip, secret-guard는 ci.yaml 문자열 단언이라 통과).

**Step 6: 커밋**
```bash
git add .github/workflows/ci.yaml tests/gates/test_gitleaks-version-extract.bats tests/gates/test_gate-secret-guard.bats
git commit -m "fix: gitleaks 버전 추출을 yq 구조 쿼리로(grep -A2 라인오프셋 제거)

- 기존 secret-guard 게이트 테스트의 grep 단언도 yq로 갱신(required gate red 방지)"
```

---

## Task 2: setup-bun 컴포지트 `install` 입력 + 디스패처/dns-drift 수렴 (수정3)

인라인 `oven-sh/setup-bun@SHA` 복붙을 version SSOT 컴포지트로. `install:false`로 디스패처 no-install 보존.

**Files:**
- Modify: `.github/actions/setup-bun/action.yml`
- Modify: `.github/workflows/create-app.yaml:29-30`·`create-cache.yaml:26`·`create-database.yaml:26`·`update-secrets.yaml:26`·`dns-drift.yaml:19-20`
- Modify: `tests/gates/test_setup-bun.bats` (**기존** — "all 7" 채택 리스트가 stale, 5 디스패처 추가 + install 입력/install:false 검사. 별도 신규 파일 대신 확장, 중복 방지)

**Step 1: 실패 테스트 작성** — **기존 `tests/gates/test_setup-bun.bats`를 확장**(신규 파일 X). ① 기존 `@test "all 7 install workflows adopt..."`의 워크플로 리스트에 5개 디스패처(create-app/create-cache/create-database/update-secrets/dns-drift) 추가 + 이름/주석 "7"→"12". ② 아래 @test 추가:
```bash
@test "setup-bun composite exposes an install input (default true)" {
  run grep -Eq '^[[:space:]]+install:' .github/actions/setup-bun/action.yml   # inputs.install 키
  [ "$status" -eq 0 ]
}

@test "dispatchers + dns-drift use the composite with install:false (no inline oven-sh, deps unneeded)" {
  for wf in create-app create-cache create-database update-secrets dns-drift; do
    run grep -Fq 'oven-sh/setup-bun' ".github/workflows/$wf.yaml"
    [ "$status" -ne 0 ]                                   # 인라인 잔존 0
    run grep -Fq './.github/actions/setup-bun' ".github/workflows/$wf.yaml"
    [ "$status" -eq 0 ]                                   # 컴포지트 사용
    run grep -Eq "install:[[:space:]]*'?false'?" ".github/workflows/$wf.yaml"
    [ "$status" -eq 0 ]                                   # install:false(동작보존)
  done
}
```
> 기존 `@test "setup-bun composite exists and pins bun + frozen install"`(L8)은 `bun install --frozen-lockfile` 라인이 `if` 아래로 가도 문자열 grep이라 통과 — 무파손 확인.

**Step 2: 실패 확인** — `bats tests/gates/test_setup-bun.bats` → FAIL(아직 인라인).

**Step 3: 컴포지트에 install 입력** — `.github/actions/setup-bun/action.yml`:
```yaml
name: setup-bun
description: bun 핀 + (옵션)frozen 설치 (버전 SSOT). bun-version을 한 곳에서 핀한다.
inputs:
  install:
    description: "bun install --frozen-lockfile 실행 여부 (deps 불요 잡은 false)"
    default: 'true'
runs:
  using: composite
  steps:
    - uses: oven-sh/setup-bun@0c5077e51419868618aeaa5fe8019c62421857d6  # v2.2.0
      with:
        bun-version: "1.3.10"
    - if: ${{ inputs.install == 'true' }}
      shell: bash
      run: bun install --frozen-lockfile
```
> 기존 컴포지트 사용처(ci/bump/audit/_create-*)는 `install` 미지정 → 기본 true → **무영향**(현행 `bun install` 유지).

**Step 4: 통과 확인(부분)** — `bats tests/gates/test_setup-bun.bats` → 1번째 PASS.

**Step 5: 디스패처/dns-drift 이주** — 각 파일의 인라인 2줄
```yaml
      - uses: oven-sh/setup-bun@0c5077e51419868618aeaa5fe8019c62421857d6  # v2.2.0
        with: { bun-version: "1.3.10" }
```
→
```yaml
      - uses: ./.github/actions/setup-bun
        with: { install: 'false' }     # validate-mutation/dns 체크는 deps 불요
```
대상: create-app:29-30, create-cache:26-27, create-database:26-27, update-secrets:26-27, dns-drift:19-20. (각 파일 실제 줄 확인 — `with` 한 줄/두 줄 형태 보존.)
> **로컬 컴포지트 참조는 checkout 필요** — 각 잡이 이미 `actions/checkout`을 먼저 함(확인). dns-drift:18·디스패처 validate:27 등 checkout 선행 OK.

**Step 6: 통과 확인** — `bats tests/gates/test_setup-bun.bats` → 전부 PASS.

**Step 7: 커밋**
```bash
git add .github/actions/setup-bun/action.yml .github/workflows/create-app.yaml \
        .github/workflows/create-cache.yaml .github/workflows/create-database.yaml \
        .github/workflows/update-secrets.yaml .github/workflows/dns-drift.yaml \
        tests/gates/test_setup-bun.bats
git commit -m "refactor: 디스패처/dns-drift의 setup-bun을 컴포지트로 수렴(install:false 동작보존)"
```

---

## Task 3: actionlint를 required gate에 (수정2)

워크플로 `run:` 셸인젝션·문법/표현식 오류를 정적 게이트. setup-toolchain에 핀+체크섬 추가 → gate 스텝.

**Files:**
- Modify: `.github/actions/setup-toolchain/action.yml` (actionlint 입력+스텝)
- Modify: `.github/workflows/ci.yaml` (gate에 actionlint 스텝 + setup-toolchain `actionlint: 'true'`)
- Modify: `tests/gates/test_toolchain-checksums.bats` (actionlint 체크섬 항목)
- Test: `tests/gates/test_actionlint-gate.bats` (신규)
- Create (조건부): `.github/actionlint.yaml` (queue:max schema-lag scoped ignore — Step 6/F3, 호환 버전이면 불요)
- **드러난 워크플로 이슈 수정**(actionlint가 처음 잡는 것 — 파일 미정, 실행 시)

**Step 1: 실패 테스트 작성**:
```bash
#!/usr/bin/env bats
# actionlint가 required gate(ci.yaml)에서 워크플로를 검사하는지 + 설치가 핀+체크섬인지. ⚠️ [ ]만.
setup() { ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"; cd "$ROOT" || exit 1; }

@test "setup-toolchain has a pinned, checksummed actionlint install step" {
  # YAML은 inputs: + 자식 actionlint: 키 구조 — 리터럴 'inputs.actionlint' 아님(F4). 실제 키를 grep.
  run grep -Eq '^[[:space:]]+actionlint:' .github/actions/setup-toolchain/action.yml
  [ "$status" -eq 0 ]
  run grep -Fq 'rhysd/actionlint' .github/actions/setup-toolchain/action.yml
  [ "$status" -eq 0 ]
  run grep -Fq 'sha256sum -c -' .github/actions/setup-toolchain/action.yml   # 체크섬 검증 패턴
  [ "$status" -eq 0 ]
}

@test "ci.yaml gate runs actionlint" {
  # gate 잡 안 스텝(별도 잡이면 비-required라 무성 회귀 — A.5/F8 가드와 동일 논리)
  run grep -Eq '^\s+run:\s+actionlint|actionlint\b' .github/workflows/ci.yaml
  [ "$status" -eq 0 ]
  run grep -Fq "actionlint: 'true'" .github/workflows/ci.yaml
  [ "$status" -eq 0 ]
}

@test "queue: max mutation-queue contract survives actionlint addition (F3)" {
  # actionlint가 concurrency.queue를 schema-lag로 거부해도 queue:max를 지우면 직렬화 계약 파괴 — 보존 단언.
  for wf in create-database bump-poll bump tf-reconcile create-app; do
    run grep -Fq 'queue: max' ".github/workflows/$wf.yaml"
    [ "$status" -eq 0 ]
  done
}
```

**Step 2: 실패 확인** — `bats tests/gates/test_actionlint-gate.bats` → FAIL.

**Step 3: setup-toolchain에 actionlint 추가** — 입력 + 스텝(기존 도구 패턴: curl+checksum+tar). **실 SHA256은 실행 시 공식 자산에서 산출**(placeholder 금지):
```yaml
# inputs:에 추가
  actionlint:  { description: actionlint v1.7.7,     default: 'false' }
# runs.steps:에 추가
    - if: ${{ inputs.actionlint == 'true' }}
      shell: bash
      run: |
        # actionlint 버전 핀 + 체크섬(rhysd/actionlint, arm64). run: 블록 shellcheck 통합 검사.
        f=/tmp/actionlint.tgz
        curl -fsSL https://github.com/rhysd/actionlint/releases/download/v1.7.7/actionlint_1.7.7_linux_arm64.tar.gz -o "$f"
        echo "<실 SHA256>  $f" | sha256sum -c -
        sudo tar -xz -C /usr/local/bin -f "$f" actionlint
```
> 버전/체크섬: 최신 안정(예 1.7.7) 확정 후 그 릴리스 `checksums.txt`의 `linux_arm64` SHA256을 핀. asset 파일명은 `actionlint_<ver>_linux_arm64.tar.gz`(v 없음), 바이너리명 `actionlint`.
> ★**버전 선택은 Step 6 호환 체크와 연동(F3)**: `concurrency.queue: max`(2026-05 GA)를 수용하는 actionlint 버전을 우선 핀. 수용 버전이 없으면 최신 핀 + Step 6의 `.github/actionlint.yaml` scoped ignore.

**Step 4: 체크섬 가드 갱신** — `tests/gates/test_toolchain-checksums.bats`가 각 도구의 실 SHA256(placeholder 금지)을 강제하면 actionlint 항목을 그 테스트의 대상 목록/패턴에 추가(테스트 구조 확인 후).

**Step 5: gate에 actionlint 스텝** — ci.yaml `gate` 잡, setup-toolchain 호출에 `actionlint: 'true'` 추가 + shellcheck 스텝(L72) 부근에 actionlint 스텝:
```yaml
      - name: actionlint — 워크플로 정적 검사(run: 셸인젝션·표현식·문법)
        # required gate 잡 안 스텝(별도 잡이면 비-required라 무성 회귀). setup-toolchain이 설치.
        run: actionlint
```
setup-toolchain `with:`에 `actionlint: 'true'` 추가.

**Step 6: actionlint 호환 체크 + 드러난 이슈 분류 (F3)** — `actionlint` 로컬 설치 후 실행:
```bash
actionlint   # 전 .github/workflows/*.yaml + run: 블록 shellcheck 통합
```
출력을 **2분류**:
- **(a) 진짜 이슈** — 셸인젝션(untrusted `${{ }}` in `run:`)·표현식 오류·미정의 ref·타입 불일치 → **수정**(대부분 이미 env-경유 패턴이라 적을 것이나 0 보장 X).
- **(b) known-valid GitHub 문법의 schema-lag** — 특히 **`concurrency.queue: max`(2026-05 GA)**를 actionlint가 모르면 `property "queue" is not defined`류로 거부. **`queue: max`를 절대 제거/약화 금지**(homelab 직렬화 계약). 대신:
  1. 우선 — 그 키를 아는 actionlint 버전이 있으면 Step 3 핀을 그 버전으로.
  2. 없으면 — `.github/actionlint.yaml`에 **그 에러만 좁게** ignore, 문서화:
     ```yaml
     # .github/actionlint.yaml — concurrency.queue: max 는 2026-05 GA 유효 문법.
     # actionlint schema-lag 오탐만 무시(queue:max 직렬화 계약은 유지, 절대 제거 금지).
     ignore:
       - 'property "queue" is not defined'   # 실행 시 actionlint 실제 출력 문구로 교체(좁게)
     ```
  ★ignore는 **그 한 메시지에만** — 다른 진짜 에러를 가리면 안 됨. ignore 적용 후 `actionlint`가 (b)만 빠지고 (a)는 여전히 잡는지 확인. `.github/actionlint.yaml`은 actionlint가 자동 로드(gate 스텝 변경 불요).
> ★**required gate를 red 상태로 도입하지 않는다** — Step 1의 actionlint 게이트 테스트 통과 + 로컬 `actionlint` 0 이슈(또는 scoped ignore 후 0)를 **PR 전** 확인. queue:max 보존 가드(Step 1)도 PASS.

**Step 7: 통과 확인** — `bats tests/gates/test_actionlint-gate.bats` PASS + `actionlint` 로컬 0 이슈.

**Step 8: 커밋**(드러난 수정은 분리 커밋 권장)
```bash
git add .github/actions/setup-toolchain/action.yml .github/workflows/ci.yaml \
        tests/gates/test_toolchain-checksums.bats tests/gates/test_actionlint-gate.bats
# (queue:max scoped ignore를 썼으면) git add .github/actionlint.yaml
git commit -m "feat: required gate에 actionlint 추가(워크플로 run 셸인젝션·문법 정적검사)"
# 드러난 진짜 워크플로 이슈가 있으면 분리 커밋:
# git commit -m "fix: actionlint가 드러낸 <이슈> 수정"
```

---

## Task 4: mutable 액션 comprehensive SHA-pin + 가드 (수정1)

전 third-party mutable `@vN`을 commit SHA로 핀. 가드 테스트로 회귀 차단.

**Files:**
- Modify: `.github/workflows/*.yaml`(checkout 등 mutable 액션 포함 전부), `.github/actions/*/action.yml`(있으면)
- Test: `tests/gates/test_action-pinning.bats` (신규)

**대상 액션(현재 mutable @vN) + 점유:**
- `actions/checkout@v4` (30회/19파일)
- `hashicorp/setup-terraform@v3` (iac×3, tf-reconcile×3)
- `docker/login-action@v3` (bump×2, bump-poll, build, _create-app, reusable-app-build)
- `docker/build-push-action@v6` (build, reusable-app-build)
- `docker/setup-buildx-action@v3` (build, reusable-app-build)
- `actions/cache@v4` (verify)
- `actions/download-artifact@v4` (bump)
- `actions/upload-artifact@v4` (build)
- (이미 SHA-pin·불변: create-github-app-token·oven-sh/setup-bun·actions/setup-node)

**Step 1: 실패 테스트(가드) 작성** — **positive 스캔**(F1: `@vN`뿐 아니라 `@main`/축약/깨진 ref도 차단) — 전 non-local `uses:` ref가 40-hex SHA로 핀:
```bash
#!/usr/bin/env bats
# 전 third-party/reusable 액션 ref가 commit SHA(@40hex)로 핀됐는지 — 공급망 표면 0.
# 로컬 './' ref(컴포지트·reusable 워크플로)는 면제. ⚠️ 중간 단언 [ ]만.
setup() { ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"; cd "$ROOT" || exit 1; }

@test "every non-local action ref is pinned to a 40-hex commit SHA" {
  # uses: 라인 전수 → 로컬 './' 제외 → 나머지(third-party)는 @[0-9a-f]{40} 필수.
  # @vN·@main·@축약SHA 전부 잔존 0. 핀 뒤 '# vN' 주석은 @ 직후가 아니라 무관.
  bad=$(grep -rhnE '^[[:space:]]*-?[[:space:]]*uses:[[:space:]]' .github/workflows/ .github/actions/ \
        | grep -vE 'uses:[[:space:]]+\./' \
        | grep -vE 'uses:[[:space:]]+[^@[:space:]]+@[0-9a-f]{40}([[:space:]]|#|$)' || true)
  [ -z "$bad" ]      # 비어야 통과. 디버깅: echo "$bad"로 위반 라인 확인
}
```

**Step 2: 실패 확인** — `bats tests/gates/test_action-pinning.bats` → 1번째 FAIL(mutable 다수).

**Step 3: 각 액션 SHA 해석** — 각 `owner/action@vN`의 vN 태그가 가리키는 commit SHA:
```bash
# 예: actions/checkout v4
gh api repos/actions/checkout/git/ref/tags/v4 --jq '.object.type,.object.sha'
# annotated tag면 .object.sha를 deref: gh api repos/actions/checkout/git/tags/<sha> --jq .object.sha
# 또는 릴리스: gh api repos/actions/checkout/releases/tags/v4.x.x --jq .target_commitish (정확한 commit 확인)
```
8개 액션 각각 1회 해석 → SHA 표 작성. **mutable 태그의 현재 SHA**를 핀(향후 manual 갱신, D2).

**Step 4: 전 워크플로 치환** (action→SHA 맵 기반) — 각 `owner/action@vN` → `owner/action@<sha>  # vN`. **구분자는 `|`**(치환부 `# vN`의 `#`가 `s#…#…#g`와 충돌해 sed 파싱 에러, F2). **주석 없는 라인만 sed, 주석 라인은 수동**:
```bash
# 주석 없는 다수 라인: @vN + 선택적 trailing space + EOL만 매치(주석 라인 회피). macOS sed -i ''.
# 액션별 반복(SHA는 Step3 맵):
git grep -lE 'uses: actions/checkout@v4([[:space:]]*$)' .github/ | while read -r f; do
  sed -i '' 's|actions/checkout@v4[[:space:]]*$|actions/checkout@<SHA>  # v4|' "$f"
done
# 8개 액션 반복: checkout/setup-terraform/docker-login/build-push/buildx/cache/download-artifact/upload-artifact.
```
> ⚠️ **기존 인라인 주석 라인은 수동 편집**(sed `$` 앵커가 안 잡음 — 의도) — `actions/checkout@v4 # push 이벤트…`(iac.yaml:131)·`# 로컬 telegram…`(dns-drift:18) 등은 `actions/checkout@<SHA>  # v4 — push 이벤트…`로 직접. 중복 `# v4 # …` 방지.
> ⚠️ Task 2에서 디스패처 인라인 oven-sh/setup-bun은 이미 컴포지트로 빠졌으니 대상 아님.
> ⚠️ 치환 후 **diff 전수 검토**(놓친 ref·잘못된 SHA·주석 중복).

**Step 5: 가드 통과 확인** — `bats tests/gates/test_action-pinning.bats` → PASS(전 non-local ref가 40-hex).

**Step 6: SHA 원격 resolution 검증 (F1 — 머지 전 1회)** — 핀된 각 SHA가 그 레포에 **실재**하는지(typo/날조 SHA 차단). actionlint는 원격 ref를 resolve 안 하고 gate는 편집된 모든 워크플로를 실행하지 않으므로 이 검증이 안전망:
```bash
# 전 third-party 핀 ref 추출 → 레포별 SHA가 gh api로 resolve되는지(404=깨진 핀).
grep -rhoE 'uses: [^.][^[:space:]]+@[0-9a-f]{40}' .github/ \
  | sed -E 's|uses:[[:space:]]+||' | sort -u | while read -r ref; do
    repo="${ref%@*}"; sha="${ref#*@}"
    gh api "repos/${repo}/commits/${sha}" --jq .sha >/dev/null 2>&1 || echo "UNRESOLVED: ${ref}"
  done
# 출력 0줄 = 전 핀이 원격에 실재. UNRESOLVED 있으면 그 SHA 재해석(Step3).
```
> `gh` 인증 필요(로컬 gh auth 또는 CI GITHUB_TOKEN). **머지 전 1회**(매 CI 반복 불필요·rate-limit) — 가드(40-hex)는 gate 상주, resolution은 PR 시점 검증. + `actionlint`(Task3) 로컬 실행으로 핀 후 문법 유효 확인.

**Step 7: 커밋**
```bash
git add .github/ tests/gates/test_action-pinning.bats
git commit -m "fix: 전 third-party 액션 SHA-pin(mutable @vN 공급망 표면 제거) + 가드

- checkout/setup-terraform/docker-*/cache/artifact를 commit SHA로 핀(# vN 주석)
- 토큰/시크릿/레지스트리 민팅 잡의 mutable 액션 탈취 표면 제거
- 가드 테스트로 @vN 회귀 차단"
```

---

## Task 5: 전체 게이트 검증

**Files:** 없음(검증만)

**Step 1: 신규/영향 테스트** — 신규 + **수정된 기존**(stale 차단):
```bash
bats tests/gates/test_gitleaks-version-extract.bats tests/gates/test_gate-secret-guard.bats \
     tests/gates/test_setup-bun.bats tests/gates/test_actionlint-gate.bats \
     tests/gates/test_action-pinning.bats tests/gates/test_toolchain-checksums.bats \
     tests/gates/test_setup-toolchain-composite.bats tests/gates/test_ci-toolchain-pin.bats \
     tests/gates/test_ci-gate.bats
```
→ 0 failures. (Step 2 `make ci`가 전 suite 재확인.)

**Step 2: 전체 게이트 미러** — `make ci`(gate 8스텝 미러). actionlint/yq/gitleaks는 러너 도구라 로컬은 setup-toolchain 경로 또는 설치본 필요 — 최소 `actionlint`·gitleaks yq 추출은 로컬 실행 증명.

**Step 3: actionlint 최종** — `actionlint` 0 이슈(전 워크플로 + 핀 반영).

**Step 4: 가드 최종** — positive 핀 가드(`test_action-pinning.bats`, 전 non-local `uses:`가 40-hex) PASS + Task 4 Step 6 SHA resolution 0 UNRESOLVED. `grep -A2 'gitleaks/gitleaks' .github/workflows/ci.yaml` → 0(yq로 교체됨).

**Step 5: PR 준비** — `git log --oneline origin/main..HEAD` 요약. ★**머지 전 gate green 필수**(required check) — PR 올려 gate 1회 관찰(잘못된 SHA·actionlint red 즉시 포착). PR/머지는 owner.

---

## 실행 순서 메모

- **순서: Task 1(yq) → 2(setup-bun 컴포지트) → 3(actionlint) → 4(SHA-pin) → 5(게이트)**. actionlint(3)를 핀(4) 앞에 둬 핀 후 gate가 actionlint로 워크플로 검증. ci.yaml은 Task 1·3에서, 디스패처는 Task 2·4에서 수정 — 각 Task가 해당 부분만.
- **gate=required** — 깨지면 전 머지 차단. 각 Task 후 영향 bats + 최종 `make ci`/actionlint 로컬. 라이브(ArgoCD) 영향 0.
- SHA-pin(Task4)은 가장 기계적이나 diff 큼 — 치환 후 **전수 diff 검토**(기존 인라인 주석 중복 주의).

---

## Adversarial review dispositions

hardened-planning 4-pass codex 적대 리뷰 + 선제 감사. **11발견(codex 6 + 선제 2 ... 표기) 전부 Accept·반영**. 각 게이트 AskUserQuestion 승인. 설계변경(brainstorming 재실행) 없음 → 카운트 리셋 없음. Pass 3에서 nominal cap(3) 도달, 사용자 승인으로 Pass 4 1회 추가, Pass 4 후 **확정**(Pass 5 미실행).

| Pass | # | 발견 | Sev | Disposition |
|---|---|---|---|---|
| 1 | F1 | SHA-pin 가드가 `@vN` 블록리스트+checkout 스폿체크 → `@main`/축약/깨진 ref 통과 | high | **Accepted** — positive 가드(전 non-local `uses:`가 `@40hex`) + gh api SHA resolution 검증 (Task 4) |
| 1 | F2 | bulk sed `s#…# v4#g` 구분자 `#` 충돌 → 파싱 에러 | medium | **Accepted** — 구분자 `\|` + 주석 라인 수동 맵 (Task 4) |
| 2 | F3 | actionlint(핀)가 `concurrency.queue: max`(2026-05 GA) 거부 → gate 영구 red 또는 직렬화 계약 파괴 | high | **Accepted** — 호환 버전/`.github/actionlint.yaml` scoped ignore + `queue: max` 보존 가드 + Step6 한정 (Task 3) |
| 3 | F4 | actionlint setup 테스트 `grep 'inputs.actionlint'` — YAML은 `inputs:`+자식 키라 통과 불가 | high | **Accepted** — 실제 키 `^␣actionlint:` grep (Task 3) |
| 3 | F5 | gitleaks 테스트 버전(8.18.4) 하드코딩 = 제2 SSOT, bump 시 gate red | medium | **Accepted** — 임의 버전 temp 픽스처(라인오프셋 독립 증명), 실제 버전 단언 제거 (Task 1) |
| 4 | F6 | Task 1 yq 변경이 기존 `test_gate-secret-guard.bats:13`(grep 단언)을 red로 | high | **Accepted** — 그 단언 yq로 갱신 + Task 1 검증 포함 |
| 4 | P1 | (선제 감사) Task 2가 5 디스패처 채택 추가 → 기존 `test_setup-bun.bats`("all 7") stale | — | **Accepted(선제)** — test_setup-bun.bats 7→12 확장 (Task 2) |
| 4 | P2 | (선제 감사) Task 3 actionlint가 `test_toolchain-checksums.bats` 목록에 부재 | — | **Accepted(선제)** — actionlint 체크섬 항목 추가 (Task 3) |

**최종 패스(4) verdict:** `needs-attention`(F6) — 반영 + **동일 "기존 테스트 stale" 클래스를 전 Task 선제 감사로 종결**(Task 1/2/3 수정, Task 4 충돌 0). 사용자 합의로 Pass 4에서 확정 — F6/선제분은 재리뷰 없이 반영, **executing-plans의 `make ci`(run-bats 전 suite)·actionlint·gate가 구현 시 잔여를 포착**. ★핵심 교훈: **gate=required라 기존 게이트 테스트를 stale하게 두면 변경 자체가 머지를 막는다**(F6) — CI 변경 시 그 영역을 단언하는 기존 테스트를 함께 갱신.

## Execution directives
- **Skill:** implement via `executing-plans` in a **separate session, in this worktree** (`.claude/worktrees/feat+cicd-supply-chain`).
- **Run continuously:** 라우틴 리뷰로 멈추지 말 것. 진짜 블로커(의존성 부재·반복 실패 검증·모순 지시·치명 갭)에서만 정지. 그 외 전 Task 완주. **Task 순서: 1 → 2 → 3 → 4 → 5.**
- **★gate=유일 required check** — actionlint/yq/gitleaks/SHA-pin 변경은 **PR 전 로컬 검증**(actionlint 0 이슈·SHA resolution 0 UNRESOLVED·`make ci`)으로 green 증명. red 상태로 도입 금지.
- **Commits — 직접 적용; `Skill(commit)` 미사용**(연속 실행 유지):
  - **한국어** 메시지, **AI 마커 금지**.
  - **Format:** `<type>(<scope>): 한국어 설명`.
  - **Type만:** `feat`/`fix`/`refactor`/`docs`/`style`/`test`/`chore`. (공급망 핀·gitleaks=`fix:`[보안], 컴포지트 수렴=`refactor:`, actionlint 신규 게이트=`feat:`.)
  - **Grouping:** Task별 자체 커밋(actionlint 드러낸 수정은 분리). 같은 목적·디렉토리 함께.
  - **Where:** 현재 feature 워크트리(`worktree-feat+cicd-supply-chain`) 직접 커밋.
- **Push/PR:** owner 판단. `.github/`는 ArgoCD 미싱크(라이브 영향 0)지만 워크플로 파일 변경 push는 `workflows:write`라 owner 로컬. ★머지 전 gate 1회 관찰(잘못된 SHA·actionlint red 즉시 포착).
