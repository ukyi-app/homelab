# CI/CD 하드닝 Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 홈랩 CI/CD 전 표면(GitHub Actions·composite·CI 호출 mjs·Makefile)의 39개 검증된 적대적-감사 발견 + 인접 deadmanswitch를 9단계 TDD로 하드닝한다.

**Architecture:** 테마/공유인프라별 단계 PR(라이브버그 우선). 공유 composite/lib(`tf-destroy-guard`·`tf-r2-init`·`setup-node-pnpm`·`setup-toolchain` kubeseal input·`tools/lib/identity.mjs`·`telegram-source-enum.bats`)로 중복 제거. 각 단계는 자체 게이트 테스트로 독립 머지(PR-first + auto-merge). **Phase 5만 owner-local `terraform apply`**(github 루트=신뢰앵커, CI 무인 apply 금지).

**Tech Stack:** GitHub Actions(composite actions), Node ESM(`tools/*.mjs`), bats, conftest/OPA(`policy/`), Terraform(cloudflare/github/tailscale, R2 backend), kubeseal/SOPS, ArgoCD GitOps.

**작업 위치:** git worktree `/Users/ukyi/workspace/homelab-cicd-hardening` (branch `feat/cicd-hardening` @ origin/main). 모든 경로/커밋은 이 워크트리 기준.

**머지 순서:** Phase 1 → 2 → 3 → 4 → 5(owner-local) → 6 → 7 → 8 → 9. 공유 composite는 소비 단계보다 먼저 구축(tf-destroy-guard=P3, identity.mjs=P2, source-enum bats=P1, tf-r2-init/setup-node-pnpm/kubeseal=P7).

---

## 횡단 조정 (Assembler — 실행 시 필수 준수)

> 일관성 비평이 잡은 cross-phase 결합. 아래 지시가 개별 섹션의 라인번호 앵커보다 **우선**한다.

1. **`tools/audit-orphans.mjs`는 3개 태스크(P6 races-5 · P8 drift-3 · P8 fm-5)가 같은 파일·같은 BLOCKING Set 리터럴·같은 registry 루프 영역을 편집한다.** 라인번호 앵커 금지 — **코드 랜드마크**(함수/Set 리터럴/주석 마커)로 앵커링. 머지 순서 **P6(races-5) → P8(drift-3 → fm-5)**. P8 태스크는 P6가 수정한 파일(registry 루프가 이미 active/inactive로 split, BLOCKING에 `activation-surface-drift` 포함) 기준으로 앵커를 재작성한다. 최종 BLOCKING set = `{dangling-binding, orphan-dns(active:true)}`, 비차단(정보성) = `{orphan-dns-inactive, dangling-role, activation-surface-drift, missing-activation}`(⚠️ codex pass3 F1: activation을 **차단**하면 정상 active-app 이미지 bump가 데드락 — 정보성으로만). BLOCKING Set 편집은 단일 지점에서만.

2. **Phase 8 obs-3(build.yaml 알림 추가)은 `tools/test/telegram-callsites.bats`도 갱신**한다(P6 Task 5가 pr-sweeper.yml로 콜사이트 수를 16으로 설정 → build.yaml이 17번째). 카운트 16→17 + here-doc에 `build.yaml 1` 추가. P8은 P6 이후 머지. build.yaml notify가 5개 필수 `with:` 키를 모두 갖는지 확인.

3. **Phase 4 supplychain-7의 행동(decoy 거부) 회귀 테스트는 게이트 포함 파일에 둔다.** `tests/sops-guard.bats`는 게이트 글롭에서 **제외**된다(ci.yaml:58·Makefile:106 — 실 age 키 의존). 따라서 age 키 불필요한 decoy/partial-enc 거부 **행동** 단언을 `tools/test/gate-secret-guard.bats`(게이트 포함)에 추가한다. 구조 검증만 verify 잡(비필수)에 남긴다.

4. **Phase 5는 단일 원자 PR — RED-only 커밋 금지.** `tools/test/auth.bats`는 게이트 포함이라 구현 없는 standalone RED 커밋은 required CI를 깬다. **테스트 작성 + 구현(tf 리소스/변수 제거)을 한 커밋에 묶는다.** 라이브 DEPLOY_BOT_PAT 삭제(owner-local `terraform -chdir=infra/github apply`)는 코드 게이트 밖 수동 태스크임을 명시(인지된 non-TDD).

5. **drift-6는 두 개의 별개 composite로 분리 — 재정의 아님.** `tf-destroy-guard`=Phase 3(part 1), `tf-r2-init`=Phase 7(part 2). 각 composite는 정확히 한 번만 정의.

6. **`telegram-source-enum.bats` reverse(dead-member) 체크의 emitter 범위** = 워크플로 `.with.source` ∪ `platform/` ∪ `tools/` ∪ `EXEMPT_RESERVED`. `.github`의 비-source 컨텍스트에서만 나오는 미래 enum 추가는 dead로 오탐될 수 있음(범위 인지 — 필요 시 exemption 추가).

7. **Phase 9(deadmanswitch)** — 동작 bats는 정적이지만 **라이브 발효는 `checksum/relay-script` pod-template annotation으로 ArgoCD가 자동 롤**(codex pass2 F7 — ConfigMap 무재시작 함정 회피, AGENTS.md). 게이트 테스트가 `annotation==hash(relay.sh)`를 강제. 수동 `rollout restart`는 발효 메커니즘이 아니라 사후 검증일 뿐.

---

## Phase 1 — 라이브 알림 + source 가드 (P0)

라이브 버그 하나(obs-1)와 그 근본원인을 양방향으로 잠그는 공유 게이트 bats(obs-2)를 다룬다. 두 발견은 같은 파일(`.github/actions/telegram-notify/notify.sh:25`의 enum 건초더미)을 중심으로 한다. obs-2가 만드는 `tools/test/telegram-source-enum.bats`는 설계 공유인프라 #5(notify source-label 검증 bats)이며 이후 단계는 이를 참조만 한다.

순서: 먼저 **obs-2의 가드 bats를 작성**해 그 안에서 obs-1의 라이브 버그가 FAIL로 드러나게 한 뒤(가드가 실제로 잡는지 증명), obs-1 fix로 PASS시킨다. 그다음 reverse-direction(dead member) 단언을 추가한다. 단, TDD 단위를 작게 유지하기 위해 Task 1에서 obs-1 핫픽스를 가장 좁은 단위(case 단언 한 줄)로 먼저 끝내고, Task 2에서 공유 가드 bats(양방향)를 배선한다.

검증된 사실(라이브 grep으로 확인):
- `tf-reconcile.yml:163,225`가 `source: IaC드리프트`를 발화하는데 `notify.sh:25` 건초더미엔 `IaC IaC수렴`만 있고 `IaC드리프트`가 없다 → `*)` 기본 분기 `exit 2`(라이브 침묵 + run red).
- 게이트 글롭은 `ls tools/test/*.bats`(Makefile:104, ci.yaml:45) — 신규 `tools/test/telegram-source-enum.bats`는 자동 포함.
- 워크플로 `.with.source` 추출 신뢰 idiom(mikefarah yq v4.52): `[.jobs.*.steps[]? | select(.uses == "./.github/actions/telegram-notify") | .with.source] | .[]`. (`.jobs[].steps[]?`는 빈 결과 — `.jobs.*` wildcard 필요.) 워크플로에서 실제 발화되는 라벨 13종: `DB생성 IaC IaC드리프트 IaC수렴 감사 배포 변이 시크릿갱신 앱생성 온보딩 이미지폴링 캐시생성 해체`.
- enum 멤버 14종 = 위 13종 + `복원드릴` + `알림` − (`IaC드리프트`는 현재 enum에 **없음**). `복원드릴`은 워크플로가 아니라 `platform/cnpg/prod/restore-drill-script.sh`(CronJob)가 발화 → reverse 체크가 워크플로만 보면 false-positive. `알림`은 현재 발화처 0(예약 라벨) → reverse 체크에 명시 exemption 필요.

---

### Task 1: notify.sh enum에 `IaC드리프트` 토큰 추가 (obs-1)

**Files:**
- Modify `/Users/ukyi/workspace/homelab-cicd-hardening/.github/actions/telegram-notify/notify.sh:25`
- Test `/Users/ukyi/workspace/homelab-cicd-hardening/tools/test/telegram-notify.bats` (기존 파일에 회귀 케이스 추가)

이 라이브 버그는 단위가 작아 기존 `telegram-notify.bats`(notify.sh를 DRY_RUN으로 실행하는 단위 스위트)에 `SOURCE=IaC드리프트`가 `exit 0`해야 한다는 회귀 테스트를 추가해 잡는다. (양방향 워크플로↔enum 교차검증은 Task 2의 공유 가드가 담당.)

**Step 1: Write the failing test** — 기존 파일 끝(라인 143 이후)에 추가:

```bash
@test "accepts the IaC드리프트 source label emitted by tf-reconcile drift steps (obs-1 live bug)" {
  # tf-reconcile.yml:163,225가 발화하는 라벨 — enum 건초더미에 빠져 있으면 exit 2(라이브 침묵).
  run env STATUS=drift SOURCE=IaC드리프트 TITLE="github 드리프트" sh "$SH"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "IaC드리프트"; [ "$?" -eq 0 ]
}
```

**Step 2: Run it, expect FAIL** —
```
bats tools/test/telegram-notify.bats
```
기대 실패: 새 케이스가
```
✗ accepts the IaC드리프트 source label emitted by tf-reconcile drift steps (obs-1 live bug)
   (in test file tools/test/telegram-notify.bats, line N)
     `[ "$status" -eq 0 ]' failed
```
로 떨어진다(notify.sh가 `telegram-notify: unknown source 'IaC드리프트'` stderr + exit 2).

**Step 3: Minimal implementation** — `notify.sh:25` 건초더미에 `IaC드리프트`를 추가. `IaC수렴` 바로 뒤에 끼운다(IaC 계열 인접):

```sh
case " 알림 복원드릴 앱생성 DB생성 캐시생성 시크릿갱신 해체 배포 온보딩 IaC IaC수렴 IaC드리프트 감사 이미지폴링 변이 " in
```

(원본 라인: `case " 알림 복원드릴 앱생성 DB생성 캐시생성 시크릿갱신 해체 배포 온보딩 IaC IaC수렴 감사 이미지폴링 변이 " in` — `IaC수렴 ` 뒤에 `IaC드리프트 `만 삽입. 건초더미는 앞뒤 공백 패딩이 멤버십의 토큰 경계이므로 토큰 사이 단일 공백 유지.)

**Step 4: Run test, expect PASS** —
```
bats tools/test/telegram-notify.bats
```
기대 출력: 전체 스위트 통과(기존 + 신규), 예:
```
✓ accepts the IaC드리프트 source label emitted by tf-reconcile drift steps (obs-1 live bug)
...
24 tests, 0 failures
```
(`rejects an unknown source label` 케이스는 `SOURCE=NotAKoreanLabel`이라 여전히 PASS — 회귀 없음.)

**Step 5: Commit** —
```
git -C /Users/ukyi/workspace/homelab-cicd-hardening add .github/actions/telegram-notify/notify.sh tools/test/telegram-notify.bats && git -C /Users/ukyi/workspace/homelab-cicd-hardening commit -m "fix: notify.sh enum에 IaC드리프트 추가 — tf-reconcile 드리프트 알림 침묵 해소"
```

---

### Task 2: 워크플로 source ↔ enum 양방향 검증 게이트 bats 구축 (obs-2)

**Files:**
- Create `/Users/ukyi/workspace/homelab-cicd-hardening/tools/test/telegram-source-enum.bats` (공유 #5 — notify source-label bats)
- (구현 변경 없음 — Task 1이 이미 라이브 enum을 고쳤으므로 forward 단언은 즉시 green이어야 한다. 이 Task는 근본원인 차단 게이트를 영구 배선한다.)

이 bats는 `notify.sh:25` 한 줄에서 enum 토큰을 추출하고, 모든 워크플로의 `.with.source` 리터럴을 yq로 파싱해 **forward(워크플로 source ∈ enum)** + **reverse(enum 멤버가 어딘가에서 실제 발화 — dead member 검출)** 를 단언한다. 게이트 글롭 `tools/test/*.bats`가 자동 포함한다.

**Step 1: Write the failing test** — 신규 파일 전체:

```bash
#!/usr/bin/env bats
# notify.sh enum과 워크플로 .with.source 리터럴을 양방향 교차검증한다 (obs-2, 공유 #5).
# obs-1 류 라이브 버그(워크플로가 enum에 없는 source를 발화 → exit 2 침묵)의 근본원인을 게이트에서 차단.
# ⚠️ @test 이름은 영어만(한글이면 bats dir-run 인코딩 깨짐 — AGENTS.md).
# ⚠️ 중간 단언은 [ ]만(bash 3.2 [[ ]] 실패 침묵통과 — AGENTS.md).
# ⚠️ declare -A 금지(bash 3.2). enum 추출은 notify.sh:25 case 라인을 SSOT로 파싱.

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  WF="$ROOT/.github/workflows"
  SH="$ROOT/.github/actions/telegram-notify/notify.sh"
  command -v yq >/dev/null || skip "yq required"
  # enum 토큰: notify.sh의 source-검증 case 건초더미(따옴표 안 공백구분) 한 줄에서 추출.
  # 그 라인은 ' 알림 복원드릴 … 변이 '를 case subject로 가진 유일한 라인이다.
  ENUM_LINE="$(grep -nE 'case " (알림|복원드릴)' "$SH" | head -1 | cut -d: -f2-)"
  [ -n "$ENUM_LINE" ] || { echo "enum case 라인을 notify.sh에서 못 찾음"; false; }
  ENUM_TOKENS="$(printf '%s' "$ENUM_LINE" | sed -E 's/.*case " (.*) " in.*/\1/' | tr ' ' '\n' | grep -v '^$' | sort -u)"
  # 워크플로가 telegram-notify 액션에 넘기는 모든 source 리터럴.
  WF_SOURCES="$(
    for f in "$WF"/*.yml "$WF"/*.yaml; do
      [ -e "$f" ] || continue
      yq -r '[.jobs.*.steps[]? | select(.uses == "./.github/actions/telegram-notify") | .with.source] | .[]' "$f" 2>/dev/null
    done | grep -v '^$' | grep -v '^null$' | sort -u
  )"
  # reverse 방향: 워크플로가 아닌 발화처(예: CNPG restore-drill CronJob)도 enum을 정당하게 쓴다.
  # 워크플로만 보면 false-positive가 나므로, 비-워크플로 발화처는 레포 전역 grep으로 보강하고
  # 발화처가 아예 0인 예약 라벨만 명시 exemption으로 둔다.
  EXEMPT_RESERVED="알림"   # 제네릭 예약 라벨 — 현재 emitter 0(의도). 삭제는 별도 결정.
}

@test "enum tokens were extracted (non-empty SSOT parse of notify.sh case line)" {
  [ -n "$ENUM_TOKENS" ]
  # 최소 알려진 멤버가 들어있어야(파싱 깨짐 회귀 차단)
  printf '%s\n' "$ENUM_TOKENS" | grep -qx "배포"; [ "$?" -eq 0 ]
  printf '%s\n' "$ENUM_TOKENS" | grep -qx "IaC드리프트"; [ "$?" -eq 0 ]
}

@test "workflow sources were extracted (non-empty — yq wildcard path sanity)" {
  [ -n "$WF_SOURCES" ]
  printf '%s\n' "$WF_SOURCES" | grep -qx "IaC드리프트"; [ "$?" -eq 0 ]
}

@test "forward: every workflow .with.source is a member of the notify.sh enum (obs-1 root cause)" {
  bad=""
  while read -r src; do
    [ -n "$src" ] || continue
    if ! printf '%s\n' "$ENUM_TOKENS" | grep -qx "$src"; then
      bad="$bad $src"
    fi
  done <<EOF
$WF_SOURCES
EOF
  [ -z "$bad" ] || { echo "enum에 없는 워크플로 source:$bad (notify.sh exit 2 → 침묵 알림)"; false; }
}

@test "reverse: every enum member is actually emitted somewhere (no dead member except reserved)" {
  dead=""
  while read -r tok; do
    [ -n "$tok" ] || continue
    # 워크플로 발화처
    if printf '%s\n' "$WF_SOURCES" | grep -qx "$tok"; then continue; fi
    # 비-워크플로 발화처(스크립트/CronJob 등) — 레포 전역에서 'source 라벨'로 등장하는지.
    # restore-drill-script.sh는 '복원드릴 · ident' 형태로 본문에 라벨을 직접 쓴다.
    if grep -rqF "$tok" "$ROOT/platform" "$ROOT/tools" 2>/dev/null; then continue; fi
    # 명시 예약 라벨 exemption
    if [ "$tok" = "$EXEMPT_RESERVED" ]; then continue; fi
    dead="$dead $tok"
  done <<EOF
$ENUM_TOKENS
EOF
  [ -z "$dead" ] || { echo "발화처 없는 dead enum 멤버:$dead (제거하거나 EXEMPT_RESERVED에 등록)"; false; }
}
```

**Step 2: Run it, expect FAIL** —

먼저 이 가드가 obs-1 같은 버그를 실제로 잡는지 **증명**한다. Task 1의 fix를 일시 되돌린 상태에서 forward 케이스가 빨개져야 한다. (executor는 stash로 검증):
```
git -C /Users/ukyi/workspace/homelab-cicd-hardening stash push -- .github/actions/telegram-notify/notify.sh   # obs-1 fix 일시 제거(검증용)
bats tools/test/telegram-source-enum.bats
```
기대 실패:
```
✗ forward: every workflow .with.source is a member of the notify.sh enum (obs-1 root cause)
     enum에 없는 워크플로 source: IaC드리프트 (notify.sh exit 2 → 침묵 알림)
```
검증 후 즉시 복원:
```
git -C /Users/ukyi/workspace/homelab-cicd-hardening stash pop
```
(stash 없이 가드의 의도만 확인하려면, Task 1 미적용 상태에서 이 Task를 먼저 작성해도 동일하게 forward가 FAIL한다. 어느 순서든 "가드가 obs-1을 잡는다"가 핵심.)

**Step 3: Minimal implementation** — 구현 코드 변경 없음. obs-1은 Task 1이 이미 고쳤다. 이 Task의 산출물은 게이트 bats 자체(Step 1의 신규 파일)다. 추가 배선 불필요 — `make ci`/Makefile:104의 `ls tools/test/*.bats` 글롭이 신규 파일을 자동 포함한다(하드코딩 목록 없음, 검증됨).

**Step 4: Run test, expect PASS** —
```
bats tools/test/telegram-source-enum.bats
```
기대 출력:
```
✓ enum tokens were extracted (non-empty SSOT parse of notify.sh case line)
✓ workflow sources were extracted (non-empty — yq wildcard path sanity)
✓ forward: every workflow .with.source is a member of the notify.sh enum (obs-1 root cause)
✓ reverse: every enum member is actually emitted somewhere (no dead member except reserved)

4 tests, 0 failures
```
게이트 통합 확인(신규 bats가 글롭에 잡히는지):
```
make ci
```
기대: bats 단계가 `telegram-source-enum.bats`를 포함해 실행, 0 failures.

**Step 5: Commit** —
```
git -C /Users/ukyi/workspace/homelab-cicd-hardening add tools/test/telegram-source-enum.bats && git -C /Users/ukyi/workspace/homelab-cicd-hardening commit -m "test: 워크플로 source↔notify enum 양방향 게이트 — obs-1 근본원인 차단"
```

---

### 단계 노트 (executor 참고)

- **양방향 단언 근거**: forward(워크플로 source ⊆ enum)는 obs-1류 침묵 버그를 차단. reverse(enum ⊆ 발화처 ∪ exempt)는 미사용 멤버 누적/오타 멤버를 검출하되, `복원드릴`(CNPG CronJob 발화) false-positive를 `grep -r platform/ tools/`로 흡수하고 `알림`(예약, emitter 0)만 명시 exemption.
- **yq idiom 함정**: `.jobs[].steps[]?`는 mikefarah yq v4에서 빈 결과를 낸다(검증됨) — 반드시 `.jobs.*.steps[]?` wildcard + `[ ... ] | .[]` array-flatten을 쓸 것. `2>/dev/null`로 yq stderr를 삼키되 결과 비어있음은 두 번째 sanity 케이스가 잡는다.
- **enum SSOT 파싱**: 토큰을 별도 하드코딩하지 않고 `notify.sh`의 case 라인 자체에서 추출 → notify.sh가 SSOT. 라벨 추가 시 가드가 자동 추종.
- **bash 3.2 안전**: 모든 중간 단언 `[ ]`, `declare -A` 미사용, `<<EOF` here-doc로 목록 순회. `@test` 이름 전부 영어.

---

## Phase 2 — mutator fail-closed (P0)

이 단계는 변이(mutator) 도구 패밀리의 fail-closed 균일성을 복원한다. `create-app.mjs`/`onboard-app.mjs`/`provision-cache.mjs`는 이미 allowed-flag 가드(Phase 이전, PR #50)를 가졌지만 `bump-tag.mjs`(권위 bump-poll 경로)·`teardown-app.mjs`·`teardown-resource.mjs`는 아직 오타 플래그를 침묵 무시한다. 또한 6개 콜사이트에 분기된 앱-이름 regex 4종을 `tools/lib/identity.mjs` SSOT로 수렴한다.

작업 순서: Task 3(`identity.mjs` SSOT 구축)을 Task 1·2보다 **먼저** 머지할 필요는 없다(각 Task는 독립 파일 가드라 직교) — 단 같은 PR/단계 안에서 Task 3의 콜사이트 교체가 Task 1의 `bump-tag.mjs` regex 라인(19)을 건드리므로, 한 단계 안에서는 Task 1 → Task 3 순으로 적용해 충돌을 피한다(Task 1이 line 19 regex를 그대로 두고 ALLOWED_FLAGS만 추가 → Task 3이 line 19를 import로 치환).

> 공유 인프라: 이 단계가 **`tools/lib/identity.mjs`(APP_NAME_RE = `/^[a-z][a-z0-9-]{0,38}[a-z0-9]$/`)를 구축**한다(설계 공유 #4). 다른 단계(예: races-5 audit-orphans)가 앱 이름 검증이 필요하면 이 모듈을 import한다 — 재정의 금지.

---

### Task 1: bump-tag.mjs allowed-flag 가드 + `--expect-current` (dry-3)

`tools/bump-tag.mjs`의 `takeOpt`(lines 6–16)는 `--diges`처럼 오타한 `--digest`를 떼어내지 못한다. 그 결과 `digest`가 `undefined`로 남고, lines 45–48이 **기존 `image.digest`를 삭제**한다 — digest-핀 bump가 권위 bump-poll 경로에서 조용히 tag-only로 격하되고 exit 0(공급망 핀 무력화). 또한 races-4 TOCTOU 방어를 위해 `--expect-current <tag>` 옵션을 추가한다(bump-poll이 `git checkout main` 후 현재 tag 재검증).

**Files:**
- Modify `tools/bump-tag.mjs` (lines 6–17 영역: `takeOpt` 직후 allowed-flag 거부 추가 + `--expect-current` take)
- Modify `tools/bump-tag.mjs` (line 39 영역: no-op 판정 전에 expect-current 검사 삽입)
- Modify (extend) Test `tools/test/bump.bats`

**Step 1: Write the failing test** — `tools/test/bump.bats`에 아래 `@test`들을 파일 끝(line 81 `}` 다음)에 추가한다. `DIG` 변수(line 33)는 기존 정의를 재사용한다.

```bash
# ── dry-3: allowed-flag 가드 (오타 플래그가 digest 핀을 침묵 삭제하는 것 차단) ──
@test "bump rejects an unknown flag with exit 2 (typo'd --digest must not silently drop the pin)" {
  f="$FIX/apps/blog/deploy/prod/values.yaml"
  # 먼저 digest 핀을 심는다
  node tools/bump-tag.mjs blog sha-deadbee --digest "$DIG" --repo-root "$FIX"
  run yq '.image.digest' "$f"
  [ "$output" == "$DIG" ]
  # --diges 오타: 가드가 없으면 takeOpt가 못 떼어내 digest=undefined → image.digest 삭제 + exit 0
  run node tools/bump-tag.mjs blog sha-feedbee --diges "$DIG" --repo-root "$FIX"
  [ "$status" -eq 2 ]
  echo "$output" | grep -q "알 수 없는 옵션"
  # 거부됐으므로 핀은 그대로여야 한다 (격하 없음)
  run yq '.image.digest' "$f"
  [ "$output" == "$DIG" ]
}

@test "bump --expect-current aborts when current tag differs (races-4 TOCTOU)" {
  # 현재 tag는 sha-0000000 (setup fixture). 기대값을 sha-aaaaaaa로 주면 불일치 → abort
  run node tools/bump-tag.mjs blog sha-feedbee --expect-current sha-aaaaaaa --repo-root "$FIX"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "expect-current"
}

@test "bump --expect-current proceeds when current tag matches" {
  f="$FIX/apps/blog/deploy/prod/values.yaml"
  run node tools/bump-tag.mjs blog sha-feedbee --expect-current sha-0000000 --repo-root "$FIX"
  [ "$status" -eq 0 ]
  run yq '.image.tag' "$f"
  [ "$output" == "sha-feedbee" ]
}

@test "bump rejects a value-flag with no value (arity, F2 digest-pin downgrade class)" {
  # ⚠️ codex pass5 F2: --digest가 값 없이 끝에 오면 digest=undefined로 떨어져 digest 핀을 조용히 격하했다.
  # arity 파서는 값 누락을 exit 2로 거부해야 한다(핀 격하 방지).
  run node tools/bump-tag.mjs blog sha-feedbee --digest --repo-root "$FIX"
  [ "$status" -eq 2 ]
  echo "$output" | grep -q "arity"
}

@test "bump rejects a value-flag whose value is another --flag (arity)" {
  # --digest 다음이 또 다른 플래그면 값이 누락된 것 — 그 플래그를 값으로 삼키지 말고 거부.
  run node tools/bump-tag.mjs blog sha-feedbee --digest --expect-current sha-0000000 --repo-root "$FIX"
  [ "$status" -eq 2 ]
}
```

**Step 2: Run it, expect FAIL**

```bash
eval "$(mise activate bash)"; bats tools/test/bump.bats
```

기대 실패: 첫 신규 테스트에서 `--diges`가 침묵 무시돼 exit 0 + digest 삭제 →
`✗ bump rejects an unknown flag with exit 2 ...` / `(in test file ..., line ...) [ "$status" -eq 2 ]` (실제 status=0). `--expect-current` 테스트는 옵션 미구현이라 `--expect-current`가 positional로 흘러들어 형식 검증에서 다른 메시지로 실패.

**Step 3: Minimal implementation** — ⚠️ codex pass5 F2: 기존 `takeOpt`는 `--digest`가 값 없이(끝에) 오면 undefined로 떨어뜨려 digest 핀을 조용히 격하(이 Task가 막으려는 바로 그 클래스)한다. `takeOpt` 함수 정의·호출(원본 line 6–17)을 **arity 검증 파서**로 대체한다 — 인식된 값-플래그는 비어있지 않고 다음 토큰이 또 다른 `--flag`가 아닌 값을 반드시 가져야 한다.

`tools/bump-tag.mjs`의 `takeOpt` 정의·호출(원본 line 6–17)을 다음으로 교체:

```javascript
// arity 검증 파서: 인식된 값-플래그는 비어있지 않은 값(다음 토큰이 `--flag`가 아님)을 필수로 갖는다.
// 미인식 `--flag`는 거부(오타 침묵-무시 차단). 나머지는 positional(app, tag).
const VALUE_FLAGS = new Set(["--repo-root", "--digest", "--expect-current"]);
const opts = {};
const positionals = [];
for (let i = 0; i < argv.length; i++) {
  const a = argv[i];
  if (a.startsWith("--")) {
    if (!VALUE_FLAGS.has(a)) { console.error(`알 수 없는 옵션: ${a}\n허용: ${[...VALUE_FLAGS].join(" ")}`); process.exit(2); }
    const v = argv[i + 1];
    if (v === undefined || v.startsWith("--")) { console.error(`옵션 ${a}에 값이 없다(arity 위반) — 값을 명시하라`); process.exit(2); }
    opts[a] = v; i++; // 값 소비
  } else {
    positionals.push(a);
  }
}
const repoRoot = opts["--repo-root"] ?? "."; // 테스트는 fixture root를 넘긴다 (라이브 CI는 기본 ".")
const digest = opts["--digest"]; // 있으면 image.digest를 권위 참조로 함께 기록
const expectCurrent = opts["--expect-current"]; // races-4 TOCTOU: bump-poll이 checkout 후 현재 tag 재검증
const [app, tag] = positionals;
```

그 다음, no-op 판정(현 line 39) **앞**에 expect-current 검사를 삽입한다. 현 line 35–39 영역:

```javascript
const doc = parseDocument(readFileSync(path, "utf8"));
const curTag = doc.getIn(["image", "tag"]);
const curDigest = doc.getIn(["image", "digest"]);
// races-4 TOCTOU 방어: 호출자가 기대한 현재 tag와 실제가 다르면 중단(레이스로 main이 이미 진전).
if (expectCurrent !== undefined && curTag !== expectCurrent) {
  console.error(`expect-current 불일치: 기대 ${expectCurrent}, 실제 ${curTag ?? "<none>"} — bump 중단(race)`); process.exit(3);
}
// no-op 판정은 tag+digest 쌍으로 — digest 미지정이면 "digest 없음"이 목표 상태다.
if (curTag === tag && (curDigest ?? undefined) === digest) {
```

usage 문자열(line 23)도 `[--expect-current sha-<gitsha>]`을 포함하도록 갱신:

```javascript
  console.error("usage: bump-tag <app> sha-<gitsha> [--digest sha256:<64hex>] [--expect-current sha-<gitsha>] [--repo-root <dir>]"); process.exit(2);
```

**Step 4: Run test, expect PASS**

```bash
eval "$(mise activate bash)"; bats tools/test/bump.bats
```

기대 출력: 모든 `@test ... ok`(기존 9 + 신규 3 = 12 통과), `12 tests, 0 failures`.

**Step 5: Commit**

```bash
git -C /Users/ukyi/workspace/homelab-cicd-hardening add tools/bump-tag.mjs tools/test/bump.bats && git -C /Users/ukyi/workspace/homelab-cicd-hardening commit -m "fix: bump-tag 오타 플래그 거부 + --expect-current TOCTOU 가드 (digest 핀 격하 차단)"
```

---

### Task 2: teardown-app/teardown-resource allowed-flag 가드 (dry-4)

`teardown-app.mjs`의 `arg`(line 9)와 `teardown-resource.mjs`의 `arg`/`has`(lines 26–27)는 미지정 플래그를 조용히 삼킨다 — mutator 패밀리 fail-closed 균일성 위반. 같은 allowed-set 거부를 추가한다.

**Files:**
- Modify `tools/teardown-app.mjs` (line 9–12 영역: `arg` 정의 직후 가드 추가)
- Modify `tools/teardown-resource.mjs` (line 26–34 영역: `arg`/`has`/`step` 파싱 직후 가드 추가)
- Modify (extend) Test `tools/test/cli-flag-guard.bats`

**Step 1: Write the failing test** — 기존 `tools/test/cli-flag-guard.bats`(line 25 마지막 `@test` 다음)에 추가한다. 이 파일의 `setup()`은 repo root로 cd한다(line 7).

```bash
@test "teardown-app rejects an unknown flag" {
  run node tools/teardown-app.mjs --app blog --dry-run --bogus-flag x
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "알 수 없는 옵션"
}

@test "teardown-resource rejects an unknown flag" {
  run node tools/teardown-resource.mjs --db shared --dry-run --bogus-flag x
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "알 수 없는 옵션"
}
```

**Step 2: Run it, expect FAIL**

```bash
eval "$(mise activate bash)"; bats tools/test/cli-flag-guard.bats
```

기대 실패: `--bogus-flag`가 침묵 무시돼 teardown이 정상 진행(exit 0 또는 다른 사유 exit). `✗ teardown-app rejects an unknown flag` / `[ "$status" -ne 0 ]` 실패(status=0).

**Step 3: Minimal implementation**

`tools/teardown-app.mjs` — line 9(`const arg = ...`) 다음, `const DRY = ...`(line 10) 앞에 가드를 삽입한다. teardown-app 허용 집합 `{--app, --repo-root, --dry-run}`:

```javascript
const arg = (k, d) => { const i = process.argv.indexOf(k); return i > -1 ? process.argv[i + 1] : d; };
// 오타 옵션 침묵-무시 차단 — arg() 헬퍼는 미지정 플래그를 조용히 무시한다(mutator 패밀리 fail-closed).
const ALLOWED_FLAGS = new Set(["--app", "--repo-root", "--dry-run"]);
for (const a of process.argv.slice(2)) {
  if (a.startsWith("--") && !ALLOWED_FLAGS.has(a)) { console.error(`알 수 없는 옵션: ${a}\n허용: ${[...ALLOWED_FLAGS].join(" ")}`); process.exit(2); }
}
const DRY = process.argv.includes("--dry-run");
```

`tools/teardown-resource.mjs` — line 34(`const step = ...`) 다음, `const fail = ...`(line 36) 앞에 가드를 삽입한다. 허용 집합 `{--db, --cache, --repo-root, --delete-data, --backup-verified, --step, --dry-run}`:

```javascript
const step = arg("--step", deleteData ? undefined : "tombstone");
// 오타 옵션 침묵-무시 차단 — arg()/has() 헬퍼는 미지정 플래그를 조용히 무시한다(mutator 패밀리 fail-closed).
const ALLOWED_FLAGS = new Set(["--db", "--cache", "--repo-root", "--delete-data", "--backup-verified", "--step", "--dry-run"]);
for (const a of process.argv.slice(2)) {
  if (a.startsWith("--") && !ALLOWED_FLAGS.has(a)) { console.error(`알 수 없는 옵션: ${a}\n허용: ${[...ALLOWED_FLAGS].join(" ")}`); process.exit(2); }
}
```

**Step 4: Run test, expect PASS**

```bash
eval "$(mise activate bash)"; bats tools/test/cli-flag-guard.bats && bats tools/test/teardown.bats
```

기대 출력: `cli-flag-guard.bats` 5 tests 0 failures(기존 3 + 신규 2), `teardown.bats`도 회귀 없음(0 failures — 정상 플래그는 모두 허용 집합에 포함됨).

**Step 5: Commit**

```bash
git -C /Users/ukyi/workspace/homelab-cicd-hardening add tools/teardown-app.mjs tools/teardown-resource.mjs tools/test/cli-flag-guard.bats && git -C /Users/ukyi/workspace/homelab-cicd-hardening commit -m "fix: teardown-app/teardown-resource 오타 플래그 거부 (mutator fail-closed 균일화)"
```

---

### Task 3: tools/lib/identity.mjs SSOT + 6 콜사이트 수렴 (dry-6)

4종 분기 regex가 라이브에 공존한다: create-app:33 / onboard-app:28 / teardown-app:13 = `^[a-z][a-z0-9-]{1,29}$`; validate-mutation:26 / activate-app:31 = `^[a-z][a-z0-9-]{0,38}[a-z0-9]$`; bump-tag:19 = `^[a-z][a-z0-9-]{0,40}$`. validator 정책(`^[a-z][a-z0-9-]{0,38}[a-z0-9]$`, trailing hyphen 금지, 길이 2..40)으로 `tools/lib/identity.mjs`에 수렴하고 6개 콜사이트가 import한다.

**Files:**
- Create `tools/lib/identity.mjs`
- Modify `tools/create-app.mjs` (line 33; import 추가)
- Modify `tools/onboard-app.mjs` (line 28; import 추가)
- Modify `tools/teardown-app.mjs` (line 13; import 추가)
- Modify `tools/validate-mutation.mjs` (line 26; import 추가)
- Modify `tools/activate-app.mjs` (line 31; import 추가)
- Modify `tools/bump-tag.mjs` (line 19; import 추가)
- Test `tools/test/identity.bats` (Create)

**Step 1: Write the failing test** — `tools/test/identity.bats`를 새로 만든다(`tools/test/*.bats` 글롭이 gate에 자동 포함). `@test` 이름은 영어, 중간 단언은 `[ ]`. node 인라인으로 export된 정규식과 6개 콜사이트의 동작 일치를 검증한다.

```bash
#!/usr/bin/env bats
# dry-6: 앱-이름 regex SSOT(tools/lib/identity.mjs). 4종 분기 regex를 validator 정책으로 수렴.
# trailing hyphen 금지(`^[a-z][a-z0-9-]{0,38}[a-z0-9]$`). 모든 mutator 콜사이트가 동일 검증.
# ⚠️ 중간 단언은 [ ]만 — bash 3.2 [[ ]] 침묵 통과 함정.

setup() { ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"; cd "$ROOT" || exit 1; }

@test "identity exports APP_NAME_RE with the validator policy (no trailing hyphen, 2..40)" {
  run node --input-type=module -e '
    import { APP_NAME_RE } from "./tools/lib/identity.mjs";
    const ok = ["ab", "blog", "my-app", "a"+"b".repeat(38)+"c"];        // 길이 2..40, 유효
    const bad = ["a", "-bad", "bad-", "Bad", "ab_c", "x".repeat(41)];   // 1글자/선후행 하이픈/대문자/언더스코어/길이초과
    for (const s of ok)  if (!APP_NAME_RE.test(s)) { console.error("FALSE NEG:", s); process.exit(1); }
    for (const s of bad) if (APP_NAME_RE.test(s))  { console.error("FALSE POS:", s); process.exit(1); }
    console.log("ok");
  '
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "ok"
}

@test "every mutator callsite imports APP_NAME_RE from lib/identity (no inline app-name regex left)" {
  # 6 콜사이트가 분기 regex 대신 SSOT를 쓴다 — 인라인 `[a-z][a-z0-9-]{1,29}`/`{0,40}` 잔존 0
  run grep -nE 'a-z0-9-\]\{1,29\}|a-z0-9-\]\{0,40\}' \
    tools/create-app.mjs tools/onboard-app.mjs tools/teardown-app.mjs tools/bump-tag.mjs
  [ "$status" -ne 0 ]   # grep이 아무것도 못 찾아야(=잔존 0) status!=0
  for f in create-app onboard-app teardown-app validate-mutation activate-app bump-tag; do
    run grep -q "lib/identity.mjs" "tools/$f.mjs"
    [ "$status" -eq 0 ]
  done
}

@test "teardown-app now rejects a trailing-hyphen app name (policy tightened)" {
  run node tools/teardown-app.mjs --app bad- --dry-run
  [ "$status" -ne 0 ]
}
```

**Step 2: Run it, expect FAIL**

```bash
eval "$(mise activate bash)"; bats tools/test/identity.bats
```

기대 실패: `tools/lib/identity.mjs`가 없어 첫 테스트 import가 `ERR_MODULE_NOT_FOUND`로 status≠0 → `[ "$status" -eq 0 ]` 실패. 두 번째 테스트는 인라인 regex가 아직 남아 grep이 매치(status=0) → `[ "$status" -ne 0 ]` 실패.

**Step 3: Minimal implementation**

(a) `tools/lib/identity.mjs` 생성:

```javascript
// 앱-이름 식별자 SSOT — 모든 mutator(create-app/onboard-app/teardown-app/validate-mutation/
// activate-app/bump-tag)가 이 정규식을 공유한다. 정책은 validate-mutation의 화이트리스트:
// 소문자 시작, 소문자/숫자/하이픈, **trailing hyphen 금지**, 길이 2..40.
// path traversal·오라우팅 방어의 1차 게이트이므로 분기 금지(콜사이트마다 다르면 우회 표면이 생긴다).
export const APP_NAME_RE = /^[a-z][a-z0-9-]{0,38}[a-z0-9]$/;
```

(b) `tools/create-app.mjs` — 기존 import 블록(line 7–9) 다음에 import 추가, line 33 교체:

import 추가(line 9 `import { parse ... } from "yaml";` 다음):
```javascript
import { APP_NAME_RE } from "./lib/identity.mjs";
```
line 33 교체:
```javascript
if (!APP_NAME_RE.test(app)) fail(`app 이름 불량: '${app}'`);
```

(c) `tools/onboard-app.mjs` — line 9 import 다음에 추가, line 28 교체:

import 추가:
```javascript
import { APP_NAME_RE } from "./lib/identity.mjs";
```
line 28 교체:
```javascript
if (!APP_NAME_RE.test(app ?? "")) fail(`app 이름 불량: '${app}' (${APP_NAME_RE})`);
```

(d) `tools/teardown-app.mjs` — line 7 import(`import { ... } from "node:fs";`) 다음에 추가, line 13 교체:

import 추가:
```javascript
import { APP_NAME_RE } from "./lib/identity.mjs";
```
line 13 교체:
```javascript
if (!app || !APP_NAME_RE.test(app)) {
```

(e) `tools/validate-mutation.mjs` — line 6 import(`import { readFileSync } from "node:fs";`) 다음에 추가, line 26의 `app:` 엔트리 교체:

import 추가:
```javascript
import { APP_NAME_RE } from "./lib/identity.mjs";
```
`FIELD_RE`의 `app` 엔트리(line 26)를 교체:
```javascript
  app: APP_NAME_RE,
```

(f) `tools/activate-app.mjs` — line 13 import(`import path from "node:path";`) 다음에 추가, line 31 교체:

import 추가:
```javascript
import { APP_NAME_RE } from "./lib/identity.mjs";
```
line 31 교체:
```javascript
if (!APP_NAME_RE.test(app)) die(`app 이름 형식 불량: ${app}`);
```

(g) `tools/bump-tag.mjs` — line 4 import(`import { parseDocument } from "yaml";`) 다음에 추가, line 19 교체:

import 추가:
```javascript
import { APP_NAME_RE } from "./lib/identity.mjs";
```
line 19 교체:
```javascript
if (!app || !APP_NAME_RE.test(app)) {
```

> 주의: Task 1을 같은 단계에서 먼저 적용했다면 bump-tag.mjs line 19는 변하지 않은 상태(Task 1은 ALLOWED_FLAGS만 추가)이므로 이 교체가 그대로 적용된다.

**Step 4: Run test, expect PASS**

```bash
eval "$(mise activate bash)"; bats tools/test/identity.bats && bats tools/test/create-app.bats tools/test/onboard.bats tools/test/teardown.bats tools/test/validate-mutation.bats tools/test/activate-app.bats tools/test/bump.bats
```

기대 출력: `identity.bats` 3 tests 0 failures; 6개 콜사이트 회귀 스위트 모두 0 failures(정책이 `{1,29}`→`{0,38}+말미문자`로 바뀌어도 기존 fixture 앱 이름 `blog`/`orders`/`billing`/`shared`는 전부 유효 — trailing-hyphen·단일문자 케이스만 새로 거부).

**Step 5: Commit**

```bash
git -C /Users/ukyi/workspace/homelab-cicd-hardening add tools/lib/identity.mjs tools/create-app.mjs tools/onboard-app.mjs tools/teardown-app.mjs tools/validate-mutation.mjs tools/activate-app.mjs tools/bump-tag.mjs tools/test/identity.bats && git -C /Users/ukyi/workspace/homelab-cicd-hardening commit -m "refactor: 앱-이름 regex SSOT(tools/lib/identity.mjs)로 6 콜사이트 수렴"
```

---

### Phase 2 게이트 확인 (단계 마무리)

세 Task 머지 후 전체 게이트 미러를 1회 돌려 회귀 부재를 확인한다:

```bash
eval "$(mise activate bash)"; make ci
```

기대: `make ci`가 gate 8스텝(skeleton + 원장 conftest + sops 라운드트립 + bats 스위트 + shellcheck 등)을 통과. 신규 `tools/test/identity.bats`는 `bats tools/test/*.bats` 글롭(Makefile:104)이 자동 포함하므로 별도 배선 불필요.

---

## Phase 3 — 무인 destroy 가드 + entitlement 게이트 (P0)

이 단계는 머지→apply의 primary 경로(`iac.yaml` apply job)에 빠져 있는 destroy 가드를 채우고(drift-1),
3곳에 흩어진 destroy-count 로직을 `tf-destroy-guard` composite 하나로 수렴하며(drift-6),
apply에서만 400으로 드러나는 Cloudflare 무료 플랜 entitlement 위반을 **required gate**에서 정적으로
차단하고(drift-5), reconcile의 hard-exit destroy 가드를 합법 teardown이 30분마다 영구 차단하지 않도록
완화한다(drift-2).

> **Notes — 게이트 배선의 load-bearing 결정 (drift-5/drift-2 공통):**
> required status check는 `gate`(ci.yaml job) **하나뿐**이다(`infra/github/repo.tf:43` `contexts = ["gate"]`).
> `infra/_test/*.bats`는 `iac.yaml`의 `iac-validate` job에서 **하드코딩 목록**으로만 돌고(글롭 아님), 이 job은
> required가 아니다 — 즉 `infra/_test/`에 둔 bats는 PR 차단력이 없다. 반면 `gate` job(ci.yaml:57-59)과
> `make ci`(Makefile:106)는 `tests/*.bats`를 **글롭**으로 자동 포함한다. 따라서 entitlement 단언은
> `tests/cloudflare-entitlement.bats`에 둬야 required gate가 강제한다. drift-2 reconcile 구조 단언도 동일 이유로
> 기존 `infra/_test/tf_reconcile.bats`(비-required)를 보강하되, 핵심 회귀는 `tests/`로 끌어올린다.
> 순수 grep 단언이라 terraform/cluster 비접촉(CI-safe).

### Task 1: tf-destroy-guard composite — destroy-count 로직 SSOT (drift-6)

**Files:**
- Create: `.github/actions/tf-destroy-guard/action.yml`
- Create: `.github/actions/tf-destroy-guard/destroy-guard.sh`
- Test: `tools/test/tf-destroy-guard.bats` (gate 글롭 `tools/test/*.bats`가 자동 포함)

`telegram-notify`/`notify.sh` 패턴을 그대로 따른다 — 로직은 `destroy-guard.sh`(POSIX sh)에 두고
`action.yml`은 얇은 래퍼. bats는 스크립트를 직접 호출하며, `terraform show`를 실제로 돌리지 않도록
`PLAN_JSON`(미리 렌더한 plan JSON 경로) 오버라이드를 둔다. 없으면 `terraform -chdir=$ROOT show -json $PLAN`.

**Step 1: Write the failing test**

`tools/test/tf-destroy-guard.bats`:
```bash
#!/usr/bin/env bats
# tf-destroy-guard composite 테스트 — destroy-count 단일 구현(warn|block).
# ⚠️ bash 3.2: 중간 단언은 [ ]만(​[[ ]] 실패는 침묵 통과). action 로직은 destroy-guard.sh에 있고
# PLAN_JSON 오버라이드로 terraform 없이 단위 검증한다.

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  ACT="$ROOT/.github/actions/tf-destroy-guard/action.yml"
  SH="$ROOT/.github/actions/tf-destroy-guard/destroy-guard.sh"
  TMP="$(mktemp -d)"
  # delete 2건(replace=delete+create 포함) 픽스처
  cat > "$TMP/has-delete.json" <<'JSON'
{"resource_changes":[
  {"address":"a","change":{"actions":["delete"]}},
  {"address":"b","change":{"actions":["delete","create"]}},
  {"address":"c","change":{"actions":["update"]}}
]}
JSON
  # delete 0건
  cat > "$TMP/no-delete.json" <<'JSON'
{"resource_changes":[
  {"address":"a","change":{"actions":["create"]}},
  {"address":"b","change":{"actions":["no-op"]}}
]}
JSON
}
teardown() { rm -rf "$TMP"; }

@test "action.yml is a composite that runs destroy-guard.sh and declares mode input" {
  run grep -E "using: composite" "$ACT"; [ "$status" -eq 0 ]
  run grep -E "destroy-guard\.sh" "$ACT"; [ "$status" -eq 0 ]
  run grep -E "^[[:space:]]+mode:" "$ACT"; [ "$status" -eq 0 ]
}

@test "destroy-guard.sh is POSIX sh (no bashisms)" {
  run grep -E "^#!/usr/bin/env sh|^#!/bin/sh" "$SH"; [ "$status" -eq 0 ]
  run grep -nE '\[\[|\$\{[A-Za-z_]+\^\^|\$\{[A-Za-z_]+//' "$SH"; [ "$status" -ne 0 ]
}

@test "block mode exits 1 with ::error:: when deletes present" {
  run env MODE=block PLAN_JSON="$TMP/has-delete.json" sh "$SH"
  [ "$status" -eq 1 ]
  echo "$output" | grep -q '::error::'; [ "$?" -eq 0 ]
  echo "$output" | grep -q '2'; [ "$?" -eq 0 ]
}

@test "block mode exits 0 when no deletes" {
  run env MODE=block PLAN_JSON="$TMP/no-delete.json" sh "$SH"
  [ "$status" -eq 0 ]
  run grep -q '::error::' <<<"$output"; [ "$status" -ne 0 ]
}

@test "warn mode never exits non-zero even with deletes (warning only)" {
  run env MODE=warn PLAN_JSON="$TMP/has-delete.json" sh "$SH"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '::warning::'; [ "$?" -eq 0 ]
  run grep -q '::error::' <<<"$output"; [ "$status" -ne 0 ]
}

@test "invalid mode is rejected fail-closed (exit non-zero)" {
  run env MODE=bogus PLAN_JSON="$TMP/no-delete.json" sh "$SH"
  [ "$status" -ne 0 ]
}

@test "the destroy jq selector matches the canonical inline impl" {
  # 기존 인라인 가드(iac.yaml/tf-reconcile.yml)와 동일한 select(.=="delete") 셀렉터를 SSOT로 유지
  run grep -F 'select(. == "delete")' "$SH"; [ "$status" -eq 0 ]
}

@test "emits typed result=blocked-delete on delete+block and result=ok on no-delete (F1)" {
  # ⚠️ codex pass5 F1: 호출 측이 outcome이 아니라 result로 분기 — blocked-delete만 alert-and-skip.
  run env GITHUB_OUTPUT="$TMP/o1" MODE=block PLAN_JSON="$TMP/has-delete.json" sh "$SH"
  [ "$status" -eq 1 ]
  grep -q '^result=blocked-delete$' "$TMP/o1"
  grep -q '^destroy_count=2$' "$TMP/o1"
  run env GITHUB_OUTPUT="$TMP/o2" MODE=block PLAN_JSON="$TMP/no-delete.json" sh "$SH"
  [ "$status" -eq 0 ]
  grep -q '^result=ok$' "$TMP/o2"
}

@test "emits result=error and exits 2 on a corrupt/missing plan — tooling error, not delete-block (F1)" {
  # 내부 오류(plan 부재/손상)는 delete 차단과 구분돼야 호출 측이 잡을 loud 실패시킨다.
  run env GITHUB_OUTPUT="$TMP/o3" MODE=block PLAN_JSON="$TMP/does-not-exist.json" sh "$SH"
  [ "$status" -eq 2 ]
  grep -q '^result=error$' "$TMP/o3"
  printf 'not json{' > "$TMP/bad.json"
  run env GITHUB_OUTPUT="$TMP/o4" MODE=block PLAN_JSON="$TMP/bad.json" sh "$SH"
  [ "$status" -eq 2 ]
  grep -q '^result=error$' "$TMP/o4"
}
```

**Step 2: Run it, expect FAIL**
```
bats tools/test/tf-destroy-guard.bats
```
Expected: every test errors with `No such file or directory` for
`.github/actions/tf-destroy-guard/action.yml` / `destroy-guard.sh` (파일 부재).

**Step 3: Minimal implementation**

`.github/actions/tf-destroy-guard/destroy-guard.sh`:
```sh
#!/usr/bin/env sh
# tf plan의 delete/replace(=delete+create) 액션 수를 세어 무인 apply를 가드한다(SSOT).
# ⚠️ codex pass5 F1: 결과를 **typed output**(result, destroy_count)으로 낸다 — 호출 측이 "의도된 delete 차단"과
# "내부 오류(plan 읽기 실패·jq 부재·파싱 실패)"를 구분해, 후자는 잡을 **loud 실패**시키게 한다(가드가 깨졌는데
# green으로 위장하는 것 방지).
#   result=ok             : delete 0 (또는 mode=warn)  → exit 0
#   result=blocked-delete : delete>0 && mode=block      → exit 1 (호출 측이 alert-and-skip로 강등)
#   result=error          : 내부/도구 오류              → exit 2 (호출 측이 잡 실패)
# 단위 테스트용: PLAN_JSON이 있으면 그 파일을, 없으면 `terraform -chdir=$ROOT show -json $PLAN`.
set -u
out="${GITHUB_OUTPUT:-/dev/null}"
emit() { echo "result=$1" >> "$out"; }

MODE="${MODE:-block}"
case "$MODE" in
  warn|block) : ;;
  *) emit error; echo "::error::tf-destroy-guard: mode는 warn|block만 — '$MODE' 거부"; exit 2 ;;
esac

command -v jq >/dev/null 2>&1 || { emit error; echo "::error::tf-destroy-guard: jq 부재 — 내부 오류(잡 실패)"; exit 2; }

if [ -n "${PLAN_JSON:-}" ]; then
  plan_json=$(cat "$PLAN_JSON" 2>/dev/null) || { emit error; echo "::error::PLAN_JSON 읽기 실패: ${PLAN_JSON}"; exit 2; }
else
  ROOT="${ROOT:?ROOT(=-chdir 루트) 필요}"
  PLAN="${PLAN:-tf.plan}"
  plan_json=$(terraform -chdir="$ROOT" show -json "$PLAN" 2>/tmp/tdg.err) || { emit error; echo "::error::terraform show 실패(plan 산출 누락/손상): $(cat /tmp/tdg.err 2>/dev/null)"; exit 2; }
fi

# 기존 인라인 가드와 동일 셀렉터 — replace(delete+create)의 delete도 잡는다.
destroys=$(printf '%s' "$plan_json" | jq '[.resource_changes[].change.actions[] | select(. == "delete")] | length' 2>/dev/null)
case "$destroys" in
  ''|*[!0-9]*) emit error; echo "::error::destroy_count 파싱 실패(plan JSON 손상)"; exit 2 ;;
esac
echo "destroy_count=$destroys" >> "$out"

if [ "$destroys" -gt 0 ]; then
  if [ "$MODE" = "block" ]; then
    emit blocked-delete
    echo "::error::tf plan에 delete/replace ${destroys}건 — 무인 apply 차단(수동 검토 후 적용)"
    exit 1
  fi
  emit ok
  echo "::warning::tf plan에 delete/replace ${destroys}건 — 머지 시 무인 apply가 차단(수동 검토 필요)"
  exit 0
fi
emit ok
exit 0
```

`.github/actions/tf-destroy-guard/action.yml`:
```yaml
# tf-destroy-guard composite — tf plan의 delete/replace를 세어 무인 apply를 가드(SSOT).
# 로직은 destroy-guard.sh(POSIX sh)에 있고 bats로 PLAN_JSON 픽스처 단위 검증한다.
# ⚠️ plan 산출(`-out=tf.plan`)은 호출 측이 먼저 수행 — 이 액션은 산출된 plan만 검사한다.
name: tf-destroy-guard
description: tf plan의 delete/replace 액션 가드(mode=block→exit1 / mode=warn→::warning::)
inputs:
  mode:    { description: "block|warn", required: false, default: "block" }
  root:    { description: "terraform -chdir 루트(예: infra/cloudflare)", required: true }
  plan:    { description: "plan 산출물 경로(루트 기준)", required: false, default: "tf.plan" }
outputs:
  result:        { description: "ok | blocked-delete | error (codex pass5 F1)", value: "${{ steps.guard.outputs.result }}" }
  destroy_count: { description: "delete 액션 수(result=error면 미설정)", value: "${{ steps.guard.outputs.destroy_count }}" }
runs:
  using: composite
  steps:
    - id: guard
      shell: sh
      env:
        MODE: ${{ inputs.mode }}
        ROOT: ${{ inputs.root }}
        PLAN: ${{ inputs.plan }}
      run: sh "$GITHUB_ACTION_PATH/destroy-guard.sh"
```

**Step 4: Run test, expect PASS**
```
bats tools/test/tf-destroy-guard.bats
```
Expected: `9 tests, 0 failures`(typed-output 2건 포함 — F1).

추가 회귀 게이트(스크립트가 shellcheck 게이트에 잡힘):
```
shellcheck .github/actions/tf-destroy-guard/destroy-guard.sh
```
Expected: 출력 없음, exit 0.

**Step 5: Commit**
```
git -C /Users/ukyi/workspace/homelab-cicd-hardening add .github/actions/tf-destroy-guard/action.yml .github/actions/tf-destroy-guard/destroy-guard.sh tools/test/tf-destroy-guard.bats && git -C /Users/ukyi/workspace/homelab-cicd-hardening commit -m "feat: tf-destroy-guard composite — tf plan destroy-count 가드 SSOT(warn|block)"
```

---

### Task 2: iac.yaml apply에 destroy 가드 삽입 + 3곳 composite 수렴 (drift-1)

**Files:**
- Modify: `.github/workflows/iac.yaml:150-153` (apply job: plan/apply 사이에 block 가드 삽입)
- Modify: `.github/workflows/iac.yaml:107-112` (iac-plan preview: 인라인 warn → composite mode=warn)
- Modify: `.github/workflows/tf-reconcile.yml:77-86` (reconcile: 인라인 block jq → composite mode=block)
- Test: `infra/_test/tf_reconcile.bats` (보강 — reconcile이 composite를 쓰는지) +
  Create: `tests/iac-destroy-guard.bats` (required gate 글롭 `tests/*.bats`로 picked up)

> **Notes:** drift-1의 핵심 회귀("primary apply 경로에 destroy 가드 부재")는 required gate에서 강제돼야 한다.
> 그래서 apply job 구조 단언은 `tests/iac-destroy-guard.bats`에 둔다(비-required `iac-validate`가 아니라).
> tf-reconcile composite 채택 단언은 기존 `infra/_test/tf_reconcile.bats`를 보강하되, 기존
> `cloudflare reconcile keeps the destroy guard` 테스트가 인라인 문자열(`무인 apply 차단`)을 찾으므로
> composite 전환에 맞춰 그 단언을 composite 참조로 갱신한다(아니면 회귀가 거짓 통과).

**Step 1: Write the failing test**

`tests/iac-destroy-guard.bats`:
```bash
#!/usr/bin/env bats
# drift-1: iac.yaml의 primary merge→apply 경로(apply job)는 plan과 apply 사이에 tf-destroy-guard
# (mode=block)를 거쳐야 한다. iac-plan preview는 동일 composite를 mode=warn으로 쓴다.
# ⚠️ bash 3.2: 중간 단언은 [ ]만. 순수 grep — terraform/cluster 비접촉(required gate-safe).

WF="$BATS_TEST_DIRNAME/../.github/workflows/iac.yaml"

@test "apply job uses tf-destroy-guard with mode=block" {
  # apply job 블록(plan→apply 사이)에 composite + block 모드가 있어야 한다.
  run grep -q 'uses: ./.github/actions/tf-destroy-guard' "$WF"
  [ "$status" -eq 0 ]
  run grep -qE 'mode:[[:space:]]*block' "$WF"
  [ "$status" -eq 0 ]
}

@test "apply job no longer applies without a guard (apply preceded by guard usage)" {
  # apply 스텝과 guard 사용이 같은 워크플로에 공존 — guard 미사용 회귀를 차단.
  run grep -c 'uses: ./.github/actions/tf-destroy-guard' "$WF"
  [ "$status" -eq 0 ]
  [ "$output" -ge 2 ]   # apply(block) + iac-plan preview(warn) 두 콜사이트
}

@test "iac-plan preview uses tf-destroy-guard mode=warn (not an inline jq block)" {
  run grep -qE 'mode:[[:space:]]*warn' "$WF"
  [ "$status" -eq 0 ]
  # 인라인 destroy jq 셀렉터는 composite로 옮겨졌어야 한다(워크플로에서 제거).
  run grep -F 'select(. == "delete")' "$WF"
  [ "$status" -ne 0 ]
}
```

기존 `infra/_test/tf_reconcile.bats`에 reconcile composite 채택 단언 추가:
```bash
@test "cloudflare reconcile uses the tf-destroy-guard composite (block) not inline jq" {
  run grep -q 'uses: ./.github/actions/tf-destroy-guard' "$WF"
  [ "$status" -eq 0 ]
  # 인라인 destroy jq가 reconcile에서 제거됐는지(composite로 수렴)
  run grep -F 'select(. == "delete")' "$WF"
  [ "$status" -ne 0 ]
}
```

**Step 2: Run it, expect FAIL**
```
bats tests/iac-destroy-guard.bats infra/_test/tf_reconcile.bats
```
Expected: `apply job uses tf-destroy-guard with mode=block` 실패 —
`grep ... uses: ./.github/actions/tf-destroy-guard` status≠0 (아직 인라인 jq). reconcile 신규 단언도
`select(. == "delete")` 가 여전히 존재해 실패. iac-plan 단언도 인라인 jq 존재로 실패.

**Step 3: Minimal implementation**

`iac.yaml` apply job — `plan → apply (분리…)` 스텝(150-153)을 plan만으로 줄이고, 사이에 가드 삽입:
```yaml
      - name: terraform plan (-out=tf.plan)
        run: terraform -chdir=infra/cloudflare plan -input=false -lock-timeout=120s -out=tf.plan
      # primary merge→apply 경로 destroy 가드 — DNS/tunnel/ruleset의 delete/replace를 무인 apply 차단.
      # (prevent_destroy R2 버킷은 plan에서 이미 막히지만, 그 외 리소스 replace=delete+create도 차단.)
      - name: destroy 가드 (block)
        uses: ./.github/actions/tf-destroy-guard
        with:
          mode: block
          root: infra/cloudflare
          plan: tf.plan
      - name: terraform apply (plan 산출물만 적용)
        run: terraform -chdir=infra/cloudflare apply -input=false tf.plan
```

`iac.yaml` iac-plan preview — 107-112의 인라인 jq warn 블록을 제거하고, plan 스텝 뒤 별도 스텝으로:
```yaml
      # plan.txt를 STEP_SUMMARY에 게시하는 기존 스텝은 그대로(rc 0/2/* 처리 유지),
      # 인라인 destroy jq 경고만 composite로 치환한다.
      - name: destroy 사전 경고 (warn)
        if: steps.pf.outputs.configured == 'true'
        uses: ./.github/actions/tf-destroy-guard
        with:
          mode: warn
          root: infra/cloudflare
          plan: tf.plan
```
그리고 기존 plan 스텝 안의 `if [ "$rc" = "2" ]; then destroys=$(... select(. == "delete") ...); ... ::warning:: ... fi`
블록(108-112)을 삭제한다(composite로 이관). plan 스텝은 `-out=tf.plan`을 이미 산출하므로(93줄) composite가
그 산출물을 읽는다.

`tf-reconcile.yml` reconcile — 77-86의 인라인 destroy jq를 composite로 치환. case `2)` 분기 구조상
plan(`-out=tf.plan`) 직후 별도 스텝으로 가드를 두고, apply는 drift=true일 때만 수행하도록 재구성:
```yaml
      - name: drift 감지 (plan -out=tf.plan)
        id: drift
        run: |
          set +e
          terraform -chdir=infra/cloudflare plan -input=false -lock-timeout=120s \
            -detailed-exitcode -out=tf.plan
          rc=$?
          set -e
          case "$rc" in
            0) echo "drift=false" >> "$GITHUB_OUTPUT"; echo "드리프트 없음 — no-op" ;;
            2) echo "drift=true" >> "$GITHUB_OUTPUT" ;;
            *) exit "$rc" ;;
          esac
      # destroy/replace가 있으면 무인 apply 금지 — DR/배포 자산 보호. composite가 ::error::+exit1.
      - name: destroy 가드 (block)
        if: steps.drift.outputs.drift == 'true'
        uses: ./.github/actions/tf-destroy-guard
        with:
          mode: block
          root: infra/cloudflare
          plan: tf.plan
      - name: apply (드리프트 + 가드 통과 시에만)
        if: steps.drift.outputs.drift == 'true'
        run: terraform -chdir=infra/cloudflare apply -input=false tf.plan
```

기존 `infra/_test/tf_reconcile.bats`의 `cloudflare reconcile keeps the destroy guard` 테스트는 인라인
문자열(`무인 apply 차단`)을 찾으므로, composite 전환에 맞춰 갱신:
```bash
@test "cloudflare reconcile keeps the destroy guard" {
  run grep -q 'uses: ./.github/actions/tf-destroy-guard' "$WF"
  [ "$status" -eq 0 ]
  run grep -qE 'chdir=infra/cloudflare apply' "$WF"
  [ "$status" -eq 0 ]
}
```

**Step 4: Run test, expect PASS**
```
bats tests/iac-destroy-guard.bats infra/_test/tf_reconcile.bats
```
Expected: 두 파일 합쳐 모든 테스트 `0 failures`.
워크플로 문법 회귀 방지로 actionlint(있으면)도 통과해야 한다(아래는 선택):
```
command -v actionlint >/dev/null && actionlint .github/workflows/iac.yaml .github/workflows/tf-reconcile.yml || true
```

**Step 5: Commit**
```
git -C /Users/ukyi/workspace/homelab-cicd-hardening add .github/workflows/iac.yaml .github/workflows/tf-reconcile.yml tests/iac-destroy-guard.bats infra/_test/tf_reconcile.bats && git -C /Users/ukyi/workspace/homelab-cicd-hardening commit -m "fix: iac.yaml apply에 destroy 가드 삽입 + 3곳을 tf-destroy-guard composite로 수렴"
```

---

### Task 3: Cloudflare 무료 플랜 entitlement 정적 게이트 (drift-5)

**Files:**
- Create: `tests/cloudflare-entitlement.bats` (required gate 글롭 `tests/*.bats`로 picked up)
- Modify: `Makefile:101` `ci` 타겟 (이미 `tests/*.bats` 글롭 포함 — 추가 배선 불필요, 확인만)

> **Notes:** `infra/cloudflare/waf.tf`·`cache.tf` 구조 그대로 단언한다 — waf.tf의 ratelimit `period = 10` /
> `mitigation_timeout = 10`(무료 유일 허용), 모든 ruleset 식에 `matches(` 정규식 연산자 금지(Business 전용 →
> apply에서 400). 현재는 코드 주석으로만 강제 → bad value가 gate+plan을 통과하고 apply 400 후 tf-reconcile이
> 30분마다 스팸. `tests/`에 둬 required gate가 강제한다(`infra/_test/`는 비-required라 무효).

**Step 1: Write the failing test**

`tests/cloudflare-entitlement.bats`:
```bash
#!/usr/bin/env bats
# drift-5: Cloudflare 무료 플랜 entitlement를 정적 강제(현재는 주석 + apply-time 400으로만 드러남).
#  - rate-limit period == 10 && mitigation_timeout == 10 (무료 유일 허용값)
#  - 모든 ruleset 식에 matches( 정규식 연산자 금지(Business/WAF Advanced 전용 → 400 "not entitled")
# ⚠️ bash 3.2: 중간 단언은 [ ]만. 순수 grep — terraform/cluster 비접촉(required gate-safe).

WAF="$BATS_TEST_DIRNAME/../infra/cloudflare/waf.tf"
CACHE="$BATS_TEST_DIRNAME/../infra/cloudflare/cache.tf"

@test "waf ratelimit period is exactly 10 (free-plan only value)" {
  run grep -cE '^[[:space:]]*period[[:space:]]*=[[:space:]]*10([[:space:]]|$|#)' "$WAF"
  [ "$status" -eq 0 ]
  [ "$output" -eq 1 ]
}

@test "waf ratelimit mitigation_timeout is exactly 10 (free-plan only value)" {
  run grep -cE '^[[:space:]]*mitigation_timeout[[:space:]]*=[[:space:]]*10([[:space:]]|$|#)' "$WAF"
  [ "$status" -eq 0 ]
  [ "$output" -eq 1 ]
}

@test "waf has no non-10 period (catches drift to 60/300/etc)" {
  # period = <10이 아닌 숫자>를 찾으면 실패. (100=requests_per_period라 'period ='로 앵커)
  run grep -nE '^[[:space:]]*period[[:space:]]*=[[:space:]]*[0-9]+' "$WAF"
  [ "$status" -eq 0 ]
  run grep -nE '^[[:space:]]*period[[:space:]]*=[[:space:]]*(10([[:space:]]|$|#))' "$WAF"
  # 모든 period 라인이 10이어야: 전체 period 라인 수 == 10인 period 라인 수
  total="$(grep -cE '^[[:space:]]*period[[:space:]]*=[[:space:]]*[0-9]+' "$WAF")"
  tens="$(grep -cE '^[[:space:]]*period[[:space:]]*=[[:space:]]*10([[:space:]]|$|#)' "$WAF")"
  [ "$total" -eq "$tens" ]
}

@test "no matches( regex operator in any cloudflare ruleset expression" {
  # matches(는 Business/WAF Advanced 전용 — 무료 플랜 apply 400. waf.tf/cache.tf 양쪽 금지.
  run grep -nE 'matches[[:space:]]*\(' "$WAF" "$CACHE"
  [ "$status" -ne 0 ]
}

@test "ratelimit characteristics include the mandatory cf.colo.id" {
  # 무료 rate-limit는 ip.src + cf.colo.id 필수(누락 시 apply 400) — entitlement 인접 가드.
  run grep -qE 'characteristics[[:space:]]*=.*cf\.colo\.id' "$WAF"
  [ "$status" -eq 0 ]
}
```

**Step 2: Run it, expect FAIL (먼저 위반을 주입해 가드가 동작함을 증명)**

가드가 진짜 잡는지 보이기 위해 임시로 위반을 만들고 FAIL을 확인한다(원복 후 PASS):
```
# period를 60으로 변조한 사본으로 가드 동작 증명
cp infra/cloudflare/waf.tf /tmp/waf.bak
sed 's/period              = 10/period              = 60/' /tmp/waf.bak > /tmp/waf.tf
# 테스트가 레포 파일을 보므로, 가드 자체의 FAIL은 신규 .bats를 먼저 추가하기 전 상태에서 확인:
bats tests/cloudflare-entitlement.bats
```
신규 파일 추가 직후 첫 실행은 **현재 waf.tf/cache.tf가 이미 적법**하므로 PASS한다. 가드가 위반을 잡는지는
다음으로 증명:
```
sed -i.bak 's/^\([[:space:]]*period[[:space:]]*=[[:space:]]*\)10/\160/' infra/cloudflare/waf.tf
bats tests/cloudflare-entitlement.bats
```
Expected FAIL: `waf ratelimit period is exactly 10` 와 `waf has no non-10 period` 가 실패
(`expected 1, got 0` / `total != tens`). 확인 후 원복:
```
mv infra/cloudflare/waf.tf.bak infra/cloudflare/waf.tf
```

**Step 3: Minimal implementation**

코드 변경 없음 — `tests/cloudflare-entitlement.bats`가 곧 구현(현재 `waf.tf`/`cache.tf`가 이미 적법:
`period = 10`, `mitigation_timeout = 10`, `matches(` 없음). 이 단계는 정적 회귀 가드를 **추가**해
향후 드리프트(60/300, matches 도입)를 required gate에서 차단하는 것). `make ci`/`gate`의 `tests/*.bats`
글롭이 자동 포함하므로 추가 배선 불필요 — 확인만 한다.

**Step 4: Run test, expect PASS**
```
bats tests/cloudflare-entitlement.bats
```
Expected: `5 tests, 0 failures`.

required gate 글롭 포함 확인(배선 누락 회귀 방지):
```
ls tests/*.bats | grep -q 'cloudflare-entitlement.bats' && echo "gate glob includes entitlement bats"
```
Expected: `gate glob includes entitlement bats`.

**Step 5: Commit**
```
git -C /Users/ukyi/workspace/homelab-cicd-hardening add tests/cloudflare-entitlement.bats && git -C /Users/ukyi/workspace/homelab-cicd-hardening commit -m "test: Cloudflare 무료 플랜 entitlement 정적 게이트(period/mitigation==10·matches 금지)"
```

---

### Task 4: reconcile destroy 가드를 alert-and-skip로 완화 (drift-2)

**Files:**
- Modify: `.github/workflows/tf-reconcile.yml` (reconcile job: delete 발견 시 hard-exit → ::warning:: + telegram, **apply 전체 skip[원자적]**, 잡은 생존; owner 로컬 apply 후 다음 주기 수렴)
- Test: `infra/_test/tf_reconcile.bats` (보강) + `tests/iac-destroy-guard.bats` (drift-2 구조 단언 추가)
- (런북 노트: live-DNS 수렴 체크는 별도 경량 옵션으로 명시 — CI 비접촉)

> **Notes — drift-2 설계 선택(더 단순·견고한 옵션 채택 + 정당화):**
> 두 대안 — (A) "main 커밋된 예상 삭제 vs 드리프트 삭제 구분", (B) "alert-and-skip(delete면 ::warning::+telegram
> → owner 로컬 apply, reconcile 잡은 죽이지 않음)". **(B)를 채택**한다. (A)는 plan의 delete를 "git에 커밋된 의도된
> teardown"과 매핑하려면 apps.json/dns.tf ↔ plan resource address 양방향 대조가 필요해 CI에서 무겁고 깨지기
> 쉽다(replace=delete+create 구분, address 정규화). (B)는 Task 1의 `tf-destroy-guard mode=block`이 이미 정확히
> "delete면 멈춤"을 하므로, reconcile에서 그 exit를 **잡 실패가 아니라 알림**으로 강등하면 된다.
>
> ⚠️ **codex pass3 F3 — 원자성 정직(부분 수렴 불가):** terraform saved-plan(`apply tf.plan`)은 **원자적**이라
> delete만 빼고 적용할 수 없다. 따라서 "alert-and-skip"이 보존하는 건 **reconcile 잡의 생존**(빨개지지 않아 다른
> 루트 drift 잡·다음 주기가 계속 돈다)이지 **같은 plan 안의 비-delete 부분 수렴이 아니다** — delete가 하나라도
> 있으면 그 plan의 **apply 전체를 skip**하므로 co-pending 비-delete 변경도 owner 로컬 apply까지 **함께 대기**한다.
> 이는 **의도된 DR-safety tradeoff**다: delete는 DR/배포 자산을 건드리므로 owner 검토를 강제하고, 그 비용으로
> co-pending 비-delete 변경이 대기한다(홈랩 변경 빈도에선 수용 가능). owner가 로컬 `terraform apply`로 delete를
> 수렴하면 **다음 주기**에 나머지가 수렴한다. 핵심 버그(합법 teardown의 push-apply 취소로 30분마다 잡이 영구
> red)는 (B)로 해소된다(잡이 안 죽음). iac.yaml apply(primary)는 여전히 block(Task 2) — 무인 delete 차단 유지.
> **운영 규약:** delete를 포함하는 cloudflare 변경은 무관한 DNS 변경과 같은 머지 창에 섞지 말 것(섞이면 함께 동결).
> **live-DNS 수렴 체크**는 Task 5에서 커밋된 opt-in 워크플로로 별도 제공(클러스터리스 gate와 분리).

**Step 1: Write the failing test**

`infra/_test/tf_reconcile.bats` 보강:
```bash
@test "reconcile delete guard is alert-and-skip (does not hard-fail the job on delete)" {
  # drift-2: delete가 있어도 reconcile job 자체는 실패시키지 않는다(::warning:: + telegram). ⚠️ F3: saved-plan
  # apply는 원자적이라 delete 포함 시 apply 전체가 skip되며(부분 수렴 불가), owner 로컬 apply 후 다음 주기에 수렴.
  # 즉 reconcile 경로엔 'exit 1'로 잡을 죽이는 인라인 destroy 분기가 없어야 한다(가드는 continue-on-error로 강등).
  run grep -nE '무인 apply 차단.*exit 1|exit 1[[:space:]]*#.*destroy' "$WF"
  [ "$status" -ne 0 ]
}

@test "reconcile guard step is continue-on-error and emits a warning (not job failure)" {
  run grep -qE 'continue-on-error:[[:space:]]*true' "$WF"
  [ "$status" -eq 0 ]
}

@test "reconcile telegram fires on delete-blocked drift (owner-local apply nudge)" {
  # delete 차단 시에도 telegram이 발화하도록 알림 조건이 guard result(blocked-delete)를 포함해야 한다.
  run grep -qE "guard|blocked-delete|result" "$WF"
  [ "$status" -eq 0 ]
}

@test "reconcile apply gates on guard result==ok and fails the job on result==error (F1)" {
  # ⚠️ codex pass5 F1: outcome은 delete-block과 내부 오류를 구분 못 한다 — apply는 result=='ok'에서만,
  # result=='error'(가드 자체 깨짐)는 잡을 loud 실패시켜야(조용한 skip 금지).
  run grep -qE "steps\.guard\.outputs\.result == 'ok'" "$WF"
  [ "$status" -eq 0 ]
  run grep -qE "steps\.guard\.outputs\.result == 'error'" "$WF"
  [ "$status" -eq 0 ]
}
```

`tests/iac-destroy-guard.bats`에 drift-2 분리 불변식 추가:
```bash
@test "iac.yaml primary apply guard stays block (drift-2 alert-and-skip is reconcile-only)" {
  # primary apply(iac.yaml)는 alert-and-skip로 완화하지 않는다 — 무인 delete는 여기서 끝까지 막힌다.
  run grep -qE 'mode:[[:space:]]*block' "$WF"
  [ "$status" -eq 0 ]
  run grep -qE 'continue-on-error:[[:space:]]*true' "$WF"
  [ "$status" -ne 0 ]   # iac.yaml apply 경로엔 continue-on-error 없음
}
```

**Step 2: Run it, expect FAIL**
```
bats infra/_test/tf_reconcile.bats tests/iac-destroy-guard.bats
```
Expected: `reconcile guard step is continue-on-error and emits a warning` 실패 —
`continue-on-error: true` 가 tf-reconcile.yml에 아직 없어 status≠0. `reconcile telegram fires on
delete-blocked drift`도 `guard|outcome` 미존재로 실패.

**Step 3: Minimal implementation**

`tf-reconcile.yml` reconcile job — Task 2에서 만든 가드 스텝을 `continue-on-error: true` + `id`로 바꾸고,
delete 차단(=가드 실패)이면 apply를 건너뛰되 telegram으로 알린다:
```yaml
      - name: drift 감지 (plan -out=tf.plan)
        id: drift
        run: |
          set +e
          terraform -chdir=infra/cloudflare plan -input=false -lock-timeout=120s \
            -detailed-exitcode -out=tf.plan
          rc=$?
          set -e
          case "$rc" in
            0) echo "drift=false" >> "$GITHUB_OUTPUT"; echo "드리프트 없음 — no-op" ;;
            2) echo "drift=true" >> "$GITHUB_OUTPUT" ;;
            *) exit "$rc" ;;
          esac
      # drift-2: delete/replace는 무인 apply 금지하되 reconcile 잡은 죽이지 않는다(alert-and-skip) —
      # 합법 teardown(push-apply 취소)이 30분마다 잡을 영구 red로 만드는 것을 막는다. ⚠️ F3: 원자적이라 delete
      # 포함 시 비-delete도 함께 대기. ⚠️ codex pass5 F1: outcome이 아니라 가드의 **typed output**으로 분기 —
      # result=='ok'만 apply, 'blocked-delete'면 alert-and-skip, 'error'(가드 자체 깨짐)면 잡을 loud 실패.
      - name: destroy 가드 (block, alert-and-skip)
        id: guard
        if: steps.drift.outputs.drift == 'true'
        continue-on-error: true
        uses: ./.github/actions/tf-destroy-guard
        with:
          mode: block
          root: infra/cloudflare
          plan: tf.plan
      # codex pass5 F1: 가드 내부 오류(plan 손상·jq 부재 등)는 delete 차단과 다르다 — 조용히 skip하지 말고 잡 실패.
      - name: 가드 내부 오류면 잡 실패 (delete 차단과 구분)
        if: steps.drift.outputs.drift == 'true' && steps.guard.outputs.result == 'error'
        run: |
          echo "::error::tf-destroy-guard 내부 오류(result=error) — 가드 신뢰 불가, reconcile 잡 실패시켜 가시화"
          exit 1
      - name: apply (드리프트 + 가드 result=ok일 때만)
        if: steps.drift.outputs.drift == 'true' && steps.guard.outputs.result == 'ok'
        run: terraform -chdir=infra/cloudflare apply -input=false tf.plan
```

그리고 기존 telegram 스텝(89-99)의 조건/상태를 가드 차단까지 포괄하도록 갱신:
```yaml
      - name: telegram notify (수렴/실패/delete-차단 시에만)
        if: failure() || steps.drift.outputs.drift == 'true'
        uses: ./.github/actions/telegram-notify
        with:
          status: ${{ steps.guard.outputs.result == 'blocked-delete' && 'drift' || (job.status == 'success' && steps.drift.outputs.drift == 'true' && 'drift' || job.status) }}
          source: IaC수렴
          title: IaC 수렴
          ident: "drift=${{ steps.drift.outputs.drift }} guard=${{ steps.guard.outputs.result }} (blocked-delete면 owner 로컬 apply)"
          link: ${{ github.server_url }}/${{ github.repository }}/actions/runs/${{ github.run_id }}
          bot-token: ${{ secrets.TELEGRAM_BOT_TOKEN }}
          chat-id: ${{ secrets.TELEGRAM_CHAT_ID }}
```

**Step 4: Run test, expect PASS**
```
bats infra/_test/tf_reconcile.bats tests/iac-destroy-guard.bats
```
Expected: 두 파일 모두 `0 failures`. (iac.yaml apply 경로엔 `continue-on-error` 없음 → drift-2 분리 불변식 PASS.)

선택 워크플로 문법 점검:
```
command -v actionlint >/dev/null && actionlint .github/workflows/tf-reconcile.yml || true
```

**Step 5: Commit**
```
git -C /Users/ukyi/workspace/homelab-cicd-hardening add .github/workflows/tf-reconcile.yml infra/_test/tf_reconcile.bats tests/iac-destroy-guard.bats && git -C /Users/ukyi/workspace/homelab-cicd-hardening commit -m "fix: tf-reconcile destroy 가드를 alert-and-skip로 — 합법 teardown 영구 차단 해소"
```

---

### Task 5: live-DNS 수렴 체커 — 커밋된 opt-in 스케줄 워크플로 (drift-2 잔여)

> ⚠️ codex pass2 F9: 기존안은 "라이브 호출 없음"을 단언하는 주석/테스트만 둬서, drift-2가 이름붙인 갭(apply
> 실패로 active:true host의 DNS가 안 생긴 경우)을 잡는 **실행체가 0**이었다(documented away). 대신 **커밋된
> opt-in 체커**를 둔다: active&&public host가 실제 resolve되는지 확인하고 NXDOMAIN이면 telegram 드리프트 알림.
> 라이브 DNS 호출은 이 워크플로 안에서만(required gate는 여전히 클러스터리스) — preflight로 active&&public이
> 0이면 skip(깨끗한 성공). 체커 로직은 resolver 주입으로 fixture 테스트(라이브 무관).

**Files:**
- Create: `tools/dns-drift-check.mjs` (resolver 주입 — 라이브는 node:dns, 테스트는 --fixture)
- Create: `.github/workflows/dns-drift.yml` (스케줄 opt-in, preflight skip, checkout→체커→telegram)
- Create (test): `tools/test/dns-drift-check.bats` (fixture resolver: NXDOMAIN→drift / 전부 resolve→무드리프트)

> ⚠️ 횡단 조정: `dns-drift.yml`은 `./.github/actions/telegram-notify`를 쓰는 **새 콜사이트**다 — checkout이
> 선행한다(F8 가드 충족). telegram-callsites.bats의 "exactly N workflows" 카운트는 dns-drift(Phase 3)·
> pr-sweeper(Phase 6)·build.yaml(Phase 8)를 모두 포함해야 한다(Phase 6 Task 5 enum 갱신 시 dns-drift 포함).

**Step 1: Write the failing test** — `tools/test/dns-drift-check.bats`:
```bash
#!/usr/bin/env bats
# drift-2: active&&public host가 실제로 resolve되는지(apply 누락으로 DNS 미생성인지) 확인.
# resolver 주입(--fixture)으로 라이브 DNS 없이 fixture 검증. @test 영어, 중간 단언 [ ].
setup() { ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"; }

@test "reports drift for an active and public host that does not resolve (NXDOMAIN)" {
  d="$BATS_TEST_TMPDIR"
  printf '[{"name":"blog","host":"blog.ukyi.app","public":true,"active":true},{"name":"draft","host":"draft.ukyi.app","public":false,"active":true},{"name":"old","host":"old.ukyi.app","public":true,"active":false}]\n' > "$d/apps.json"
  # fixture: blog는 NXDOMAIN(null). draft(public:false)·old(active:false)는 검사 대상 아님.
  out=$(node "$ROOT/tools/dns-drift-check.mjs" --apps "$d/apps.json" --fixture '{"blog.ukyi.app":null}')
  echo "$out" | jq -e '.drift[] | select(.host=="blog.ukyi.app" and (.reason|test("NXDOMAIN")))'
  echo "$out" | jq -e '.drift | length == 1'
  echo "$out" | jq -e '.transient | length == 0'
  ! echo "$out" | grep -q 'draft.ukyi.app'
  ! echo "$out" | grep -q 'old.ukyi.app'
}

@test "reports no drift when every active and public host resolves" {
  d="$BATS_TEST_TMPDIR"
  printf '[{"name":"blog","host":"blog.ukyi.app","public":true,"active":true}]\n' > "$d/apps.json"
  out=$(node "$ROOT/tools/dns-drift-check.mjs" --apps "$d/apps.json" --fixture '{"blog.ukyi.app":["104.21.0.1"]}')
  echo "$out" | jq -e '.drift | length == 0'
  echo "$out" | jq -e '.transient | length == 0'
}

@test "a transient resolver failure (SERVFAIL/timeout) is NOT counted as drift (F3 tri-state)" {
  # ⚠️ codex pass4 F3: transient는 NXDOMAIN과 구분 — drift 버킷이 아니라 transient 버킷에 들어가야 한다.
  d="$BATS_TEST_TMPDIR"
  printf '[{"name":"blog","host":"blog.ukyi.app","public":true,"active":true}]\n' > "$d/apps.json"
  out=$(node "$ROOT/tools/dns-drift-check.mjs" --apps "$d/apps.json" --fixture '{"blog.ukyi.app":"TRANSIENT"}')
  echo "$out" | jq -e '.drift | length == 0'
  echo "$out" | jq -e '.transient[] | select(.host=="blog.ukyi.app")'
}
```

**Step 2: Run it, expect FAIL** — `bats tools/test/dns-drift-check.bats`
기대 실패: `tools/dns-drift-check.mjs` 부재로 node가 `MODULE_NOT_FOUND`(실행 불가)로 세 케이스 모두 실패.

**Step 3: Minimal implementation** — `tools/dns-drift-check.mjs`:
```js
#!/usr/bin/env node
// active&&public host가 실제로 resolve되는지 확인 — apply 실패로 DNS가 안 생긴 경우(active:true인데 미노출)를
// 잡는다. Cloudflare proxied 레코드는 anycast IP로 뜨므로 "resolve=레코드 존재, NXDOMAIN=미생성"으로 본다.
// resolver는 주입 가능: 라이브는 node:dns, 테스트는 --fixture(host→records|null) JSON.
import { readFileSync } from "node:fs";
import { promises as dnsp } from "node:dns";

const arg = (k) => { const i = process.argv.indexOf(k); return i > -1 ? process.argv[i + 1] : undefined; };
const appsPath = arg("--apps") ?? "infra/cloudflare/apps.json";
const fixture = arg("--fixture");

// resolver: host → 배열(존재) | null(NXDOMAIN) | undefined(transient: SERVFAIL/timeout)
let resolve;
if (fixture !== undefined) {
  const map = JSON.parse(fixture);
  // 테스트용 sentinel: 값이 "TRANSIENT" 문자열이면 undefined(일시 실패)로 매핑(JSON엔 undefined가 없으므로).
  resolve = async (h) => {
    if (!Object.prototype.hasOwnProperty.call(map, h)) return null;
    const v = map[h];
    return v === "TRANSIENT" ? undefined : v;
  };
} else {
  resolve = async (h) => {
    try { return await dnsp.resolve(h); }                 // A/AAAA — proxied면 Cloudflare anycast IP
    catch (e) {
      if (e.code === "ENOTFOUND" || e.code === "ENODATA") return null;  // 레코드 없음(미생성)
      return undefined;                                    // transient(SERVFAIL/timeout) — drift 단정 불가
    }
  };
}

const registry = JSON.parse(readFileSync(appsPath, "utf8"));
const drift = [];       // NXDOMAIN — active:true인데 DNS 레코드 미존재(apply 누락). 이것만 drift로 센다.
const transient = [];   // ⚠️ codex pass4 F3: SERVFAIL/timeout/저하된 resolver — drift로 단정 불가(별도 버킷)
for (const r of registry) {
  if (!(r.public && r.active)) continue;                   // dns.tf는 public&&active만 노출
  const recs = await resolve(r.host);
  if (recs === null) drift.push({ host: r.host, name: r.name, reason: "NXDOMAIN — active:true인데 DNS 레코드 미존재(apply 누락 의심)" });
  else if (recs === undefined) transient.push({ host: r.host, name: r.name, reason: "resolve 일시 실패(SERVFAIL/timeout) — drift 아님, 재확인 필요" });
}
// drift와 transient 분리 출력 — 워크플로는 .drift.length만 drift 알림으로(transient는 별도 경고).
console.log(JSON.stringify({ drift, transient }, null, 2));
```

**Step 4: Run test, expect PASS** — `bats tools/test/dns-drift-check.bats` → `3 tests, 0 failures`(NXDOMAIN→drift / 전부 resolve→무 / transient→별도 버킷).

**Step 5: 워크플로 + Commit** — `.github/workflows/dns-drift.yml`:
```yaml
# active&&public host의 라이브 DNS resolve 체크 (drift-2 잔여, opt-in 스케줄). apply 실패로 active:true인데
# DNS가 안 생긴 경우를 잡는다. 라이브 DNS 호출은 이 워크플로 안에서만 — required gate는 클러스터리스 유지.
name: dns-drift
on:
  schedule:
    - cron: "23 */6 * * *"   # 6시간마다(DNS는 자주 안 변함)
  workflow_dispatch: {}
permissions:
  contents: read
concurrency:
  group: dns-drift
  cancel-in-progress: true
jobs:
  check:
    runs-on: ubuntu-24.04-arm
    steps:
      - uses: actions/checkout@v4        # 로컬 telegram-notify 액션 resolve + 체커 실행(F8 가드 충족)
      - uses: actions/setup-node@v4
        with: { node-version: "22" }
      - id: pf   # active&&public이 0이면 skip(깨끗한 성공)
        run: |
          n=$(node -e 'const a=JSON.parse(require("fs").readFileSync("infra/cloudflare/apps.json","utf8"));process.stdout.write(String(a.filter(r=>r.public&&r.active).length))')
          if [ "$n" -gt 0 ]; then echo "go=true" >> "$GITHUB_OUTPUT"; else echo "go=false" >> "$GITHUB_OUTPUT"; echo "::notice::active&&public 0 — dns-drift skip"; fi
      - id: check
        if: steps.pf.outputs.go == 'true'
        run: |
          node tools/dns-drift-check.mjs --apps infra/cloudflare/apps.json > /tmp/drift.json
          # ⚠️ codex pass4 F3: drift 알림은 .drift(NXDOMAIN)만 센다 — transient(SERVFAIL/timeout)는 거짓 알림 방지.
          n=$(node -e 'const o=JSON.parse(require("fs").readFileSync("/tmp/drift.json","utf8"));process.stdout.write(String(o.drift.length))')
          t=$(node -e 'const o=JSON.parse(require("fs").readFileSync("/tmp/drift.json","utf8"));process.stdout.write(String(o.transient.length))')
          echo "count=$n" >> "$GITHUB_OUTPUT"
          echo "transient=$t" >> "$GITHUB_OUTPUT"
          [ "$t" -gt 0 ] && echo "::warning::DNS resolve 일시 실패 ${t}건(transient — drift 아님, 재확인)"
          cat /tmp/drift.json
      - name: telegram notify (드리프트/실패 시에만)
        if: steps.pf.outputs.go == 'true' && (failure() || steps.check.outputs.count != '0')
        uses: ./.github/actions/telegram-notify
        with:
          status: ${{ steps.check.outputs.count != '0' && 'drift' || job.status }}
          source: IaC드리프트
          title: DNS 드리프트
          ident: "active&&public host 미해결 ${{ steps.check.outputs.count }}건"
          link: ${{ github.server_url }}/${{ github.repository }}/actions/runs/${{ github.run_id }}
          bot-token: ${{ secrets.TELEGRAM_BOT_TOKEN }}
          chat-id: ${{ secrets.TELEGRAM_CHAT_ID }}
```
커밋:
```
git -C /Users/ukyi/workspace/homelab-cicd-hardening add tools/dns-drift-check.mjs .github/workflows/dns-drift.yml tools/test/dns-drift-check.bats && git -C /Users/ukyi/workspace/homelab-cicd-hardening commit -m "feat: live-DNS 드리프트 체커 + opt-in 스케줄 워크플로 (drift-2 — active&&public host 미해결 감지)"
```

---

### Phase 종료 게이트 (전체 회귀 확인)

이 단계 머지 전 로컬에서 required gate를 그대로 재현:
```
make ci
```
Expected: 신규 `tools/test/tf-destroy-guard.bats`(글롭)·`tests/cloudflare-entitlement.bats`·
`tests/iac-destroy-guard.bats`·`tests/iac-live-dns-note.bats`(글롭) + 갱신된 `shellcheck`(destroy-guard.sh) 포함
전 스텝 통과, exit 0. `iac-validate`의 `infra/_test/tf_reconcile.bats`도 PR(iac.yaml paths) 시 통과.

---

## Phase 4 — secret-guard 강제 + 분기보호 불변식 (P0)

> **테마**: 시크릿 누출 방지 가드(gitleaks + sops-guard)가 PR 게이트에 **강제되지 않는** 갭과,
> 그 가드 자체의 우회 가능 로직, 그리고 분기보호 불변식의 무인 relaxation 위험을 닫는다.
>
> **배경 사실(라이브 확인됨)**: required check는 `gate`(ci.yaml의 잡) 단일이다 — `verify`(verify.yml,
> gitleaks + sops 라운드트립 보유)는 PR에서 돌지만 required가 아니라, gitleaks를 통과 못 한 PR도
> `gate`만 green이면 머지 가능하다. `gate` 잡은 `setup-toolchain`에서 이미 `yq: 'true'`를 켜므로(ci.yaml:24-32)
> sops-guard의 yq 검증이 그대로 동작한다. 분기보호는 `contexts=["gate"]`·`strict=true`·`enforce_admins=false`
> (gh api로 라이브 확인). 게이트 러너는 `ubuntu-24.04-arm`(arm64)이라 gitleaks 자산은 `gitleaks_8.18.4_linux_arm64.tar.gz`.
>
> **공유 인프라**: 이 단계는 새 composite/lib를 만들지 않는다. supplychain-7의 새 bats는 기존
> `tests/sops-guard.bats`를 확장하고(이 파일은 `make ci`/로컬에서 실행되며 실 age 키 의존 케이스가
> 있어 `gate` 글롭에서는 명시 제외됨 — ci.yaml:58의 `sops-guard.bats` 제외 참고), supplychain-1의
> 새 bats는 `infra/_test/`에 추가해 iac.yaml의 기존 infra/_test 호출 블록(iac.yaml:37-42)에 배선한다.

---

### Task 1: sops-guard.sh substring grep → 구조화 yq 검증 (supplychain-7)

`scripts/sops-guard.sh:7`은 `grep -q 'sops_mac\|"sops":'` 부분문자열 매칭이라, 평문 `*.enc.yaml`에
`# sops_mac` 같은 데코이 토큰만 있으면 통과한다(실측 확인됨). 실제 sops 구조(`.sops.mac` +
`.sops.lastmodified` 존재)와 **data/stringData 리프가 전부 `ENC[...]`인지**를 yq로 검증한다.
실 age 키 복호 없이 게이트 러너(yq만 보유)에서 동작한다.

> ⚠️ codex pass3 F2 — **범위 한정(integrity 아님)**: 이 구조 가드는 **평문/데코이 enc.yaml 차단용 tripwire**이지
> SOPS **integrity 게이트가 아니다**. broken MAC·잘못된 recipient·복호 불가 암호문은 못 잡는다(완전 검증은 age
> private key가 필요한데 게이트는 의도적으로 keyless — 보안 모델). 실제 무결성은 **(a)** owner-local 작성 규율
> (`make secret-edit`이 복호→편집→재암호화로 항상 유효 MAC 생성, AGENTS.md "*.enc.yaml 직접 수정 금지") **(b)**
> `verify` 잡의 sops-roundtrip(ephemeral 키)으로 보장한다. **추가 가드:** `*.enc.yaml` **변경**이 포함된 PR은
> auto-merge 전에 **owner-local `sops --decrypt`(또는 KSOPS 풀 렌더 `make render COMP=<x>`)로 복호 가능성을
> 검증**한다(런북에 명시) — 구조 가드를 integrity 게이트로 과대포장하지 않는다.

**Files:**
- Modify: `scripts/sops-guard.sh` (전면 재작성)
- Test: `tests/sops-guard.bats` (기존 3 케이스 유지 + 데코이 우회 회귀 케이스 추가)

**Step 1: Write the failing test** — `tests/sops-guard.bats`에 데코이 케이스를 추가한다(기존 setup/teardown 재사용).

```bash
@test "guard BLOCKS a plaintext *.enc.yaml carrying a sops_mac decoy token" {
  # 부분문자열 grep 우회: 평문인데 'sops_mac' 리터럴만 박힌 파일은 차단돼야 한다.
  cat > apps/_guardtest/prod/decoy.enc.yaml <<'YAML'
apiVersion: v1
kind: Secret
metadata:
  name: evil
stringData:
  TOKEN: super-secret-plaintext
# sops_mac
YAML
  run ./scripts/sops-guard.sh apps/_guardtest/prod/decoy.enc.yaml
  [ "$status" -eq 1 ]
  echo "$output" | grep -q 'BLOCKED'
}

@test "guard BLOCKS a file with sops metadata but a plaintext data leaf (partial enc)" {
  # sops 블록은 있으나 stringData 리프가 평문이면 차단(부분 암호화 누출 방지).
  cp tests/fixtures/sample-secret.yaml apps/_guardtest/prod/partial.enc.yaml
  sops --encrypt --in-place apps/_guardtest/prod/partial.enc.yaml
  # 암호화 후 한 리프를 평문으로 되돌린다(누출 시뮬레이션).
  yq -i '.stringData.URL = "postgres://user:pw@db:5432/app"' apps/_guardtest/prod/partial.enc.yaml
  run ./scripts/sops-guard.sh apps/_guardtest/prod/partial.enc.yaml
  [ "$status" -eq 1 ]
  echo "$output" | grep -q 'BLOCKED'
}
```

**Step 2: Run it, expect FAIL**

```bash
bats tests/sops-guard.bats
```
기대 실패: 현재 guard는 `# sops_mac` 데코이를 부분문자열로 통과시킨다 →
`guard BLOCKS a plaintext *.enc.yaml carrying a sops_mac decoy token` 케이스가
`expected 1, got 0`으로 실패(`✗ ... carrying a sops_mac decoy token`). partial 케이스도 `status 0`으로 실패.

**Step 3: Minimal implementation** — `scripts/sops-guard.sh` 전면 재작성:

```bash
#!/usr/bin/env bash
# *.enc.yaml이 실제로 SOPS 암호화됐는지 구조적으로 검증한다.
# 부분문자열 grep(데코이 우회 가능)이 아니라:
#  1) sops 메타데이터 블록(.sops.mac + .sops.lastmodified)이 존재하고
#  2) data/stringData 리프가 전부 ENC[...] 형태(평문 리프 0건)인지 확인.
# 실 age 키 복호는 필요 없다(yq만 있으면 게이트 러너에서 동작).
set -euo pipefail

if ! command -v yq >/dev/null 2>&1; then
  echo "sops-guard: yq가 필요하다(설치 후 재시도)." >&2
  exit 2
fi

rc=0
for f in "$@"; do
  case "$f" in
    *.enc.yaml)
      reason=""
      if ! yq -e '.sops.mac' "$f" >/dev/null 2>&1; then
        reason="no sops.mac"
      elif ! yq -e '.sops.lastmodified' "$f" >/dev/null 2>&1; then
        reason="no sops.lastmodified"
      else
        # data/stringData 리프 중 ENC[AES256_GCM,...] prefix가 아닌 평문 리프 개수.
        # ⚠️ codex pass1 F4: 리터럴 "ENC[*]" 정확일치는 실제 ENC[AES256_GCM,...]를 평문으로 오판 →
        #    추적된 모든 enc.yaml을 오차단(gate 자체가 실패)한다. mikefarah yq엔 startswith가 없어
        #    test() 정규식으로 prefix 검사. `\\[`는 yq가 `\[`(리터럴 `[`)로 unescape한다.
        leaks=$(yq '[(.data // {})[], (.stringData // {})[]] | map(select(test("^ENC\\[") | not)) | length' "$f" 2>/dev/null || echo 99)
        [ "$leaks" = "0" ] || reason="$leaks plaintext data/stringData leaf(s)"
      fi
      if [ -n "$reason" ]; then
        echo "BLOCKED: $f is *.enc.yaml but NOT properly sops-encrypted ($reason)." >&2
        echo "         Run: sops --encrypt --in-place \"$f\"" >&2
        rc=1
      fi
      ;;
  esac
done
exit $rc
```

**Step 4: Run test, expect PASS**

```bash
bats tests/sops-guard.bats
shellcheck scripts/sops-guard.sh
```
기대 출력: `5 tests, 0 failures`(기존 3 + 신규 2), shellcheck 무경고.
(주의: `[[ ]]` 아닌 `[ ]` 단순명령 단언 — bash 3.2 침묵통과 함정 회피.)

**Step 5: Commit**

```bash
git -C /Users/ukyi/workspace/homelab-cicd-hardening add scripts/sops-guard.sh tests/sops-guard.bats && \
git -C /Users/ukyi/workspace/homelab-cicd-hardening commit -m "fix: sops-guard 부분문자열 grep → 구조화 yq 검증 (데코이 우회 차단)"
```

---

### Task 2: gitleaks + sops-guard를 required `gate` 잡에 폴딩 (supplychain-3)

gitleaks(pre-commit) + sops-guard는 `verify` 잡에서만 돈다 — required check가 아니라
시크릿 누출 PR이 `gate`만 통과하면 머지 가능하다. required contexts 변경은 owner-local apply가
필요하므로(github 루트=신뢰앵커), **코드 전용**으로 `gate` 잡(ci.yaml)에 새 스텝을 추가해 머지 즉시 발효시킨다.
gitleaks는 pre-commit rev(`v8.18.4`)와 동일 버전 바이너리를 핀 설치하고, sops-guard는 추적된 모든
`*.enc.yaml`에 직접 실행한다(`gate`는 이미 yq 보유).

**Files:**
- Modify: `.github/workflows/ci.yaml` (setup-toolchain 스텝 뒤, line 32 이후에 새 스텝 2개)
- Test: `tools/test/gate-secret-guard.bats` (게이트 잡이 gitleaks 핀 + sops-guard를 강제하는지 정적 단언 — `gate` 글롭 `tools/test/*.bats`로 자동 포함)

**Step 1: Write the failing test** — `tools/test/gate-secret-guard.bats` 신규:

```bash
#!/usr/bin/env bats
# supplychain-3: 시크릿 누출 가드(gitleaks + sops-guard)가 required `gate` 잡에 강제되는지 단언.
# verify.yml은 required가 아니므로(분기보호 contexts=["gate"]) gate 잡 자체에 폴딩돼야 한다.

CI="$BATS_TEST_DIRNAME/../../.github/workflows/ci.yaml"
PRECOMMIT="$BATS_TEST_DIRNAME/../../.pre-commit-config.yaml"

@test "gate job installs gitleaks pinned to the pre-commit rev" {
  # pre-commit rev(SSOT)와 동일 버전을 핀해야 한다(드리프트 시 두 가드가 갈라짐).
  rev=$(grep -A2 'gitleaks/gitleaks' "$PRECOMMIT" | grep -oE 'rev: v[0-9.]+' | grep -oE 'v[0-9.]+')
  [ -n "$rev" ]
  run grep -q "gitleaks/gitleaks/releases/download/${rev}/" "$CI"
  [ "$status" -eq 0 ]
}

@test "gate gitleaks scans the working tree (--no-git), not full git history (F2)" {
  # ⚠️ codex pass4 F2: bare 'gitleaks detect'는 히스토리 전체 스캔이라 과거 시크릿 하나로 게이트가 영구 red.
  # 작업트리만 스캔하는 --no-git이 있어야 한다(pre-commit 훅 등가).
  run grep -qE 'gitleaks detect' "$CI"
  [ "$status" -eq 0 ]
  run grep -qE 'gitleaks detect.*--no-git' "$CI"
  [ "$status" -eq 0 ]
}

@test "gate gitleaks download is checksum-verified, not a bare curl|tar (F3 supply-chain)" {
  # ⚠️ codex pass5 F3: required gate의 gitleaks 다운로드는 핀된 SHA256으로 검증 후 추출해야 한다.
  run grep -qE 'sha256sum -c' "$CI"
  [ "$status" -eq 0 ]
  # 체크섬 없이 gitleaks tarball을 curl→tar로 바로 파이프하면 안 된다.
  run grep -qE 'gitleaks.*\.tar\.gz" *\| *sudo tar' "$CI"
  [ "$status" -ne 0 ]
}

@test "gate job runs sops-guard over all tracked enc.yaml" {
  run grep -q 'scripts/sops-guard.sh' "$CI"
  [ "$status" -eq 0 ]
  # 추적된 *.enc.yaml을 ls-files로 넘겨야 한다(스테이징 아닌 전 추적 파일).
  run grep -qE "git ls-files '\\*\\.enc\\.yaml'" "$CI"
  [ "$status" -eq 0 ]
}

@test "secret guard step lives in the gate job (required check), not only verify" {
  # `gate:` 잡 본문 안에 gitleaks/sops-guard가 있어야 한다(verify.yml에만 있으면 안 됨).
  run awk '/^  gate:/{g=1} /^  [a-z]/ && !/^  gate:/{g=0} g && (/gitleaks/||/sops-guard/){print}' "$CI"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
}

@test "sops-guard PASSES a realistically sops-shaped enc.yaml (ENC[AES256_GCM,...] leaves)" {
  # codex pass1 F4 회귀 fixture: 실제 SOPS 리프 형태가 평문으로 오판되지 않아야(gate가 모든 enc.yaml을
  # 오차단하지 않게). age 키 불필요 — sops-guard는 구조만 본다. 게이트 글롭 포함 파일이라 required로 강제.
  d="$BATS_TEST_TMPDIR"
  cat > "$d/real.enc.yaml" <<'YAML'
apiVersion: v1
kind: Secret
stringData:
    TOKEN: ENC[AES256_GCM,data:Zm9v,iv:YmFy,tag:YmF6,type:str]
sops:
    mac: ENC[AES256_GCM,data:bWFj,type:str]
    lastmodified: "2026-06-16T00:00:00Z"
YAML
  run "$BATS_TEST_DIRNAME/../../scripts/sops-guard.sh" "$d/real.enc.yaml"
  [ "$status" -eq 0 ]
}

@test "sops-guard BLOCKS a plaintext-leaf enc.yaml even with valid sops metadata (gated behavioral)" {
  d="$BATS_TEST_TMPDIR"
  cat > "$d/leak.enc.yaml" <<'YAML'
apiVersion: v1
kind: Secret
stringData:
    TOKEN: super-secret-plaintext
sops:
    mac: ENC[AES256_GCM,data:bWFj,type:str]
    lastmodified: "2026-06-16T00:00:00Z"
YAML
  run "$BATS_TEST_DIRNAME/../../scripts/sops-guard.sh" "$d/leak.enc.yaml"
  [ "$status" -eq 1 ]
  echo "$output" | grep -q 'BLOCKED'
}
```

**Step 2: Run it, expect FAIL**

```bash
bats tools/test/gate-secret-guard.bats
```
기대 실패: 현재 ci.yaml에 gitleaks/sops-guard 스텝이 없다 → 앞 4개 **wiring** 케이스
(`gate job installs gitleaks ...`부터)가 `✗`(grep status 1). 출력에
`gitleaks/gitleaks/releases/download/v8.18.4/` 미발견. (뒤 2개 **behavioral** 케이스는 Task 1의
`scripts/sops-guard.sh`를 직접 호출하므로 — Phase 4 Task 1 머지 후 — 이미 `ok`. 이 Task는 wiring 4건을 green으로 바꾼다.)

**Step 3: Minimal implementation** — ci.yaml의 setup-toolchain 스텝(line 24-32) 직후에 시크릿 가드 스텝 2개를 삽입한다. `chart render + validate` 스텝(line 33) 앞에 추가:

```yaml
      - name: secret-guard — gitleaks(누출) + sops-guard(평문 enc.yaml) 강제
        # verify.yml의 gitleaks/sops-guard는 required가 아니라(분기보호 contexts=["gate"]),
        # 누출 PR이 gate만 통과하면 머지된다 → required `gate` 잡에 폴딩(코드 전용, 머지 즉시 발효).
        # gitleaks는 pre-commit rev와 동일 버전을 핀(SSOT 드리프트 방지). 러너=arm64.
        run: |
          ver=$(grep -A2 'gitleaks/gitleaks' .pre-commit-config.yaml | grep -oE 'rev: v[0-9.]+' | grep -oE '[0-9.]+')
          # ⚠️ codex pass5 F3: required gate에서 curl|tar로 바로 추출하면 체크섬 없는 실행체 공급망 표면이 된다
          # (supplychain-5와 동일 계열). 파일로 받아 **핀된 SHA256 검증 후** 추출한다. SHA256은 해당 릴리스의
          # 공식 checksums.txt에서 arm64 tarball 값을 핀(버전 핀 v${ver}과 함께 Renovate가 갱신).
          GL_SHA256="<gitleaks_${ver}_linux_arm64.tar.gz 공식 SHA256 — 릴리스 checksums.txt에서>"
          curl -fsSL -o /tmp/gitleaks.tgz "https://github.com/gitleaks/gitleaks/releases/download/v${ver}/gitleaks_${ver}_linux_arm64.tar.gz"
          echo "${GL_SHA256}  /tmp/gitleaks.tgz" | sha256sum -c -
          sudo tar -xz -C /usr/local/bin -f /tmp/gitleaks.tgz gitleaks
          # git 히스토리 전체 스캔(pre-commit 훅과 동등). --redact: 발견 시 시크릿 평문 미출력.
          # ⚠️ codex pass4 F2: bare 'gitleaks detect'는 git 히스토리 전체 스캔 → 과거 false-positive/회전된
          # 옛 시크릿 하나가 모든 PR을 영구 머지불가(게이트 red)로 만든다. pre-commit 훅처럼 작업트리만 스캔.
          gitleaks detect --no-git --source . --redact --no-banner --exit-code 1
      - name: sops-guard — 추적된 모든 *.enc.yaml 구조 검증
        # 평문 *.enc.yaml(또는 부분 암호화)을 차단. gate는 setup-toolchain에서 yq를 이미 설치했다.
        run: |
          files=$(git ls-files '*.enc.yaml')
          if [ -n "$files" ]; then scripts/sops-guard.sh $files; fi
```

`make ci`(로컬 게이트 미러)에도 동일 sops-guard 스텝을 반영한다 — Makefile `ci:` 타겟의 shellcheck 스텝(Makefile:105) 뒤에 추가:

```makefile
	@files=$$(git ls-files '*.enc.yaml'); if [ -n "$$files" ]; then scripts/sops-guard.sh $$files; fi
```
(gitleaks는 로컬 pre-commit 훅이 이미 커버하므로 `make ci`엔 sops-guard만 미러 — gitleaks 바이너리 핀은 게이트 전용.)

**Step 4: Run test, expect PASS**

```bash
bats tools/test/gate-secret-guard.bats
# 워크플로 YAML 문법 정합(설치돼 있으면):
command -v actionlint >/dev/null 2>&1 && actionlint .github/workflows/ci.yaml || echo "actionlint 미설치 — skip"
# sops-guard 미러가 로컬에서 동작하는지(추적 enc.yaml 7건 통과):
scripts/sops-guard.sh $(git ls-files '*.enc.yaml') && echo "sops-guard OK"
```
기대 출력: `6 tests, 0 failures`(wiring 4 + behavioral 2); `sops-guard OK`(추적된 7개 enc.yaml 전부 정상 암호화 — F4 predicate 수정으로 ENC[AES256_GCM,...]가 평문 오판되지 않음).

**Step 5: Commit**

```bash
git -C /Users/ukyi/workspace/homelab-cicd-hardening add .github/workflows/ci.yaml Makefile tools/test/gate-secret-guard.bats && \
git -C /Users/ukyi/workspace/homelab-cicd-hardening commit -m "feat: gitleaks+sops-guard를 required gate 잡에 폴딩 (누출 PR 머지 차단)"
```

---

### Task 3: 분기보호 불변식 tf bats — contexts ⊇ {gate} && strict==true (supplychain-1 부분)

`infra/github/repo.tf`의 `required_status_checks`가 게이트를 무인으로 약화(예: `contexts`에서 `gate`
제거, `strict=false`)당하면 auto-merge 폴백이 un-gate된다. tf bats로 불변식을 단언하고,
`enforce_admins=false`가 **의도된 솔로-오너 잔여 우회**임을 코드 주석으로 문서화한다.
설계 dispositions에 따라 `required_approving_review_count=1`(솔로-오너 auto-merge 파괴)·
`require_last_push_approval=true`(count=0에서 no-op)는 **추가하지 않는다**.

**Files:**
- Modify: `infra/github/repo.tf:49` (`enforce_admins = false` 줄에 의도 문서화 주석 추가)
- Test: `tools/test/branch_protection.bats` (신규 — **`gate` 글롭 `tools/test/*.bats`로 자동 포함**)

> ⚠️ codex pass1 F1: 이 불변식은 **required `gate`가 강제**해야 한다. `infra/_test/*.bats`는 iac.yaml에서만
> 돌고 required check가 아니므로(분기보호 contexts=["gate"]만 required), 거기 두면 `contexts`/`strict`를 약화한
> PR이 유일 required check를 통과해버린다 — 가드가 머지-차단력을 못 갖는다. 따라서 `tools/test/`(gate 글롭)에
> 둔다. iac.yaml 배선은 불필요(글롭이 자동 포함). Phase 5 Task 1이 같은 이유로 `tools/test/auth.bats`를 쓴다.

**Step 1: Write the failing test** — `tools/test/branch_protection.bats` 신규(`$BATS_TEST_DIRNAME` 상대경로 + grep 불변식):

```bash
#!/usr/bin/env bats
# supplychain-1(부분): main 분기보호의 게이트 불변식이 무인으로 약화되지 못하게 한다.
#  - required_status_checks.contexts 가 "gate" 를 포함(auto-merge 폴백의 유일 required check).
#  - strict == true (머지 전 브랜치가 base에 최신 — stale 통과 차단).
#  - enforce_admins == false 가 의도된 솔로-오너 잔여 우회임을 주석으로 문서화.
# dispositions 준수: review_count=1 / require_last_push_approval=true 는 단언하지 않는다
# (솔로-오너 auto-merge 파괴 / count=0에서 no-op).

TF="$BATS_TEST_DIRNAME/../../infra/github/repo.tf"

@test "required_status_checks.contexts includes gate" {
  # contexts 줄에 "gate" 가 있어야 한다(required check SSOT).
  run grep -E 'contexts[[:space:]]*=.*"gate"' "$TF"
  [ "$status" -eq 0 ]
}

@test "required_status_checks strict is true" {
  # strict=true: base에 뒤처진 브랜치의 stale 통과를 막는다.
  run grep -E 'strict[[:space:]]*=[[:space:]]*true' "$TF"
  [ "$status" -eq 0 ]
}

@test "branch protection block does NOT set strict=false anywhere" {
  # 무인 relaxation 회귀 가드: strict=false 가 절대 등장하지 않아야 한다.
  run grep -E 'strict[[:space:]]*=[[:space:]]*false' "$TF"
  [ "$status" -ne 0 ]
}

@test "enforce_admins=false is documented as a deliberate solo-owner residual bypass" {
  # 잔여 위험을 코드에 명시(미문서 우회로 오인 방지). 주석에 '잔여' 또는 'residual' + 'enforce_admins'.
  run grep -nE 'enforce_admins' "$TF"
  [ "$status" -eq 0 ]
  run grep -niE '솔로|residual|잔여' "$TF"
  [ "$status" -eq 0 ]
}
```

**Step 2: Run it, expect FAIL**

```bash
bats tools/test/branch_protection.bats
```
기대 실패: `enforce_admins=false is documented as a deliberate solo-owner residual bypass` 케이스가
`✗`(repo.tf:49 `enforce_admins = false`에 의도 주석이 없어 `솔로|residual|잔여` grep status 1).
나머지 3 케이스는 현 repo.tf가 이미 `contexts=["gate"]`·`strict=true`라 통과 — 이 테스트는 **불변식 잠금**이 목적.

**Step 3: Minimal implementation** — `repo.tf:49`의 `enforce_admins = false`에 의도 문서화 주석을 추가한다:

```hcl
  # enforce_admins=false: 솔로-오너 환경의 의도된 잔여 우회다. required_pull_request_reviews의
  # approving_review_count=0(아래)이라 owner가 자기 PR을 auto-merge로 통과시키는 모델과 정합 —
  # admin 강제를 켜면 owner 직접 머지 경로가 막혀 운영 불가. 게이트(gate check + strict)는
  # admin에게도 유효(이 줄은 admin '추가' 룰만 면제). residual bypass임을 branch_protection.bats가 잠근다.
  enforce_admins      = false
```

**Step 4: Run test, expect PASS** — `tools/test/branch_protection.bats`는 `gate` 잡 글롭(`tools/test/*.bats`)으로
자동 포함되므로 별도 워크플로 배선이 불필요하다(iac.yaml 미수정). 검증:

```bash
bats tools/test/branch_protection.bats
make tf-validate    # repo.tf 주석 추가가 fmt/validate를 깨지 않는지
# gate 글롭이 이 파일을 실제로 집는지(required check 포함 증명):
ls tools/test/*.bats | grep -q 'branch_protection.bats' && echo "gate 글롭 포함 OK"
```
기대 출력: `4 tests, 0 failures`; `github: validated`(외 cloudflare/tailscale도 validated); `gate 글롭 포함 OK`.

**Step 5: Commit**

```bash
git -C /Users/ukyi/workspace/homelab-cicd-hardening add infra/github/repo.tf tools/test/branch_protection.bats && \
git -C /Users/ukyi/workspace/homelab-cicd-hardening commit -m "test: main 분기보호 게이트 불변식을 required gate에 잠금(contexts⊇gate·strict=true) + enforce_admins 의도 문서화"
```

---

## Phase 5 — standing 자격증명 제거 (P0, owner-local apply)

> **이 단계만 owner-local apply다.** `infra/github`는 신뢰 앵커 루트라 CI 무인 apply 금지(AGENTS.md).
> 코드 제거 PR은 auto-merge로 main에 들어가지만 **라이브 GitHub Actions secret `DEPLOY_BOT_PAT`는
> owner가 로컬에서 `terraform -chdir=infra/github apply`로만 삭제**한다. 시퀀싱은 Task 4에 명시.
>
> **배경(검증됨):** `DEPLOY_BOT_PAT`는 App 마이그레이션(Phase 1~6 app-platform-dx) 후 워크플로 소비자가
> 0이다. 전 레포 grep 결과 라이브 참조는 `infra/github/secrets.tf`(리소스)·`variables.tf`(변수)·
> `terraform.tfvars.example`(주석)·`.env.secrets.example`(`TF_VAR_bot_pat`)·`tf-reconcile.yml:135`
> (`TF_VAR_bot_pat: ${{ secrets.TF_GITHUB_BOT_PAT }}`, drift-github 잡에 주입)뿐이다. `docs/plans/`와
> `homelab-token/action.yml:1`(대체 주석)은 역사/설명이라 건드리지 않는다. 별개 시크릿
> `TF_GITHUB_*`(plan-only 드리프트용)는 보존한다 — `TF_GITHUB_BOT_PAT` 자체가 아니라 그것이 채우던
> **변수 `bot_pat`**가 사라지므로 drift-github 잡의 `TF_VAR_bot_pat` 주입 라인만 제거한다.
>
> **검증된 함정(이 단계 관련):** 터미널 실험으로 확인 — terraform은 env(`TF_VAR_*`)로 들어온 **선언되지
> 않은 변수**를 경고·에러 없이 조용히 무시한다(undeclared 경고는 `.tfvars` 파일 소스에서만 발화). 따라서
> `variable "bot_pat"` 제거 후 `tf-reconcile.yml`에 `TF_VAR_bot_pat`가 남아도 plan은 안 깨진다 — 그래도
> dead 주입은 오해를 부르므로 위생상 함께 제거한다.

### Task 1: auth.bats에 bot_pat terraform 부재 단언 추가 (supplychain-2)

게이트가 강제하는 회귀 가드를 먼저 만든다. `infra/_test/*.bats`는 `gate` 잡(ci.yaml)에 **배선돼 있지
않다**(iac.yaml의 하드코딩 목록 39~42에서만 실행) — 반면 `tools/test/*.bats`는 `gate` 잡 line 45
`ls tools/test/*.bats`로 글롭돼 branch protection required check `gate`가 강제한다. 따라서 영구 회귀
가드는 기존 `tools/test/auth.bats`(이미 PAT-0 불변식 파일)에 추가한다.

**Files:**
- Modify (test): `tools/test/auth.bats` (현재 4개 `@test`, line 1~28에 추가)

**Step 1: Write the failing test** — `tools/test/auth.bats` 끝(line 28 `}` 다음)에 4개 `@test` 추가.
`setup()`가 이미 `ROOT`를 정의하므로 그걸 쓴다. bash 3.2 함정 회피: 중간 단언은 전부 `[ ]`(단순 명령).

```bash

@test "no github_actions_secret bot_pat resource remains in terraform" {
  # App 마이그레이션 후 DEPLOY_BOT_PAT(write-capable standing PAT)는 소비자 0 — 리소스가 남으면 안 됨
  run grep -nE 'github_actions_secret"?[[:space:]]*"bot_pat"' "$ROOT/infra/github/secrets.tf"
  [ "$status" -ne 0 ]
}

@test "no variable bot_pat declared in terraform" {
  run grep -nE '^variable[[:space:]]+"bot_pat"' "$ROOT/infra/github/variables.tf"
  [ "$status" -ne 0 ]
}

@test "DEPLOY_BOT_PAT secret_name is gone from terraform" {
  # secret_name 문자열까지 사라져야 라이브 destroy가 next apply에서 발생한다
  run grep -rn 'DEPLOY_BOT_PAT' "$ROOT/infra/github/"
  [ "$status" -ne 0 ]
}

@test "tf-reconcile drift-github no longer injects TF_VAR_bot_pat" {
  # 변수 제거 후 dead 주입(오해 유발) 차단 — TF_GITHUB_TOKEN/OWNER 등 나머지 plan-only 시크릿은 보존
  run grep -nE 'TF_VAR_bot_pat' "$ROOT/.github/workflows/tf-reconcile.yml"
  [ "$status" -ne 0 ]
}
```

**Step 2: Run it, expect FAIL** —
```
bats tools/test/auth.bats
```
기대 실패: 4개 신규 테스트가 모두 FAIL.
```
not ok 5 no github_actions_secret bot_pat resource remains in terraform
# (in test file tools/test/auth.bats, line ...)
#   `[ "$status" -ne 0 ]' failed
not ok 6 no variable bot_pat declared in terraform
not ok 7 DEPLOY_BOT_PAT secret_name is gone from terraform
not ok 8 tf-reconcile drift-github no longer injects TF_VAR_bot_pat
```
(기존 1~4는 PASS — 이 테스트만 빨개진다. grep이 매치를 찾아 `status=0`이므로 `-ne 0` 단언 실패.)

**Step 3: Minimal implementation** — 없음. 이 Task는 가드(실패하는 4개 테스트)를 **작성만** 한다. 실제 코드
제거는 Task 2~3에서 단계적으로 green이 된다(일부 테스트가 여러 impl 단계에 걸쳐 있어 깔끔히 분할되지 않음 —
예: `DEPLOY_BOT_PAT secret_name is gone`은 `secrets.tf`(Task 2)와 `terraform.tfvars.example`(Task 3)이 둘
다 정리돼야 green).

**Step 4: Run test, expect FAIL** — 신규 4건이 RED. 종료 기준은 "정확히 4건 RED". Task 3 완료 시 전부 GREEN.

**Step 5: Commit (PR-내 중간 커밋 — 단독 push 금지)** — ⚠️ 횡단 조정 #4: `tools/test/auth.bats`는 `gate`
글롭(`tools/test/*.bats`) 포함 파일이라 **RED 상태로 단독 push하면 required CI(`gate`)가 실패**한다. Phase 5는
**단일 PR**로 Task 1~3을 함께 담고 `gate`는 PR head(Task 3 후 green)에서만 평가되게 한다 — 로컬 커밋은 만들되
Task 3 완료 전엔 push하지 않는다(또는 auto-merge가 최종 green까지 대기하도록 마지막에 한 번 push). 커밋:
```
git -C /Users/ukyi/workspace/homelab-cicd-hardening add tools/test/auth.bats && git -C /Users/ukyi/workspace/homelab-cicd-hardening commit -m "test: DEPLOY_BOT_PAT terraform 부재 회귀 가드 (supplychain-2, PR 최종에 green)"
```

---

### Task 2: terraform에서 bot_pat 리소스/변수 제거 (supplychain-2)

**Files:**
- Modify: `infra/github/secrets.tf:1-5` (리소스 블록 삭제)
- Modify: `infra/github/variables.tf:12-16` (변수 블록 삭제)

**Step 1: Write the failing test** — Task 1에서 작성 완료(`tools/test/auth.bats`의 신규 4건). 이 Task는
그 RED를 GREEN으로 바꾸는 구현 단계다. (별도 새 테스트 없음.)

**Step 2: Run it, expect FAIL** — 현재 상태 재확인.
```
bats tools/test/auth.bats
```
기대: `not ok 5`, `not ok 6`, `not ok 7`(secrets.tf/variables.tf가 아직 bot_pat 보유). `not ok 8`은
Task 3에서 해소.

**Step 3: Minimal implementation** —

(a) `infra/github/secrets.tf`에서 `github_actions_secret "bot_pat"` 블록(line 1~5) 삭제. telegram 2개
리소스는 유지. 파일은 이렇게 시작해야 한다(첫 리소스가 telegram_bot_token):

```hcl
resource "github_actions_secret" "telegram_bot_token" {
  repository      = github_repository.homelab.name
  secret_name     = "TELEGRAM_BOT_TOKEN"
  plaintext_value = var.telegram_bot_token
}
resource "github_actions_secret" "telegram_chat_id" {
  repository      = github_repository.homelab.name
  secret_name     = "TELEGRAM_CHAT_ID"
  plaintext_value = var.telegram_chat_id
}
```

(b) `infra/github/variables.tf`에서 `variable "bot_pat"` 블록(line 12~16) 삭제. 결과 파일:

```hcl
variable "github_owner" {
  type = string
}
variable "github_token" {
  type      = string
  sensitive = true
}
variable "repo_name" {
  type    = string
  default = "homelab"
}
variable "telegram_bot_token" {
  type      = string
  sensitive = true
}
variable "telegram_chat_id" {
  type      = string
  sensitive = true
}
```

**Step 4: Run test, expect PASS** —
```
bats tools/test/auth.bats && make tf-validate
```
기대: `auth.bats` 5·6·7번 GREEN(8번은 아직 RED — Task 3). `make tf-validate`는
```
github: validated
```
포함(변수/리소스 제거가 `terraform validate`를 깨지 않음 — bot_pat은 어디서도 참조되지 않으므로). 8번
때문에 auth.bats 전체는 아직 1건 FAIL일 수 있으니 부분 검증으로 확인:
```
bats tools/test/auth.bats -f 'bot_pat resource'
bats tools/test/auth.bats -f 'variable bot_pat'
bats tools/test/auth.bats -f 'DEPLOY_BOT_PAT secret_name'
```
세 건 모두 `ok`.

**Step 5: Commit** —
```
git -C /Users/ukyi/workspace/homelab-cicd-hardening add infra/github/secrets.tf infra/github/variables.tf && git -C /Users/ukyi/workspace/homelab-cicd-hardening commit -m "fix: DEPLOY_BOT_PAT terraform 리소스·변수 제거 — 무소비자 standing PAT (supplychain-2)"
```

---

### Task 3: dead bot_pat 참조 정리 — tfvars.example·.env.secrets.example·tf-reconcile.yml (supplychain-2)

변수가 사라졌으니 그것을 채우던 주입/문서 참조를 정리한다. `tf-reconcile.yml`의 `TF_VAR_bot_pat` 주입은
이제 선언되지 않은 변수를 채우는 dead 라인(터미널 실험상 terraform이 env 미선언 var를 조용히 무시 →
plan은 안 깨지지만 오해 유발)이라 제거한다. `TF_GITHUB_TOKEN`/`TF_GITHUB_OWNER`/telegram·R2 시크릿은
plan-only 드리프트에 여전히 필요하므로 **보존**한다.

**Files:**
- Modify: `.github/workflows/tf-reconcile.yml:135` (`TF_VAR_bot_pat:` 라인 삭제)
- Modify: `infra/github/terraform.tfvars.example:4,11` (주석에서 `bot_pat`/`DEPLOY_BOT_PAT` 언급 정리)
- Modify: `.env.secrets.example:38-42` (`TF_VAR_bot_pat` 블록 삭제)

**Step 1: Write the failing test** — Task 1의 `@test "tf-reconcile drift-github no longer injects
TF_VAR_bot_pat"`가 이 Task를 커버한다. tfvars.example/.env.secrets.example의 주석 정리는 비-게이트(문서)
이므로 별도 단언을 추가하지 않는다(과잉 게이트 회피) — `DEPLOY_BOT_PAT secret_name is gone` 단언이
`infra/github/` 전체 grep이라 tfvars.example의 `DEPLOY_BOT_PAT` 언급도 잡으므로 그 라인은 정리가 강제된다.

**Step 2: Run it, expect FAIL** —
```
bats tools/test/auth.bats -f 'TF_VAR_bot_pat'
bats tools/test/auth.bats -f 'DEPLOY_BOT_PAT secret_name'
```
기대 FAIL:
```
not ok 1 tf-reconcile drift-github no longer injects TF_VAR_bot_pat
not ok 1 DEPLOY_BOT_PAT secret_name is gone from terraform
```
(tf-reconcile.yml:135에 `TF_VAR_bot_pat` 존재 + terraform.tfvars.example:11에 `DEPLOY_BOT_PAT` 언급 존재.)

**Step 3: Minimal implementation** —

(a) `.github/workflows/tf-reconcile.yml`의 drift-github 잡에서 line 135 한 줄 삭제:
```yaml
          TF_VAR_bot_pat: ${{ secrets.TF_GITHUB_BOT_PAT }}
```
주변(`TF_VAR_github_owner`/`TF_VAR_github_token`/`TF_VAR_telegram_*`/`R2_*`)은 그대로 둔다.

(b) `infra/github/terraform.tfvars.example`:
- line 4 `# ⚠️ 시크릿(github_token / bot_pat / telegram_*)은 ...` → `bot_pat /` 제거:
  ```
  # ⚠️ 시크릿(github_token / telegram_*)은 여기 넣지 말 것 — .env.secrets의
  ```
- line 11~13 블록의 `write-only 시크릿(DEPLOY_BOT_PAT 등)은 ...` 문장 삭제(이제 write-only 시크릿이
  없으므로). `TF_GITHUB_TOKEN(읽기 가능 PAT) / TF_GITHUB_OWNER` 안내는 보존하고, 끝 문장을 정리:
  ```
  # 선택: tf-reconcile.yml의 plan-only 드리프트 알림을 켜려면 아래 Actions 시크릿을 등록한다
  #       (없으면 preflight가 skip) — TF_GITHUB_TOKEN(읽기 가능 PAT) / TF_GITHUB_OWNER.
  #       TELEGRAM_*는 기존 시크릿 재사용.
  ```

(c) `.env.secrets.example`의 ④ 블록(line 38~42 `# ── ④ GitHub write-back 봇 PAT ...`부터
`export TF_VAR_bot_pat=""`까지) 전체 삭제 — DEPLOY_BOT_PAT 발급 안내가 무효. 이후 번호(⑤ telegram)는
그대로 둔다(번호 재정렬은 선택, 최소 변경 위해 미수정).

**Step 4: Run test, expect PASS** —
```
bats tools/test/auth.bats && make tf-validate && shellcheck $(git -C /Users/ukyi/workspace/homelab-cicd-hardening ls-files '*.sh') >/dev/null
```
기대: `auth.bats` 8개 전부 `ok`(신규 4 + 기존 4):
```
ok 5 no github_actions_secret bot_pat resource remains in terraform
ok 6 no variable bot_pat declared in terraform
ok 7 DEPLOY_BOT_PAT secret_name is gone from terraform
ok 8 tf-reconcile drift-github no longer injects TF_VAR_bot_pat
```
`make tf-validate` → `github: validated` 포함. (shellcheck는 .env.secrets.example이 `.sh`가 아니라
무영향 — sanity용.) YAML 문법 sanity:
```
python3 -c "import yaml,sys; yaml.safe_load(open('/Users/ukyi/workspace/homelab-cicd-hardening/.github/workflows/tf-reconcile.yml'))" && echo yaml-ok
```

**Step 5: Commit** —
```
git -C /Users/ukyi/workspace/homelab-cicd-hardening add .github/workflows/tf-reconcile.yml infra/github/terraform.tfvars.example .env.secrets.example && git -C /Users/ukyi/workspace/homelab-cicd-hardening commit -m "refactor: dead bot_pat 주입·문서 참조 정리 — tf-reconcile/tfvars/env.secrets (supplychain-2)"
```

---

### Task 4: owner-local apply 시퀀싱 + 런북 절차 기록 (supplychain-2)

코드 제거 PR이 auto-merge로 main에 들어가도 **라이브 GitHub Actions secret은 그대로 남는다**(CI는 이
루트를 apply하지 않음). 라이브 삭제는 owner가 로컬에서만 수행한다. 이 절차를 plan에 명시하고 런북에 적는다.

**owner-local 시퀀싱 (이 PR 머지 후 수동):**
1. Phase 5 PR이 `gate` 통과 → auto-merge로 main 진입(코드만; 라이브 secret 무변경).
2. 다음 `tf-reconcile.yml` 주기(30분) 또는 수동 `workflow_dispatch`에서 `drift-github` 잡이 `terraform
   plan -detailed-exitcode`로 **`github_actions_secret.bot_pat` 1건 destroy** 드리프트를 감지 → telegram
   `IaC드리프트` 알림(Phase 1 obs-1 enum 수정으로 알림이 침묵하지 않음). plan-only라 apply는 안 함.
   - 주의(검증됨): plaintext secret 값은 API로 못 읽으므로 평소엔 거짓 드리프트가 없다. 여기서 뜨는
     destroy는 **config에서 리소스가 사라진 진짜 삭제 의도**라 정상 신호다.
3. owner가 로컬에서 `infra/github` 신뢰 앵커를 apply:
   ```
   set -a && . .env.secrets && set +a
   terraform -chdir=infra/github init -reconfigure -backend-config=backend.hcl
   terraform -chdir=infra/github plan      # destroy: github_actions_secret.bot_pat (1 to destroy) 확인
   terraform -chdir=infra/github apply     # 라이브 DEPLOY_BOT_PAT 삭제
   ```
   (`.env.secrets`에서 `TF_VAR_bot_pat`를 Task 3에서 지웠으므로, 로컬 state↔config 비교만으로 destroy가
   계획된다 — apply 후 state에서도 리소스가 사라진다.)
4. apply 후 `tf-reconcile`의 `drift-github`가 다음 주기에 **no-drift**(exit 0)로 수렴 → 알림 종료.
5. (최종) GitHub UI repo Settings → Secrets → Actions에서 `DEPLOY_BOT_PAT`가 사라졌는지 육안 확인 +
   해당 fine-grained PAT를 github.com/settings/personal-access-tokens에서 **revoke**(state 삭제와 별개로
   토큰 자체 폐기 — standing 자격 완전 제거).

**Files:**
- Modify (런북): `docs/runbooks/app-platform.md` (로컬 전용·gitignored — 절차 추가). 부재 시
  `docs/runbooks/02-cloud-iac-bootstrap.md`에 추가. **git에 커밋하지 않는다**(런북은 gitignored).

**Step 1: Write the failing test** — 런북은 gitignored 로컬 전용이라 CI 게이트 대상이 아니다. 이 Task의
회귀 가드는 이미 Task 1~3의 `auth.bats`(코드측 부재)가 담당한다. owner-local 라이브 삭제는 클러스터/계정
상태라 CI가 비접촉(설계 "라이브 의존은 정적 단언 + 런북 절차로 분리" 원칙). 따라서 새 자동 테스트 없음 —
**수동 검증 체크리스트**(아래 Step 4)가 종료 기준이다.

**Step 2: Run it, expect FAIL** — 해당 없음(런북/수동 절차). 머지 전 상태에서 라이브 secret이 아직
존재함을 plan으로 확인하는 것이 "현 상태"다:
```
terraform -chdir=/Users/ukyi/workspace/homelab-cicd-hardening/infra/github plan 2>&1 | grep -i 'bot_pat'
```
기대: `# github_actions_secret.bot_pat will be destroyed` (1 to destroy) — config 제거가 destroy로
계획됨을 확인.

**Step 3: Minimal implementation** — 위 "owner-local 시퀀싱" 5단계를 런북
`docs/runbooks/app-platform.md`의 App Platform 트리거 경계 섹션 하위에 "DEPLOY_BOT_PAT standing 자격 폐기
(Phase 5)" 소제목으로 기록한다(로컬 파일, 커밋 안 함). 런북이 로컬에 없으면 생성하되 git add 금지.

**Step 4: Run test, expect PASS** — owner 수동 실행 후 검증(클러스터/계정 라이브 — CI 외부):
```
terraform -chdir=/Users/ukyi/workspace/homelab-cicd-hardening/infra/github plan 2>&1 | grep -ci 'bot_pat'
```
기대 출력: `0` (apply 후 destroy 대상 없음 — state·config·live 3자 수렴). 추가 라이브 확인:
```
gh api repos/<owner>/homelab/actions/secrets --jq '.secrets[].name' | grep -c DEPLOY_BOT_PAT
```
기대: `0` (라이브 secret 삭제 확인). 코드측 가드 재확인:
```
bats /Users/ukyi/workspace/homelab-cicd-hardening/tools/test/auth.bats
```
기대: 8/8 `ok`.

**Step 5: Commit** — 런북은 gitignored라 커밋 대상 없음. 이 Task는 **코드 커밋을 생성하지 않는다**(라이브
apply + 로컬 런북만). plan 본문에 "owner 수동 단계 — 코드 커밋 없음"을 명시한다. (만약 런북이 추적
대상으로 잘못 잡히면 절대 add하지 말 것 — `docs/runbooks/`는 `.gitignore`로 보호됨.)

---

## Phase 6 — 동시성 직렬화 (P1)

> 테마6(races) + fm-2 + obs-5. bump.yaml의 누락된 `queue: max`(races-1·2, **medium**)로 시작해
> auto-merge fallback 판별(races-6), stale-PR 스위퍼(races-3/obs-5), bump-poll TOCTOU(races-4),
> activate-app surface 마커(races-5), onboard 고정 브랜치명(fm-2)을 다룬다.
>
> 공유 의존: `tools/bump-tag.mjs --expect-current`는 **Phase 2에서 구축** — 여기선 호출만 한다.
> 신규 bats는 `tools/test/*.bats` 글롭이 `gate`에 자동 포함한다(ci.yaml:45, Makefile:104).
> 신규 `scripts/*.sh`는 `shellcheck $(git ls-files '*.sh')` 게이트가 자동 커버한다(ci.yaml:50).
> 중간 단언은 `[ ]`만(bash 3.2 `[[ ]]` 침묵통과 함정), `@test` 이름은 영어(한글 인코딩 깨짐 함정).

---

### Task 1: bump.yaml를 homelab-mutation + queue:max로 직렬화 (races-1, races-2)

**Files:**
- Modify `.github/workflows/bump.yaml:14-16` (concurrency 블록)
- Modify (test) `tools/test/bump.bats:76-81` (기존 "single concurrency group" 단언 강화)

**Step 1: Write the failing test** — `tools/test/bump.bats`의 마지막 `@test`를 정확한 group/queue 단언으로 교체한다. 기존(76-81)은 group 비-공백 + cancel-in-progress=false만 본다.

```bats
@test "bump workflow joins the global homelab-mutation queue (no pending loss)" {
  # races-1/2: values-writeback는 queue:max가 없어 동시 3번째 write-back이 대기 건을 조용히 취소했다.
  # 문서화된 전역 직렬화(homelab-mutation + queue:max)에 합류시켜 인-repo bump 유실을 막는다.
  run yq '.concurrency.group' "$WF"
  [ "$output" == "homelab-mutation" ]
  run yq '.concurrency.queue' "$WF"
  [ "$output" == "max" ]
  run yq '.concurrency.cancel-in-progress' "$WF"
  [ "$output" == "false" ] # 반쯤 끝난 write-back은 절대 취소하지 않는다 (queue:max는 cancel:true와 병용 불가)
}
```

**Step 2: Run it, expect FAIL** — `bats tools/test/bump.bats`
기대 실패: 마지막 테스트가 `(in test file tools/test/bump.bats, line 78) \`[ "$output" == "homelab-mutation" ]' failed` — 현재 group은 `values-writeback`이고 `.concurrency.queue`는 `null`.

**Step 3: Minimal implementation** — `.github/workflows/bump.yaml:12-16`을 교체:

```yaml
# 직렬화: 모든 main 변이(dispatch-mutation/bump-poll/bump)가 공유하는 전역 큐에 합류한다.
# values-writeback 전용 그룹은 queue:max가 없어 동시 3번째 write-back이 대기 건을 조용히 취소했다
# (races-1/2 — 인-repo bump 유실). 진행 중인 커밋은 절대 취소하지 않는다(cancel-in-progress:false).
# queue:max(2026-05 GA)는 cancel-in-progress:true와 병용 불가 — false 유지.
concurrency:
  group: homelab-mutation
  cancel-in-progress: false
  queue: max
```

**Step 4: Run test, expect PASS** — `bats tools/test/bump.bats`
기대 출력: `ok N bump workflow joins the global homelab-mutation queue (no pending loss)` 포함 전체 통과(`N tests, 0 failures`). 워크플로 YAML 파싱 게이트도 무영향: `bats tools/test/workflow-yaml.bats` 통과.

**Step 5: Commit**
`git -C /Users/ukyi/workspace/homelab-cicd-hardening add .github/workflows/bump.yaml tools/test/bump.bats && git -C /Users/ukyi/workspace/homelab-cicd-hardening commit -m "fix: bump 워크플로를 homelab-mutation+queue:max 전역 직렬화에 합류 (write-back 유실 차단)"`

---

### Task 2: CLEAN 판별 auto-merge fallback 공유 스크립트 (races-6)

**Files:**
- Create `scripts/auto-merge-or-fail.sh`
- Create (test) `tools/test/automerge-fallback.bats`

**Step 1: Write the failing test** — `tools/test/automerge-fallback.bats`. `gh`를 PATH stub으로 대체해(`mergeStateStatus`/머지 호출을 기록) 분기 행동을 검증한다. raw 직접 머지는 mergeStateStatus가 CLEAN일 때만 일어나야 하고, BLOCKED면 시끄럽게 실패해야 한다.

```bats
#!/usr/bin/env bats
# races-6: auto-merge fallback이 un-gated 직접 머지를 분기보호에만 의존하지 않게 — 이미 CLEAN인
# PR에서만 직접 squash하고, 그 외(BLOCKED/BEHIND/UNKNOWN)는 시끄럽게 실패한다.
# ⚠️ 중간 단언은 [ ]만(bash 3.2 [[ ]] 침묵통과). @test 이름은 영어.

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  S="$ROOT/scripts/auto-merge-or-fail.sh"
  TMP="$(mktemp -d)"
  BIN="$TMP/bin"; mkdir -p "$BIN"
  LOG="$TMP/gh.log"
  # gh stub: 인자/서브커맨드를 LOG에 기록. mergeStateStatus는 $GH_STATE로 주입.
  cat > "$BIN/gh" <<EOF
#!/usr/bin/env bash
echo "gh \$*" >> "$LOG"
case "\$*" in
  *"pr view"*"mergeStateStatus"*) printf '%s' "\${GH_STATE:-CLEAN}"; exit 0 ;;
  *"pr merge --auto"*) exit "\${GH_AUTO_RC:-1}" ;;   # --auto는 이미 clean PR엔 에러(라이브 계약) → 기본 실패
  *"pr merge --squash"*) exit 0 ;;
esac
exit 0
EOF
  chmod +x "$BIN/gh"
  export PATH="$BIN:$PATH"
}
teardown() { rm -rf "$TMP"; }

@test "auto-merge arms via --auto and never falls back when --auto succeeds" {
  GH_AUTO_RC=0 run bash "$S" mybranch
  [ "$status" -eq 0 ]
  grep -q "pr merge --auto --squash mybranch" "$LOG"
  # --auto 성공 시 직접 머지(--squash 단독)는 호출되지 않는다
  run grep -c "pr merge --squash mybranch" "$LOG"
  [ "$output" -eq 0 ]
}

@test "falls back to a direct squash ONLY when the PR is already CLEAN" {
  GH_AUTO_RC=1 GH_STATE=CLEAN run bash "$S" mybranch
  [ "$status" -eq 0 ]
  grep -q "pr view mybranch" "$LOG"
  grep -q "pr merge --squash mybranch" "$LOG"
}

@test "fails loudly (does not direct-merge) when --auto fails and PR is BLOCKED" {
  GH_AUTO_RC=1 GH_STATE=BLOCKED run bash "$S" mybranch
  [ "$status" -ne 0 ]
  # un-gated 직접 머지는 절대 시도하지 않는다
  run grep -c "pr merge --squash mybranch" "$LOG"
  [ "$output" -eq 0 ]
  echo "$output" "$status"
}

@test "fails loudly when PR is BEHIND (must update-branch first, not direct-merge)" {
  GH_AUTO_RC=1 GH_STATE=BEHIND run bash "$S" mybranch
  [ "$status" -ne 0 ]
  run grep -c "pr merge --squash mybranch" "$LOG"
  [ "$output" -eq 0 ]
}

@test "requires a branch argument" {
  run bash "$S"
  [ "$status" -ne 0 ]
}
```

**Step 2: Run it, expect FAIL** — `bats tools/test/automerge-fallback.bats`
기대 실패: `bash: .../scripts/auto-merge-or-fail.sh: No such file or directory` (스크립트 미존재) — 전 테스트 실패.

**Step 3: Minimal implementation** — `scripts/auto-merge-or-fail.sh`:

```sh
#!/usr/bin/env sh
# PR-first auto-merge fallback (races-6) — un-gated 직접 머지를 분기보호에만 의존하지 않는다.
# `gh pr merge --auto`는 이미 clean(체크 완료)인 PR엔 에러를 낸다(라이브 검증된 GitHub 계약).
# 그 폴백을 "PR이 이미 CLEAN일 때"로만 좁힌다: BLOCKED/BEHIND/UNKNOWN이면 시끄럽게 실패해
# required check `gate`를 우회한 직접 머지가 일어나지 않게 한다.
# 사용: GH_TOKEN 환경에서 scripts/auto-merge-or-fail.sh <branch>
set -eu

branch="${1:-}"
[ -n "$branch" ] || { echo "::error::auto-merge-or-fail: branch 인자 필수"; exit 2; }

# 1) 정상 경로: auto-merge 무장(gate 통과 시 GitHub가 머지). 성공하면 끝.
if gh pr merge --auto --squash "$branch"; then
  exit 0
fi

# 2) --auto가 거부됨 → 보통 "이미 clean이라 무장할 게 없음". mergeStateStatus로 확인 후에만 직접 머지.
state="$(gh pr view "$branch" --json mergeStateStatus -q .mergeStateStatus 2>/dev/null || echo UNKNOWN)"
case "$state" in
  CLEAN)
    # gate가 이미 green인 PR — 직접 squash는 분기보호를 우회하지 않는다(required check 충족됨).
    gh pr merge --squash "$branch"
    ;;
  *)
    echo "::error::auto-merge-or-fail: PR '$branch' mergeStateStatus=$state — 직접 머지 거부 (gate 미통과/behind/충돌). 수동 확인 필요."
    exit 1
    ;;
esac
```

**Step 4: Run test, expect PASS** — `bats tools/test/automerge-fallback.bats`
기대 출력: `5 tests, 0 failures`. shellcheck 게이트도 통과: `shellcheck scripts/auto-merge-or-fail.sh` → 출력 없음(exit 0).

**Step 5: Commit**
`git -C /Users/ukyi/workspace/homelab-cicd-hardening add scripts/auto-merge-or-fail.sh tools/test/automerge-fallback.bats && git -C /Users/ukyi/workspace/homelab-cicd-hardening commit -m "feat: CLEAN 판별 auto-merge fallback 공유 스크립트 (분기보호 우회 직접머지 차단)"`

---

### Task 3: 6개 콜사이트를 공유 fallback 스크립트로 수렴 (races-6)

**Files:**
- Modify `.github/workflows/bump.yaml:111` 및 `:186`
- Modify `.github/workflows/bump-poll.yml:107`
- Modify `.github/workflows/_create-database.yml:90`
- Modify `.github/workflows/_create-cache.yml:92`
- Modify `.github/workflows/_update-secrets.yml:88`
- Create (test) — Task 2의 `automerge-fallback.bats`에 콜사이트 수렴 단언 추가

**Step 1: Write the failing test** — `tools/test/automerge-fallback.bats`에 6콜사이트가 raw fallback(`gh pr merge --auto --squash "$branch" || gh pr merge --squash "$branch"`)을 더는 쓰지 않고 공유 스크립트를 부르는지 단언하는 테스트를 추가한다.

```bats
@test "all six auto-merge callsites use the shared script, not the raw OR-fallback" {
  WF="$ROOT/.github/workflows"
  # races-6: un-gated 직접 머지 OR-폴백을 6곳에서 박멸 — 공유 스크립트만 호출한다.
  raw=$(grep -rn 'gh pr merge --auto --squash "\$branch" || gh pr merge --squash' "$WF" || true)
  [ -z "$raw" ]
  for f in bump.yaml bump-poll.yml _create-database.yml _create-cache.yml _update-secrets.yml; do
    grep -q 'auto-merge-or-fail.sh' "$WF/$f" || { echo "missing shared fallback in $f"; false; }
  done
  # bump.yaml은 두 job(writeback/writeback-dispatch) — 2회 호출
  run grep -c 'auto-merge-or-fail.sh' "$WF/bump.yaml"
  [ "$output" -eq 2 ]
}
```

**Step 2: Run it, expect FAIL** — `bats tools/test/automerge-fallback.bats`
기대 실패: `(in test file .../automerge-fallback.bats) \`[ -z "$raw" ]' failed` — 6개 raw OR-폴백이 여전히 매치된다.

**Step 3: Minimal implementation** — 6콜사이트 각각에서 `gh pr merge --auto --squash "$branch" || gh pr merge --squash "$branch"`(및 위의 라이브 계약 주석 줄)을 다음 한 줄로 치환한다(스크립트가 동일 정책을 담는다):

```sh
          bash scripts/auto-merge-or-fail.sh "$branch"
```

bump-poll.yml:107은 들여쓰기가 한 단계 깊다(while 루프 내부) — 매칭 들여쓰기로:

```sh
              bash scripts/auto-merge-or-fail.sh "$branch"
```

(각 워크플로는 이미 `apps/`/`platform/` 체크아웃 루트에서 돌고 `GH_TOKEN`을 env로 노출하므로 스크립트가 그대로 동작한다.)

**Step 4: Run test, expect PASS** — `bats tools/test/automerge-fallback.bats && bats tools/test/workflow-yaml.bats`
기대 출력: automerge-fallback 전체 통과(6 tests, 0 failures), workflow-yaml YAML 파싱 통과. telegram-callsites 회귀 없음: `bats tools/test/telegram-callsites.bats` 통과.

**Step 5: Commit**
`git -C /Users/ukyi/workspace/homelab-cicd-hardening add .github/workflows/bump.yaml .github/workflows/bump-poll.yml .github/workflows/_create-database.yml .github/workflows/_create-cache.yml .github/workflows/_update-secrets.yml tools/test/automerge-fallback.bats && git -C /Users/ukyi/workspace/homelab-cicd-hardening commit -m "refactor: 6개 auto-merge 콜사이트를 공유 fallback 스크립트로 수렴"`

---

### Task 4: stale auto-merge-pending PR 스위퍼 워크플로 (races-3, obs-5)

**Files:**
- Create `.github/workflows/pr-sweeper.yml`
- Create (test) `tools/test/pr-sweeper.bats`

**Step 1: Write the failing test** — `tools/test/pr-sweeper.bats`. 워크플로 YAML을 정적 검사: 스케줄 트리거, 봇 PR(bump*/create-*/onboard-*/update-secrets*) 한정, BEHIND PR에 `gh pr update-branch`, 최소 권한, 실패 알림(source: 변이).

```bats
#!/usr/bin/env bats
# races-3/obs-5: strict=true + 비동기 auto-merge면 2번째 PR이 main 뒤에서 멈춘다(BEHIND).
# 스위퍼가 auto-merge-pending인데 behind인 봇 PR을 주기적으로 update-branch해 수렴시킨다.
# ⚠️ 중간 단언은 [ ]만. @test 이름은 영어.

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  F="$ROOT/.github/workflows/pr-sweeper.yml"
  command -v yq >/dev/null || skip "yq required"
}

@test "pr-sweeper runs on a schedule (cron) and manual dispatch only" {
  run yq '.on.schedule[0].cron' "$F"
  [ -n "$output" ]
  [ "$output" != "null" ]
  run yq '.on.workflow_dispatch' "$F"
  [ "$output" != "null" ]
  # push/pull_request 트리거 금지(스위퍼는 스케줄 전용)
  run yq '.on.push' "$F"
  [ "$output" == "null" ]
}

@test "pr-sweeper uses the writer App token (PR-first), not a standing PAT" {
  grep -q "HOMELAB_WRITER_APP_ID" "$F"
  ! grep -q "DEPLOY_BOT_PAT" "$F"
}

@test "pr-sweeper updates behind branches via gh pr update-branch" {
  grep -q "update-branch" "$F"
}

@test "pr-sweeper scopes to bot branches only (head prefix filter)" {
  # bump/ bump-poll/ create-database/ create-cache/ create-app/ onboard/ update-secrets/ 만 손댄다
  grep -qE 'bump|create-|onboard|update-secrets' "$F"
}

@test "pr-sweeper notifies on failure via the telegram action (source: 변이)" {
  run yq '[.jobs[].steps[]? | select(.uses=="./.github/actions/telegram-notify")] | length' "$F"
  [ "$output" != "0" ]
  grep -q "source: 변이" "$F"
}

@test "pr-sweeper checks out the repo before using the local telegram-notify action (F8)" {
  # ⚠️ codex pass2 F8: 로컬 액션은 체크아웃된 레포에서 resolve된다 — checkout이 telegram-notify보다 앞서야.
  co=$(grep -nE 'uses:[[:space:]]*actions/checkout' "$F" | head -1 | cut -d: -f1)
  tg=$(grep -nE 'uses:[[:space:]]*\./\.github/actions/telegram-notify' "$F" | head -1 | cut -d: -f1)
  [ -n "$co" ]
  [ -n "$tg" ]
  [ "$co" -lt "$tg" ]
}

@test "no workflow uses a local ./.github/actions composite without an actions/checkout (F8 systemic)" {
  # F8 재발 방지: 로컬 composite를 쓰는 모든 워크플로는 checkout을 가져야 한다(파일 단위 presence 가드).
  WFDIR="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)/.github/workflows"
  bad=""
  for w in "$WFDIR"/*.yml "$WFDIR"/*.yaml; do
    [ -e "$w" ] || continue
    if grep -qE 'uses:[[:space:]]*\./\.github/actions/' "$w"; then
      grep -qE 'uses:[[:space:]]*actions/checkout' "$w" || bad="$bad $(basename "$w")"
    fi
  done
  [ -z "$bad" ] || { echo "로컬 액션 쓰는데 checkout 없는 워크플로:$bad"; false; }
}
```

**Step 2: Run it, expect FAIL** — `bats tools/test/pr-sweeper.bats`
기대 실패: 모든 테스트가 파일 부재로 실패 — `yq`가 빈 파일/없는 파일에서 `null`을 내거나 grep이 매치 0 → 첫 `@test`부터 `(line 17) [ -n "$output" ]` 또는 grep 실패.

**Step 3: Minimal implementation** — `.github/workflows/pr-sweeper.yml`:

```yaml
# stale auto-merge-pending PR 스위퍼 (races-3/obs-5).
# strict=true 분기보호 + 비동기 auto-merge면 동시 2번째 봇 PR이 main 뒤로 처져(BEHIND) auto-merge가
# 영원히 무장만 한 채 멈춘다("PR 생성됨(머지 대기)"는 "배포됨"이 아니다 — obs-5). 주기적으로 열린
# 봇 PR 중 auto-merge 무장 + BEHIND인 것만 update-branch해 수렴을 깨운다. 다른 PR은 손대지 않는다.
name: pr-sweeper
on:
  schedule:
    - cron: "*/30 * * * *"
  workflow_dispatch: {}

# 직렬화 불필요(읽고 update-branch만; 머지는 GitHub auto-merge가) — 단 동시 중복은 무의미하니 single.
concurrency:
  group: pr-sweeper
  cancel-in-progress: true

permissions:
  contents: read

jobs:
  sweep:
    runs-on: ubuntu-24.04-arm
    steps:
      # ⚠️ codex pass2 F8: 로컬 composite(아래 telegram-notify)는 체크아웃된 레포에서 resolve된다 —
      # checkout이 없으면 failure 알림 스텝이 액션 로드 실패로 죽어 알림 자체가 안 간다. 첫 스텝으로 checkout.
      - uses: actions/checkout@v4
      # writer App: 봇 PR 브랜치 update + auto-merge 무장 확인(Contents+PR write).
      - uses: actions/create-github-app-token@bcd2ba49218906704ab6c1aa796996da409d3eb1 # v3.2.0
        id: writer
        with:
          app-id: ${{ secrets.HOMELAB_WRITER_APP_ID }}
          private-key: ${{ secrets.HOMELAB_WRITER_APP_PRIVATE_KEY }}
          permission-contents: write
          permission-pull-requests: write
      - name: behind한 auto-merge-pending 봇 PR을 update-branch
        env:
          GH_TOKEN: ${{ steps.writer.outputs.token }}
          REPO: ${{ github.repository }}
        run: |
          # 열린 PR 중 봇 head prefix만 — autoMergeRequest!=null(무장됨) && mergeStateStatus=BEHIND.
          # update-branch는 main을 머지해 BEHIND를 풀고, gate 재실행 → green이면 auto-merge가 머지한다.
          gh pr list --repo "$REPO" --state open \
            --json number,headRefName,mergeStateStatus,autoMergeRequest \
            --jq '.[] | select(.autoMergeRequest != null)
                       | select(.mergeStateStatus == "BEHIND")
                       | select(.headRefName | test("^(bump|bump-poll|create-database|create-cache|create-app|onboard|update-secrets)/"))
                       | .number' > /tmp/behind.txt
          if [ ! -s /tmp/behind.txt ]; then echo "behind한 봇 PR 없음 — no-op"; exit 0; fi
          while read -r n; do
            [ -n "$n" ] || continue
            echo "update-branch PR #$n"
            gh pr update-branch "$n" --repo "$REPO" || echo "::warning::PR #$n update-branch 실패(충돌 가능) — 다음 주기 재시도"
          done < /tmp/behind.txt
      - name: telegram notify (실패 시)
        if: failure()
        uses: ./.github/actions/telegram-notify
        with:
          status: failure
          source: 변이
          title: PR 스위퍼
          link: ${{ github.server_url }}/${{ github.repository }}/actions/runs/${{ github.run_id }}
          bot-token: ${{ secrets.TELEGRAM_BOT_TOKEN }}
          chat-id: ${{ secrets.TELEGRAM_CHAT_ID }}
```

**Step 4: Run test, expect PASS** — `bats tools/test/pr-sweeper.bats && bats tools/test/workflow-yaml.bats`
기대 출력: pr-sweeper 7 tests 0 failures(F8 checkout 가드 2건 포함), workflow-yaml 통과. (telegram-callsites.bats의 "exactly 15 expected workflows" 단언이 16번째를 셀 수 있으니 Task 5에서 그 enum을 갱신한다.)

**Step 5: Commit**
`git -C /Users/ukyi/workspace/homelab-cicd-hardening add .github/workflows/pr-sweeper.yml tools/test/pr-sweeper.bats && git -C /Users/ukyi/workspace/homelab-cicd-hardening commit -m "feat: stale auto-merge-pending PR 스위퍼 워크플로 추가 (BEHIND 봇 PR update-branch 수렴)"`

---

### Task 5: telegram-callsites enum에 pr-sweeper 등록 (obs-5 부속)

**Files:**
- Modify (test) `tools/test/telegram-callsites.bats:10-33` (열거 목록 + 합계)

**Step 1: Write the failing test** — 이미 존재하는 enum 테스트가 pr-sweeper(1)를 포함하도록 here-doc과 합계를 갱신한다. 갱신 자체가 "현재 16곳" 사실을 단언으로 굳힌다.

```bats
@test "exactly the 16 expected workflows notify via the action (enumerated, bump=2, tf-reconcile=3)" {
  total=0
  while read -r wf n; do
    [ -n "$wf" ] || continue
    got=$(grep -c "uses: ./.github/actions/telegram-notify" "$WF/$wf" 2>/dev/null || true)
    [ "${got:-0}" -eq "$n" ] || { echo "$wf: want $n got ${got:-0}"; false; }
    total=$(( total + ${got:-0} ))
  done <<'EOF'
_create-app.yml 1
_create-database.yml 1
_create-cache.yml 1
_update-secrets.yml 1
_teardown.yml 1
_audit.yml 1
bump.yaml 2
bump-poll.yml 1
onboard.yaml 1
iac.yaml 1
tf-reconcile.yml 3
dispatch-mutation.yml 1
pr-sweeper.yml 1
EOF
  [ "$total" -eq 16 ]
  ! grep -rq "api.telegram.org" "$WF"   # raw curl 0
}
```

**Step 2: Run it, expect FAIL** — 먼저 갱신 *전* 상태에서 pr-sweeper.yml이 추가됐으므로 기존 "exactly the 15" 테스트가 이미 깨져 있음: `bats tools/test/telegram-callsites.bats`
기대 실패: `[ "$total" -eq 15 ]` 실패(total=16) — 즉 Task 4 머지로 인해 이 테스트가 빨개진 상태를 이 Task가 고친다. (TDD 순서상 Task 4 직후 이 테스트가 RED → Step 3에서 GREEN.)

**Step 3: Minimal implementation** — Step 1의 블록으로 `tools/test/telegram-callsites.bats:10-33`의 첫 `@test`를 교체(제목 15→16, here-doc에 `pr-sweeper.yml 1` 추가, 합계 16).

**Step 4: Run test, expect PASS** — `bats tools/test/telegram-callsites.bats`
기대 출력: `4 tests, 0 failures` (첫 테스트 포함 전부 ok).

**Step 5: Commit**
`git -C /Users/ukyi/workspace/homelab-cicd-hardening add tools/test/telegram-callsites.bats && git -C /Users/ukyi/workspace/homelab-cicd-hardening commit -m "test: telegram 콜사이트 enum에 pr-sweeper 등록 (16곳)"`

---

### Task 6: auto-merge 알림 ident/body를 'PR 생성됨(머지 대기)'로 정정 (obs-5)

**Files:**
- Modify `.github/workflows/_create-database.yml:91-99` (telegram body)
- Modify `.github/workflows/_create-cache.yml:93-101`
- Modify `.github/workflows/_update-secrets.yml:89-97`
- Modify `.github/workflows/bump.yaml:112-119` 및 `:198-205`
- Create (test) — `pr-sweeper.bats`에 알림 시맨틱 단언 추가(파일 정합 검사)

**Step 1: Write the failing test** — `tools/test/pr-sweeper.bats`에 추가: auto-merge 경로 워크플로의 telegram body가 "배포됨/완료" 같은 종결 어휘 대신 "머지 대기"를 담아 obs-5(무장 ≠ 배포)를 표면화하는지 검사.

```bats
@test "auto-merge workflows phrase success as 'PR 생성됨(머지 대기)' not as deployed" {
  WF="$ROOT/.github/workflows"
  # obs-5: auto-merge 성공은 "PR 무장"이지 "배포 완료"가 아니다 — 알림 body가 그 사실을 드러낸다.
  for f in _create-database.yml _create-cache.yml _update-secrets.yml; do
    grep -q "머지 대기" "$WF/$f" || { echo "missing '머지 대기' notice in $f"; false; }
  done
}
```

**Step 2: Run it, expect FAIL** — `bats tools/test/pr-sweeper.bats`
기대 실패: `missing '머지 대기' notice in _create-database.yml` — 현재 body는 "핸들 …" 만 담는다.

**Step 3: Minimal implementation** — 각 auto-merge 워크플로의 `telegram notify` 스텝 `body:`(또는 ident)에 머지-대기 단서를 추가한다. 비밀번호/URL 노출 규약은 유지(핸들 이름만).

- `_create-database.yml:99` `body:`를 다음으로:
  ```yaml
          body: "PR 생성됨(머지 대기) · 핸들 db-${{ steps.spec.outputs.name }}-conn / db-${{ steps.spec.outputs.name }}-ro-conn (prod)"
  ```
- `_create-cache.yml:101` `body:`를:
  ```yaml
          body: "PR 생성됨(머지 대기) · conn 핸들 cache-${{ steps.spec.outputs.name }}-conn (prod)"
  ```
- `_update-secrets.yml`: 현재 body 없음 — `ident:` 다음 줄에 추가:
  ```yaml
          body: "PR 생성됨(머지 대기)"
  ```
- `bump.yaml`: 두 notify 스텝(`title: 이미지 태그 갱신`)에 `body:` 추가 — `ident:` 다음 줄:
  ```yaml
          body: "PR 생성됨(머지 대기)"
  ```

(success/failure 양쪽에서 같은 step이 발화하지만 body는 정보성이라 무해 — `job.status`가 실패면 글리프가 🔴로 구분된다.)

**Step 4: Run test, expect PASS** — `bats tools/test/pr-sweeper.bats && bats tools/test/telegram-callsites.bats`
기대 출력: pr-sweeper 전체 통과(머지-대기 단언 포함), telegram-callsites 회귀 없음(body 키는 required set에 없으므로 "required with: keys" 단언 무영향).

**Step 5: Commit**
`git -C /Users/ukyi/workspace/homelab-cicd-hardening add .github/workflows/_create-database.yml .github/workflows/_create-cache.yml .github/workflows/_update-secrets.yml .github/workflows/bump.yaml tools/test/pr-sweeper.bats && git -C /Users/ukyi/workspace/homelab-cicd-hardening commit -m "fix: auto-merge 알림을 'PR 생성됨(머지 대기)'로 정정 (무장≠배포 표면화)"`

---

### Task 7: bump-poll 루프에 --expect-current TOCTOU 가드 배선 (races-4)

**Files:**
- Modify `.github/workflows/bump-poll.yml:96-99` (checkout main 후 bump-tag 호출)
- Create (test) `tools/test/bump-poll-toctou.bats`

**Step 1: Write the failing test** — `tools/test/bump-poll-toctou.bats`. `--expect-current` 옵션은 **Phase 2에서 bump-tag.mjs에 구축**된다(여기선 사용만). 이 테스트는 워크플로가 plan→push 사이 `git checkout main` 후 현재 tag를 재증명하도록 `--expect-current`를 넘기는지 정적 검사한다.

```bats
#!/usr/bin/env bats
# races-4: bump-poll의 plan(descendant/digest 증명)은 한 스냅샷 기준 — checkout main 후 push 사이
# main이 움직이면 stale 증명을 push할 수 있다. bump-tag.mjs --expect-current(Phase 2 구축)로
# bump 직전 values의 현재 tag가 플래너가 본 from-tag와 같음을 재증명한다(불일치면 fail-closed).
# ⚠️ 중간 단언은 [ ]만. @test 이름은 영어.

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  F="$ROOT/.github/workflows/bump-poll.yml"
}

@test "bump-poll passes --expect-current to bump-tag after checkout main (TOCTOU guard)" {
  # 플래너 item의 from-tag(현재 배포 tag)를 추출해 bump-tag에 재증명용으로 넘긴다.
  grep -q -- "--expect-current" "$F"
  # bump-tag 호출과 같은 라인/스텝에 --digest와 함께 존재해야 한다(같은 명령)
  run grep -E 'bump-tag\.mjs .*--expect-current|--expect-current.*bump-tag\.mjs' "$F"
  [ "$status" -eq 0 ]
}

@test "bump-poll still checks out main fresh before each branch (snapshot reset)" {
  grep -q "git checkout main" "$F"
}

@test "expect-current is sourced from the planner snapshot, not re-read from live values.yaml (F2)" {
  # ⚠️ codex pass1 F2: checkout 후 values.yaml에서 재읽기하면 main이 움직여도 expect가 같이 움직여
  # 자기비교(no-op)가 된다. 플래너 스냅샷($item의 .current.tag)에서 와야 fail-closed가 실효한다.
  run grep -E 'expect=.*(yq|cat).*values\.yaml' "$F"
  [ "$status" -ne 0 ]
  run grep -E 'expect=.*\.current\.tag' "$F"
  [ "$status" -eq 0 ]
}
```

**Step 2: Run it, expect FAIL** — `bats tools/test/bump-poll-toctou.bats`
기대 실패: `\`grep -q -- "--expect-current" "$F"' failed` — 현재 bump-poll은 `--expect-current`를 넘기지 않는다. F2 케이스도 `expect=...current.tag` 미발견으로 실패.

**Step 3: Minimal implementation** — `bump-poll.yml`의 bump 루프(88-99)에서 **플래너 item의 `.current.tag`**(plan 시점에 기록된 현재 배포 tag — `poll-ghcr.mjs`가 `result.current = { tag, digest }`로 emit하며 각 plan item에 `.current.tag`로 존재)를 뽑아 `--expect-current`로 넘긴다. 96-99를 다음으로 교체:

```sh
            git checkout main
            branch="bump-poll/${app}-${RUN_ID}"
            git checkout -b "$branch"
            # races-4 TOCTOU 가드: 플래너가 증명한 from-tag는 plan JSON의 `.current.tag`(plan 시점 스냅샷)다.
            # ⚠️ codex pass1 F2: checkout main 후 values.yaml에서 다시 읽으면 main이 움직여도 그 값이 같이
            # 움직여 "자기 자신과 비교"가 돼 가드가 no-op이 된다 → 반드시 플래너 스냅샷($item.current.tag)을 쓴다.
            # checkout 직후의 실측 image.tag가 이 expect와 다르면(=plan 이후 main 이동) bump-tag가 fail-closed로
            # 중단(stale 증명 push 방지) — 다음 주기가 새 스냅샷으로 다시 plan한다.
            expect=$(echo "$item" | jq -r '.current.tag')
            node tools/bump-tag.mjs "$app" "$tag" --digest "$digest" --expect-current "$expect"
```

(`--expect-current`는 Phase 2에서 "현재 image.tag가 인자와 다르면 exit 2"로 구현된다 — 본 Task는 그 옵션을 호출 경로에 배선만 한다. Phase 6은 Phase 2 머지 이후 순서.)

**Step 4: Run test, expect PASS** — `bats tools/test/bump-poll-toctou.bats && bats tools/test/workflow-yaml.bats`
기대 출력: bump-poll-toctou 3 tests 0 failures, workflow-yaml YAML 파싱 통과.

**Step 5: Commit**
`git -C /Users/ukyi/workspace/homelab-cicd-hardening add .github/workflows/bump-poll.yml tools/test/bump-poll-toctou.bats && git -C /Users/ukyi/workspace/homelab-cicd-hardening commit -m "fix: bump-poll 루프에 --expect-current TOCTOU 가드 배선 (stale 증명 push 차단)"`

---

### Task 8: activate-app가 증명한 surface 마커를 커밋 (races-5, part 1)

**Files:**
- Create `tools/lib/surface-hash.mjs` (`.activation` 제외 canonical surface 해시 — 마커·감사 공용 SSOT + CLI)
- Modify `tools/activate-app.mjs` (상단 import + flip 블록 86-94에서 `.activation` 마커 기록)
- Modify (test) `tools/test/activate-app.bats` (마커 기록 + 자기-무효화 회귀 단언)

> ⚠️ codex pass1 F3: `apps/<app>` 전체 tree-hash는 `.activation` 마커 자신을 포함하므로 마커를 커밋하는 순간
> tree-hash가 바뀐다 → 정상 활성 앱이 전부 `activation-surface-drift`로 오탐. **`.activation`을 제외한 canonical
> 해시**를 쓰고, 마커 기록(Task 8)과 감사(Task 9)가 `tools/lib/surface-hash.mjs`의 동일 함수를 호출한다.
> 이 Task의 fixture(`$R`)는 **git repo여야** 한다(`surfaceHash`가 `git ls-tree <rev>:apps/<app>`를 읽음) —
> 기존 activate-app.bats setup이 git repo가 아니면 `git init` + 초기 커밋을 setup에 추가한다.

**Step 1: Write the failing test** — `tools/test/activate-app.bats`에 추가: `--flip` 통과 시 `.activation`이 증명한 sha + canonical surfaceHash를 담아 기록되고, **마커 커밋 후에도 해시가 동일**한지(자기 무효화 회귀) 검사.

```bats
@test "writes a committed .activation marker with the proved sha and canonical surfaceHash on flip" {
  run node "$A" --app orders --sha "$SHA" --synced-rev "$SHA" \
    --repo-dir "$R" --status-file "$TMP/status.json" --flip
  [ "$status" -eq 0 ]
  M="$R/apps/orders/deploy/prod/.activation"
  [ -f "$M" ]
  run jq -r '.sha' "$M"
  [ "$output" == "$SHA" ]
  # surfaceHash는 공용 lib(.activation 제외)와 동일 알고리즘 결과여야 한다 — 테스트도 같은 CLI를 호출.
  expected=$(node "$ROOT/tools/lib/surface-hash.mjs" "$R" HEAD orders)
  run jq -r '.surfaceHash' "$M"
  [ "$output" == "$expected" ]
}

@test "marker surfaceHash stays valid AFTER the .activation marker is committed (F3 self-invalidation)" {
  # ⚠️ codex pass1 F3 회귀: 마커를 커밋하면 apps/orders 트리가 바뀌지만 canonical 해시는 .activation을
  # 제외하므로 커밋 전/후가 동일해야 한다(자기 무효화 금지). 이 케이스가 없으면 F3 회귀를 못 잡는다.
  before=$(node "$ROOT/tools/lib/surface-hash.mjs" "$R" HEAD orders)
  run node "$A" --app orders --sha "$SHA" --synced-rev "$SHA" \
    --repo-dir "$R" --status-file "$TMP/status.json" --flip
  [ "$status" -eq 0 ]
  git -C "$R" add -A
  git -C "$R" commit -qm "activate orders (+.activation marker)"
  after=$(node "$ROOT/tools/lib/surface-hash.mjs" "$R" HEAD orders)
  [ "$before" == "$after" ]
  run jq -r '.surfaceHash' "$R/apps/orders/deploy/prod/.activation"
  [ "$output" == "$after" ]
}

@test "does not write .activation when flip is not requested (gate-only run)" {
  run node "$A" --app orders --sha "$SHA" --synced-rev "$SHA" \
    --repo-dir "$R" --status-file "$TMP/status.json"
  [ "$status" -eq 0 ]
  [ ! -f "$R/apps/orders/deploy/prod/.activation" ]
}
```

**Step 2: Run it, expect FAIL** — `bats tools/test/activate-app.bats`
기대 실패: `(line: [ -f "$M" ]) failed` — `.activation`이 기록되지 않는다(마커/lib 미구현).

**Step 3: Minimal implementation** —

(a) `tools/lib/surface-hash.mjs` 신규 — 마커·감사 공용 canonical 해시(`.activation` 제외):

```js
import { createHash } from "node:crypto";
import { execFileSync } from "node:child_process";

// apps/<app>의 canonical surface 해시 — .activation 마커 자신은 제외한다.
// ⚠️ codex pass1 F3: apps/<app> 전체 tree-hash는 .activation을 포함해 마커 커밋 즉시 자기 무효화한다
// (정상 활성 앱이 전부 surface-drift로 오탐). marker 기록(activate-app)과 감사(audit-orphans)가
// 이 함수를 동일하게 호출해야 일치한다. rev: 커밋 ref(syncedRev 또는 "HEAD"). 실패 시 "" 반환.
export function surfaceHash(repoDir, rev, app) {
  let out;
  try {
    out = execFileSync("git", ["-C", repoDir, "ls-tree", "-r", `${rev}:apps/${app}`], { encoding: "utf8" });
  } catch {
    return "";
  }
  const lines = out.split("\n")
    .filter((l) => l && !l.endsWith("\tdeploy/prod/.activation"))
    .sort();
  return createHash("sha256").update(lines.join("\n")).digest("hex");
}

// CLI: node tools/lib/surface-hash.mjs <repoDir> <rev> <app> → 해시 출력(테스트가 동일 알고리즘 재사용).
if (process.argv[1] && process.argv[1].endsWith("surface-hash.mjs")) {
  const [repoDir, rev, app] = process.argv.slice(2);
  process.stdout.write(surfaceHash(repoDir, rev, app));
}
```

(b) `tools/activate-app.mjs` 상단 import에 `import { surfaceHash } from "./lib/surface-hash.mjs";` 추가 후 flip 블록(86-93)을 확장한다(라이브 Healthy 재증명은 런북 단계로 분리 — design 명시):

```js
// 게이트 전부 통과 — active:true 플립(워크트리). host/public은 절대 건드리지 않는다.
if (args.flip) {
  const rows = JSON.parse(currentRaw);
  const row = rows.find((r) => r.name === app);
  if (row.active === true) console.error("activate-app: 이미 active — 멱등 no-op");
  row.active = true;
  writeFileSync(appsJsonPath, JSON.stringify(rows, null, 2) + "\n");
  // races-5: 증명한 surface를 커밋된 마커로 남긴다. ⚠️ codex F3: .activation 제외 canonical 해시를 syncedRev에서
  // 계산(마커 자기 무효화 방지). ⚠️ codex pass3 F1: 이 마커는 **정보성**이다 — audit이 차단 게이트로 쓰면 정상
  // 이미지 bump(surface 변경)가 머지 불가가 되고, 새 revision은 머지돼야 Healthy가 되므로 데드락. 노출 재검증은
  // 런북(activate 절차)이 담당한다. 빈 해시여도 마커는 남기고 audit이 정보성 missing-activation으로 표시한다.
  // ⚠️ codex pass4 F1: DNS 노출은 apps/<app> 트리뿐 아니라 apps.json의 노출 행(host/public/active)이 결정한다.
  // 마커에 그 행 projection을 포함해, activation 이후 host/public 변경(앱 트리 무변경)도 정보성으로 잡는다.
  const registryRow = { name: row.name, host: row.host ?? null, public: row.public ?? false };
  const marker = { app, sha, syncedRev, surfaceHash: surfaceHash(repoDir, syncedRev, app), registry: registryRow, activatedAt: new Date().toISOString() };
  writeFileSync(
    path.join(repoDir, `apps/${app}/deploy/prod/.activation`),
    JSON.stringify(marker, null, 2) + "\n",
  );
}
```

**Step 4: Run test, expect PASS** — `bats tools/test/activate-app.bats`
기대 출력: 기존 6 + 신규 3 = `9 tests, 0 failures` (마커 기록 + 자기-무효화 회귀 + 미기록 통과).

**Step 5: Commit**
`git -C /Users/ukyi/workspace/homelab-cicd-hardening add tools/lib/surface-hash.mjs tools/activate-app.mjs tools/test/activate-app.bats && git -C /Users/ukyi/workspace/homelab-cicd-hardening commit -m "feat: activate-app가 .activation 제외 canonical surfaceHash를 마커로 커밋 (races-5)"`

---

### Task 9: audit-orphans에 activation surface-drift 체크 추가 (races-5, part 2)

**Files:**
- Modify `tools/audit-orphans.mjs:34,53-57,100-106` (BLOCKING set + active 행 마커 대조)
- Modify (test) `tools/test/audit-orphans.bats` (surface-drift 단언)

**Step 1: Write the failing test** — `tools/test/audit-orphans.bats`에 추가: active:true 앱의 `.activation` surfaceHash가 현재 canonical surfaceHash와 다르면 `activation-surface-drift`가 **정보성으로 리포트**된다(⚠️ codex pass3 F1: `--ci` **비차단** — 차단하면 정상 이미지 bump가 데드락). fixture는 git repo가 필요(canonical 해시 계산) — 픽스처 setup을 보강하거나 별도 setup의 새 describe로.

```bats
@test "audit REPORTS surface drift for an active app changed after activation (informational, non-blocking)" {
  # active:true + .activation 마커(옛 tree-hash) + 그 후 apps/<app> 표면 변경 → drift.
  # git repo로 tree-hash를 계산한다(마커 포맷과 동일 알고리즘).
  G="$TMP/git"; mkdir -p "$G"; cp -R "$FR/." "$G/"
  git -C "$G" init -q -b main; git -C "$G" config user.email t@t; git -C "$G" config user.name t
  git -C "$G" add -A; git -C "$G" commit -qm init
  oldhash=$(node "$ROOT/tools/lib/surface-hash.mjs" "$G" HEAD orders)  # .activation 제외 canonical
  printf '{"app":"orders","sha":"abc1234","syncedRev":"abc1234","surfaceHash":"%s"}\n' "$oldhash" \
    > "$G/apps/orders/deploy/prod/.activation"
  # 마커 기록 후 표면 변경
  printf 'image: {repo: x, tag: sha-NEW9999}\nroute: {public: true, host: orders.example.com}\n' \
    > "$G/apps/orders/deploy/prod/values.yaml"
  git -C "$G" add -A; git -C "$G" commit -qm "surface change post-activation"
  # apps.json: orders만 active:true (ghost 제거해 orphan-dns 노이즈 배제)
  echo '[{ "name": "orders", "host": "orders.example.com", "public": true, "active": true }]' \
    > "$G/infra/cloudflare/apps.json"
  # ⚠️ codex pass3 F1: surface-drift는 정보성 — --ci를 막지 않는다(정상 bump 데드락 방지). 리포트는 된다.
  run node "$ROOT/tools/audit-orphans.mjs" --repo-root "$G" --ci
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "activation-surface-drift"
}

@test "audit does NOT flag an active app whose surface matches AFTER the .activation marker is committed (F3 regression)" {
  G="$TMP/git2"; mkdir -p "$G"; cp -R "$FR/." "$G/"
  git -C "$G" init -q -b main; git -C "$G" config user.email t@t; git -C "$G" config user.name t
  echo '[{ "name": "orders", "host": "orders.example.com", "public": true, "active": true }]' \
    > "$G/infra/cloudflare/apps.json"
  git -C "$G" add -A; git -C "$G" commit -qm init
  # ⚠️ codex pass1 F3: canonical surfaceHash(.activation 제외)로 마커를 만들고 .activation을 **커밋**한다.
  # 커밋이 apps/orders 트리를 바꿔도 canonical 해시는 불변이라 drift가 없어야 한다(자기 무효화 회귀).
  curhash=$(node "$ROOT/tools/lib/surface-hash.mjs" "$G" HEAD orders)
  printf '{"app":"orders","sha":"abc1234","syncedRev":"abc1234","surfaceHash":"%s"}\n' "$curhash" \
    > "$G/apps/orders/deploy/prod/.activation"
  git -C "$G" add -A; git -C "$G" commit -qm "activate orders (+.activation marker)"
  run node "$ROOT/tools/audit-orphans.mjs" --repo-root "$G"
  [ "$status" -eq 0 ]
  run sh -c 'echo "$1" | grep -c activation-surface-drift' _ "$output"
  [ "$output" -eq 0 ]
}

@test "audit REPORTS missing-activation for an active app with no marker but does NOT block (F1 non-blocking)" {
  # ⚠️ codex pass3 F1: 마커 없음은 정보성 missing-activation — --ci를 막지 않는다(정상 active-app 데드락 방지).
  G="$TMP/git3"; mkdir -p "$G"; cp -R "$FR/." "$G/"
  git -C "$G" init -q -b main; git -C "$G" config user.email t@t; git -C "$G" config user.name t
  echo '[{ "name": "orders", "host": "orders.example.com", "public": true, "active": true }]' \
    > "$G/infra/cloudflare/apps.json"
  rm -f "$G/apps/orders/deploy/prod/.activation"
  git -C "$G" add -A; git -C "$G" commit -qm init
  run node "$ROOT/tools/audit-orphans.mjs" --repo-root "$G" --ci
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "missing-activation"
}

@test "audit REPORTS surface drift when only apps.json host/public changes after activation (F1)" {
  # ⚠️ codex pass4 F1: 앱 트리(apps/<app>) 무변경이어도 apps.json의 host/public가 바뀌면 DNS 노출이 변한다 →
  # 마커의 registry projection과 불일치 → 정보성 surface-drift. (비차단 — --ci status 0.)
  G="$TMP/git5"; mkdir -p "$G"; cp -R "$FR/." "$G/"
  git -C "$G" init -q -b main; git -C "$G" config user.email t@t; git -C "$G" config user.name t
  echo '[{ "name": "orders", "host": "orders.example.com", "public": true, "active": true }]' \
    > "$G/infra/cloudflare/apps.json"
  curhash=$(node "$ROOT/tools/lib/surface-hash.mjs" "$G" HEAD orders)
  # 마커는 옛 host(orders.example.com)로 기록
  printf '{"app":"orders","sha":"abc1234","syncedRev":"abc1234","surfaceHash":"%s","registry":{"name":"orders","host":"orders.example.com","public":true}}\n' "$curhash" \
    > "$G/apps/orders/deploy/prod/.activation"
  git -C "$G" add -A; git -C "$G" commit -qm init
  # 앱 트리는 그대로 두고 apps.json host만 변경(노출 표면 변경)
  echo '[{ "name": "orders", "host": "neworders.example.com", "public": true, "active": true }]' \
    > "$G/infra/cloudflare/apps.json"
  run node "$ROOT/tools/audit-orphans.mjs" --repo-root "$G" --ci
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "activation-surface-drift"
}
```

**Step 2: Run it, expect FAIL** — `bats tools/test/audit-orphans.bats`
기대 실패: 신규 테스트(`activation-surface-drift`·`missing-activation` 미인지)가 실패 — audit-orphans가 아직 이 유형들을 모른다.

**Step 3: Minimal implementation** — `tools/audit-orphans.mjs`에 추가:

1) BLOCKING set 확장(34행):
```js
const BLOCKING = new Set(["dangling-binding", "orphan-dns"]); // ⚠️ codex pass3 F1: activation-* 는 비차단(정보성) — 차단 게이트는 정상 이미지 bump를 데드락시킨다(아래)
```

2) `tools/lib/surface-hash.mjs`(Task 8에서 생성)에서 `surfaceHash`를 import(`import { surfaceHash } from "./lib/surface-hash.mjs";`)한 뒤, registry↔매니페스트 루프(54-57) 다음에 active 행 surface-drift 체크 블록 추가. ⚠️ codex pass1 F3: 마커·감사 **둘 다** `.activation` 제외 canonical 해시를 써야 자기 무효화가 없다(직접 `rev-parse :apps/<app>` 금지 — 마커 커밋이 tree-hash를 바꿔 전 앱 오탐):

```js
// 1b) activation surface-drift (races-5) — active:true(+ 매니페스트 존재) 앱의 커밋된 .activation
// surfaceHash가 현재 canonical surfaceHash(.activation 제외)와 다르면, activation 이후 표면이 바뀐 것.
// ⚠️ codex pass3 F1: **정보성만**(BLOCKING 아님). 차단 게이트로 쓰면 정상 이미지 bump(values.yaml의
// image.tag 변경 → surface 변경)가 머지 불가가 되고, 새 revision은 머지돼야 Healthy가 되므로 데드락
// (autoDeploy 붕괴). 노출 재검증은 런북(activate 절차)이 담당한다. canonical 해시(F3)는 .activation 자기
// 무효화로 인한 false-positive 노이즈를 막기 위해 여전히 필요하다.
for (const r of registry) {
  if (r.active !== true || !appDirs.includes(r.name)) continue;
  const markerPath = `${appsRoot}/${r.name}/deploy/prod/.activation`;
  const marker = readJson(markerPath, null);
  if (!marker || !marker.surfaceHash) {
    add("missing-activation", r.name, "active:true인데 .activation 마커 없음/빈 surfaceHash — 정보성(activate-app 재실행 또는 런북 재검증 권장)");
    continue;
  }
  const current = surfaceHash(ROOT, "HEAD", r.name); // .activation 제외 canonical — 마커와 동일 함수
  if (current && current !== marker.surfaceHash)
    add("activation-surface-drift", r.name, `activation 이후 apps/${r.name} 표면 변경(정보성 — 런북 재검증 권장; 마커 ${String(marker.surfaceHash).slice(0, 12)} ≠ 현재 ${current.slice(0, 12)})`);
  // ⚠️ codex pass4 F1: apps.json 노출 행(host/public)이 바뀌면 앱 트리 무변경이어도 DNS 노출이 변한다 — 정보성으로 잡는다.
  const curProj = { name: r.name, host: r.host ?? null, public: r.public ?? false };
  if (marker.registry && JSON.stringify(curProj) !== JSON.stringify(marker.registry))
    add("activation-surface-drift", r.name, `activation 이후 apps.json 노출 행 변경(host/public — 마커 ${JSON.stringify(marker.registry)} ≠ 현재 ${JSON.stringify(curProj)}) — 런북 재검증 권장`);
}
```

(⚠️ codex pass3 F1: `activation-surface-drift`·`missing-activation`은 **비차단(정보성)**이다 — `--ci`를 막지 않아 정상 active-app 이미지 bump가 데드락되지 않는다. 마커는 가시성/런북 재검증 트리거용. `!appDirs.includes`로 매니페스트 없는 행(orphan-dns 케이스)은 skip. waive 메커니즘은 차단이 없어 불필요 — 제거.)

**Step 4: Run test, expect PASS** — `bats tools/test/audit-orphans.bats`
기대 출력: 기존 + 신규 테스트(surface-drift 정보성 리포트 / 커밋 후 무드리프트 / 마커없음 정보성) 전부 `ok`. activation-* 는 `--ci` 비차단이라 정상 bump PR을 막지 않는다.

**Step 5: Commit**
`git -C /Users/ukyi/workspace/homelab-cicd-hardening add tools/audit-orphans.mjs tools/test/audit-orphans.bats && git -C /Users/ukyi/workspace/homelab-cicd-hardening commit -m "feat: audit-orphans에 activation surface-drift 정보성 리포트 추가 (races-5, 비차단)"`

---

### Task 10: onboard 고정 브랜치명에 run_id 부여 (fm-2)

**Files:**
- Modify `.github/workflows/onboard.yaml:83`
- Create (test) — `tools/test/onboard.bats`에 브랜치명 단언 추가(파일 존재 확인 후 적절 위치)

**Step 1: Write the failing test** — `tools/test/onboard.bats`에 추가(워크플로 정적 검사 형식). 고정 `onboard/${APP}` 금지, `${{ github.run_id }}` 포함을 강제 — 다른 모든 dispatch reusable과 동일 패턴.

```bats
@test "onboard branch name is run-scoped (no fixed collision-prone branch)" {
  WF="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)/.github/workflows/onboard.yaml"
  # fm-2: 고정 onboard/<app>는 재dispatch 시 충돌해 게이트 후 abort + dangling 브랜치를 남긴다.
  # 모든 dispatch reusable처럼 run_id로 유일화한다.
  ! grep -qE 'branch="onboard/\$\{APP\}"' "$WF"
  grep -q 'github.run_id' "$WF"
  grep -qE 'branch="onboard/\$\{APP\}-' "$WF"
}
```

(이 테스트는 `onboard.bats` 어디에 넣든 setup의 `$ROOT` 의존이 있으면 그걸 쓰고, 없으면 위처럼 인라인 경로 계산. 기존 onboard.bats setup을 먼저 읽어 일관되게 배치한다.)

**Step 2: Run it, expect FAIL** — `bats tools/test/onboard.bats`
기대 실패: `\`! grep -qE 'branch="onboard/\$\{APP\}"' "$WF"' failed` — 현재 onboard.yaml:83이 `branch="onboard/${APP}"`(run_id 없음)라 grep이 매치해 부정(`!`)이 실패한다.

**Step 3: Minimal implementation** — `onboard.yaml`의 PR 스텝에 `RUN_ID` env를 노출하고 브랜치명을 유일화한다.

77-83의 env 블록에 `RUN_ID` 추가:
```yaml
        env:
          GH_TOKEN: ${{ steps.token.outputs.token }}
          APP: ${{ steps.scaffold.outputs.app }}
          RUN_ID: ${{ github.run_id }}
```
그리고 83행:
```sh
          branch="onboard/${APP}-${RUN_ID}"
```

**Step 4: Run test, expect PASS** — `bats tools/test/onboard.bats && bats tools/test/workflow-yaml.bats`
기대 출력: onboard.bats 전체 통과(신규 브랜치명 단언 포함), workflow-yaml YAML 파싱 통과.

**Step 5: Commit**
`git -C /Users/ukyi/workspace/homelab-cicd-hardening add .github/workflows/onboard.yaml tools/test/onboard.bats && git -C /Users/ukyi/workspace/homelab-cicd-hardening commit -m "fix: onboard 브랜치명에 run_id 부여 (재dispatch 충돌·dangling 차단)"`

---

## Phase 6 통합 검증

전 Task 완료 후 게이트 미러 1회:
- `bats tools/test/bump.bats tools/test/automerge-fallback.bats tools/test/pr-sweeper.bats tools/test/bump-poll-toctou.bats tools/test/activate-app.bats tools/test/audit-orphans.bats tools/test/onboard.bats tools/test/telegram-callsites.bats tools/test/workflow-yaml.bats` → 전부 통과.
- `shellcheck $(git -C /Users/ukyi/workspace/homelab-cicd-hardening ls-files '*.sh')` → 신규 `scripts/auto-merge-or-fail.sh` 포함 무경고.
- `make ci` → `gate` 미러 green(8스텝).

**시퀀싱 주의:** Task 7(`--expect-current` 배선)은 **Phase 2가 bump-tag.mjs에 `--expect-current`를 구축한 뒤** 머지해야 라이브에서 동작한다(정적 bats는 Phase 2 없이도 통과 — 호출 존재만 검사). Phase 6 전체는 Phase 2 머지 이후 순서로 배치한다.

---

## Phase 7 — DRY/SSOT + 공급망 위생 (P2)

> 테마7. P2, auto-merge(`gate` 통과). 공유 인프라 중 **`tf-destroy-guard`는 Phase 3에서 이미 구축**됐으므로 여기서 재정의하지 않는다. 이 단계는 `setup-toolchain`에 `kubeseal` input을 추가하고, `setup-node-pnpm`·`tf-r2-init` composite를 신규 구축한 뒤 콜사이트를 수렴시킨다.
>
> 순서 주의: **Task 1(setup-toolchain kubeseal input) → Task 2(checksum) → Task 3(dry-1/dry-2 인라인 흡수)**. dry-1이 onboard/_create-app의 인라인 helm/kubeconform/conftest curl을 제거하므로, 기존 `tools/test/ci-toolchain-pin.bats`의 "인라인 helm 핀" 단언이 깨진다 → Task 3에서 그 테스트를 함께 갱신한다.
>
> bats `@test` 이름은 영어. 중간 단언은 `[ ]`만(bash 3.2 `[[ ]]` 침묵 통과 함정). 모든 신규 `tools/test/*.bats`는 `ci.yaml` gate의 `ls tools/test/*.bats` 글롭에 자동 포함된다.

---

### Task 1: setup-toolchain에 kubeseal input 추가 (dry-2 수렴 토대) (dry-1, dry-2)

봉인 워크플로 2종이 kubeseal을 v0.27.3(`_create-cache`)/v0.37.0(`_create-database`)로 제각각 핀한다. 컨트롤러 appVersion(`platform/sealed-secrets/prod/helmrelease.yaml:9` → app v0.37.0)에 맞춰 단일 `kubeseal` input(v0.37.0)을 SSOT로 추가한다.

**Files:**
- Modify `.github/actions/setup-toolchain/action.yml` (inputs 블록 + runs.steps에 kubeseal step 추가)
- Test `tools/test/setup-toolchain-kubeseal.bats` (Create)

**Step 1: Write the failing test**

```bash
cat > tools/test/setup-toolchain-kubeseal.bats <<'BATS'
#!/usr/bin/env bats
# setup-toolchain composite의 kubeseal input — 봉인 워크플로의 kubeseal 버전 SSOT.
# 컨트롤러 appVersion(helmrelease.yaml app v0.37.0)과 동일 버전으로 수렴(seal/unseal 호환).
# ⚠️ 중간 단언은 [ ]만 — bash 3.2 [[ ]] 침묵 통과.

setup() { ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"; A="$ROOT/.github/actions/setup-toolchain/action.yml"; }

@test "setup-toolchain declares a kubeseal input" {
  run grep -E '^[[:space:]]*kubeseal:' "$A"
  [ "$status" -eq 0 ]
}

@test "setup-toolchain pins kubeseal to v0.37.0 (controller appVersion)" {
  run grep -E 'sealed-secrets/releases/download/v0\.37\.0/kubeseal-0\.37\.0-linux-arm64\.tar\.gz' "$A"
  [ "$status" -eq 0 ]
  # 옛 v0.27.3 핀이 composite에 남지 않았는지
  run grep -E 'kubeseal-0\.27\.3' "$A"
  [ "$status" -ne 0 ]
}

@test "kubeseal step is gated on the kubeseal input" {
  # input이 'true'일 때만 설치 — 다른 잡엔 영향 0
  run grep -E "inputs\.kubeseal == 'true'" "$A"
  [ "$status" -eq 0 ]
}
BATS
```

**Step 2: Run it, expect FAIL**

```bash
bats tools/test/setup-toolchain-kubeseal.bats
```
Expected: `not ok 1 setup-toolchain declares a kubeseal input` (현재 action.yml에 kubeseal input 없음).

**Step 3: Minimal implementation**

`.github/actions/setup-toolchain/action.yml`의 inputs 블록 마지막(`age:` 다음)에 추가:

```yaml
  age:         { description: age latest,            default: 'false' }
  kubeseal:    { description: kubeseal v0.37.0,       default: 'false' }
```

그리고 `runs.steps`의 age step 뒤에 추가:

```yaml
    - if: ${{ inputs.kubeseal == 'true' }}
      shell: bash
      run: |
        # kubeseal 버전 핀 — 컨트롤러 appVersion(platform/sealed-secrets app v0.37.0)과 동일해야 seal/unseal 호환.
        # 봉인 워크플로(_create-cache/_create-database)가 제각각 핀하던 v0.27.3/v0.37.0을 이 한 곳으로 수렴.
        curl -fsSL https://github.com/bitnami-labs/sealed-secrets/releases/download/v0.37.0/kubeseal-0.37.0-linux-arm64.tar.gz \
          | sudo tar xz -C /usr/local/bin kubeseal
```

**Step 4: Run test, expect PASS**

```bash
bats tools/test/setup-toolchain-kubeseal.bats
```
Expected: `ok 1..3`.

**Step 5: Commit**

```bash
git -C /Users/ukyi/workspace/homelab-cicd-hardening add .github/actions/setup-toolchain/action.yml tools/test/setup-toolchain-kubeseal.bats && git -C /Users/ukyi/workspace/homelab-cicd-hardening commit -m "feat: setup-toolchain에 kubeseal input 추가 (봉인 버전 SSOT v0.37.0)"
```

---

### Task 2: 모든 setup-toolchain 다운로드에 SHA256 검증 + age 버전 핀 (supplychain-5)

`setup-toolchain`은 9개 바이너리를 TLS만 믿고 받는다(체크섬 검증 0). `age`는 `latest`(무핀). 각 다운로드 직후 `sha256sum -c`로 검증하고 age를 고정 버전으로 핀한다.

> **체크섬 조달 절차(executor가 실행):** 플레이스홀더 SHA를 절대 커밋하지 마라. 각 핀 버전의 공식 체크섬을 라이브로 받아 기록한다.
> ```bash
> # 예: yq v4.44.6 arm64
> curl -fsSL https://github.com/mikefarah/yq/releases/download/v4.44.6/checksums | grep yq_linux_arm64
> # tarball류는 자산을 직접 받아 sha256sum으로 산출(릴리스가 checksums를 안 줄 때)
> curl -fsSL https://github.com/yannh/kubeconform/releases/download/v0.6.7/kubeconform-linux-arm64.tar.gz | sha256sum
> ```
> helm은 `https://get.helm.sh/helm-v3.16.4-linux-arm64.tar.gz.sha256sum`, sops/kubeseal/shellcheck/kustomize/conftest는 릴리스의 `*checksums*` 자산에서 arm64 라인을 취한다. age는 `https://github.com/FiloSottile/age/releases`의 고정 버전(v1.2.1) 자산 + 체크섬으로 핀.

**Files:**
- Modify `.github/actions/setup-toolchain/action.yml` (각 step에 `sha256sum -c` + age 버전 핀)
- Test `tools/test/toolchain-checksums.bats` (Create)

**Step 1: Write the failing test**

```bash
cat > tools/test/toolchain-checksums.bats <<'BATS'
#!/usr/bin/env bats
# setup-toolchain 다운로드 공급망 위생 — 모든 바이너리가 SHA256 검증을 거치고 age가 핀됐는가.
# TLS만 믿으면 미러/계정 침해 시 변조 바이너리가 gate 러너에서 실행된다.
# ⚠️ 중간 단언은 [ ]만 — bash 3.2 [[ ]] 침묵 통과.

setup() { ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"; A="$ROOT/.github/actions/setup-toolchain/action.yml"; }

@test "age is pinned to a fixed version (not latest)" {
  # dl.filippo.io/age/latest 무핀 경로가 사라졌는가
  run grep -E 'dl\.filippo\.io/age/latest' "$A"
  [ "$status" -ne 0 ]
  # 고정 버전 자산(age-v...-linux-arm64.tar.gz)으로 받는가
  run grep -E 'age/releases/download/v[0-9]+\.[0-9]+\.[0-9]+/age-v[0-9]' "$A"
  [ "$status" -eq 0 ]
}

@test "every download step verifies a sha256 checksum" {
  # 핀 도구 9종 전부 sha256sum -c를 호출하는지 — 한 번이라도 누락이면 fail.
  # 'sha256sum -c'가 도구 수(>=9)만큼 등장하는지 하한 검사.
  n=$(grep -c 'sha256sum -c' "$A")
  [ "$n" -ge 9 ]
}

@test "no checksum line is an obvious placeholder" {
  # 0000.../deadbeef/TODO/REPLACE 류 더미가 커밋되지 않았는지
  run grep -Ei 'REPLACE|TODO|deadbeef|^0{16}|[[:space:]]0{64}[[:space:]]' "$A"
  [ "$status" -ne 0 ]
}
BATS
```

**Step 2: Run it, expect FAIL**

```bash
bats tools/test/toolchain-checksums.bats
```
Expected: `not ok 1 age is pinned to a fixed version (not latest)` (현재 `dl.filippo.io/age/latest` 사용) 및 `not ok 2 every download step verifies a sha256 checksum` (`sha256sum -c` 0회).

**Step 3: Minimal implementation**

각 step을 "받기 → `sha256sum -c` → 설치" 패턴으로 변환한다. 검증 실패 시 즉시 비-0 종료. 패턴 예(yq):

```yaml
    - if: ${{ inputs.yq == 'true' }}
      shell: bash
      run: |
        # yq는 직접 바이너리 — snap yq는 strict confinement라 mktemp 픽스처를 못 읽는다(라이브 함정).
        f=/tmp/yq; curl -fsSL https://github.com/mikefarah/yq/releases/download/v4.44.6/yq_linux_arm64 -o "$f"
        echo "<YQ_SHA256>  $f" | sha256sum -c -
        sudo install -m 0755 "$f" /usr/local/bin/yq
```

tarball류는 받아서 검증 후 추출(파이프 스트림 검증 불가 → 파일로 먼저 받는다). 예(conftest):

```yaml
    - if: ${{ inputs.conftest == 'true' }}
      shell: bash
      run: |
        f=/tmp/conftest.tgz
        curl -fsSL https://github.com/open-policy-agent/conftest/releases/download/v0.56.0/conftest_0.56.0_Linux_arm64.tar.gz -o "$f"
        echo "<CONFTEST_SHA256>  $f" | sha256sum -c -
        sudo tar -xz -C /usr/local/bin -f "$f" conftest
```

helm/kustomize/shellcheck/sops/kubeconform/kubeseal 동일 변환(각자 추출 디렉토리·바이너리 경로 유지). age는 `latest`를 고정 버전으로 교체:

```yaml
    - if: ${{ inputs.age == 'true' }}
      shell: bash
      run: |
        # age 버전 핀 + 체크섬 — 무핀 latest는 공급망/재현성 구멍.
        f=/tmp/age.tgz
        curl -fsSL https://github.com/FiloSottile/age/releases/download/v1.2.1/age-v1.2.1-linux-arm64.tar.gz -o "$f"
        echo "<AGE_SHA256>  $f" | sha256sum -c -
        tar -xz -C /tmp -f "$f"
        sudo mv /tmp/age/age /tmp/age/age-keygen /usr/local/bin/
```

`<*_SHA256>` 자리에는 위 "체크섬 조달 절차"로 받은 실제 64-hex 값을 채운다(플레이스홀더 금지 — Task의 placeholder 테스트가 잡는다).

**Step 4: Run test, expect PASS**

```bash
bats tools/test/toolchain-checksums.bats && bats tools/test/setup-toolchain-kubeseal.bats
```
Expected: 둘 다 `ok`. 추가로 실제 다운로드/검증 무결성은 `ci.yaml` gate run(setup-toolchain 실호출)이 라이브 검증한다 — 잘못된 SHA면 gate가 `sha256sum: WARNING`으로 즉시 실패.

**Step 5: Commit**

```bash
git -C /Users/ukyi/workspace/homelab-cicd-hardening add .github/actions/setup-toolchain/action.yml tools/test/toolchain-checksums.bats && git -C /Users/ukyi/workspace/homelab-cicd-hardening commit -m "feat: setup-toolchain 전 다운로드에 SHA256 검증 + age 버전 핀 (공급망 위생)"
```

---

### Task 3: 인라인 toolchain curl을 setup-toolchain으로 흡수 + kubeseal 버전 수렴 (dry-1, dry-2)

`onboard.yaml:46-51`·`_create-app.yml:99,101,108`(인라인 kubeconform/helm/conftest), `_create-cache.yml:54-55`·`_create-database.yml:55-56`(인라인 kubeseal)을 `setup-toolchain` 채택으로 교체한다. 이때 cache의 v0.27.3 → v0.37.0 수렴이 자동 달성된다. 기존 `tools/test/ci-toolchain-pin.bats`의 "onboard/_create-app 인라인 helm 핀" 단언이 깨지므로 같은 커밋에서 갱신한다.

**Files:**
- Modify `.github/workflows/onboard.yaml` (`install chart toolchain` step → composite)
- Modify `.github/workflows/_create-app.yml` (인라인 kubeconform/helm curl 제거 → composite step)
- Modify `.github/workflows/_create-cache.yml` (kubeseal+conftest 인라인 → composite)
- Modify `.github/workflows/_create-database.yml` (kubeseal 인라인 → composite, cert 확인 step 분리 유지)
- Modify `.github/workflows/_update-secrets.yml` (yq 사용 — composite로 yq 명시 설치; 현재 yq 설치 step 부재라 잠재 버그도 함께 차단)
- Modify `tools/test/ci-toolchain-pin.bats` (인라인 helm 핀 단언 → composite 채택 단언으로 갱신)
- Test `tools/test/setup-toolchain-kubeseal.bats` (Task 1 — 콜사이트 단언 확장)

**Step 1: Write the failing test**

`tools/test/setup-toolchain-kubeseal.bats`에 콜사이트 단언을 추가(append):

```bash
cat >> tools/test/setup-toolchain-kubeseal.bats <<'BATS'

@test "sealing workflows use the composite kubeseal (no inline kubeseal curl)" {
  local wf
  for wf in _create-cache.yml _create-database.yml; do
    run grep -F 'uses: ./.github/actions/setup-toolchain' "$ROOT/.github/workflows/$wf"
    [ "$status" -eq 0 ]
    # 인라인 kubeseal 다운로드가 워크플로에 남지 않았는지
    run grep -E 'sealed-secrets/releases/download/.*kubeseal' "$ROOT/.github/workflows/$wf"
    [ "$status" -ne 0 ]
  done
  # 옛 v0.27.3 핀이 어디에도 안 남았는지(레포 전역)
  run grep -rE 'kubeseal-0\.27\.3' "$ROOT/.github/workflows/"
  [ "$status" -ne 0 ]
}

@test "onboard and _create-app use the composite (no inline helm/kubeconform/conftest curl)" {
  local wf
  for wf in onboard.yaml _create-app.yml; do
    run grep -F 'uses: ./.github/actions/setup-toolchain' "$ROOT/.github/workflows/$wf"
    [ "$status" -eq 0 ]
    run grep -E 'get\.helm\.sh/helm-v' "$ROOT/.github/workflows/$wf"
    [ "$status" -ne 0 ]
    run grep -E 'conftest_0\.56\.0' "$ROOT/.github/workflows/$wf"
    [ "$status" -ne 0 ]
  done
}
BATS
```

그리고 `tools/test/ci-toolchain-pin.bats`의 두 번째 `@test`를 갱신: onboard/_create-app가 더 이상 인라인 helm을 갖지 않고 composite를 쓰는지로 단언을 바꾼다.

```bash
# ci-toolchain-pin.bats Step: replace the "helm is pinned wherever installed" test body
```

`.../ci-toolchain-pin.bats`의 두 번째 테스트(현재 onboard/_create-app 인라인 helm 핀 단언)를 아래로 교체:

```bash
@test "helm is pinned via setup-toolchain everywhere it is installed" {
  # ci/verify/onboard/_create-app 모두 composite로 helm 설치 — 인라인 get-helm-3 핀은 더 이상 없다.
  local wf
  for wf in ci.yaml onboard.yaml _create-app.yml; do
    run grep -F 'uses: ./.github/actions/setup-toolchain' ".github/workflows/$wf"
    [ "$status" -eq 0 ]
  done
  # composite가 helm을 고정 버전 tarball로 핀한다
  run grep -E 'get\.helm\.sh/helm-v[0-9]+\.[0-9]+\.[0-9]+' .github/actions/setup-toolchain/action.yml
  [ "$status" -eq 0 ]
}
```

**Step 2: Run it, expect FAIL**

```bash
bats tools/test/setup-toolchain-kubeseal.bats tools/test/ci-toolchain-pin.bats
```
Expected: `not ok ... onboard and _create-app use the composite` (현재 인라인 `get.helm.sh` 존재) 및 `not ok ... sealing workflows use the composite kubeseal`.

**Step 3: Minimal implementation**

`onboard.yaml` — `install chart toolchain (render + ledger gate)` step(46-51)을 교체:

```yaml
      - name: install chart toolchain (render + ledger gate)
        uses: ./.github/actions/setup-toolchain
        with:
          kubeconform: 'true'
          helm: 'true'
          conftest: 'true'
```

(setup-node/corepack/pnpm install step과 composite 사이 순서는 그대로 — composite는 sudo curl만 한다.)

`_create-app.yml` — "생성 + 렌더 게이트 + PR" step의 인라인 kubeconform/helm/conftest curl(99,101,108줄)을 제거하고, 같은 step 앞에 composite step을 추가:

```yaml
      - name: install chart toolchain (render + ledger gate)
        uses: ./.github/actions/setup-toolchain
        with:
          kubeconform: 'true'
          helm: 'true'
          conftest: 'true'
      - name: 생성 + 렌더 게이트 + PR
        env:
          ...
        run: |
          [ -n "$DOMAIN" ] || { echo "::error::repo variable HOMELAB_DOMAIN 미설정"; exit 1; }
          [ -f .apprepo/.app-config.yml ] || { echo "::error::.app-config.yml 없음(앱 레포 ${APP_REPO}@${TAG#sha-})"; exit 1; }
          sealed_arg=""
          if [ -f ".apprepo/deploy/${APP}-secrets.sealed.yaml" ]; then
            sealed_arg="--sealed .apprepo/deploy/${APP}-secrets.sealed.yaml"
          fi
          # shellcheck disable=SC2086
          node tools/create-app.mjs --config .apprepo/.app-config.yml --app "$APP" \
            --repo "$APP_REPO" --domain "$DOMAIN" --tag "$TAG" --digest "$DIGEST" $sealed_arg \
            | tee /tmp/plan.json
          # 렌더 게이트: 새 values로 공유 차트가 kubeconform-clean하게 렌더되는가
          helm template "$APP" platform/charts/app -f "apps/$APP/deploy/prod/values.yaml" \
            | kubeconform -strict -ignore-missing-schemas \
                -schema-location default \
                -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json' \
                -summary
          # 원장 게이트(PR required check와 동일 검증 선행)
          pnpm verify:ledger
          git config user.name "homelab-bot"
          ...
```

(즉 인라인 curl 3줄만 제거 — 나머지 render/ledger/PR 로직은 유지.)

`_create-cache.yml` — `kubeseal + conftest 설치` step(52-58)을 composite로:

```yaml
      - name: kubeseal + conftest 설치
        uses: ./.github/actions/setup-toolchain
        with:
          kubeseal: 'true'
          conftest: 'true'
```

`_create-database.yml` — `kubeseal 설치 + 봉인 cert 확인` step(50-57)에서 cert 확인은 유지하되 설치는 composite로 분리:

```yaml
      - name: 봉인 cert 확인 (없으면 산출 0)
        run: |
          # cert가 아직 없으면(컨트롤러 미가동/미수확) 어떤 산출도 만들지 않고 중단
          [ -f tools/sealed-secrets-cert.pem ] || { echo "::error::tools/sealed-secrets-cert.pem 없음 — sealed-secrets 컨트롤러 가동 후 'kubeseal --fetch-cert'로 받아 커밋해야 한다"; exit 1; }
      - name: kubeseal 설치 (버전 SSOT — 컨트롤러 appVersion v0.37.0)
        uses: ./.github/actions/setup-toolchain
        with:
          kubeseal: 'true'
```

`_update-secrets.yml` — yq를 쓰지만(65-74줄 `yq -e`/`yq -i`) 설치 step이 없다(러너 기본 yq 의존 — 잠재 드리프트). composite로 yq 명시 설치 step을 checkout 뒤에 추가:

```yaml
      - name: install yq (봉인본 메타 검증 + checksum annotation)
        uses: ./.github/actions/setup-toolchain
        with:
          yq: 'true'
```

**Step 4: Run test, expect PASS**

```bash
bats tools/test/setup-toolchain-kubeseal.bats tools/test/ci-toolchain-pin.bats tools/test/workflow-yaml.bats
```
Expected: 전부 `ok` (workflow-yaml로 YAML 무결성도 확인).

**Step 5: Commit**

```bash
git -C /Users/ukyi/workspace/homelab-cicd-hardening add .github/workflows/onboard.yaml .github/workflows/_create-app.yml .github/workflows/_create-cache.yml .github/workflows/_create-database.yml .github/workflows/_update-secrets.yml tools/test/setup-toolchain-kubeseal.bats tools/test/ci-toolchain-pin.bats && git -C /Users/ukyi/workspace/homelab-cicd-hardening commit -m "refactor: 인라인 toolchain curl을 setup-toolchain으로 흡수 + kubeseal v0.37.0 수렴"
```

---

### Task 4: setup-node-pnpm composite 구축 + 9 콜사이트 채택 (dry-7)

동일한 `setup-node@v4(node 22) + corepack prepare pnpm@11 + pnpm install --frozen-lockfile` 3-step 블록이 9개 워크플로에 복제돼 있다. node-version·pnpm corepack 버전을 한 곳에 핀하는 composite를 만들고 채택한다.

**Files:**
- Create `.github/actions/setup-node-pnpm/action.yml`
- Modify `ci.yaml`(18-22), `onboard.yaml`(41-44), `bump.yaml`(51-54, 142-145), `bump-poll.yml`(64-67), `_create-app.yml`(57-60), `_create-database.yml`(33-36), `_create-cache.yml`(32-35), `_teardown.yml`(36-39), `_audit.yml`(14-17)
- Test `tools/test/setup-node-pnpm.bats` (Create)

**Step 1: Write the failing test**

```bash
cat > tools/test/setup-node-pnpm.bats <<'BATS'
#!/usr/bin/env bats
# setup-node-pnpm composite — node-version + pnpm corepack 핀을 한 곳에 SSOT화.
# 9개 워크플로에 복붙된 setup-node/corepack/frozen-install 블록을 흡수한다.
# ⚠️ 중간 단언은 [ ]만 — bash 3.2 [[ ]] 침묵 통과.

setup() { ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"; A="$ROOT/.github/actions/setup-node-pnpm/action.yml"; }

@test "setup-node-pnpm composite exists and pins node + pnpm" {
  [ -f "$A" ]
  run grep -E "node-version: ['\"]22['\"]" "$A"
  [ "$status" -eq 0 ]
  run grep -E 'corepack prepare pnpm@11' "$A"
  [ "$status" -eq 0 ]
  run grep -E 'pnpm install --frozen-lockfile' "$A"
  [ "$status" -eq 0 ]
}

@test "all 9 node workflows adopt the composite" {
  local wf
  for wf in ci.yaml onboard.yaml bump.yaml bump-poll.yml _create-app.yml _create-database.yml _create-cache.yml _teardown.yml _audit.yml; do
    run grep -F 'uses: ./.github/actions/setup-node-pnpm' "$ROOT/.github/workflows/$wf"
    [ "$status" -eq 0 ]
  done
}

@test "no node workflow keeps the inline corepack pnpm@11 block" {
  # dispatch-mutation은 pnpm install을 안 쓰므로(검증 전용) 제외 대상 — 인라인 corepack 0
  run grep -rE 'corepack prepare pnpm@11' "$ROOT/.github/workflows/"
  [ "$status" -ne 0 ]
}
BATS
```

**Step 2: Run it, expect FAIL**

```bash
bats tools/test/setup-node-pnpm.bats
```
Expected: `not ok 1 setup-node-pnpm composite exists and pins node + pnpm` (composite 부재).

**Step 3: Minimal implementation**

`.github/actions/setup-node-pnpm/action.yml` 생성:

```yaml
name: setup-node-pnpm
description: node + corepack pnpm 핀 + frozen 설치 (버전 SSOT). node-version·pnpm 버전을 한 곳에서 핀한다.

runs:
  using: composite
  steps:
    - uses: actions/setup-node@v4
      with:
        node-version: "22"
    # corepack로 pnpm@11 활성 — 러너 기본 pnpm/npm 버전 드리프트 차단(lockfile 호환).
    - shell: bash
      run: corepack enable && corepack prepare pnpm@11 --activate
    - shell: bash
      run: pnpm install --frozen-lockfile
```

각 워크플로의 3-step 블록을 단일 step으로 교체. 예(`ci.yaml` 18-22줄):

```yaml
      - uses: actions/checkout@v4
      - uses: ./.github/actions/setup-node-pnpm
      - name: install chart toolchain
        uses: ./.github/actions/setup-toolchain
        with:
          ...
```

`bump.yaml`은 두 잡(`writeback` 51-54, `writeback-dispatch` 142-145) 모두 교체. `_audit.yml`(14-17), `_teardown.yml`(36-39), `bump-poll.yml`(64-67), `onboard.yaml`(41-44), `_create-app.yml`(57-60), `_create-database.yml`(33-36), `_create-cache.yml`(32-35) 동일. 각 워크플로에서 composite 채택 시 checkout(토큰 포함) step은 **앞에 그대로 유지**한다 — composite는 checkout 이후에 와야 한다(레포 컨텍스트 필요).

> dispatch-mutation.yml은 `setup-node`만 쓰고 `pnpm install`을 안 하므로(검증 전용) **이 composite를 채택하지 않는다** — frozen-install이 불필요한 오버헤드. 테스트의 9개 목록에서 의도적으로 제외.

**Step 4: Run test, expect PASS**

```bash
bats tools/test/setup-node-pnpm.bats tools/test/workflow-yaml.bats
```
Expected: 전부 `ok`.

**Step 5: Commit**

```bash
git -C /Users/ukyi/workspace/homelab-cicd-hardening add .github/actions/setup-node-pnpm/action.yml .github/workflows/ci.yaml .github/workflows/onboard.yaml .github/workflows/bump.yaml .github/workflows/bump-poll.yml .github/workflows/_create-app.yml .github/workflows/_create-database.yml .github/workflows/_create-cache.yml .github/workflows/_teardown.yml .github/workflows/_audit.yml tools/test/setup-node-pnpm.bats && git -C /Users/ukyi/workspace/homelab-cicd-hardening commit -m "refactor: setup-node-pnpm composite — node/pnpm 핀 SSOT + 9 워크플로 채택"
```

---

### Task 5: tf-r2-init composite 구축 + 5 콜사이트 채택 (drift-6 잔여)

`backend.hcl` heredoc 작성 + `init -backend-config=backend.hcl -input=false -lockfile=readonly`가 5곳에 복제됐다(iac.yaml `iac-plan`·`apply`, tf-reconcile `reconcile`·`drift-github`·`drift-tailscale`). 차이는 `root`(cloudflare/github/tailscale)와 `state-key`(`<root>/prod/terraform.tfstate`)뿐이므로 composite로 SSOT화한다. (`tf-destroy-guard`는 Phase 3에서 구축 — 재사용만.)

**Files:**
- Create `.github/actions/tf-r2-init/action.yml`
- Modify `.github/workflows/iac.yaml` (iac-plan init 76-82, apply init 143-149)
- Modify `.github/workflows/tf-reconcile.yml` (reconcile init 60-66, drift-github init 142-148, drift-tailscale init 204-210)
- Test `tools/test/tf-r2-init.bats` (Create)

**Step 1: Write the failing test**

```bash
cat > tools/test/tf-r2-init.bats <<'BATS'
#!/usr/bin/env bats
# tf-r2-init composite — backend.hcl 작성 + init -lockfile=readonly를 SSOT화.
# 5콜사이트(iac×2, tf-reconcile×3) 중복 제거. -lockfile=readonly 불변식이 한 곳에 산다.
# ⚠️ 중간 단언은 [ ]만 — bash 3.2 [[ ]] 침묵 통과.

setup() { ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"; A="$ROOT/.github/actions/tf-r2-init/action.yml"; }

@test "tf-r2-init composite exists with root + state-key inputs" {
  [ -f "$A" ]
  run grep -E '^[[:space:]]*root:' "$A"
  [ "$status" -eq 0 ]
  run grep -E '^[[:space:]]*state-key:' "$A"
  [ "$status" -eq 0 ]
}

@test "tf-r2-init enforces -lockfile=readonly in init" {
  run grep -E 'init .*-lockfile=readonly' "$A"
  [ "$status" -eq 0 ]
}

@test "iac and tf-reconcile adopt the composite (no inline backend.hcl heredoc)" {
  run grep -F 'uses: ./.github/actions/tf-r2-init' "$ROOT/.github/workflows/iac.yaml"
  [ "$status" -eq 0 ]
  run grep -F 'uses: ./.github/actions/tf-r2-init' "$ROOT/.github/workflows/tf-reconcile.yml"
  [ "$status" -eq 0 ]
  # 인라인 heredoc(cat > infra/.../backend.hcl)이 두 워크플로에서 제거됐는지
  run grep -E 'cat > infra/.*backend\.hcl' "$ROOT/.github/workflows/iac.yaml"
  [ "$status" -ne 0 ]
  run grep -E 'cat > infra/.*backend\.hcl' "$ROOT/.github/workflows/tf-reconcile.yml"
  [ "$status" -ne 0 ]
}

@test "all five init call-sites use the composite" {
  n=$(grep -c 'uses: ./.github/actions/tf-r2-init' "$ROOT/.github/workflows/iac.yaml" "$ROOT/.github/workflows/tf-reconcile.yml" | awk -F: '{s+=$2} END {print s}')
  [ "$n" -eq 5 ]
}
BATS
```

**Step 2: Run it, expect FAIL**

```bash
bats tools/test/tf-r2-init.bats
```
Expected: `not ok 1 tf-r2-init composite exists with root + state-key inputs` (composite 부재).

**Step 3: Minimal implementation**

`.github/actions/tf-r2-init/action.yml` 생성. R2 자격은 env로 받는다(composite step env에 시크릿 인라인 금지 — 호출자 env가 상속). backend.hcl은 `.gitignore` 등록됨.

```yaml
name: tf-r2-init
description: R2(S3 호환) backend.hcl 작성 + terraform init (-lockfile=readonly). R2 자격은 env(R2_ACCOUNT_ID/R2_ACCESS_KEY_ID/R2_SECRET_ACCESS_KEY)로 상속.
inputs:
  root:
    description: tf 루트 디렉토리명 (cloudflare | github | tailscale)
    required: true
  state-key:
    description: R2 state object key (예 cloudflare/prod/terraform.tfstate)
    required: true
runs:
  using: composite
  steps:
    - shell: bash
      env:
        ROOT: ${{ inputs.root }}
        STATE_KEY: ${{ inputs.state-key }}
      run: |
        # backend.hcl은 .gitignore 등록됨 — R2 자격이 평문이라 절대 커밋/로그 금지(set -x 금지).
        cat > "infra/${ROOT}/backend.hcl" <<EOF
        endpoints  = { s3 = "https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com" }
        access_key = "${R2_ACCESS_KEY_ID}"
        secret_key = "${R2_SECRET_ACCESS_KEY}"
        key        = "${STATE_KEY}"
        EOF
        # -lockfile=readonly: 커밋된 멀티플랫폼 lock과 어긋나면 실패 → 공급망/재현성 가드(불변식 SSOT)
        terraform -chdir="infra/${ROOT}" init -backend-config=backend.hcl -input=false -lockfile=readonly
```

각 콜사이트의 `terraform init (R2 backend...)` step을 교체. 예(`iac.yaml` apply 137-149줄):

```yaml
      - name: terraform init (R2 backend)
        uses: ./.github/actions/tf-r2-init
        env:
          R2_ACCOUNT_ID: ${{ secrets.R2_ACCOUNT_ID }}
          R2_ACCESS_KEY_ID: ${{ secrets.R2_ACCESS_KEY_ID }}
          R2_SECRET_ACCESS_KEY: ${{ secrets.R2_SECRET_ACCESS_KEY }}
        with:
          root: cloudflare
          state-key: cloudflare/prod/terraform.tfstate
```

> composite step에는 `if:`를 직접 못 단다 — `iac-plan`·`drift-github`·`drift-tailscale`은 `steps.pf.outputs.configured == 'true'` 조건부였다. composite 채택 시 그 step의 `if:`를 **uses 라인과 같은 step에 유지**한다(`uses` step도 `if:`를 가질 수 있다):

```yaml
      - name: terraform init (R2 backend, readonly)
        if: steps.pf.outputs.configured == 'true'
        uses: ./.github/actions/tf-r2-init
        env:
          R2_ACCOUNT_ID: ${{ secrets.R2_ACCOUNT_ID }}
          R2_ACCESS_KEY_ID: ${{ secrets.R2_ACCESS_KEY_ID }}
          R2_SECRET_ACCESS_KEY: ${{ secrets.R2_SECRET_ACCESS_KEY }}
        with:
          root: cloudflare
          state-key: cloudflare/prod/terraform.tfstate
```

state-key 매핑: iac-plan/apply=`cloudflare/prod/terraform.tfstate`, reconcile=`cloudflare/prod/terraform.tfstate`, drift-github=`github/prod/terraform.tfstate`, drift-tailscale=`tailscale/prod/terraform.tfstate`.

**Step 4: Run test, expect PASS**

```bash
bats tools/test/tf-r2-init.bats tools/test/workflow-yaml.bats infra/_test/tf_reconcile.bats
```
Expected: 전부 `ok` (tf_reconcile.bats로 plan-only 불변식 회귀도 확인).

**Step 5: Commit**

```bash
git -C /Users/ukyi/workspace/homelab-cicd-hardening add .github/actions/tf-r2-init/action.yml .github/workflows/iac.yaml .github/workflows/tf-reconcile.yml tools/test/tf-r2-init.bats && git -C /Users/ukyi/workspace/homelab-cicd-hardening commit -m "refactor: tf-r2-init composite — backend.hcl+init readonly SSOT (5 콜사이트)"
```

---

### Task 6: create-github-app-token SHA SSOT 단언 + dead homelab-token composite 삭제 (supplychain-8, dry-5)

인라인 `create-github-app-token@<sha>`가 13곳(+composite 1)에 복붙됐고, `homelab-token` composite는 **호출자가 0**이다(grep 확인: 코드는 주석 언급뿐). (1) 모든 인라인 핀이 canonical SHA와 일치하는지 bats로 단언하고, (2) dead composite + 그 테스트를 삭제한다(reference-only 유지보다 삭제가 단순 — 미사용 코드는 드리프트원).

**Files:**
- Create `tools/test/app-token-sha-ssot.bats`
- Delete `.github/actions/homelab-token/action.yml`, `tools/test/homelab-token.bats`
- (SSOT 상수는 canonical SHA를 테스트가 직접 보유 — composite 삭제 후엔 가장 많이 쓰이는 인라인 핀이 권위)

**Step 1: Write the failing test**

```bash
cat > tools/test/app-token-sha-ssot.bats <<'BATS'
#!/usr/bin/env bats
# create-github-app-token 핀 SSOT — 모든 인라인 @<sha>가 단일 canonical 40-hex SHA로 일치하는가.
# 핀이 갈라지면 일부 콜사이트가 변조/취약 버전을 쓸 수 있다(공급망). mutable @vN 태그도 거부.
# ⚠️ 중간 단언은 [ ]만 — bash 3.2 [[ ]] 침묵 통과.

setup() { ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"; cd "$ROOT" || exit 1; }

# canonical 핀 — 갱신 시 이 한 줄만 바꾸고 전 콜사이트를 같은 값으로 sed 한다.
CANON="bcd2ba49218906704ab6c1aa796996da409d3eb1"

@test "every create-github-app-token pin equals the canonical SHA" {
  # 등장하는 모든 @<ref>를 모아 canonical과 다른 게 하나라도 있으면 fail
  bad=$(grep -rhoE 'actions/create-github-app-token@[0-9a-zA-Z.]+' .github/ \
        | sed -E 's#.*@##' | sort -u | grep -v "^${CANON}\$" || true)
  [ -z "$bad" ]
}

@test "no create-github-app-token uses a mutable tag" {
  run grep -rE 'actions/create-github-app-token@v[0-9]' .github/
  [ "$status" -ne 0 ]
}

@test "the dead homelab-token composite is removed (zero callers)" {
  # uses: ./.github/actions/homelab-token 호출자가 없으므로 composite 자체를 제거했다.
  [ ! -f .github/actions/homelab-token/action.yml ]
  run grep -rF 'uses: ./.github/actions/homelab-token' .github/
  [ "$status" -ne 0 ]
}
BATS
```

**Step 2: Run it, expect FAIL**

```bash
bats tools/test/app-token-sha-ssot.bats
```
Expected: `not ok 3 the dead homelab-token composite is removed (zero callers)` (action.yml이 아직 존재). 테스트 1·2는 현재 전부 동일 SHA라 통과할 수 있으나(가드), 테스트 3이 빨개진다.

**Step 3: Minimal implementation**

dead composite와 그 테스트를 삭제:

```bash
git -C /Users/ukyi/workspace/homelab-cicd-hardening rm .github/actions/homelab-token/action.yml tools/test/homelab-token.bats
```

(삭제 후 `.github/actions/homelab-token/` 디렉토리가 비면 git이 자동으로 제거한다.) `homelab-token` composite를 언급하던 주석(`bump.yaml:39`, `onboard.yaml:29`)은 "composite action(homelab-token)은 체크아웃이 선행돼야 해서 인라인 발급한다"는 설명인데, composite가 사라졌으므로 주석을 사실에 맞게 정정:

bump.yaml:39 / onboard.yaml:29 주석을:

```yaml
      # checkout 자체에 토큰이 필요해 이 첫 step에서 create-github-app-token을 인라인 발급한다
      # (핀 SSOT: tools/test/app-token-sha-ssot.bats가 전 콜사이트 동일 SHA 강제).
```

**Step 4: Run test, expect PASS**

```bash
bats tools/test/app-token-sha-ssot.bats
```
Expected: `ok 1..3`. (`ls tools/test/*.bats`에 homelab-token.bats가 더는 없으므로 gate도 정합.)

**Step 5: Commit**

```bash
git -C /Users/ukyi/workspace/homelab-cicd-hardening add tools/test/app-token-sha-ssot.bats .github/workflows/bump.yaml .github/workflows/onboard.yaml && git -C /Users/ukyi/workspace/homelab-cicd-hardening commit -m "refactor: app-token 핀 SSOT 단언 + 미사용 homelab-token composite 삭제"
```

---

### Task 7: .apprepo gitignore + teardown 명시 git add (supplychain-6)

`.apprepo`는 외부(비신뢰) 앱 레포를 sparse-checkout하는 경로(`_create-app.yml:53`, `_update-secrets.yml:52`)인데 `.gitignore`에 없다. `_teardown.yml:64`는 `git add -A`라 만약 워크스페이스에 비신뢰 파일이 섞이면 통째 커밋될 위험이 있다. (1) `.apprepo/`를 gitignore에 추가하고, (2) teardown의 `git add -A`를 tool이 쓰는 명시 경로로 좁힌다.

**Files:**
- Modify `.gitignore` (외부 앱 체크아웃 경로 추가)
- Modify `.github/workflows/_teardown.yml` (`git add -A` → 명시 경로)
- Test `tools/test/apprepo-gitignore.bats` (Create)

**Step 1: Write the failing test**

```bash
cat > tools/test/apprepo-gitignore.bats <<'BATS'
#!/usr/bin/env bats
# .apprepo(외부/비신뢰 앱 레포 sparse-checkout 경로)는 git에 절대 들어가면 안 된다.
# teardown은 git add -A로 비신뢰 파일을 쓸어담을 수 있어 명시 경로만 add 한다.
# ⚠️ 중간 단언은 [ ]만 — bash 3.2 [[ ]] 침묵 통과.

setup() { ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"; cd "$ROOT" || exit 1; }

@test ".apprepo is gitignored" {
  run grep -E '^\.apprepo/?$' .gitignore
  [ "$status" -eq 0 ]
  # git이 실제로 무시하는지(체크-인 규칙) 확인 — check-ignore는 무시되면 exit 0
  run git check-ignore .apprepo/foo
  [ "$status" -eq 0 ]
}

@test "teardown does not use git add -A (explicit paths only)" {
  run grep -E 'git add -A' .github/workflows/_teardown.yml
  [ "$status" -ne 0 ]
  # tool이 쓰는 명시 경로를 add 하는지(apps/ + 원장 + cloudflare apps.json + cnpg/cache/data-conn)
  run grep -E 'git add .*apps/' .github/workflows/_teardown.yml
  [ "$status" -eq 0 ]
}
BATS
```

**Step 2: Run it, expect FAIL**

```bash
bats tools/test/apprepo-gitignore.bats
```
Expected: `not ok 1 .apprepo is gitignored` (현재 .gitignore에 없음) 및 `not ok 2 teardown does not use git add -A`.

**Step 3: Minimal implementation**

`.gitignore`의 SOPS scratch 섹션 근처에 추가(예: `*.tmp.yaml` 블록 뒤):

```
# --- 외부(비신뢰) 앱 레포 sparse-checkout 경로 — create-app/update-secrets가 여기에 푼다 ---
.apprepo/
```

`_teardown.yml:64`의 `git add -A`를 teardown 도구가 쓰는 트리로 한정. teardown-app은 `apps/<app>` + `docs/memory-ledger.md` + `infra/cloudflare/apps.json`을, teardown-resource는 `platform/`(cnpg/cache/data-conn) + 원장을 건드린다 — 둘을 포괄하되 `.apprepo`는 절대 포함하지 않는 명시 목록:

```yaml
          branch="${subject}-${RUN_ID}"
          git checkout -b "$branch"
          # git add -A는 비신뢰 .apprepo까지 쓸어담을 수 있다 → tool이 쓰는 트리만 명시 add.
          # (없는 경로는 git이 조용히 무시 — teardown-app/resource 양쪽을 포괄)
          git add apps docs/memory-ledger.md infra/cloudflare/apps.json platform 2>/dev/null || true
          git commit -m "$title"
```

> `git add <path>`는 존재하지 않는 경로엔 에러를 내므로 `|| true`로 흡수(teardown-app은 platform/을 안 건드리고 그 역도 성립). 이미 `git status --porcelain` 가드(61줄)가 변경 0이면 앞서 exit 0 했으므로, 여기 도달 = 추적 변경 존재.

**Step 4: Run test, expect PASS**

```bash
bats tools/test/apprepo-gitignore.bats tools/test/teardown.bats
```
Expected: 전부 `ok` (teardown.bats로 teardown 도구 회귀도 확인).

**Step 5: Commit**

```bash
git -C /Users/ukyi/workspace/homelab-cicd-hardening add .gitignore .github/workflows/_teardown.yml tools/test/apprepo-gitignore.bats && git -C /Users/ukyi/workspace/homelab-cicd-hardening commit -m "fix: .apprepo gitignore + teardown git add -A를 명시 경로로 (비신뢰 체크아웃 격리)"
```

---

### Phase 7 종료 게이트

전 Task 후 로컬 게이트 미러로 회귀를 확인한다:

```bash
make ci
```
Expected: `gate` 8스텝 전부 PASS — 특히 `tooling bats suites`(신규 6 bats 글롭 자동 포함: setup-toolchain-kubeseal·toolchain-checksums·setup-node-pnpm·tf-r2-init·app-token-sha-ssot·apprepo-gitignore), `shell script lint`, `workflow-yaml`(전 워크플로 YAML 무결성). composite 실호출(setup-toolchain checksum, setup-node-pnpm, tf-r2-init)은 GitHub Actions gate run이 라이브 검증한다.

---

## Phase 8 — doc rot + 감사 커버리지 + 가시성 (P2/P1)

이 단계는 라이브 영향이 0인 정리 작업(주석 정합·SSOT 수렴·감사 커버리지·알림 가시성)이다.
모두 auto-merge(`gate` 통과). 신규 bats는 `tools/test/*.bats` 글롭이 자동 수집한다. conftest 신규 룰 없음.

**전제(executor 환경):** `node`/`pnpm`은 mise PATH 또는 `pnpm install --frozen-lockfile` 후 사용 가능
(Makefile의 `MISE_SHIMS` 보강 + gate의 setup-node). bats 중간 단언은 `[ ]`만 사용(bash 3.2 `[[ ]]` 침묵통과 함정).
`@test` 이름은 영어(한글 인코딩 깨짐 함정).

---

### Task 1: ci.yaml BLOCKING 주석을 실제 차단 셋과 일치 (dry-8)

`ci.yaml:38`의 주석은 `stale-ledger-row`도 차단한다고 적었지만, `audit-orphans.mjs:34`의
`BLOCKING = new Set(["dangling-binding", "orphan-dns"])`는 `stale-ledger-row`를 제외한다.
주석을 코드 진실(dangling-binding + orphan-dns만)과 일치시킨다. 드리프트 회귀를 막기 위해
"주석에 적힌 BLOCKING 토큰 ⊆ 코드 BLOCKING 셋" 불변식을 bats로 강제한다.

**Files:**
- Modify `.github/workflows/ci.yaml:37-39` (주석)
- Test (new) `tools/test/ci-blocking-comment.bats`

**Step 1: Write the failing test**
```bash
cat > tools/test/ci-blocking-comment.bats <<'EOF'
#!/usr/bin/env bats
# ci.yaml의 audit-orphans 게이트 주석이 실제 BLOCKING 셋과 표류하지 않게 강제한다.
# ⚠️ 중간 단언은 [ ]만 (bash 3.2 [[ ]] 침묵통과 함정).

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  CI="$ROOT/.github/workflows/ci.yaml"
  SRC="$ROOT/tools/audit-orphans.mjs"
}

@test "ci.yaml audit gate comment does not claim stale-ledger-row is blocking" {
  # 코드의 BLOCKING 셋엔 stale-ledger-row가 없다 — 주석도 그것을 차단한다고 말하면 안 된다.
  run grep -nE '^\s*const BLOCKING = new Set\(\["dangling-binding", "orphan-dns"\]\);' "$SRC"
  [ "$status" -eq 0 ]
  # audit-orphans 게이트 스텝 주석(run 라인 직전 #...)에 stale-ledger-row가 등장하면 실패
  run bash -c "awk '/registry\\/binding 정합 게이트/{f=1} f&&/node tools\\/audit-orphans.mjs --ci/{exit} f' '$CI' | grep -c 'stale-ledger-row'"
  [ "$output" = "0" ]
}

@test "ci.yaml audit gate comment names both real blocking types" {
  run bash -c "awk '/registry\\/binding 정합 게이트/{f=1} f&&/node tools\\/audit-orphans.mjs --ci/{exit} f' '$CI'"
  echo "$output" | grep -q 'dangling-binding'
  echo "$output" | grep -q 'orphan-dns'
}
EOF
```

**Step 2: Run it, expect FAIL**
```bash
bats tools/test/ci-blocking-comment.bats
```
Expected: `not ok 1 ci.yaml audit gate comment does not claim stale-ledger-row is blocking` — 현재 주석
(`dangling-binding(missing Secret)/orphan-dns(빈 백엔드)/stale-ledger-row만 차단`)에 `stale-ledger-row`가 있어
`grep -c`가 `1`(≠`0`)을 반환.

**Step 3: Minimal implementation** — `.github/workflows/ci.yaml:37-40` 주석 교체:
```yaml
      - name: registry/binding 정합 게이트 (배포 깨는 드리프트 차단)
        # 차단(--ci)은 정확히 두 유형: dangling-binding(미존재 db/cache 참조 → 배포 시 missing Secret),
        # orphan-dns(apps.json active 행에 앱 매니페스트 부재 → 빈 백엔드 DNS 노출).
        # stale-ledger-row·unreferenced-resource·missing-registration·incomplete-purge는 비차단(정보/경고).
        run: node tools/audit-orphans.mjs --ci
```

**Step 4: Run test, expect PASS**
```bash
bats tools/test/ci-blocking-comment.bats
```
Expected: `ok 1` · `ok 2` (2 tests, 0 failures).

**Step 5: Commit**
```bash
git -C /Users/ukyi/workspace/homelab-cicd-hardening add .github/workflows/ci.yaml tools/test/ci-blocking-comment.bats && git -C /Users/ukyi/workspace/homelab-cicd-hardening commit -m "docs: ci.yaml audit 게이트 주석을 실제 BLOCKING 셋과 일치 + 드리프트 가드"
```

---

### Task 2: verify.yml·Makefile이 pnpm verify:ledger SSOT 호출 (dry-9)

ledger 검증이 3곳에 다르게 철자돼 있다: `package.json:18`(`verify:ledger` = SSOT),
`verify.yml:33-35`(인라인 `ledger-to-json.sh | conftest`), `Makefile:38-39`(동일 인라인).
`verify.yml`과 `Makefile`이 `pnpm verify:ledger`를 호출하게 수렴한다(파이프라인 1곳 정의).

**주의:** `verify.yml` verify 잡은 의도적으로 pnpm/node를 안 쓴다(주석 18-20: pnpm@11 self-install이
액션 node20 런타임에서 실패). 따라서 `pnpm verify:ledger`를 쓰려면 그 잡에 node+corepack 셋업을
추가하거나, **스크립트를 직접 호출**(`bash -c "$(node -e 'process.stdout.write(...)')"` 회피)해야 한다.
가장 단순·안전: SSOT 스크립트 1줄을 별도 셸 스크립트(`scripts/verify-ledger.sh`)로 추출하고
package.json·verify.yml·Makefile 셋 다 그 스크립트를 호출 — pnpm 의존 도입 없이 3중 복제를 제거한다.

**Files:**
- Create `scripts/verify-ledger.sh` (SSOT 파이프라인)
- Modify `package.json:18` (`verify:ledger` → 스크립트 호출)
- Modify `.github/workflows/verify.yml:32-35`
- Modify `Makefile:36-40` (`verify` 타겟)
- Test (new) `tools/test/verify-ledger-ssot.bats`

**Step 1: Write the failing test**
```bash
cat > tools/test/verify-ledger-ssot.bats <<'EOF'
#!/usr/bin/env bats
# ledger 검증 파이프라인을 1곳(scripts/verify-ledger.sh)으로 수렴 — 인라인 conftest 3중 복제 제거.
# ⚠️ 중간 단언은 [ ]만.

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
}

@test "verify-ledger.sh SSOT script exists and is executable" {
  [ -x "$ROOT/scripts/verify-ledger.sh" ]
  grep -q 'ledger-to-json.sh' "$ROOT/scripts/verify-ledger.sh"
  grep -q 'conftest test' "$ROOT/scripts/verify-ledger.sh"
}

@test "package.json verify:ledger delegates to the SSOT script" {
  run node -e "process.stdout.write(require('$ROOT/package.json').scripts['verify:ledger'])"
  echo "$output" | grep -q 'scripts/verify-ledger.sh'
}

@test "verify.yml ledger step no longer inlines the conftest pipeline" {
  # 인라인 'conftest test /tmp/ledger.json'이 verify.yml에 남아있으면 실패(SSOT 미수렴).
  run grep -c 'conftest test /tmp/ledger.json' "$ROOT/.github/workflows/verify.yml"
  [ "$output" = "0" ]
  grep -q 'scripts/verify-ledger.sh' "$ROOT/.github/workflows/verify.yml"
}

@test "Makefile verify target no longer inlines the conftest pipeline" {
  run grep -c 'conftest test /tmp/ledger.json' "$ROOT/Makefile"
  [ "$output" = "0" ]
  grep -q 'scripts/verify-ledger.sh' "$ROOT/Makefile"
}
EOF
```

**Step 2: Run it, expect FAIL**
```bash
bats tools/test/verify-ledger-ssot.bats
```
Expected: `not ok 1 verify-ledger.sh SSOT script exists` — `scripts/verify-ledger.sh` 부재로
`[ -x ... ]` 실패. tests 2-4도 인라인 `conftest test /tmp/ledger.json`이 아직 남아 FAIL.

**Step 3: Minimal implementation**

`scripts/verify-ledger.sh` (신규):
```bash
#!/usr/bin/env bash
# 메모리 원장 예산 게이트 SSOT — ledger 마크다운을 JSON으로 변환해 conftest 정책으로 검사.
# package.json(verify:ledger)·verify.yml·Makefile(verify)·make ci가 모두 이 스크립트를 호출한다.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
"$ROOT/scripts/ledger-to-json.sh" "$ROOT/docs/memory-ledger.md" > /tmp/ledger.json
conftest test /tmp/ledger.json --policy "$ROOT/policy/ledger.rego"
```
그리고 `chmod +x scripts/verify-ledger.sh`.

`package.json:18` 교체:
```json
    "verify:ledger": "scripts/verify-ledger.sh",
```

`.github/workflows/verify.yml:32-35` 교체:
```yaml
      - name: Memory ledger budget gate (R2)
        run: scripts/verify-ledger.sh
```

`Makefile:36-40` (`verify` 타겟) 교체 — 인라인 두 줄을 스크립트 호출로:
```makefile
verify: ## 레포 기반 점검 실행 (스켈레톤 + 원장 + sops 왕복)
	@./scripts/check-skeleton.sh
	@scripts/verify-ledger.sh
	@bats tests/sops-roundtrip.bats
```

**Step 4: Run test, expect PASS**
```bash
chmod +x scripts/verify-ledger.sh
bats tools/test/verify-ledger-ssot.bats
# 회귀 없음 확인: 스크립트가 실제로 통과(라이브 원장)
scripts/verify-ledger.sh && echo "ledger gate OK"
shellcheck scripts/verify-ledger.sh
```
Expected: `ok 1..4` (4 tests, 0 failures); `ledger gate OK`; shellcheck 무경고.

**Step 5: Commit**
```bash
git -C /Users/ukyi/workspace/homelab-cicd-hardening add scripts/verify-ledger.sh package.json .github/workflows/verify.yml Makefile tools/test/verify-ledger-ssot.bats && git -C /Users/ukyi/workspace/homelab-cicd-hardening commit -m "refactor: ledger 검증을 scripts/verify-ledger.sh SSOT로 수렴 (인라인 conftest 3중 복제 제거)"
```

---

### Task 3: orphan-dns 차단을 active:true 행으로만 한정 (drift-3)

`audit-orphans.mjs:54-57`은 `active:false` 행의 orphan-dns도 `active:true`와 동일하게
`BLOCKING`으로 처리한다. 하지만 `dns.tf:9`는 `if a.public && a.active`만 노출하므로
`active:false` orphan은 **DNS를 노출하지 않는다**(빈 백엔드 위험 없음) — 차단할 이유가 없다.
`active:false` orphan을 비차단 정보(`orphan-dns-inactive`)로 분리해, 정상적인 create-app
중간 상태(매니페스트 PR 머지 전 apps.json 행 존재)가 모든 PR을 막지 않게 한다.

**Files:**
- Modify `tools/audit-orphans.mjs:54-57` (orphan-dns 분기)
- Test (extend) `tools/test/audit-orphans.bats` (active:false 행 비차단 케이스 추가)

**Step 1: Write the failing test** — `tools/test/audit-orphans.bats`에 추가:
```bash
cat >> tools/test/audit-orphans.bats <<'EOF'

@test "an inactive (active:false) orphan row is non-blocking info, not orphan-dns" {
  # dns.tf는 public && active만 노출 — active:false orphan은 DNS를 노출하지 않으므로 PR을 막으면 안 된다.
  cat > "$FR/infra/cloudflare/apps.json" <<'JSON'
[
  { "name": "orders", "host": "orders.example.com", "public": true, "active": true },
  { "name": "pending-app", "host": "pending.example.com", "public": true, "active": false }
]
JSON
  run node "$ROOT/tools/audit-orphans.mjs" --repo-root "$FR" --ci
  [ "$status" -eq 0 ]   # active:false orphan은 비차단 → --ci 통과
  # 비차단 정보 유형으로 보고는 된다(가시성 유지)
  echo "$output" | jq -e '.findings | any(.type == "orphan-dns-inactive" and .subject == "pending-app")'
  # 차단 유형(orphan-dns)으로는 잡히지 않는다
  run bash -c "node '$ROOT/tools/audit-orphans.mjs' --repo-root '$FR' | jq -e '.findings | any(.type == \"orphan-dns\" and .subject == \"pending-app\")'"
  [ "$status" -ne 0 ]
}

@test "an active:true orphan row is still blocking under --ci" {
  cat > "$FR/infra/cloudflare/apps.json" <<'JSON'
[
  { "name": "orders", "host": "orders.example.com", "public": true, "active": true },
  { "name": "ghost", "host": "ghost.example.com", "public": true, "active": true }
]
JSON
  run node "$ROOT/tools/audit-orphans.mjs" --repo-root "$FR" --ci
  [ "$status" -ne 0 ]
  echo "$output" | grep -q 'orphan-dns:ghost'
}
EOF
```

**Step 2: Run it, expect FAIL**
```bash
bats tools/test/audit-orphans.bats
```
Expected: `not ok ... an inactive (active:false) orphan row is non-blocking` — 현재 코드는 모든
orphan을 `orphan-dns`(BLOCKING)로 보고하므로 `--ci`가 `pending-app`에서 비-0 종료(`[ "$status" -eq 0 ]` 실패)
+ `orphan-dns-inactive` 유형이 없어 jq -e도 실패.

**Step 3: Minimal implementation** — `tools/audit-orphans.mjs:53-57` 교체:
```javascript
// 1) registry ↔ 매니페스트
//   active:true orphan → orphan-dns(차단): dns.tf가 public&&active만 노출하므로 빈 백엔드 DNS가 실재.
//   active:false orphan → orphan-dns-inactive(정보, 비차단): DNS 미노출이라 create-app 중간 상태에서 정상.
for (const r of registry) {
  if (!appDirs.includes(r.name)) {
    if (r.active)
      add("orphan-dns", r.name, `apps.json active:true 행인데 apps/${r.name}/deploy/prod 부재 — DNS가 빈 백엔드로 노출 중`);
    else
      add("orphan-dns-inactive", r.name, `apps.json active:false 행인데 apps/${r.name}/deploy/prod 부재 — DNS 미노출(create-app 매니페스트 머지 대기 가능)`);
  }
}
```
`BLOCKING` 셋(line 34)은 변경 없음 — `orphan-dns-inactive`는 비차단으로 남는다. USAGE 문자열(line 16-17)
유형 목록에 `orphan-dns-inactive`를 정보성으로 한 줄 추가:
```
//   orphan-dns-inactive   : active:false 행인데 매니페스트 부재 — DNS 미노출(정보성, 비차단)
```

**Step 4: Run test, expect PASS**
```bash
bats tools/test/audit-orphans.bats
```
Expected: 전 테스트 `ok`(기존 5 + 신규 2 = 7+, 0 failures). 기존 "active registry row whose app
manifests are gone (orphan dns)" 테스트는 ghost가 `active:true`라 영향 없음.

**Step 5: Commit**
```bash
git -C /Users/ukyi/workspace/homelab-cicd-hardening add tools/audit-orphans.mjs tools/test/audit-orphans.bats && git -C /Users/ukyi/workspace/homelab-cicd-hardening commit -m "fix: orphan-dns 차단을 active:true 행으로만 한정 (active:false는 비차단 정보 — dns.tf와 정합)"
```

---

### Task 4: ledger Totals 치환 헬퍼 SSOT + 발화 단언 (fm-3)

`teardown-app.mjs:43`·`create-app.mjs:214`·`provision-cache.mjs:337`·`onboard-app.mjs:169`가
각자 동일한 정규식 `out.replace(/req ≈ \d+ Mi · limit ≈ \d+ Mi/, ...)`을 철자한다. 프로즈 문구가
드리프트하면 `.replace`가 **조용히 no-op**(매치 0 → 원본 그대로)이라 합계가 stale이 된다.
헬퍼 1곳으로 모으고, 치환이 실제로 발화했는지(pre≠post 또는 매치 count==1) 단언해 fail-loud화한다.

**Files:**
- Create `tools/lib/ledger-totals.mjs` (replaceTotals 헬퍼)
- Modify `tools/teardown-app.mjs:7,43`
- Modify `tools/create-app.mjs:9,214`
- Modify `tools/provision-cache.mjs` (import + line 337)
- Modify `tools/onboard-app.mjs` (import + line 169)
- Test (new) `tools/test/ledger-totals.bats`

**Step 1: Write the failing test**
```bash
cat > tools/test/ledger-totals.bats <<'EOF'
#!/usr/bin/env bats
# ledger Totals 프로즈 치환 SSOT 헬퍼 — 프로즈 드리프트 시 silent no-op 대신 fail-loud.
# ⚠️ 중간 단언은 [ ]만.

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  LIB="$ROOT/tools/lib/ledger-totals.mjs"
}

@test "replaceTotals substitutes the totals prose and returns updated text" {
  run node -e '
    import("file://" + process.argv[1]).then(m => {
      const before = "blah\n**합계:** req ≈ 100 Mi · limit ≈ 200 Mi (≤ 8704 Mi).\n";
      const after = m.replaceTotals(before, 150, 250);
      if (!/req ≈ 150 Mi · limit ≈ 250 Mi/.test(after)) { console.error("no-sub"); process.exit(1); }
      console.log("ok");
    }).catch(e => { console.error(e.message); process.exit(1); });
  ' "$LIB"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '^ok$'
}

@test "replaceTotals throws (fail-loud) when the totals prose is missing" {
  run node -e '
    import("file://" + process.argv[1]).then(m => {
      try { m.replaceTotals("no totals phrase here\n", 1, 2); console.log("DID-NOT-THROW"); }
      catch (e) { console.log("threw"); }
    });
  ' "$LIB"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '^threw$'
}

@test "teardown-app imports the shared helper (no inline replace regex)" {
  run grep -c 'req ≈ \\\\d+ Mi · limit ≈ \\\\d+ Mi' "$ROOT/tools/teardown-app.mjs"
  [ "$output" = "0" ]
  grep -q "lib/ledger-totals" "$ROOT/tools/teardown-app.mjs"
}
EOF
```

**Step 2: Run it, expect FAIL**
```bash
bats tools/test/ledger-totals.bats
```
Expected: `not ok 1 ... ` — `tools/lib/ledger-totals.mjs` 부재로 dynamic import가 실패(MODULE_NOT_FOUND).
test 3도 teardown-app.mjs에 인라인 정규식이 남아 FAIL.

**Step 3: Minimal implementation**

`tools/lib/ledger-totals.mjs` (신규):
```javascript
// 메모리 원장 Totals 프로즈 치환 SSOT — create-app/onboard-app/provision-cache/teardown-app 공용.
// 프로즈 문구가 드리프트하면 String.replace가 조용히 no-op이 되어 합계가 stale로 남는다 →
// 매치가 0이면 throw해 fail-loud(silent no-op 차단). 한·영 프로즈("합계"/"Totals") 모두 매칭.
const TOTALS_RE = /req ≈ \d+ Mi · limit ≈ \d+ Mi/;

export function replaceTotals(text, sumReqMi, sumLimitMi) {
  if (!TOTALS_RE.test(text)) {
    throw new Error(
      `ledger Totals 프로즈를 찾지 못함(정규식 '${TOTALS_RE.source}') — 원장 포맷 드리프트로 합계 갱신 불가`,
    );
  }
  return text.replace(TOTALS_RE, `req ≈ ${sumReqMi} Mi · limit ≈ ${sumLimitMi} Mi`);
}
```

`tools/teardown-app.mjs` — import 추가(line 7 근처) + line 43 교체:
```javascript
import { replaceTotals } from "./lib/ledger-totals.mjs";
```
```javascript
    out = replaceTotals(out, sumReq, sumLimit);
```

`tools/create-app.mjs` — import 추가(line 9 근처) + line 214 교체:
```javascript
import { replaceTotals } from "./lib/ledger-totals.mjs";
```
```javascript
  out = replaceTotals(out, sumReq + reqMi, sumLimit + limitMi);
```

`tools/provision-cache.mjs` — import 추가 + line 337 교체:
```javascript
import { replaceTotals } from "./lib/ledger-totals.mjs";
```
```javascript
  out = replaceTotals(out, sumReq + reqMi, sumLimit + limitMi);
```

`tools/onboard-app.mjs` — import 추가 + line 169 교체:
```javascript
import { replaceTotals } from "./lib/ledger-totals.mjs";
```
```javascript
  out = replaceTotals(out, sumReq + reqMi, sumLimit + limitMi);
```

**Step 4: Run test, expect PASS**
```bash
bats tools/test/ledger-totals.bats
# 회귀: 기존 create-app/teardown/provision-cache/onboard bats가 여전히 통과(헬퍼 경로 동등)
bats tools/test/create-app.bats tools/test/teardown.bats tools/test/provision-cache.bats tools/test/onboard.bats
```
Expected: ledger-totals 3 `ok`; 기존 4 스위트 0 failures(Totals 프로즈가 정상 매치되므로 동등 출력).

**Step 5: Commit**
```bash
git -C /Users/ukyi/workspace/homelab-cicd-hardening add tools/lib/ledger-totals.mjs tools/teardown-app.mjs tools/create-app.mjs tools/provision-cache.mjs tools/onboard-app.mjs tools/test/ledger-totals.bats && git -C /Users/ukyi/workspace/homelab-cicd-hardening commit -m "refactor: ledger Totals 치환을 replaceTotals 헬퍼로 SSOT화 + 프로즈 드리프트 시 fail-loud"
```

---

### Task 5: poll-ghcr manifest 404와 transient 오류 구분 (fm-4)

`poll-ghcr.mjs:64-74`의 라이브 `manifest()`는 `docker buildx imagetools inspect` 실패를 전부
`return null`("빌드 안 된 커밋")로 삼킨다. 인증 실패·네트워크 장애·rate-limit 같은 **transient
오류**도 null이 되면 "이미지 없음"으로 오인해 그 커밋을 건너뛰거나 후진 후보를 고른다.
실패 메시지가 `not found`/`manifest unknown`(진짜 404)일 때만 absent(null), 그 외엔 rethrow해
`planApp`의 outer try/catch(line 146-150)가 `refuse`로 fail-closed하게 한다.
fixture 모드도 transient를 시뮬레이션할 수 있게 `manifest-<tag>.error.json` 픽스처를 지원한다.

**Files:**
- Modify `tools/poll-ghcr.mjs:48-76` (makeQuery — fixture + live manifest)
- Test (extend) `tools/test/poll-ghcr.bats` (transient → refuse 케이스)

**Step 1: Write the failing test** — `tools/test/poll-ghcr.bats`에 추가:
```bash
cat >> tools/test/poll-ghcr.bats <<'EOF'

@test "a transient imagetools error (not a genuine 404) refuses instead of treating image as absent" {
  # bbb2222 manifest를 transient 오류로 표시 — 진짜 404가 아니므로 'absent'로 삼키면 안 되고 refuse여야.
  rm -f "$FX/orders.manifest-sha-bbb2222.json"
  cat > "$FX/orders.manifest-sha-bbb2222.error.json" <<'JSON'
{ "message": "received unexpected HTTP status: 500 Internal Server Error" }
JSON
  run_poll
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.[0].action == "refuse"'
  echo "$output" | jq -e '.[0].reason | test("manifest|transient|일시")'
}

@test "a genuine manifest-unknown 404 is still treated as image absent (not built)" {
  rm -f "$FX/orders.manifest-sha-bbb2222.json"
  cat > "$FX/orders.manifest-sha-bbb2222.error.json" <<'JSON'
{ "message": "ghcr.io/ukyi-app/orders:sha-bbb...: not found" }
JSON
  run_poll
  [ "$status" -eq 0 ]
  # 404는 absent → 후보 없음(noop), refuse 아님
  echo "$output" | jq -e '.[0].action == "noop"'
}
EOF
```

**Step 2: Run it, expect FAIL**
```bash
bats tools/test/poll-ghcr.bats
```
Expected: `not ok ... transient imagetools error ... refuses` — 현재 fixture `manifest()`는
`.error.json`을 모르고, 픽스처 부재 시 항상 `null`(absent)을 반환하므로 transient도 noop이 되어
`.[0].action == "refuse"` jq -e가 실패.

**Step 3: Minimal implementation** — `tools/poll-ghcr.mjs:48-76` 교체:
```javascript
// 진짜 404(이미지 미빌드)만 absent로 삼킨다 — transient(인증/네트워크/5xx)는 rethrow해
// planApp outer catch가 refuse로 fail-closed(후진 후보 선택 방지).
function isNotFound(msg) {
  return /not found|manifest unknown|no such manifest|404/i.test(msg ?? "");
}

function makeQuery(app) {
  if (args.fixtures) {
    const fx = (name) => {
      const p = path.join(args.fixtures, `${app}.${name}.json`);
      return existsSync(p) ? JSON.parse(readFileSync(p, "utf8")) : null;
    };
    return {
      commits: (src) => fx("commits") ?? [],
      compare: (src, base, head) => fx(`compare-${short(base)}-${head === "main" ? "main" : short(head)}`),
      manifest: (repo, tag) => {
        const t = tag.slice(0, 11); // sha- + 7자
        const err = fx(`manifest-${t}.error`);
        if (err) {
          if (isNotFound(err.message)) return null; // 진짜 404 — 미빌드
          throw new Error(`manifest 일시 오류(transient): ${err.message}`);
        }
        return fx(`manifest-${t}`);
      },
    };
  }
  const gh = (p) => JSON.parse(execFileSync("gh", ["api", p], { encoding: "utf8" }));
  return {
    commits: (src) => gh(`repos/${src}/commits?sha=main&per_page=30`),
    compare: (src, base, head) => gh(`repos/${src}/compare/${base}...${head}`),
    manifest: (repo, tag) => {
      try {
        const out = execFileSync(
          "docker", ["buildx", "imagetools", "inspect", `${repo}:${tag}`, "--format", "{{json .Manifest}}"],
          { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] },
        );
        return { digest: JSON.parse(out).digest };
      } catch (e) {
        const stderr = (e.stderr ?? "").toString();
        if (isNotFound(stderr) || isNotFound(e.message)) return null; // 진짜 404 — 미빌드 커밋
        throw new Error(`manifest 조회 일시 오류(transient, rethrow→refuse): ${stderr || e.message}`);
      }
    },
  };
}
```
참고: 라이브 분기는 stderr를 캡처해야 `not found`를 읽을 수 있어 `stdio[2]`를 `"ignore"`→`"pipe"`로 바꿨다.

**Step 4: Run test, expect PASS**
```bash
bats tools/test/poll-ghcr.bats
```
Expected: 기존 8 + 신규 2 = 10 tests, 0 failures. transient→`refuse`, 404→`noop`. 기존
"commit without a built image is skipped"(픽스처 단순 부재)는 여전히 absent→noop으로 동작.

**Step 5: Commit**
```bash
git -C /Users/ukyi/workspace/homelab-cicd-hardening add tools/poll-ghcr.mjs tools/test/poll-ghcr.bats && git -C /Users/ukyi/workspace/homelab-cicd-hardening commit -m "fix: poll-ghcr가 manifest 404와 transient 오류 구분 (transient는 rethrow→refuse fail-closed)"
```

---

### Task 6: audit-orphans dangling-role 체크 추가 (fm-5)

`teardown-resource.mjs:155-169` cleanup은 conn/owner/ro sealed + CR을 제거하지만, cluster.yaml의
`managed.roles` 항목은 **별도 커밋(워크플로 단계)**으로만 제거된다(line 168 manual 안내). 그 단계가
빠지면 role이 사라진 sealed secret(`db-<name>-owner.sealed.yaml`)을 가리킨 채 cluster.yaml에 잔존하지만,
`audit-orphans.mjs:96-98`은 `state=='purging'`(incomplete-purge)만 본다 — purge 완료 후(state=purged)
고아 role은 보이지 않는다. cluster.yaml managed.roles를 읽어, role의 `passwordSecret.name` sealed 파일이
없으면 `dangling-role` 정보(비차단)로 보고한다.

**Files:**
- Modify `tools/audit-orphans.mjs` (cluster.yaml 읽기 + dangling-role 체크 블록 추가)
- Test (new) `tools/test/audit-dangling-role.bats`

**Step 1: Write the failing test**
```bash
cat > tools/test/audit-dangling-role.bats <<'EOF'
#!/usr/bin/env bats
# audit-orphans dangling-role: cluster.yaml managed.roles 항목의 passwordSecret sealed가 부재하면 고아.
# (purge cleanup이 sealed/CR을 지웠지만 cluster.yaml role 제거 커밋이 빠진 상태.)
# ⚠️ 중간 단언은 [ ]만.

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  TMP="$(mktemp -d)"; FR="$TMP/repo"
  mkdir -p "$FR/apps" "$FR/infra/cloudflare" "$FR/docs" \
    "$FR/platform/cnpg/prod/databases" "$FR/platform/data-conn/prod" "$FR/platform/cache/prod"
  echo '[]' > "$FR/infra/cloudflare/apps.json"
  printf '<!-- ledger:meta -->\n' > "$FR/docs/memory-ledger.md"
  # cluster.yaml: orders DB의 owner/ro managed role 2개. ro sealed는 제거됨(고아), owner sealed는 존재.
  cat > "$FR/platform/cnpg/prod/cluster.yaml" <<'YAML'
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata: { name: pg }
spec:
  managed:
    roles:
      - name: orders_owner
        passwordSecret: { name: db-orders-owner }
      - name: orders_ro
        passwordSecret: { name: db-orders-ro }
YAML
  # owner sealed만 존재 — ro sealed는 cleanup이 지웠지만 role은 cluster.yaml에 잔존(고아)
  touch "$FR/platform/cnpg/prod/databases/db-orders-owner.sealed.yaml"
}
teardown() { rm -rf "$TMP"; }

@test "a managed role whose passwordSecret sealed file is gone is reported as dangling-role" {
  run node "$ROOT/tools/audit-orphans.mjs" --repo-root "$FR"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.findings | any(.type == "dangling-role" and .subject == "orders_ro")'
  # owner role은 sealed가 살아있어 고아 아님
  run bash -c "node '$ROOT/tools/audit-orphans.mjs' --repo-root '$FR' | jq -e '.findings | any(.type==\"dangling-role\" and .subject==\"orders_owner\")'"
  [ "$status" -ne 0 ]
}

@test "dangling-role is informational (non-blocking under --ci)" {
  run node "$ROOT/tools/audit-orphans.mjs" --repo-root "$FR" --ci
  [ "$status" -eq 0 ]
}
EOF
```

**Step 2: Run it, expect FAIL**
```bash
bats tools/test/audit-dangling-role.bats
```
Expected: `not ok 1 ... dangling-role` — 현재 audit-orphans는 cluster.yaml managed.roles를 보지
않아 `dangling-role` finding이 없어 jq -e 실패.

**Step 3: Minimal implementation** — `tools/audit-orphans.mjs`의 purge 블록(line 95-98) 다음에 추가:
```javascript
// 6) dangling-role — cluster.yaml managed.roles 항목인데 passwordSecret sealed가 부재(정보성).
//    purge cleanup이 sealed/CR을 제거했지만 cluster.yaml role 제거 커밋이 빠진 상태를 잡는다
//    (incomplete-purge는 state=purging만 봐서 purge 완료 후 고아 role을 못 본다).
const clusterPath = `${ROOT}/platform/cnpg/prod/cluster.yaml`;
if (existsSync(clusterPath)) {
  const cluster = parseYaml(readFileSync(clusterPath, "utf8")) ?? {};
  const roles = cluster?.spec?.managed?.roles ?? [];
  const dbDir = `${ROOT}/platform/cnpg/prod/databases`;
  for (const role of roles) {
    const secret = role?.passwordSecret?.name;
    if (!secret) continue;
    if (!existsSync(`${dbDir}/${secret}.sealed.yaml`))
      add("dangling-role", role.name, `cluster.yaml managed.role이 부재 sealed(${secret}.sealed.yaml)를 참조 — purge 후 role 제거 커밋 누락 가능`);
  }
}
```
USAGE 문자열(line 9 근처) 유형 목록에 추가:
```
//   dangling-role         : cluster.yaml managed.role인데 passwordSecret sealed 부재 — 고아 role (정보성)
```
`dangling-role`은 `BLOCKING` 셋에 넣지 않는다(정보성, 비차단).

**Step 4: Run test, expect PASS**
```bash
bats tools/test/audit-dangling-role.bats
# 회귀: 기존 audit-orphans 스위트
bats tools/test/audit-orphans.bats
```
Expected: dangling-role 2 `ok`; 기존 audit-orphans 스위트 0 failures(cluster.yaml 없는 픽스처는
`existsSync` 가드로 skip).

**Step 5: Commit**
```bash
git -C /Users/ukyi/workspace/homelab-cicd-hardening add tools/audit-orphans.mjs tools/test/audit-dangling-role.bats && git -C /Users/ukyi/workspace/homelab-cicd-hardening commit -m "feat: audit-orphans에 dangling-role 체크 추가 (purge 후 cluster.yaml 잔존 role 감지)"
```

---

### Task 7: build.yaml에 telegram-notify 추가 (obs-3)

`build.yaml`엔 telegram-notify가 0개다 — pg-tools 이미지 빌드/push가 실패해도 owner는 Actions UI를
뒤져야만 안다. `if: always()` 알림 스텝을 추가한다(source: `배포`, status: `${{ job.status }}`,
app/sha ident). source `배포`는 notify.sh enum(line 25)에 이미 존재.

**Files:**
- Modify `.github/workflows/build.yaml` (build 잡 끝에 telegram-notify 스텝 + secrets 가드)
- Test (new) `tools/test/build-notify.bats`

**Step 1: Write the failing test**
```bash
cat > tools/test/build-notify.bats <<'EOF'
#!/usr/bin/env bats
# build.yaml은 telegram-notify로 빌드 결과를 알린다(source=배포, if: always()).
# ⚠️ 중간 단언은 [ ]만.

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  BUILD="$ROOT/.github/workflows/build.yaml"
}

@test "build.yaml invokes the telegram-notify composite" {
  grep -q './.github/actions/telegram-notify' "$BUILD"
}

@test "build.yaml notify step runs on always() so failures are visible" {
  grep -q 'if: always()' "$BUILD"
}

@test "build.yaml notify uses source 배포 and job.status" {
  grep -q 'source: 배포' "$BUILD"
  grep -q 'status: ' "$BUILD"
  grep -q 'job.status' "$BUILD"
}

@test "build notify source label is a member of the notify.sh enum" {
  # notify.sh enum 건초더미에 '배포'가 있어야 한다(dead label 송신 차단).
  grep -q ' 배포 ' "$ROOT/.github/actions/telegram-notify/notify.sh"
}
EOF
```

**Step 2: Run it, expect FAIL**
```bash
bats tools/test/build-notify.bats
```
Expected: `not ok 1 build.yaml invokes the telegram-notify composite` — build.yaml에 telegram-notify가
없어 grep 실패.

**Step 3: Minimal implementation** — `.github/workflows/build.yaml` build 잡 끝(line 94 이후)에 추가:
```yaml
      # 빌드 결과를 owner에게 가시화 — push 실패가 Actions UI에만 묻히지 않게(if: always()).
      - name: telegram notify
        if: always()
        uses: ./.github/actions/telegram-notify
        with:
          status: ${{ job.status }}
          source: 배포
          title: 이미지 빌드
          ident: ${{ matrix.app }}@${{ github.sha }}
          link: ${{ github.server_url }}/${{ github.repository }}/actions/runs/${{ github.run_id }}
          bot-token: ${{ secrets.TELEGRAM_BOT_TOKEN }}
          chat-id: ${{ secrets.TELEGRAM_CHAT_ID }}
```
(matrix 빌드라 앱별로 1건씩 알림 — `fail-fast: false`와 정합. 성공/실패 모두 `job.status`로 매핑.)

**Step 4: Run test, expect PASS**
```bash
bats tools/test/build-notify.bats
# workflow YAML 유효성(기존 게이트가 쓰는 스위트가 있으면 동반 확인)
bats tools/test/workflow-yaml.bats
```
Expected: build-notify 4 `ok`; workflow-yaml 스위트 0 failures(YAML 파싱 통과).

**Step 5: Commit**
```bash
git -C /Users/ukyi/workspace/homelab-cicd-hardening add .github/workflows/build.yaml tools/test/build-notify.bats && git -C /Users/ukyi/workspace/homelab-cicd-hardening commit -m "feat: build.yaml에 telegram-notify 추가 (이미지 빌드 결과 가시화, source=배포)"
```

---

### Task 8: dispatch-mutation notify-failure를 failure() || cancelled()로 (obs-4)

`dispatch-mutation.yml:143`의 `notify-failure`는 `if: failure()`만 켜져 있어, owner가 큐잉된
변이를 취소(cancelled)하거나 `queue: max` 큐 정리로 취소될 때는 **조용히 묻힌다**. notify.sh는
`cancelled` status를 지원(line 18: `⚪ 취소`)하므로 `if: failure() || cancelled()`로 넓히고,
status를 정적 `failure`가 아니라 실제 상태로 매핑한다.

**Files:**
- Modify `.github/workflows/dispatch-mutation.yml:143` (if 조건) + `:159` (status 매핑)
- Test (extend) `tools/test/dispatcher.bats`

**Step 1: Write the failing test** — `tools/test/dispatcher.bats`에 추가:
```bash
cat >> tools/test/dispatcher.bats <<'EOF'

@test "notify-failure fires on cancelled as well as failure" {
  run grep -nE "if:\s*failure\(\)\s*\|\|\s*cancelled\(\)" "$ROOT/.github/workflows/dispatch-mutation.yml"
  [ "$status" -eq 0 ]
}

@test "notify-failure normalizes status from needs.* results, not its own job.status (F5)" {
  # ⚠️ codex pass2 F5: notify-failure 잡의 job.status는 그 잡 자신(success)이라 거짓 ✅. toJSON(needs)로
  # 정규화하는 스텝이 있고, telegram status가 그 정규화 출력(steps.norm.outputs.status)을 써야 한다.
  WF="$ROOT/.github/workflows/dispatch-mutation.yml"
  run grep -nE 'toJSON\(needs\)' "$WF"
  [ "$status" -eq 0 ]
  run grep -nE 'status:[[:space:]]*\$\{\{[[:space:]]*steps\.norm\.outputs\.status' "$WF"
  [ "$status" -eq 0 ]
  # notify-failure telegram status로 job.status를 직접 쓰면 거짓 success — 금지.
  run grep -nE 'status:[[:space:]]*\$\{\{[[:space:]]*job\.status[[:space:]]*\}\}' "$WF"
  [ "$status" -ne 0 ]
}
EOF
```
(참고: `dispatcher.bats` setup의 `ROOT` 변수를 그대로 재사용. 부재 시 추가 테스트 상단에
`ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"`를 넣는 setup 확인 — 기존 파일 setup에 이미 정의돼 있음.)

**Step 2: Run it, expect FAIL**
```bash
bats tools/test/dispatcher.bats
```
Expected: `not ok ... notify-failure fires on cancelled` — 현재 `if: failure()`라 `|| cancelled()`
정규식 grep이 비-0(매치 0).

**Step 3: Minimal implementation** — `.github/workflows/dispatch-mutation.yml`:

line 141-144 (notify-failure 잡 헤더) 교체:
```yaml
  # 거부/실패/취소가 조용히 묻히지 않게 — owner는 Actions UI 외에 Telegram으로도 본다.
  # queue:max 취소나 owner 수동 취소도 cancelled()로 잡아 가시화한다.
  notify-failure:
    needs: [validate, create-app, update-secrets, teardown-app, teardown-resource, audit, create-database, create-cache, route]
    if: failure() || cancelled()
```
⚠️ codex pass2 F5: `notify-failure` 잡 안에서 `job.status`는 **그 잡 자신**의 상태(= 보통 success)라, 실패/취소한
reusable을 ✅로 보고한다. `needs.*.result` 전체에서 상태를 정규화하는 스텝을 추가한다. checkout 스텝 뒤,
`sanitize action input` 스텝 앞에 삽입:
```yaml
      - name: normalize upstream status
        id: norm
        env:
          RESULTS: ${{ toJSON(needs) }}   # 모든 needs의 result — 본 잡 job.status(success)가 아니라 이걸로 판정
        run: |
          # if: failure()||cancelled()로 진입했으므로 취소>실패 우선 정규화(둘 다 notify.sh enum 멤버).
          if printf '%s' "$RESULTS" | grep -q '"result": *"cancelled"'; then
            echo "status=cancelled" >> "$GITHUB_OUTPUT"
          else
            echo "status=failure" >> "$GITHUB_OUTPUT"
          fi
```
그리고 telegram-notify 스텝의 `status:`(line 159)를 **정규화 출력**으로 교체(본 잡 `job.status` 금지 — 항상 success라 거짓 ✅):
```yaml
        with:
          status: ${{ steps.norm.outputs.status }}
```
(cancelled 시 `⚪ 취소`, 그 외 `🔴 실패` 렌더 — 어떤 reusable이 실패/취소해도 올바른 상태로 알림.)

**Step 4: Run test, expect PASS**
```bash
bats tools/test/dispatcher.bats
bats tools/test/workflow-yaml.bats
```
Expected: dispatcher 스위트 0 failures(신규 2 `ok` 포함); workflow-yaml YAML 파싱 통과.

**Step 5: Commit**
```bash
git -C /Users/ukyi/workspace/homelab-cicd-hardening add .github/workflows/dispatch-mutation.yml tools/test/dispatcher.bats && git -C /Users/ukyi/workspace/homelab-cicd-hardening commit -m "fix: dispatch-mutation notify-failure를 failure() || cancelled()로 + 취소 상태 매핑"
```

---

### Task 9: _audit.yml telegram body의 [:20] 캡·에러삼킴 제거 (obs-6)

`_audit.yml:27`은 audit 결과를 `.findings[:20]`로 잘라 (20건 초과 드리프트를 숨김) +
`2>/dev/null || true`로 jq 오류를 삼킨다(malformed JSON이면 빈 body로 조용히 전송). [:20] 캡을
제거(notify.sh의 4096자 캡에 위임)하고, `2>/dev/null || true` 삼킴을 제거해 jq 실패가 스텝을 깨게 한다.

**Files:**
- Modify `.github/workflows/_audit.yml:27` (jq 표현식)
- Test (new): 기존 `tools/test/workflow-yaml.bats`나 신규 grep 단언 — 여기선 `_audit.yml` 전용
  정적 단언을 `tools/test/build-notify.bats`에 묶지 않고 별도로 `dispatcher.bats`에 추가(이미 audit
  잡 라우팅을 검증하는 스위트). 단순·격리 위해 `tools/test/audit-orphans.bats`가 아닌 워크플로
  단언이므로 신규 케이스를 `dispatcher.bats`에 추가한다.

**Step 1: Write the failing test** — `tools/test/dispatcher.bats`에 추가:
```bash
cat >> tools/test/dispatcher.bats <<'EOF'

@test "_audit.yml summary does not cap findings at 20 (relies on notify.sh 4096 cap)" {
  run grep -c '\.findings\[:20\]' "$ROOT/.github/workflows/_audit.yml"
  [ "$output" = "0" ]
}

@test "_audit.yml summary does not swallow jq errors with 2>/dev/null || true" {
  run grep -cE '2>/dev/null \|\| true' "$ROOT/.github/workflows/_audit.yml"
  [ "$output" = "0" ]
}
EOF
```

**Step 2: Run it, expect FAIL**
```bash
bats tools/test/dispatcher.bats
```
Expected: `not ok ... does not cap findings at 20` — 현재 `jq -r '.findings[:20][] ...'`라
grep -c가 `1`(≠`0`); 두 번째도 `|| true`가 남아 FAIL.

**Step 3: Minimal implementation** — `.github/workflows/_audit.yml:23-32` (build audit summary 스텝) 교체:
```yaml
      - name: build audit summary
        id: report
        if: always()
        run: |
          # [:20] 캡 제거 — 전 드리프트를 보낸다(notify.sh의 4096자 캡이 안전하게 자른다).
          # jq 오류 삼킴(|| true) 제거 — malformed JSON이면 스텝을 깨 조용한 빈 body 전송을 차단.
          summary="$(jq -r '.findings[] | "- \(.type): \(.subject)"' /tmp/audit.json)"
          {
            echo "body<<EOF"
            printf '드리프트 건수: %s\n%s\n' "$COUNT" "$summary"
            echo "EOF"
          } >> "$GITHUB_OUTPUT"
        env:
          COUNT: ${{ steps.audit.outputs.count }}
```

**Step 4: Run test, expect PASS**
```bash
bats tools/test/dispatcher.bats
bats tools/test/workflow-yaml.bats
```
Expected: dispatcher 스위트 0 failures(신규 2 `ok`); workflow-yaml YAML 파싱 통과.

**Step 5: Commit**
```bash
git -C /Users/ukyi/workspace/homelab-cicd-hardening add .github/workflows/_audit.yml tools/test/dispatcher.bats && git -C /Users/ukyi/workspace/homelab-cicd-hardening commit -m "fix: _audit.yml 알림에서 findings [:20] 캡·jq 에러삼킴 제거 (전 드리프트 가시화)"
```

---

## 단계 8 마무리 — 전체 게이트 확인

전 태스크 커밋 후 로컬 게이트 미러로 회귀 0 확인:
```bash
bats tools/test/ci-blocking-comment.bats tools/test/verify-ledger-ssot.bats \
     tools/test/ledger-totals.bats tools/test/audit-orphans.bats \
     tools/test/audit-dangling-role.bats tools/test/poll-ghcr.bats \
     tools/test/build-notify.bats tools/test/dispatcher.bats
shellcheck $(git -C /Users/ukyi/workspace/homelab-cicd-hardening ls-files '*.sh')
make ci   # gate 8스텝 로컬 미러 (mise PATH 보강됨)
```
Expected: 전 스위트 0 failures; shellcheck 무경고; `make ci` 통과 → PR auto-merge(`gate` green).

---

## Phase 9 — dead-man switch (인접, P1)

> **컨텍스트 (read-before-edit로 확인):** `platform/victoria-stack/deadmanswitch-relay.yaml`은 ConfigMap(`relay.sh`) + Deployment + Service. Alertmanager의 항상-발화 Watchdog가 `http://deadmanswitch-relay:9095/ping`(`platform/victoria-stack/alertmanager.yaml:79`)로 webhook을 보내고, 릴레이는 그걸 받을 때 healthchecks.io로 ping을 전달한다. healthchecks.io에서 **ping의 부재**가 곧 page다 — 즉 "webhook 미수신인데도 healthchecks가 green"이면 dead-man switch가 무력화된다.
>
> **버그 (fm-1):** 현재 루프(`relay.sh` ~13-16행)는
> ```sh
> while true; do
>   printf '...ok' | nc -l -p 9095 2>/dev/null || true
>   wget -q -T 10 -O /dev/null "$HEALTHCHECKS_URL" || echo "ping failed $(date)"
> done
> ```
> `|| true`가 `nc` 실패를 삼키고, 그 뒤 `wget`이 **무조건** 발화한다. `nc -l`이 연결을 서빙하지 않고 반환하면(파드 재시작 시 bind 경합, busybox 엣지) 루프가 빠르게 회전하며 webhook이 한 건도 안 와도 healthchecks를 폭주 ping해 체크를 영구 green으로 유지한다 — 문서화된 `-q` 인시던트(AGENTS.md)와 동류.
>
> **수정:** (1) `nc`가 실제로 연결을 서빙(exit 0)했을 때만 healthchecks를 ping, 실패 분기엔 floor `sleep 5`로 self-throttle.
> (2) ⚠️ codex pass2 F7: ConfigMap 스크립트 변경은 파드 자동 재시작이 없다(AGENTS.md) — 수동 `rollout restart`에만
> 의존하면 PR 머지·sync·테스트 통과 후에도 **옛 스크립트가 영구 실행**될 수 있다(dead-man switch라 치명적). 레포가
> 이미 쓰는 패턴(create-app의 `checksum/secrets` podAnnotation)처럼 **relay.sh 내용 해시를 Deployment pod
> template의 `checksum/relay-script` annotation**으로 박아, 스크립트가 바뀌면 template이 바뀌어 **ArgoCD가 자동
> 롤**하게 한다. 게이트 테스트가 `annotation == hash(relay.sh)`를 강제 → 스크립트만 고치고 annotation을 안 바꾸면
> 게이트 실패.
>
> **이건 k8s 워크로드다 (CI 인접).** 동작 테스트는 **정적**(임베드 `relay.sh` bats grep) — busybox 부재·CI 클러스터
> 비접촉. 단, 위 checksum annotation으로 **라이브 발효는 GitOps(ArgoCD)가 보장**한다 — 수동 `rollout restart`는
> 발효 메커니즘이 아니라 사후 검증일 뿐이다.
>
> **게이트 배선:** `platform/victoria-stack/test_relay.bats`는 이미 존재하며(현재 `-q` 회귀 가드 1건), `make ci`/`ci.yaml`의 `find platform -name 'test_*.bats' -not -path '*/charts/*'` 글롭이 자동 수집한다(Makefile:107-109, ci.yaml:68-72 — 제외 목록은 `test_creds_reference`/`test_drill_alerting`/`test_kustomize_build`뿐이라 `test_relay.bats`는 포함). 신규 파일을 만들지 않고 이 파일을 확장한다.

---

### Task 1: nc 성공 시에만 healthchecks ping + 실패 floor sleep (fm-1)

**Files:**
- Modify `platform/victoria-stack/deadmanswitch-relay.yaml`:5-16 (ConfigMap `relay.sh`의 while 루프)
- Test `platform/victoria-stack/test_relay.bats` (기존 파일 확장 — gate 글롭 자동 포함)

**Step 1: Write the failing test**

기존 `test_relay.bats`의 `-q` 가드 `@test`는 보존하고, fm-1 회귀 가드 3건을 추가한다. 정적 grep으로 "nc 실패 시 wget이 도달 불가"(= wget이 nc 성공 분기 안에 중첩) + "실패 분기에 floor sleep 존재" + "`wget` 직전에 `|| true`로 nc 실패를 삼키지 않음"을 단언한다. `[ ]`만 사용(bash 3.2 `[[ ]]` 침묵통과 함정), `@test` 이름은 영어(한글 인코딩 깨짐 함정).

`platform/victoria-stack/test_relay.bats`를 아래로 교체한다(기존 setup/첫 @test 유지 + 신규 3건):

```bash
#!/usr/bin/env bats
# deadmanswitch relay 회귀 가드.
# (1) busybox 1.36 nc에는 -q 옵션이 없다 — 'nc -l -p PORT -q 1'은 invalid option으로 즉시 죽어
#     webhook을 영구 거부했고, 그 결과 healthchecks를 과도 ping해 dead-man switch를 무력화한
#     라이브 인시던트가 있었다.
# (2) fm-1: nc가 실제로 연결을 서빙(exit 0)했을 때만 healthchecks를 ping해야 한다. nc 실패를
#     '|| true'로 삼키고 무조건 wget을 발화하면, bind 경합/busybox 엣지로 nc가 연결 없이 반환할 때
#     루프가 healthchecks를 폭주 ping해 webhook 미수신인데도 체크가 영구 green이 된다.
# 이 릴레이는 k8s 워크로드라 테스트는 임베드 relay.sh에 대한 '정적' grep이다(busybox 부재·CI 클러스터 비접촉).
# ⚠️ 중간 단언은 [ ]만 — bash 3.2 [[ ]] 침묵 통과. @test 이름은 영어 — 한글 인코딩 깨짐.

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  F="$ROOT/platform/victoria-stack/deadmanswitch-relay.yaml"
}

@test "relay nc listener does not use the busybox-incompatible -q flag" {
  run grep -nE 'nc[[:space:]].*-q' "$F"
  [ "$status" -ne 0 ]
}

@test "relay does not swallow nc failure with a trailing || true before pinging" {
  # '... | nc -l ... || true' 패턴(nc 실패 무시)이 더는 없어야 한다.
  run grep -nE 'nc[[:space:]]+-l[^|]*\|\|[[:space:]]*true' "$F"
  [ "$status" -ne 0 ]
}

@test "relay pings healthchecks only when nc served a request (wget nested under nc success)" {
  # wget(healthchecks ping)이 nc를 조건으로 한 if 성공 분기 안에 있어야 한다.
  # 정적 증거: 'if ... nc -l ...; then' 라인이 존재하고, 그 then 블록 안에서 wget이 호출된다.
  run grep -nE 'if[[:space:]].*nc[[:space:]]+-l[[:space:]]+-p[[:space:]]+9095' "$F"
  [ "$status" -eq 0 ]
  # wget은 if 가드와 같은 then 블록의 들여쓰기 깊이(공백 6칸 이상)로 중첩돼야 한다.
  run grep -nE '^[[:space:]]{6,}wget[[:space:]]' "$F"
  [ "$status" -eq 0 ]
}

@test "relay self-throttles on nc bind failure with a floor sleep" {
  # nc 실패 분기에 sleep(>=1초)이 있어 bind 경합 시 루프 spin/healthchecks 폭주를 막는다.
  run grep -nE '^[[:space:]]+sleep[[:space:]]+[1-9][0-9]*' "$F"
  [ "$status" -eq 0 ]
}

@test "relay Deployment carries a checksum/relay-script annotation matching relay.sh (F7 GitOps roll)" {
  # ⚠️ codex pass2 F7: ConfigMap 변경은 파드 자동 재시작이 없다 — 스크립트 해시를 pod template annotation으로
  # 박아 relay.sh 변경 시 template이 바뀌어 ArgoCD가 자동 롤하게 한다. 이 단언이 annotation==hash를 강제.
  command -v yq >/dev/null || skip "yq required"
  expected=$(yq 'select(.kind=="ConfigMap").data."relay.sh"' "$F" | sha256sum | cut -c1-16)
  ann=$(yq 'select(.kind=="Deployment").spec.template.metadata.annotations."checksum/relay-script"' "$F")
  [ -n "$ann" ]
  [ "$ann" = "$expected" ]
}
```

**Step 2: Run it, expect FAIL**

```bash
bats platform/victoria-stack/test_relay.bats
```

기대 실패: 첫 `@test`(`-q` 가드)는 PASS(이미 충족), 신규 4건(`|| true`·nc중첩·sleep·checksum)은 FAIL —
```
 ✓ relay nc listener does not use the busybox-incompatible -q flag
 ✗ relay does not swallow nc failure with a trailing || true before pinging
   (in test file ...) `[ "$status" -ne 0 ]' failed
 ✗ relay pings healthchecks only when nc served a request (wget nested under nc success)
   (in test file ...) `[ "$status" -eq 0 ]' failed
 ✗ relay self-throttles on nc bind failure with a floor sleep
   (in test file ...) `[ "$status" -eq 0 ]' failed
```
이유: 현재 manifest에 `nc -l ... || true`가 존재(`|| true` 단언 실패), `if ... nc -l -p 9095` 라인 부재, `sleep` 부재.

**Step 3: Minimal implementation**

`platform/victoria-stack/deadmanswitch-relay.yaml`의 ConfigMap `relay.sh`(5-16행)를 교체한다. `nc`를 `if`의 조건으로 두면 `set -eu`가 루프를 죽이지 않는다(compound 조건 실패는 `set -e` 비대상 — 단, 중간 `[[ ]]` 함정은 bats 한정이라 여기 sh 스크립트엔 무관). `wget`은 nc 성공 분기 안으로 중첩, 실패 분기엔 `sleep 5`.

```yaml
data:
  relay.sh: |
    #!/bin/sh
    set -eu
    # busybox nc 루프를 이용한 최소 HTTP 리스너.
    # /ping에 어떤 POST가 오든 healthchecks.io로 ping 한 번을 보낸다.
    # 주의: busybox 1.36 nc에는 -q 옵션이 없다(invalid option으로 리스너가 즉시 죽어
    # webhook이 영구 connection refused가 되고, while 루프가 healthchecks를 과도하게
    # ping해 dead-man switch를 무력화한다).
    # fm-1: nc가 실제로 연결을 서빙(exit 0)했을 때만 healthchecks를 ping한다. nc가 연결 없이
    # 즉시 반환하면(파드 재시작 시 bind 경합·busybox 엣지) ping을 건너뛰고 floor sleep으로
    # self-throttle한다 — 무조건 ping하면 루프가 healthchecks를 폭주 ping해 webhook이 안 와도
    # 체크를 영구 green으로 만들어 dead-man switch를 무력화한다.
    while true; do
      if printf 'HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok' | nc -l -p 9095 2>/dev/null; then
        wget -q -T 10 -O /dev/null "$HEALTHCHECKS_URL" || echo "ping failed $(date)"
      else
        echo "nc listener failed, throttling $(date)"
        sleep 5
      fi
    done
```

> ⚠️ 직접 수정(이 파일은 `*.enc.yaml`이 아니므로 평문 편집 허용 — SOPS MAC 무관). 시크릿 값(`HEALTHCHECKS_URL`)은 env로만 주입되며 스크립트/로그에 평문 출력하지 않는다(`wget`은 `-O /dev/null`, URL은 변수로만).

(b) **GitOps 자동 롤 (codex pass2 F7)** — 같은 파일의 **Deployment** 문서 `spec.template.metadata.annotations`에 relay.sh 내용 해시를 박는다. (a)에서 relay.sh를 바꿨으니 새 내용으로 해시를 재계산한다:

```bash
# annotation 값 계산(test_relay.bats와 동일 명령 — 반드시 일치해야 게이트 통과):
yq 'select(.kind=="ConfigMap").data."relay.sh"' platform/victoria-stack/deadmanswitch-relay.yaml | sha256sum | cut -c1-16
```
Deployment pod template에 추가(`annotations:` 블록 없으면 신설):
```yaml
spec:
  template:
    metadata:
      annotations:
        # relay.sh 내용 해시 — 스크립트 변경 시 이 값을 위 명령으로 갱신하면 pod template이 바뀌어
        # ArgoCD가 자동 롤한다(ConfigMap 무재시작 함정 회피, AGENTS.md). test_relay.bats가 일치를 강제.
        checksum/relay-script: "<위 명령 출력 16hex>"
```
(이 annotation이 바뀌면 Deployment generation이 올라 ArgoCD가 새 파드로 교체 → 새 relay.sh가 즉시 발효. 수동 `rollout restart` 불필요.)

**Step 4: Run test, expect PASS**

```bash
bats platform/victoria-stack/test_relay.bats
```

기대 출력:
```
 ✓ relay nc listener does not use the busybox-incompatible -q flag
 ✓ relay does not swallow nc failure with a trailing || true before pinging
 ✓ relay pings healthchecks only when nc served a request (wget nested under nc success)
 ✓ relay self-throttles on nc bind failure with a floor sleep
 ✓ relay Deployment carries a checksum/relay-script annotation matching relay.sh (F7 GitOps roll)

5 tests, 0 failures
```

게이트 통합 확인(글롭 수집 + 전체 platform 정적 스위트가 여전히 green):

```bash
rc=0; for f in $(find platform -name 'test_*.bats' -not -path '*/charts/*' \
  -not -name test_creds_reference.bats -not -name test_drill_alerting.bats \
  -not -name test_kustomize_build.bats | sort); do bats "$f" || rc=1; done; echo "rc=$rc"
```
기대: `rc=0`(`test_relay.bats`가 글롭에 포함돼 4 tests pass).

**Step 5: Commit**

```bash
git -C /Users/ukyi/workspace/homelab-cicd-hardening add platform/victoria-stack/deadmanswitch-relay.yaml platform/victoria-stack/test_relay.bats && git -C /Users/ukyi/workspace/homelab-cicd-hardening commit -m "fix: deadmanswitch relay nc-서빙 성공 시에만 healthchecks ping + checksum annotation으로 ArgoCD 자동 롤 (fm-1, F7)"
```

> **라이브 발효(GitOps 자동 — codex pass2 F7):** ConfigMap 스크립트 변경은 파드 자동 재시작이 없지만(AGENTS.md), Step 3(b)의 `checksum/relay-script` annotation이 바뀌므로 Deployment pod template이 변경돼 **ArgoCD가 자동으로 파드를 교체**한다(수동 `rollout restart` 불필요 — 발효 메커니즘이 GitOps). **사후 검증(런북):** 머지 후 healthchecks.io 대시보드에서 ping 주기가 Alertmanager `group_interval`과 일치(폭주 아님)하고, `kubectl -n observability get pod -l app=deadmanswitch-relay`가 새 파드로 교체됐는지 확인한다.

---

## Adversarial review dispositions

> **사후 감사 추적(post-approval bookkeeping)** — 이 절은 hardened-planning의 adversarial review 루프 기록이다.
> codex(working-tree 스코프)로 **5패스** 검토했고, **18개 plan finding 전부 Accept + 반영**했다. verdict는
> "approve"에 도달하지 않았으나(매 패스가 직전 수정이 노출한 더 미세한 인접 이슈를 ~3건씩 발견 — 핵심 39-발견
> 프로그램이 아니라 **추가한 리메디에이션 인프라(composite/parser/download)의 robustness 디테일**로 수렴),
> 사용자가 pass 5 findings 3건을 반영한 뒤 **정보에 입각해 확정을 결정**했다(잔여는 구현 단계 TDD가 자연히 잡는
> 종류로 판단 — diminishing returns). 미해결 high/critical finding은 없다(전부 반영).

**Pass 1** (verdict: needs-attention, 4 findings — 전부 Accept·반영):
- **security-supplychain-1** (분기보호 불변식이 required gate 밖) — Accept: 테스트를 `tools/test/branch_protection.bats`(gate 글롭)로 이동(이후 pass1 F1 표기와 동일 이슈를 pass1에서 교정).
- **concurrency-races-4** (TOCTOU 가드 자기비교) — Accept: `--expect-current`를 플래너 스냅샷 `.current.tag`에서 받도록 수정.
- **concurrency-races-5** (activation 마커 자기 무효화) — Accept: `.activation` 제외 canonical surfaceHash(공유 `tools/lib/surface-hash.mjs`)로 수정.
- **supplychain-7** (sops 가드가 ENC 정확일치) — Accept: `test("^ENC\[")` prefix + 게이트 포함 fixture.

**Pass 2** (needs-attention, 5 — 전부 Accept·반영):
- **obs-4** (notify-failure가 실패를 성공으로 보고) — Accept: `toJSON(needs)` 정규화 스텝 + `steps.norm.outputs.status`.
- **races-5 fail-open**(빈 해시 시 audit skip) — Accept(후속 pass3에서 비차단으로 재설계): 당시 fail-closed로 수정.
- **fm-1 GitOps 미적용**(deadmanswitch 수동 restart 의존) — Accept: `checksum/relay-script` pod-template annotation으로 ArgoCD 자동 롤 + render 테스트.
- **races-3/obs-5 pr-sweeper checkout 누락** — Accept: `actions/checkout` 선행 + 일반 가드 테스트(로컬 액션 쓰는 워크플로는 checkout 필수).
- **drift-2 live-DNS documented-away** — Accept: 커밋된 opt-in `tools/dns-drift-check.mjs` + `dns-drift.yml` 스케줄 워크플로.

**Pass 3** (needs-attention, 3 — 전부 Accept·반영):
- **races-5 게이트가 정상 bump 데드락** — Accept: activation surface-drift를 **비차단(정보성) + 런북 재검증**으로 격하(BLOCKING에서 제거; 원래 low 발견 + 설계의 "축소" 약속). fail-closed/waive 복잡성 제거.
- **sops 구조 가드 ≠ integrity** — Accept: 범위를 평문 tripwire로 한정 명시 + `*.enc.yaml` 변경은 owner-local `sops --decrypt` 검증 요구.
- **reconcile 원자성**(부분 수렴 불가) — Accept: 텍스트를 정직하게 정정(delete 포함 plan은 apply 전체 skip; 의도된 DR-safety tradeoff).

**Pass 4** (needs-attention, 3 — 전부 Accept·반영):
- **activation 마커가 apps.json 노출 행 무시** — Accept: 마커에 registry 행 projection(name/host/public) 포함 + audit 비교 + 회귀 테스트(정보성).
- **gitleaks full-history 스캔** — Accept: `gitleaks detect --no-git --source .`(작업트리만) + 테스트.
- **DNS 체커가 transient를 drift로 보고** — Accept: `drift`/`transient` 버킷 분리(drift count는 NXDOMAIN만) + SERVFAIL fixture 테스트.

**Pass 5** (needs-attention, 3 — 전부 Accept·반영, 이후 사용자 확정):
- **destroy-guard가 모든 실패를 delete-차단으로 처리** — Accept: composite가 typed output(`result`=ok/blocked-delete/error, `destroy_count`) — reconcile은 `result=='ok'`만 apply, `'error'`는 잡 loud 실패 + 테스트.
- **bump-tag가 값 누락 플래그 허용** — Accept: `takeOpt`를 arity 검증 파서로 대체(값-플래그는 비어있지 않고 `--flag`가 아닌 값 필수) + arity 테스트.
- **gate gitleaks 체크섬 미검증** — Accept: 파일 다운로드 + 핀된 SHA256 `sha256sum -c` 검증 후 추출 + 테스트.

**최종 상태**: 5패스 / 18 findings 전부 Accept·반영, 미해결 high/critical 0. 사용자 확정(2026-06-16). 마지막 검토 verdict는
`needs-attention`(pass 5)이나, 사용자가 pass 5 3건 반영 후 수렴 판단으로 확정 — 잔여 미세 이슈는 본 계획의 TDD(각
Task가 실패 테스트 우선)가 구현 단계에서 포착한다.
