# AGENTS.md/문서 SSOT 개편 Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** AGENTS.md(19KB/210줄)의 트랩 prose(52%)를 `docs/traps-detail.md`로 분리(progressive disclosure)하고, 디렉토리 지도·트랩 원장·런북 인덱스 드리프트 가드를 신설한다.

**Architecture:** 순수 문서/가드(라이브 클러스터 무관). 트랩 41항목을 **무손실** 이전(traps-detail.md=새 SSOT) + AGENTS는 한줄 인덱스. README 단일화(D2)·guard-path-tie(D3)·런북 로컬 가드. ★핵심 리스크=무손실(하드원 지식 유실 금지).

**Tech Stack:** Markdown(AGENTS.md/traps-detail.md/traps.md/README), bash(verify-traps/verify-runbooks), bats(run-bats 게이트), check-skeleton.

**설계 출처:** `docs/plans/2026-06-20-docs-ssot-refactor-design.md`(커밋 `6bce677`). D1=한줄 인덱스, D2=README 단일화, D3=guard-path-tie, 무손실 이전.

---

## 작업 전 공통 규칙

- **bats `@test` 영어**·중간 단언 `[ ]`·`test_` 접두·bash 3.2 호환.
- **★무손실**: 41 트랩 전량 보존 — 이전은 **재배치(reformat)만, 내용 0 삭제**. Task 6 lossless diff가 강제.
- AGENTS.md는 `@AGENTS.md`로 매 세션 로드 — 인덱스는 발견성 유지(함정 헤드라인 한눈에).
- **커밋**: 한국어 conventional·AI 마커 금지. type=feat/fix/refactor/docs/style/test/chore. (이전/문서=`docs:`, 가드=`test:`/`feat:`.)
- 기준 원본: `git show origin/main:AGENTS.md`(트랩절 L52-161, 41 불릿).

---

## Task 1: `docs/traps-detail.md` 생성 — 트랩 41항목 무손실 이전 (SSOT)

**Files:**
- Create: `docs/traps-detail.md`

**Step 1: AGENTS 트랩절 추출** — `sed -n '52,161p' AGENTS.md`로 '라이브에서 검증된 함정' 41 불릿 확보. 각 불릿 형식 `- **<용어>** — <prose>`(여러 줄 가능).

**Step 2: traps-detail.md 작성** — 헤더 + 41 섹션. ★**원본 불릿을 verbatim 보존**(F4 — `### 헤드라인`·`> 가드`만 추가, 불릿 텍스트는 0 변경):
```markdown
# 라이브에서 검증된 함정 — 상세 (SSOT)

> 이 파일이 함정의 **단일 SSOT**다(AGENTS.md '라이브에서 검증된 함정'절에서 이전, progressive disclosure).
> AGENTS.md에는 한줄 인덱스만 둔다. enforced 함정의 가드 현황은 `docs/traps.md` 원장(`make verify-traps`).
> 컴포넌트 작업 전 해당 항목을 확인할 것.

### ArgoCD sync-wave 순서/교착
- **ArgoCD sync-wave는 ...** — <원본 불릿 줄 그대로(연속 줄 포함, `**`·glob 등 0 변경)>
> 가드: `platform/cnpg/prod/test_sync_wave_ordering.bats`, `platform/argocd/root/test_sync_wave_ledger.bats`

### k8s SSA 중복 env 키/스키마 밖 필드 거부
- **k8s SSA는 ...** — <원본 불릿 verbatim>
...
```
- **각 불릿 → `### <헤드라인>` 섹션**. 헤드라인 = 짧은 식별구(AGENTS 인덱스와 **동일 텍스트** — Task 2/5 결속). 헤드라인 **아래에 원본 불릿(`- **term** —...`)을 verbatim 붙여넣기**(F4 — strip 0, 무손실 체크가 whole-line 매칭).
- **enforced 트랩**(traps.md 원장에 행 있는 것)은 섹션 끝에 **`> 가드: \`path\``**(원장의 guard 열 경로 복사) — D3 guard-path-tie 결속.
- ★코드/경로/강조(`**`)/glob(`**/*.log`)는 **원형 그대로**(재배치만, 내용 0 변경).

**Step 3: 섹션 개수 확인** — `grep -c '^### ' docs/traps-detail.md` == 41(불릿 수와 일치).

**Step 4: ★줄단위 무손실 검증 (핵심, F1)** — 원본 트랩 prose의 **모든 줄**이 traps-detail.md에 **verbatim 보존**됐는지(헤드라인만이 아니라 본문 명령·주의·복구상세까지). AGENTS 축소(Task 2) **전**에:
```bash
# 원본 트랩 '불릿 블록만'(첫 `- `부터 — intro blockquote 제외[Task1이 재작성], F5) verbatim 검사(strip 0, F4). fail-closed.
miss=0
while IFS= read -r line; do
  [ -n "$line" ] || continue
  grep -Fq "$line" docs/traps-detail.md || { echo "MISSING: $line"; miss=1; }
done < <(git show origin/main:AGENTS.md | sed -n '52,161p' | sed -n '/^- /,$p')
[ "$miss" -eq 0 ] && echo "무손실 OK(전량 verbatim)" || { echo "★무손실 위반 — 위 MISSING 줄 누락/변조"; exit 1; }
```
> ★`sed -n '/^- /,$p'`=첫 불릿부터(intro 제외, F5). strip 0(`**`·glob 원형, F4). `miss` fail-closed(MISSING 시 exit 1) — process substitution이라 메인 셸서 카운트.

**Step 5: 커밋**
```bash
git add docs/traps-detail.md
git commit -m "docs: 라이브 검증 함정 41항목을 traps-detail.md로 이전(SSOT, progressive disclosure)"
```

---

## Task 2: AGENTS.md 트랩절 → 한줄 인덱스 + 포인터 (D1)

**Files:**
- Modify: `AGENTS.md` (L52-161 → 인덱스)

**Step 1: 트랩절 교체** — '라이브에서 검증된 함정' 절(L52-161)을 한줄 인덱스로:
```markdown
## 라이브에서 검증된 함정 (재발 주의)

> 전문·근거는 **`docs/traps-detail.md`(SSOT)** — 컴포넌트 작업 전 해당 항목 확인. enforced 가드 현황은
> `docs/traps.md` 원장(`make verify-traps`). 아래는 한줄 인덱스(헤드라인 = traps-detail.md 섹션과 동일).

- ArgoCD sync-wave 순서/교착 — 이전 wave healthy 대기, 내부 wave 신중
- k8s SSA 중복 env 키/스키마 밖 필드 거부
- NetworkPolicy ipBlock pod-CIDR → default-deny 무력화
- ... (41줄, traps-detail.md `### ` 헤드라인 순서대로)
```
- **각 줄 = traps-detail.md `### ` 헤드라인(동일 텍스트) + 선택적 짧은 꼬리**. 순서 동일.

**Step 2: 무손실 1차 확인** — `grep -c '^- ' <AGENTS 인덱스 범위>` == 41(traps-detail 섹션 수와 일치).

**Step 3: 커밋**
```bash
git add AGENTS.md
git commit -m "docs: AGENTS.md 트랩절을 한줄 인덱스로 축소(prose는 traps-detail.md, 매 세션 컨텍스트 ↓)"
```

---

## Task 3: 트랩 SSOT 참조 갱신 (traps.md + 잔여 포인터)

**Files:**
- Modify: `docs/traps.md` (SSOT 참조 AGENTS→traps-detail)
- Modify: (grep로 발견되는 잔여 "AGENTS.md 라이브 함정" 포인터)

**Step 1: traps.md 갱신** — L3 "`AGENTS.md`의 '라이브에서 검증된 함정'이 함정의 단일 SSOT다" → "`docs/traps-detail.md`가 함정의 단일 SSOT다". L5 "AGENTS.md가 유일 SSOT" → "traps-detail.md가 유일 SSOT". 표 컬럼 헤더 `| 함정 (AGENTS.md) |` → `| 함정 (traps-detail.md) |`.

**Step 2: 잔여 포인터 grep** — `grep -rn "AGENTS.md.*함정\|라이브에서 검증된 함정" --include="*.md" --include="*.sh" . | grep -v docs/plans`로 다른 참조 확인 → traps-detail.md로 갱신(있으면).

**Step 3: 커밋** — ★Step 2에서 편집한 **모든 파일** 스테이징(traps.md만 add하면 잔여 포인터 편집 누락, F7):
```bash
git add docs/traps.md   # + Step 2 grep로 갱신한 잔여 포인터 파일 전부(있으면 — git status로 확인)
git status --short       # 편집했는데 미스테이징인 파일 0 확인
git commit -m "docs: 트랩 SSOT 참조를 AGENTS.md→traps-detail.md로 갱신"
```

---

## Task 4: 디렉토리 지도 README 단일화 (D2, 발견2)

**Files:**
- Modify: `AGENTS.md` (`platform/` 행 인라인 열거 제거)
- Modify: `tools/tests/test_dirmap.bats` (주석 정정)

**Step 1: AGENTS map 단일화** — `platform/` 행의 인라인 컴포넌트 열거(`(argocd, traefik, ..., data-conn)`, homepage 누락) 제거 → `| `platform/` | ArgoCD가 싱크하는 GitOps 컴포넌트 — **전체 목록은 README 디렉토리 지도**(check-skeleton 강제) |`.

**Step 2: dirmap 테스트 주석 정정** — `tools/tests/test_dirmap.bats:2` 주석 "README.md/AGENTS.md의 platform 지도" → "README.md의 platform 지도"(테스트는 이미 README만 검사 — 정합). 테스트 로직 불변.

**Step 3: homepage README 존재 확인** — `grep -q homepage README.md`(가드된 SSOT에 존재 — 자동 정합).

**Step 4: 통과 확인** — `bats tools/tests/test_dirmap.bats` PASS + `bash scripts/check-skeleton.sh`(README dirmap 강제, AGENTS 무관해짐).

**Step 5: 커밋**
```bash
git add AGENTS.md tools/tests/test_dirmap.bats
git commit -m "docs: 디렉토리 지도 README 단일화(AGENTS 인라인 열거 제거→README 포인터, homepage 드리프트 해소)"
```

---

## Task 5: 트랩 sync 가드 — guard-path-tie + 인덱스 일치 (D3, 발견4 + D1)

**Files:**
- Modify: `scripts/verify-traps.sh` (guard-path-tie 추가)
- Create: `tests/gates/test_traps-sync.bats` (인덱스 ↔ traps-detail 일치)
- Modify: `docs/traps.md` (verify-traps 설명에 guard-path-tie 한 줄)

**Step 1: 실패 테스트 작성** (`tests/gates/test_traps-sync.bats`):
```bash
#!/usr/bin/env bats
# 트랩 SSOT 동기화 가드: AGENTS 인덱스 ↔ traps-detail.md 헤드라인. ⚠️ 중간 단언 [ ]만.
setup() { ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"; }

@test "every traps-detail.md heading appears in the AGENTS.md trap index (no drift)" {
  D="$ROOT/docs/traps-detail.md"; A="$ROOT/AGENTS.md"
  # traps-detail '### ' 헤드라인 추출 → 각각 AGENTS 인덱스에 존재
  while IFS= read -r h; do
    [ -n "$h" ] || continue
    grep -Fq "$h" "$A" || { echo "FAIL: AGENTS 인덱스에 누락된 트랩 헤드라인: $h"; false; }
  done < <(grep '^### ' "$D" | sed 's/^### //')
}

@test "trap index count matches traps-detail section count" {
  A="$ROOT/AGENTS.md"; D="$ROOT/docs/traps-detail.md"
  # AGENTS 트랩 인덱스 불릿 수 == traps-detail '### ' 수
  idx="$(sed -n '/^## 라이브에서 검증된 함정/,/^## /p' "$A" | grep -c '^- ')"
  det="$(grep -c '^### ' "$D")"
  [ "$idx" -eq "$det" ]
}

@test "guard-path-tie excludes prose-mentioned paths (traps.md prose has scripts/verify-traps.sh, not required in SSOT, F6)" {
  T="$ROOT/docs/traps.md"; D="$ROOT/docs/traps-detail.md"
  run grep -Fq 'scripts/verify-traps.sh' "$T"; [ "$status" -eq 0 ]    # prose(표 밖)에 존재
  run grep -Fq 'scripts/verify-traps.sh' "$D"; [ "$status" -ne 0 ]    # SSOT엔 부재(가드 아님)
  run bash "$ROOT/scripts/verify-traps.sh"; [ "$status" -eq 0 ]       # tie가 표 guard열만이라 그래도 PASS
}
```

**Step 2: 실패 확인** — traps-detail.md/인덱스 정합 전이면 적절히 FAIL(또는 정합이면 PASS — 가드 신설).

**Step 3: verify-traps.sh guard-path-tie 추가** — 기존 '경로 실재' 검사 뒤에:
```bash
# guard-path-tie(D3, F6): 표 'guard 열'에서만 경로 추출(prose 백틱 경로 제외) → traps-detail.md에도 등장해야.
DETAIL="${2:-docs/traps-detail.md}"
if [ -f "$DETAIL" ]; then
  # 표 행(| ... |)의 마지막 데이터 열(guard) 백틱 경로만 — prose 언급(scripts/verify-traps.sh 등) 비대상(F6)
  guard_paths="$(grep -E '^\|' "$LEDGER" | awk -F'|' 'NF>=4{print $(NF-1)}' | grep -oE '`[^`]+`' | tr -d '`' | grep -E '\.(bats|sh|rego|mjs|ya?ml|json)$' | sort -u)"
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    grep -Fq "$p" "$DETAIL" || { echo "FAIL: 원장 guard 경로가 traps-detail.md에 부재(SSOT 드리프트): $p"; fail=1; }
  done <<< "$guard_paths"
fi
```
> ★기존 `paths`(전체 백틱, 존재검사용)와 별개로 **표 guard 열만**(`$(NF-1)`) tie — prose의 verify-traps.sh 등은 traps-detail.md에 비요구(F6). traps-detail.md의 `> 가드: \`path\`` 주석과 매칭(Task 1 Step 2).

**Step 4: traps.md 설명 갱신** — '검사 방향' 항목에 한 줄: "+ 원장 guard 경로가 `traps-detail.md`에도 등장하는지(guard-path-tie — SSOT↔원장 내용 드리프트 차단)".

**Step 5: 통과 확인** — `bats tests/gates/test_traps-sync.bats` PASS + `make verify-traps`(확장) PASS + `shellcheck scripts/verify-traps.sh`.

**Step 6: 커밋**
```bash
git add scripts/verify-traps.sh tests/gates/test_traps-sync.bats docs/traps.md
git commit -m "test: 트랩 SSOT 동기화 가드(guard-path-tie + 인덱스↔traps-detail 일치)"
```

---

## Task 6: 런북 인덱스 로컬 가드 — 별도 타겟 (발견3, F2)

★기존 `verify-runbooks`(Makefile:107-111, **DR 런북 bats 러너** — `test_restore_runbook.bats` 실행)는 **불변**. 인덱스 가드는 **신규 `verify-runbook-index`** 별도 타겟(DR 테스트 은닉 방지, F2).

**Files:**
- Create: `scripts/verify-runbook-index.sh`
- Modify: `Makefile` (`verify-runbook-index` 신규 타겟 — `verify-runbooks`는 손대지 않음)
- Test: `tests/gates/test_verify-runbook-index.bats`

**Step 1: 실패 테스트 작성** (`tests/gates/test_verify-runbook-index.bats`) — ★setup() 필수(F3):
```bash
#!/usr/bin/env bats
# 런북 인덱스 가드: 로컬 전용·런북 부재 시 clean skip. ⚠️ 중간 단언 [ ]만.
setup() { ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"; }

@test "runbook-index guard exists, is local-only, and skips cleanly when runbooks absent" {
  S="$ROOT/scripts/verify-runbook-index.sh"
  [ -f "$S" ]
  run grep -Eq 'docs/runbooks|AGENTS.md' "$S"; [ "$status" -eq 0 ]
  run bash "$S"; [ "$status" -eq 0 ]   # 런북 부재(CI/repo)면 skip(exit 0). bash 호출=exec비트 무의존(F3)
}

@test "existing verify-runbooks DR bats runner target is preserved (not replaced, F2)" {
  run grep -Eq 'bats docs/runbooks' "$ROOT/Makefile"; [ "$status" -eq 0 ]
}
```

**Step 2: 실패 확인** — FAIL(스크립트 없음).

**Step 3: verify-runbook-index.sh** (`scripts/verify-runbook-index.sh`):
```bash
#!/usr/bin/env bash
# 런북 인덱스 드리프트 로컬 가드 — docs/runbooks/(gitignored)에 .md가 있으면 AGENTS.md 런북 인덱스와 일치.
# 런북은 비공개 로컬이라 CI/repo엔 부재 → skip(required gate 아님). cf. verify-runbooks=DR bats 러너(별도, 불변).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RB="$ROOT/docs/runbooks"
shopt -s nullglob
files=("$RB"/*.md)
if [ ${#files[@]} -eq 0 ]; then echo "verify-runbook-index: 런북 부재(gitignored 로컬) — skip"; exit 0; fi
fail=0
for f in "${files[@]}"; do
  b="$(basename "$f")"
  case "$b" in test_*) continue;; esac
  grep -Fq "$b" "$ROOT/AGENTS.md" || { echo "FAIL: AGENTS 런북 인덱스에 누락: $b"; fail=1; }
done
[ "$fail" -eq 0 ] && echo "verify-runbook-index: 런북 인덱스 정합 OK"
exit "$fail"
```

**Step 4: Makefile 신규 타겟** — `verify-runbooks`(기존, 불변) 옆에 추가:
```makefile
.PHONY: verify-runbook-index
verify-runbook-index: ## [local] 런북 인덱스↔docs/runbooks 정합(gitignored라 CI skip — verify-runbooks와 별개)
	@bash scripts/verify-runbook-index.sh
```

**Step 5: chmod + 통과 확인 (F3)** — `chmod +x scripts/verify-runbook-index.sh`(git mode 보존) + `bats tests/gates/test_verify-runbook-index.bats` PASS(런북 부재 skip·기존 DR 러너 보존 단언) + `shellcheck scripts/verify-runbook-index.sh` + 로컬에 런북 있으면 `make verify-runbook-index`.

**Step 6: 커밋**
```bash
git add scripts/verify-runbook-index.sh Makefile tests/gates/test_verify-runbook-index.bats
git commit -m "feat: 런북 인덱스 드리프트 로컬 가드(verify-runbook-index 별도 타겟, 기존 verify-runbooks 불변)"
```

---

## Task 7: 무손실 검증 + 전체 게이트

**Files:** 없음(검증만)

**Step 1: ★무손실 재검증 (핵심, F1/F4/F5)** — Task 1 Step 4의 **불릿블록 verbatim 검증**(fail-closed)을 최종 재실행:
```bash
miss=0
while IFS= read -r line; do
  [ -n "$line" ] || continue
  grep -Fq "$line" docs/traps-detail.md || { echo "MISSING: $line"; miss=1; }
done < <(git show origin/main:AGENTS.md | sed -n '52,161p' | sed -n '/^- /,$p')
[ "$miss" -eq 0 ] || { echo "★무손실 위반"; exit 1; }
```
- 추가: traps-detail.md 섹션 == 41, AGENTS 인덱스 == 41(Task 5 가드).

**Step 2: 정적 게이트** — `bats tests/gates/test_traps-sync.bats tests/gates/test_verify-runbook-index.bats tools/tests/test_dirmap.bats` 0 failures + `make verify-traps`(확장) + `bash scripts/check-skeleton.sh` + `make ci`(run-bats·accounting·shellcheck).

**Step 3: 컨텍스트 비용 확인** — `wc -l AGENTS.md`가 ~130줄(210→축소, 트랩 prose 제거분).

**Step 4: 잔여 stale 포인터 0 + git clean (F7)** — 트랩 SSOT가 traps-detail.md로 이동했으니 "AGENTS.md가 함정 SSOT"라는 stale 참조가 없어야:
```bash
# stale 포인터(AGENTS.md를 함정 SSOT로) 0 — 있으면 traps-detail.md로 갱신 후 재커밋
grep -rn "AGENTS.md.*함정.*SSOT\|함정의 단일 SSOT.*AGENTS" --include="*.md" --include="*.sh" . | grep -v docs/plans \
  && { echo "★STALE 포인터 잔존 — 갱신 필요"; } || echo "잔여 포인터 0 OK"
git status --short    # 편집 파일 전부 커밋(미스테이징 0)
```

**Step 5: PR 준비** — `git log --oneline origin/main..HEAD` 요약. ★**라이브 무관**(순수 문서/가드, ArgoCD 미싱크 영역). PR/머지 owner.

---

## 실행 순서 메모

- **순서: Task 1(traps-detail 이전) → 2(AGENTS 인덱스) → 3(참조 갱신) → 4(README 단일화) → 5(sync 가드) → 6(런북 가드) → 7(무손실 검증)**.
- ★**무손실이 최우선** — Task 1 이전은 재배치만(내용 0 삭제), Task 7 Step 1이 강제 검증. 누락 의심 시 정지.
- 라이브 영향 **없음**(순수 문서/가드). AGENTS.md는 매 세션 로드라 인덱스 발견성 유지가 가치.

---

## Adversarial review dispositions

hardened-planning 3-pass codex 적대 리뷰. **7발견(F1~F7) 전부 Accept·반영**. 각 게이트 AskUserQuestion 승인. Pass 3에서 cap(3) 도달, Pass 4 후 **확정**(Pass 4 미실행). 7발견 중 5건이 **무손실/가드 게이트 자기정확성**(문서 리팩토링의 self-referential 가드 특성).

| Pass | # | 발견 | Sev | Disposition |
|---|---|---|---|---|
| 1 | F1 | 무손실 검증이 헤드라인 토큰 grep만 — 본문 누락 통과 | high | **Accepted** — 줄단위 verbatim 검증 + AGENTS 축소 전 실행 |
| 1 | F2 | 기존 `verify-runbooks`(DR bats 러너)를 인덱스체크로 교체→DR 테스트 은닉 | medium | **Accepted** — 신규 `verify-runbook-index` 별도 타겟, 기존 불변 |
| 1 | F3 | 런북 테스트 setup() 누락(`$ROOT`)·chmod 누락 | medium | **Accepted** — setup() + `chmod +x`(bash 호출) |
| 2 | F4 | 무손실 체크의 `**` strip이 강조·리터럴 glob 손상 → 미변경 원본도 거짓 MISSING | high | **Accepted** — 원본 불릿 verbatim 보존 + whole-line `grep -Fq`(strip 0) |
| 3 | F5 | 무손실 체크가 intro blockquote(재작성 대상)까지 검사 → 거짓 MISSING | high | **Accepted** — 소스를 불릿블록만(첫 `- `부터) + fail-closed(exit 1) |
| 3 | F6 | guard-path-tie가 prose 백틱 경로까지 요구(overbroad `paths` 재사용) | high | **Accepted** — 표 guard열만(`$(NF-1)`) tie + 회귀 @test |
| 3 | F7 | 잔여 SSOT 포인터 편집이 커밋에 미스테이징 | medium | **Accepted** — 변경 파일 전부 스테이징 + stale 포인터 0·git clean 단언 |

**최종 패스(3) verdict:** `needs-attention`(F5/F6/F7) — 반영. 사용자 합의로 Pass 3에서 확정. ★★핵심 교훈: **문서 SSOT 리팩토링의 가드는 self-referential이라 가드 자신이 버그투성이**: ①무손실 검증이 정규화(strip)하면 그 정규화가 텍스트를 손상(F4 `**`·glob)·재작성 영역(F5 intro)·헤드라인만(F1) — **whole-line verbatim·strip 0·블록 한정·fail-closed**가 정답 ②guard-path-tie는 **표 구조 파싱**(prose 백틱 경로 오염 방지, F6) ③기존 동명 타겟(verify-runbooks=DR 러너)을 덮지 말 것(F2) ④SSOT 이동은 **모든 참조 동시 갱신+스테이징**(F7). 무손실이 이 테마의 정수(하드원 트랩 41 유실 금지).

## Execution directives
- **Skill:** implement via `executing-plans` in a **separate session, in this worktree** (`.claude/worktrees/feat+docs-ssot-refactor`).
- **Run continuously:** 라우틴 리뷰로 멈추지 말 것. 진짜 블로커에서만 정지. **순서: Task 1(traps-detail 이전)→2(AGENTS 인덱스)→3(참조 갱신)→4(README 단일화)→5(sync 가드)→6(런북 가드)→7(무손실 검증)**.
- **★무손실 최우선** — Task 1 이전은 **원본 불릿 verbatim**(재배치만, 내용 0 변경). Task 1 Step 4 / Task 7 Step 1의 **fail-closed 무손실 체크가 MISSING 0**일 때만 진행. MISSING이면 정지·재이전(rewrap/요약 금지).
- **라이브 무관**(순수 문서/가드, ArgoCD 미싱크). AGENTS.md는 `@AGENTS.md`로 매 세션 로드 — 인덱스 발견성 유지.
- **Commits — 직접 적용; `Skill(commit)` 미사용**:
  - **한국어**·**AI 마커 금지**. Format `<type>(<scope>): 한국어 설명`. Type만 `feat`/`fix`/`refactor`/`docs`/`style`/`test`/`chore`. (이전/참조갱신=`docs:`, 가드=`test:`/`feat:`.) Task별 자체 커밋.
  - **Where:** 현재 feature 워크트리(`worktree-feat+docs-ssot-refactor`) 직접 커밋.
- **Push/PR:** owner 판단. 라이브 무관이라 머지 리스크 낮음. PR 전 무손실(MISSING 0)·stale 포인터 0·git clean 확인.
