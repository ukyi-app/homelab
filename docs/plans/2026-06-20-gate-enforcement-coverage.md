# gate enforcement 커버리지 Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** "테스트 죽었는데 녹색" 갭 3개를 닫는다 — CJK @test 이름 가드 추가, check-skeleton을 required gate로 승격, homepage kustomize render 테스트.

**Architecture:** `scripts/`·`.github/`·`tests/`·homepage 테스트만 변경(ArgoCD 미싱크, 라이브위험0). required `gate`(ci.yaml job `gate`)에 check-skeleton 승격 + homepage render bats(run-bats 수집). 단일 PR. 현재 전부 통과 상태라 즉시green(가드가 미래 회귀를 차단).

**Tech Stack:** bash(check-skeleton, bash 3.2 호환)·perl(-CSDA, CJK 검출, 러너/macOS 기본)·bats(tests/gates·platform/homepage/prod)·mikefarah kustomize(gate setup-toolchain). 러너=ubuntu-24.04-arm.

**설계 출처:** `docs/plans/2026-06-20-gate-enforcement-coverage-design.md`(커밋 `3c14429`). grounding: 발견2(accounting)=이미 gate강제·발견4(글롭)=accounting-red로 무력 → **제외**. 작업=발견1(CJK가드)+발견3(homepage render)+인접(check-skeleton gate승격). D1=check-skeleton에 CJK추가+gate승격.

---

## 작업 전 공통 규칙 (모든 Task)

- **bats `@test` 이름은 영어만**(본 작업이 바로 이 가드!)·중간 단언 `[ ]`(bash 3.2 `[[ ]]` 침묵통과)·`test_` 접두.
- **bash 3.2 호환**(check-skeleton): mapfile·`[[ ]]`·`cmd && n++`(set -e 함정) 금지 — if-블록·case·카운터.
- **하네스 셸=zsh** — `perl`/grep의 unquoted `$var` non-split 주의(인용/`bash -c`).
- **CJK 가드 perl은 single-quote**(bash 더블쿼트 escaping이 `\@`를 깸 — 검증됨).
- **커밋**: 한국어 conventional, AI 마커 금지. type=feat/fix/refactor/docs/style/test/chore. (가드 추가=`feat:`/`test:`, gate 승격=`feat:`/`chore:`.)

---

## Task 1: CJK @test 이름 가드 (`check-skeleton.sh`)

전 tracked `*test_*.bats`의 실제 `@test` 선언 이름에 CJK 문자가 있으면 fail(침묵스킵 차단).

**Files:**
- Modify: `scripts/check-skeleton.sh` (CJK 스캔 추가)
- Test: `tests/gates/test_check-skeleton-cjk.bats` (신규)

**Step 1: 실패 테스트 작성** — 검출 로직(픽스처, **이름만 캡처**) + check-skeleton 채택:
```bash
#!/usr/bin/env bats
# CJK @test 이름 가드 — 한글/CJK는 bats 디렉토리 실행 시 침묵스킵(검증된 함정).
# em-dash·trailing 한국어 주석은 bats OK라 제외 — @test "이름"의 **이름만** 검사. ⚠️ 중간 단언 [ ]만.
setup() { ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"; cd "$ROOT" || exit 1; }

# CJK = Unicode 스크립트 속성(무브래킷 fragment — [$CJK]로 1회 감쌈). Han/Hangul/Hiragana/Katakana는
# Ext-A(㐀 U+3400)·compat 이데오그래프·Hangul 확장까지 모두 포함(하드코딩 범위 누락 방지, F7).
CJK='\p{Han}\p{Hangul}\p{Hiragana}\p{Katakana}'
CJK_FIX="tests/gates/test_zzz_cjk_neg_fixture.bats"   # black-box 음성 픽스처(teardown이 정리)
teardown() { git reset -q -- "$CJK_FIX" 2>/dev/null || true; rm -f "$CJK_FIX"; }

@test "CJK detector flags Hangul AND CJK-extension @test NAMES only (script properties; ignores em-dash/ascii/comment)" {
  TMP="$(mktemp -d)"
  printf '  @test "%s" {\n  @test "%s extA" {\n  @test "ascii name" { # %s\n  @test "drill %s PVC" {\n  # @test "%s" mention\n' \
    "한글 이름" "㐀" "한글 주석" "—" "한글" > "$TMP/test_fx.bats"
  # 이름만 캡처 후 $1 검사(F2) — trailing 주석·em-dash·주석언급 제외. 한글(1)+Ext-A 㐀(2)만 HIT.
  run perl -CSDA -ne 'print "$ARGV:$.\n" if /^\s*\@test\s+"([^"]*)"/ && $1 =~ /['"$CJK"']/' "$TMP/test_fx.bats"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | grep -c .)" -eq 2 ]   # 정확히 2줄(한글·㐀 이름 선언)
  echo "$output" | grep -q ':1$'                      # 한글(라인1)
  echo "$output" | grep -q ':2$'                      # Ext-A 㐀(라인2) — 하드코딩 범위면 놓침
}

@test "check-skeleton FAILS (exit!=0) on a tracked CJK @test name — black-box negative (F5)" {
  # 토큰 grep이 아니라 실제 실행: CJK @test 픽스처를 git ls-files에 보이게(add -N) 한 뒤 check-skeleton 실행.
  printf '@test "%s" {\n  true\n}\n' "한글이름테스트" > "$CJK_FIX"
  git add -N "$CJK_FIX"
  run bash scripts/check-skeleton.sh
  [ "$status" -ne 0 ]                                     # CJK @test 때문에 비-0 종료(rc=1 배선 증명)
  echo "$output" | grep -q 'CJK'                          # CJK 메시지로 실패(다른 이유 아님)
}

@test "current repo has zero CJK @test names (immediate-green)" {
  bad=""
  while IFS= read -r f; do
    h="$(perl -CSDA -ne 'print "x" if /^\s*\@test\s+"([^"]*)"/ && $1 =~ /['"$CJK"']/' "$f")"
    if [ -n "$h" ]; then bad="$bad $f"; fi
  done < <(git ls-files '*test_*.bats')
  [ -z "$bad" ]
}
```
> ⚠️ `$CJK`(무브래킷 fragment)를 `'"$CJK"'`로 single-quote perl의 `[...]`에 1회 주입(F1). 이름만 캡처(`"([^"]*)"`)해 trailing 한국어 주석 false-positive 차단(F2). perl은 러너/macOS 기본.

**Step 2: 실패 확인** — `bats tests/gates/test_check-skeleton-cjk.bats` → black-box 음성 테스트 FAIL(check-skeleton에 아직 CJK 가드가 없어 CJK 픽스처에도 exit 0). detector/immediate-green은 PASS 가능.

**Step 3: check-skeleton.sh에 CJK 스캔 추가** — 기존 `test_` 접두 검사 블록 아래에:
```bash
# CJK @test 이름 가드: bats는 디렉토리 단위 실행 시 한글/CJK @test 이름을 조용히 스킵한다(검증된 함정).
# @test 선언의 **이름만**(닫는 따옴표까지 `"([^"]*)"`) 검사 — trailing 한국어 주석·em-dash는 bats OK라 제외(F2).
cjk_hits=""
while IFS= read -r f; do
  h="$(perl -CSDA -ne 'print "$ARGV:$.: $_" if /^\s*\@test\s+"([^"]*)"/ && $1 =~ /[\p{Han}\p{Hangul}\p{Hiragana}\p{Katakana}]/' "$f")"
  if [ -n "$h" ]; then cjk_hits="$cjk_hits$h"$'\n'; fi
done < <(git ls-files '*test_*.bats')
if [ -n "$cjk_hits" ]; then
  echo "FAIL: @test 이름에 CJK 문자(디렉토리 실행 시 침묵스킵) — 영어로 변경:"
  printf '%s' "$cjk_hits"
  rc=1
fi
```
> bash 3.2: `while ... done < <(...)`(process substitution)은 bash 3.2 OK. `$'\n'`도 OK. set -e 하에서 perl no-match는 빈 출력(exit0)이라 안전.

**Step 4: 통과 확인** — `bats tests/gates/test_check-skeleton-cjk.bats` → 전부 PASS. + `bash scripts/check-skeleton.sh` → exit 0(현재 0 위반).

**Step 5: 커밋**
```bash
git add scripts/check-skeleton.sh tests/gates/test_check-skeleton-cjk.bats
git commit -m "feat: check-skeleton에 CJK @test 이름 가드 추가(침묵스킵 차단)

- bats 디렉토리 실행 시 한글/CJK @test 이름이 조용히 스킵되는 함정을 자동 차단
- 실제 @test 선언만·CJK 범위만(em-dash 등은 bats OK라 제외)"
```

---

## Task 2: `check-skeleton.sh`를 required gate로 승격

check-skeleton(네이밍+dirmap+CJK 가드)이 verify.yaml(non-required)에만 → required gate로. 위반해도 머지되던 갭 차단.

**Files:**
- Modify: `.github/workflows/ci.yaml` (gate에 check-skeleton 스텝)
- Modify: `.github/workflows/verify.yaml` (중복 제거 — check-skeleton를 gate로 이전)
- Modify: `Makefile` (`ci:` 타겟에 check-skeleton 미러)
- Test: `tests/gates/test_check-skeleton-gate.bats` (신규)

**Step 1: 실패 테스트 작성**:
```bash
#!/usr/bin/env bats
# check-skeleton이 required gate(ci.yaml job 'gate')에서 실행되는지 + verify.yaml 중복 제거.
# yq 구조 파싱(주석/비활성 스텝 false-positive 차단, F10). ⚠️ [ ]만.
setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"; cd "$ROOT" || exit 1
  if ! command -v yq >/dev/null; then
    [ -z "${CI:-}" ] || { echo "FAIL: CI인데 yq 부재 — gate 구조 검증 불가(dead-green 방지)"; return 1; }
    skip "yq 미설치(로컬만 — CI는 setup-toolchain 제공)"
  fi
}

@test "required gate has an ACTIVE run step invoking check-skeleton.sh (structural, F10)" {
  # 주석/비활성 텍스트가 아니라 jobs.gate.steps[]의 실제 run 필드
  run yq -e '.jobs.gate.steps[] | select((.run // "") | test("scripts/check-skeleton.sh")) | .run' .github/workflows/ci.yaml
  [ "$status" -eq 0 ]
}

@test "verify.yaml no longer runs check-skeleton (single authority, structural)" {
  run yq -e '.jobs.verify.steps[] | select((.run // "") | test("check-skeleton"))' .github/workflows/verify.yaml
  [ "$status" -ne 0 ]
}

@test "make ci mirrors check-skeleton" {
  run awk '/^ci:/{c=1} c && /check-skeleton/{print}' Makefile
  [ -n "$output" ]
}

@test "ci gate setup-toolchain enables kustomize + yq (render guard cannot silently skip in CI, F6/F10)" {
  # jobs.gate.steps[]의 setup-toolchain 스텝 with.kustomize/with.yq가 'true'(주석 아닌 실제 필드)
  run yq -e '.jobs.gate.steps[] | select((.uses // "") | test("setup-toolchain")) | (.with.kustomize == "true" and .with.yq == "true")' .github/workflows/ci.yaml
  [ "$status" -eq 0 ]; [ "$output" = "true" ]
}
```

**Step 2: 실패 확인** — `bats tests/gates/test_check-skeleton-gate.bats` → FAIL(gate 미배선).

**Step 3: ci.yaml gate에 스텝 추가** — `gate` 잡, run-bats 부근(skeleton은 빠른 정적 가드라 앞쪽 권장):
```yaml
      - name: skeleton + 네이밍/CJK/dirmap 가드 (required — 기존 verify.yaml non-required서 승격)
        run: bash scripts/check-skeleton.sh
```

**Step 4: verify.yaml 중복 제거** — `verify` 잡의 check-skeleton 스텝 제거(gate가 권위). verify.yaml은 sops 왕복·pre-commit 고유 책임만 유지(주석도 갱신).

**Step 5: Makefile `ci:` 미러** — `ci:` 레시피에 `@./scripts/check-skeleton.sh` 추가(gate 8스텝 로컬 패리티). `make verify`의 check-skeleton는 유지(로컬 빠른 점검 — 중복이지만 verify는 로컬 전용 편의).
> 주의: `make verify`와 `make ci` 둘 다 check-skeleton 호출은 OK(로컬). 제거 대상은 **verify.yaml(CI non-required)**의 중복뿐.

**Step 6: 통과 확인** — `bats tests/gates/test_check-skeleton-gate.bats` PASS + `make ci`(또는 `bash scripts/check-skeleton.sh`) 통과.

**Step 7: 커밋**
```bash
git add .github/workflows/ci.yaml .github/workflows/verify.yaml Makefile tests/gates/test_check-skeleton-gate.bats
git commit -m "feat: check-skeleton을 required gate로 승격(네이밍/CJK/dirmap 강제)

- verify.yaml(non-required)에만 있던 가드를 gate로 — 위반 시 머지 차단
- verify.yaml 중복 제거(단일 권위), make ci 미러"
```

---

## Task 3: homepage kustomize render 테스트

7 grep-only가 못 잡는 조립 출력 + 인시던트 #65/#66 회귀를 `kustomize build`로 검증.

**Files:**
- Test: `platform/homepage/prod/test_homepage_render.bats` (신규 — run-bats 수집 → gate 강제)

**Step 1: 실패 테스트 작성** — homepage는 plain kustomize(helm/ksops 불요). **yq 객체-스코프 단언**(F3: 불변식을 같은 객체에 결속, 전체 grep 아님):
```bash
#!/usr/bin/env bats
# homepage kustomize render 가드 — grep-on-source가 못 잡는 조립 출력 + 인시던트 #65/#66 회귀.
# yq로 객체-스코프 단언(같은 Deployment 마운트·같은 egress 규칙 결속). @test 이름 영어. ⚠️ 중간 단언 [ ]만.
setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  # CI(required gate)에선 skip 금지 — 툴 부재면 fail-closed(이 가드가 dead-green 되면 theme 클래스 재현, F6).
  # GitHub Actions는 CI=true. 로컬(CI 미설정)만 skip 허용.
  if ! command -v kustomize >/dev/null || ! command -v yq >/dev/null; then
    [ -z "${CI:-}" ] || { echo "FAIL: CI인데 kustomize/yq 부재 — gate setup-toolchain 회귀(dead-green 방지)"; return 1; }
    skip "kustomize/yq 미설치(로컬만 — CI는 setup-toolchain 제공)"
  fi
  RENDERED="$BATS_TEST_TMPDIR/homepage-render.yaml"
  ( cd "$ROOT" && kustomize build platform/homepage/prod ) > "$RENDERED" 2>/dev/null
}

@test "homepage kustomize build succeeds and emits the core kinds + namespace" {
  [ -s "$RENDERED" ]
  for kind in Deployment Service HTTPRoute NetworkPolicy ConfigMap; do
    run yq -e "select(.kind == \"$kind\") | .kind" "$RENDERED"
    [ "$status" -eq 0 ]
  done
  run yq -e 'select(.metadata.namespace == "homepage") | .metadata.name' "$RENDERED"
  [ "$status" -eq 0 ]
}

@test "configMapGenerator names are bound to the Deployment volume references (assembled nameReference rewrite, F4)" {
  D='select(.kind == "Deployment" and .metadata.name == "homepage")'
  # 생성된 해시접미 ConfigMap 이름 캡처(config=homepage-<hash>, assets=homepage-assets-<hash>)
  cm_config="$(yq 'select(.kind == "ConfigMap" and (.metadata.name | test("^homepage-[a-z0-9]+$"))) | .metadata.name' "$RENDERED")"
  cm_assets="$(yq 'select(.kind == "ConfigMap" and (.metadata.name | test("^homepage-assets-[a-z0-9]+$"))) | .metadata.name' "$RENDERED")"
  [ -n "$cm_config" ]; [ -n "$cm_assets" ]
  # config-src/assets 볼륨이 그 **정확한 생성 이름**을 참조(literal homepage 참조면 런타임 실패 — grep-on-source 못 잡음)
  run yq -e "$D | .spec.template.spec.volumes[] | select(.name == \"config-src\").configMap.name == \"$cm_config\"" "$RENDERED"
  [ "$status" -eq 0 ]; [ "$output" = "true" ]
  run yq -e "$D | .spec.template.spec.volumes[] | select(.name == \"assets\").configMap.name == \"$cm_assets\"" "$RENDERED"
  [ "$status" -eq 0 ]; [ "$output" = "true" ]
}

@test "EROFS regression guard (#65): config emptyDir + seed binds + WRITABLE (readOnly!=true) mounts" {
  D='select(.kind == "Deployment" and .metadata.name == "homepage")'
  run yq -e "$D | .spec.template.spec.volumes[] | select(.name == \"config\") | has(\"emptyDir\")" "$RENDERED"
  [ "$status" -eq 0 ]; [ "$output" = "true" ]           # config 볼륨이 emptyDir(RO configMap 직접 마운트 아님)
  # seed-config: config-src(RO)→/tmp/cfg, config(emptyDir)→/app/config
  run yq -e "$D | .spec.template.spec.initContainers[] | select(.name == \"seed-config\").volumeMounts[] | select(.name == \"config-src\" and .mountPath == \"/tmp/cfg\") | .name" "$RENDERED"
  [ "$status" -eq 0 ]
  # init의 config 마운트가 **writable**(readOnly!=true) — RO면 #65 EROFS 재현(F9)
  run yq -e "$D | .spec.template.spec.initContainers[] | select(.name == \"seed-config\").volumeMounts[] | select(.name == \"config\" and .mountPath == \"/app/config\" and (.readOnly != true)) | .name" "$RENDERED"
  [ "$status" -eq 0 ]
  # 메인 컨테이너 config 마운트도 **writable**(readOnly!=true)
  run yq -e "$D | .spec.template.spec.containers[] | select(.name == \"homepage\").volumeMounts[] | select(.name == \"config\" and .mountPath == \"/app/config\" and (.readOnly != true)) | .name" "$RENDERED"
  [ "$status" -eq 0 ]
}

@test "apiserver egress regression guard (#66): one egress rule binds node CIDR + TCP/6443, no ClusterIP" {
  N='select(.kind == "NetworkPolicy" and .metadata.name == "allow-egress-to-apiserver")'
  # 한 egress 규칙이 노드 CIDR + (protocol=TCP, port=6443) 포트 엔트리를 동시에(체인 select = 같은 규칙·같은 엔트리 결속, F9)
  run yq -e "$N | .spec.egress[] | select(.to[].ipBlock.cidr == \"192.168.139.0/24\") | select(.ports[] | (.port == 6443 and .protocol == \"TCP\")) | .ports" "$RENDERED"
  [ "$status" -eq 0 ]
  # apiserver egress에 ClusterIP 10.43.0.1/32 미사용(있으면 select 매치=exit0 → 회귀)
  run yq -e "$N | .spec.egress[].to[].ipBlock.cidr | select(. == \"10.43.0.1/32\")" "$RENDERED"
  [ "$status" -ne 0 ]
}
```
> ⚠️ `yq -e`: 결과가 null/false/빈출력이면 exit≠0, 값이면 exit0(mikefarah). 객체-스코프로 같은 Deployment 마운트·같은 egress 규칙에 불변식 결속(F3 — 전체 YAML 흩뿌린 grep 아님).
> ⚠️ 정확한 yq 경로(필드명·배열구조)는 실제 `kustomize build platform/homepage/prod` 출력으로 Step 3에서 확정.

**Step 2: 실패 확인(역설)** — render 테스트는 현재 homepage가 **통과해야** 정상(라이브 안정). 따라서 이 Task는 "실패→구현"이 아니라 **"가드가 현재 불변식을 정확히 포착하는지"**가 핵심. 작성 후 즉시 실행:
```bash
bats platform/homepage/prod/test_homepage_render.bats
```
기대: PASS(현재 homepage 조립 정상). 만약 FAIL이면 (a) grep 표현이 실제 출력과 불일치 → 수정, 또는 (b) 진짜 homepage 조립 이슈 발견 → 그 자체가 가치(별도 fix 커밋).

**Step 3: yq 경로 확정** — `kustomize build platform/homepage/prod`를 실제 실행해 출력의 객체 구조(필드명·배열 구조·ipBlock/ports 표기)에 yq 경로를 맞춘다(`… | yq 'select(.kind=="Deployment").spec.template.spec.volumes'`로 실제 경로 확인 후 Step 1 단언 조정). mikefarah yq의 체인 `select` 결속이 실제 출력에서 의도대로(같은 egress 규칙) 동작하는지 확인.

**Step 4: accounting 확인** — 신규 test는 run-bats 수집 도메인(platform/homepage/prod, charts/ 아님·.ci-exclude 아님) → `bash scripts/check-bats-accounting.sh` 통과(n=1 gate).

**Step 5: 커밋**
```bash
git add platform/homepage/prod/test_homepage_render.bats
git commit -m "test: homepage kustomize render 가드 추가(조립 출력 + 인시던트 #65/#66 회귀)

- grep-on-source가 못 잡는 kustomize build 산물(생성기 해시·네임스페이스·리소스 포함) 검증
- #65 EROFS(initContainer seed+emptyDir)·#66 apiserver egress(노드서브넷:6443) 회귀가드"
```

---

## Task 4: docs/traps.md 원장에 신규 가드 등록 (F8)

`make verify-traps`가 가드 파일 삭제/리네임 드리프트를 차단하려면 신규 가드를 원장에 등록해야 한다(원장: "새 가드 테스트 추가 시 표에 한 줄").

**Files:**
- Modify: `docs/traps.md` (행 추가/확장)
- Test: `tests/gates/test_traps-ledger.bats`가 이미 원장↔파일 일치를 검사하면 그 통과 확인(없으면 verify-traps만).

**Step 1: 원장 행 추가** — `docs/traps.md` 표(`| 함정 | where | guard |`)에. **전 표를 먼저 읽어** 기존 행 중복을 피한다:
- 한글/CJK @test 침묵스킵(AGENTS.md "bats @test 이름은 영어 — 한글 인코딩 깨짐") → 신규 행:
  `| bats @test 이름 한글/CJK 디렉토리실행 침묵스킵 | gate | \`tests/gates/test_check-skeleton-cjk.bats\`, \`tests/gates/test_check-skeleton-gate.bats\` |`
- homepage 인시던트(#65 EROFS RO config·#66 apiserver egress ClusterIP) → **기존 apiserver-egress/EROFS 트랩 행이 있으면 그 guard에 `platform/homepage/prod/test_homepage_render.bats` 추가**(중복 행 금지), 없으면 신규:
  `| homepage EROFS(RO config)·apiserver egress(노드서브넷:6443 not ClusterIP) | gate | \`platform/homepage/prod/test_homepage_render.bats\`, \`platform/homepage/prod/test_homepage_netpol.bats\` |`

**Step 2: verify-traps 통과** — `make verify-traps`(scripts/verify-traps.sh가 guard 백틱 경로 실재 확인) → PASS(신규 가드 파일이 실재). traps 원장↔파일 일치 bats(있으면)도 PASS.

**Step 3: 커밋**
```bash
git add docs/traps.md
git commit -m "docs: 신규 가드(CJK @test·homepage render)를 traps 원장에 등록(verify-traps 드리프트 보호)"
```

---

## Task 5: 전체 게이트 검증

**Files:** 없음(검증만)

**Step 1: 신규/영향 테스트** — `bats tests/gates/test_check-skeleton-cjk.bats tests/gates/test_check-skeleton-gate.bats platform/homepage/prod/test_homepage_render.bats` → 0 failures.

**Step 2: 전체 게이트 미러** — `make ci`(gate 미러: check-skeleton 신규 스텝 포함·run-bats 전 suite·accounting). check-skeleton·kustomize는 로컬 실행 가능.

**Step 3: accounting/skeleton/traps 최종** — `bash scripts/check-bats-accounting.sh`(신규 bats 전부 정확히 한 도메인) + `bash scripts/check-skeleton.sh`(0 위반, CJK 포함) + `make verify-traps`(원장 guard 경로 실재, F8).

**Step 4: 즉시green 확인** — 3 가드 모두 현재 레포에서 PASS(미래 회귀 차단용). render가 homepage 이슈를 드러냈으면 별도 fix.

**Step 5: PR 준비** — `git log --oneline origin/main..HEAD` 요약. gate 변경(check-skeleton 승격)이라 **머지 전 gate 1회 관찰**. PR/머지 owner.

---

## 실행 순서 메모

- **순서: Task 1(CJK가드) → 2(gate승격) → 3(homepage render) → 4(traps 원장) → 5(검증)**. Task 1이 check-skeleton에 가드 추가 → Task 2가 그 check-skeleton을 gate로 승격(순서 의존). Task 4(traps)는 1~3의 가드 파일 실재 후. Task 3은 독립.
- **즉시green 특성** — 3 가드 모두 현재 통과해야 정상(미래 회귀 차단이 목적). render/skeleton이 현재 이슈를 드러내면 그 fix가 보너스 가치.
- 라이브(ArgoCD) 영향 0. gate=required라 승격 후 첫 gate 관찰 필수.

---

## Adversarial review dispositions

hardened-planning 4-pass codex 적대 리뷰. **Phase A grounding이 딥리뷰 4발견 중 2개를 제외**(발견2=accounting 이미 gate강제·발견4=글롭 accounting-red로 무력). **10발견(F1~F10) 전부 Accept·반영**. 각 게이트 AskUserQuestion 승인. 설계변경 없어 카운트 리셋 없음 — Pass 3에서 nominal cap(3) 도달, 사용자 승인으로 Pass 4 1회 추가, Pass 4 후 **확정**(Pass 5 미실행).

| Pass | # | 발견 | Sev | Disposition |
|---|---|---|---|---|
| 1 | F1 | CJK 테스트 변수가 `[...]`+`[$CJK]` 이중 브래킷 → 미매치 | medium | **Accepted** — CJK 무브래킷 fragment + 1줄 단언 |
| 1 | F2 | regex가 닫는 따옴표 너머 trailing 한국어 주석까지 스캔 → 유효 PR 차단 | high | **Accepted** — 이름만 캡처 `"([^"]*)"` 후 $1 검사(test+check-skeleton) |
| 1 | F3 | homepage render가 독립 문자열 grep — 같은 객체 결속 미증명 | medium | **Accepted** — yq 객체-스코프 단언 |
| 2 | F4 | render가 생성 ConfigMap의 Deployment 볼륨 참조 미검증 | high | **Accepted** — 생성 CM명 캡처→config-src/assets 볼륨 참조 결속 |
| 2 | F5 | CJK 채택 테스트가 토큰 grep(rc=1 누락도 통과) | medium | **Accepted** — black-box 음성(CJK 픽스처 git add -N→check-skeleton exit≠0) |
| 3 | F6 | render 테스트가 툴 부재 시 skip → CI dead-green(theme 클래스 재현) | high | **Accepted** — CI fail-closed(skip 금지) + gate가 yq/kustomize 설치 단언 |
| 3 | F7 | 하드코딩 CJK 범위가 Ext-A(㐀)·compat 누락 | medium | **Accepted** — perl 스크립트 속성 `\p{Han}\p{Hangul}\p{Hiragana}\p{Katakana}` + Ext-A 픽스처 |
| 3 | F8 | 신규 가드 docs/traps.md 미등록 → verify-traps 보호 밖 | medium | **Accepted** — traps 원장 행 추가(Task 4) + make verify-traps |
| 4 | F9 | render가 config 마운트 readOnly·egress protocol 미검사 | high | **Accepted** — `.readOnly != true` + egress `port==6443 and protocol=="TCP"` |
| 4 | F10 | gate 증명이 raw text grep(주석/비활성도 통과) | medium | **Accepted** — yq 구조 파싱(jobs.gate.steps[] active run/with) + CI-aware skip |

**최종 패스(4) verdict:** `needs-attention`(F9/F10) — 반영. 사용자 합의로 Pass 4에서 확정. ★핵심 교훈: **gate enforcement 테마는 프랙탈** — 가드 자신이 dead-green일 수 있다(F6 render skip·F10 raw grep·F5 토큰 grep). 가드는 ① fail-closed(CI서 skip 금지) ② 구조 파싱(yq, 텍스트 grep 아님) ③ 불변식 결속(같은 객체·readOnly·protocol)으로 실제 강제해야. executing-plans의 `make ci`(run-bats·check-skeleton·verify-traps)가 구현 시 잔여 포착.

## Execution directives
- **Skill:** implement via `executing-plans` in a **separate session, in this worktree** (`.claude/worktrees/feat+gate-enforcement-coverage`).
- **Run continuously:** 라우틴 리뷰로 멈추지 말 것. 진짜 블로커에서만 정지. 전 Task 완주. **Task 순서: 1 → 2 → 3 → 4 → 5.**
- **★즉시green 특성** — 3 가드(CJK·check-skeleton 승격·homepage render) 모두 현재 통과해야 정상(미래 회귀 차단 목적). render/skeleton이 현재 이슈를 드러내면 그 fix가 보너스. gate=required라 **머지 전 gate 1회 관찰**(잘못된 yq/skip 즉시 포착).
- **Commits — 직접 적용; `Skill(commit)` 미사용**:
  - **한국어** 메시지, **AI 마커 금지**. Format `<type>(<scope>): 한국어 설명`. Type만 `feat`/`fix`/`refactor`/`docs`/`style`/`test`/`chore`.
  - (가드 추가=`feat:`/`test:`, gate 승격=`feat:`, traps 등록=`docs:`.) Task별 자체 커밋.
  - **Where:** 현재 feature 워크트리(`worktree-feat+gate-enforcement-coverage`) 직접 커밋.
- **Push/PR:** owner 판단. `.github`·`scripts`·`tests`는 ArgoCD 미싱크(라이브 0). 단 check-skeleton gate 승격은 required check 변경이라 머지 전 gate green 증명 필수.
