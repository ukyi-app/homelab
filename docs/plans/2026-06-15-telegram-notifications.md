# 텔레그램 알림 한국어화·일관성 통일 (v1) Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 세 transport(Alertmanager · restore-drill CronJob · GitHub Actions)에서 나가는 모든 텔레그램 메시지를 기본 한국어 + 구조 일관 포맷으로 통일하고, 회귀 게이트로 고정한다 — 채널/인프라 마이그레이션 없이.

**Architecture:** 단일 메시지 계약(HTML, 고정 필드 순서) + 한국어 상태 lexicon을, 런타임에 맞는 3개 렌더러(Alertmanager Go-template / restore-drill POSIX·bash 셸 / GitHub Actions composite action)가 **독립 렌더**하고 구조 불변식 bats가 정합을 보증한다. Alertmanager는 **v0.27 유지**, 기존 1:1 DM `chat_id` 유지 — **시크릿 스토어 0 변경**. 알림기 자기 관측(scrape + 전송실패 알림)을 추가한다.

**Tech Stack:** GitHub Actions composite action (POSIX sh), Alertmanager v0.27 Go template, vmalert 규칙(VictoriaMetrics), bats, amtool, kustomize + KSOPS, SOPS.

---

## 공유 계약 · Lexicon (SSOT — 세 렌더러가 동일 준수)

> 정직한 SSOT 명명: **"1 계약 명세 + 3 준수 렌더러, CI 게이트"**. 코드는 공유 불가(런타임 상이)하나
> 구조 불변식을 bats가 3곳 모두 단언한다.

**메시지 계약** (`parse_mode=HTML`, 고정 필드 순서, 줄은 `\n` 결합):
```
{글리프} <b>{한국어 제목}</b> — {한국어 상태}
{한국어 발신처 라벨} · {핵심 식별자}
{키}: {값}                      (0개 이상 반복)
→ {액션 링크}                   (URL이 있을 때만)
```
- 동적 값은 **모두 HTML 이스케이프**(`&`→`&amp;` **먼저**, 그다음 `<`→`&lt;`, `>`→`&gt;`).
- 비신뢰 `client_payload`(bump dispatch)는 **env 경유 + 정규식 검증**(AGENTS.md 함정 — 인라인 보간 금지).
- lint은 **구조**만 강제(parse_mode=HTML 존재 / 글리프 ∈ 허용집합 / 한국어 제목 비-ASCII / 링크 존재), 정확한 카피는 강제하지 않는다.

**한국어 상태 lexicon** (글리프와 단어를 함께):

| 원천 상태(대소문자 무시) | 한국어 | 글리프 |
|---|---|---|
| `success` / `PASS` | 성공 | ✅ |
| `failure` / `FAIL` / `FIRING`(critical) | 실패 / 발생 | 🔴 |
| `FIRING`(warning) / drift | 경고 | ⚠️ |
| `RESOLVED` | 해소 | 🔵 |
| `cancelled` | 취소 | ⚪ |
| `skipped` | 건너뜀 | ⚪ |

**발신처 라벨(한국어, enum):** 알림 · 복원드릴 · 앱생성 · DB생성 · 캐시생성 · 시크릿갱신 · 해체 · 배포 · 온보딩 · IaC · IaC수렴 · 감사 · 이미지폴링 · 변이. 긴급도는 선두 글리프로 구분.

**선택적 KST 타임스탬프:** 셸 렌더러(composite action · drill)에서 `TZ=Asia/Seoul date "+%m/%d %H:%M"`. AM 템플릿은 생략(v0.27 유지).

**레포 컨벤션(필수):** bats `@test` 이름 영어 · 중간 단언은 `[ ]`(단순 명령, `[[ ]]`는 bash 3.2에서 침묵 통과) · `*.enc.yaml` 직접 수정 금지 · 커밋은 한국어 conventional(AI 마커 금지) · 게이트는 `tools/test/*.bats` + `make verify` · KSOPS 풀 렌더는 `kustomize build --enable-helm --enable-alpha-plugins --enable-exec` · composite action 선례 = `.github/actions/homelab-token`.

---

## 실행 순서 · 교차검증 필수 수정 (실행 전 숙지)

**컴포넌트 실행 순서:** ① composite action + 13스텝 이행 → ② Alertmanager 템플릿 재작성 + 자기관측 → ③ 규칙 한국어화 + Korean 게이트 → ④ restore-drill notify() → ⑤ 정리 + 최종 검증.

**다관점 교차검증이 잡은 결함 — 아래 수정이 각 Task 본문에 반영되어 있다(중복 명시):**

1. **[BLOCKER] dispatch-mutation `notify-failure` 잡은 checkout이 없다.** 이 잡(`.github/workflows/dispatch-mutation.yml:141~`)은 `validate` 잡과 분리돼 있어 `actions/checkout`이 없다. 로컬 composite action `uses: ./.github/actions/telegram-notify`는 레포 체크아웃이 필요 → **해당 잡에 `- uses: actions/checkout@<pinned-sha>`를 선행 스텝으로 추가**해야 한다(나머지 11스텝은 이미 checkout 있는 잡에서 실행 — 검증됨).
2. **[PATH] KSOPS/kustomize 렌더 타깃은 `platform/victoria-stack`(base)이다.** `platform/victoria-stack/prod/`엔 `kustomization.yaml`이 없고 `alerting.enc.yaml`만 있다(ArgoCD app `path: platform/victoria-stack`). 규칙 섹션 Task와 AM Task 5의 렌더 경로를 **base로 고정**.
3. **[MECHANISM] vmagent scrape에는 `prometheus.io/port: "9093"`가 필요하다.** `prometheus.io/scrape: "true"`만으론 부족 — `vmagent-scrape-config.yaml`의 relabel이 port 애너테이션을 읽는다. AM Deployment 파드 템플릿에 **scrape + port(+path) 애너테이션 모두** 추가.
4. **[SEQUENCING] `core.yaml`은 ②(AM)와 ③(규칙)이 함께 편집한다.** ②가 `AlertmanagerTelegramFailing` 알림을 append하고 ③이 모든 annotation의 한국어를 단언하므로, **②가 append하는 알림의 summary/description도 한국어여야** ③의 게이트가 통과한다(편집은 비중첩: 기존 annotation 한국어화 vs 신규 알림 append).
5. **[MINOR] 규칙 섹션의 "r4 6개 알림"은 7개다**(BulkSSDFilling/BulkSSDAlmostFull/StandardSSDFilling/LocalBasebackupStale/R2BackupStale/WALArchiveStalled/CNPGRestoreDrillStale).
6. **[VERIFY] 호출처는 13개다**(`bump.yaml`이 2개 — writeback + dispatch; 실측 `grep -rc "api.telegram.org/bot.*sendMessage" .github/workflows` = 13). secret 참조 카운트는 **13 × 2 = 26줄**. Task 9는 파일별 기대수를 **열거**해 단언하고(추가/삭제 시 유용한 diff), Task 10 grep 기대값은 **26**.

---

## telegram-notify composite action + 13-step migration

> Scope: this section delivers ONE composite action, ONE bats test, and migrates the **13 GitHub Actions notify steps** (bump.yaml has 2 — writeback + dispatch) to it. The restore-drill script, the Alertmanager ConfigMap, and the VM rules are handled in their own sections — they render Korean/glyph in-pod and do **not** call this action (composite actions only run on GH runners).

### Contract recap (pin exactly)

Message body (parse_mode=HTML, fixed field order; lines joined with `\n`):

```
{glyph} <b>{Korean title}</b> — {Korean status}
{Korean source label} · {key identifier}
{key}: {value}          (0+ repeated, from KV input)
→ {action link}         (only when a URL is present)
```

Status → (Korean word, glyph) lexicon — glyph travels WITH the word:

| status input (case-insensitive) | Korean | glyph |
|---|---|---|
| `success` / `PASS` | 성공 | ✅ |
| `failure` / `FAIL` / `FIRING-critical` | 실패 (or 발생 for FIRING) | 🔴 |
| `FIRING-warning` / `drift` | 경고 | ⚠️ |
| `RESOLVED` | 해소 | 🔵 |
| `cancelled` | 취소 | ⚪ |
| `skipped` | 건너뜀 | ⚪ |

Source labels (enum): `알림 복원드릴 앱생성 DB생성 캐시생성 시크릿갱신 해체 배포 온보딩 IaC IaC수렴 감사 이미지폴링 변이`.

Behavior: HTML-escape ALL dynamic values (`<`→`&lt;`, `>`→`&gt;`, `&`→`&amp;`; do `&` first); POSIX-only (sed/tr/printf, no bash-isms); best-effort send (capture curl output, on non-2xx emit `::warning::` + a `$GITHUB_STEP_SUMMARY` line, then `exit 0`); enum-validate `status` and `source`; optional KST stamp via `TZ=Asia/Seoul date "+%m/%d %H:%M"`; cap assembled text at 4096 chars, truncating with `…(생략 N건)`.

---

### Task 1 — failing structural+behavioral test for the action script

The action’s logic lives in a sibling script `notify.sh` (POSIX `sh`) so it is unit-testable without a runner. The test drives it in `DRY_RUN=1` mode where it prints the assembled `text=` payload to stdout instead of curling.

**Files**
- create `/Users/ukyi/workspace/homelab/tools/test/telegram-notify.bats`

**Step 1.1 — write the failing test**

```bash
#!/usr/bin/env bats
# telegram-notify composite action — message contract + escaping + lexicon + cap.
# ⚠️ bash 3.2: mid-test assertions use [ ] only ([[ ]] failures pass silently).
# The action's logic is in notify.sh; DRY_RUN=1 prints the assembled payload instead of curling.

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  ACT="$ROOT/.github/actions/telegram-notify/action.yml"
  SH="$ROOT/.github/actions/telegram-notify/notify.sh"
  TMP="$(mktemp -d)"
  export DRY_RUN=1
  export TG_TOKEN="x:y" TG_CHAT="123"
  export GITHUB_STEP_SUMMARY="$TMP/summary"
}
teardown() { rm -rf "$TMP"; }

@test "action.yml is a composite that runs notify.sh and declares contract inputs" {
  run grep -E "using: composite" "$ACT"; [ "$status" -eq 0 ]
  run grep -E "notify\.sh" "$ACT"; [ "$status" -eq 0 ]
  run grep -E "^[[:space:]]+status:" "$ACT"; [ "$status" -eq 0 ]
  run grep -E "^[[:space:]]+source:" "$ACT"; [ "$status" -eq 0 ]
  run grep -E "^[[:space:]]+title:" "$ACT"; [ "$status" -eq 0 ]
  run grep -E "^[[:space:]]+link:" "$ACT"; [ "$status" -eq 0 ]
  run grep -E "^[[:space:]]+bot-token:" "$ACT"; [ "$status" -eq 0 ]
  run grep -E "^[[:space:]]+chat-id:" "$ACT"; [ "$status" -eq 0 ]
}

@test "notify.sh is POSIX sh (no bash-isms)" {
  run head -1 "$SH"; [ "$status" -eq 0 ]
  run grep -E "^#!/usr/bin/env sh|^#!/bin/sh" "$SH"; [ "$status" -eq 0 ]
  run grep -nE '\[\[|\$\{[A-Za-z_]+\^\^|\$\{[A-Za-z_]+//' "$SH"; [ "$status" -ne 0 ]
}

@test "assembled message has parse_mode=HTML, the glyph, bold korean title, korean status" {
  run env STATUS=success SOURCE=배포 TITLE="이미지 갱신" sh "$SH"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "parse_mode=HTML"; [ "$?" -eq 0 ]
  echo "$output" | grep -q "✅"; [ "$?" -eq 0 ]
  echo "$output" | grep -q "<b>이미지 갱신</b>"; [ "$?" -eq 0 ]
  echo "$output" | grep -q "성공"; [ "$?" -eq 0 ]
  echo "$output" | grep -q "배포"; [ "$?" -eq 0 ]
}

@test "failure status maps to 실패 with red glyph" {
  run env STATUS=failure SOURCE=IaC TITLE="cloudflare apply" sh "$SH"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "🔴"; [ "$?" -eq 0 ]
  echo "$output" | grep -q "실패"; [ "$?" -eq 0 ]
}

@test "drift status maps to 경고 with warning glyph" {
  run env STATUS=drift SOURCE=IaC수렴 TITLE="tf-reconcile" sh "$SH"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "⚠️"; [ "$?" -eq 0 ]
  echo "$output" | grep -q "경고"; [ "$?" -eq 0 ]
}

@test "HTML-escapes <, >, and & in dynamic values" {
  run env STATUS=success SOURCE=감사 TITLE="audit" IDENT="a<b>&c" sh "$SH"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "a&lt;b&gt;&amp;c"; [ "$?" -eq 0 ]
  echo "$output" | grep -q "a<b>&c"; [ "$?" -ne 0 ]   # raw must NOT survive
}

@test "ampersand is escaped before angle brackets (no double-escape of entities)" {
  run env STATUS=success SOURCE=감사 TITLE="audit" IDENT="x & y" sh "$SH"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "x &amp; y"; [ "$?" -eq 0 ]
  echo "$output" | grep -q "&amp;lt;"; [ "$?" -ne 0 ] # no entity got re-escaped
}

@test "teardown label fix: only the non-empty subject is shown (app set, resource empty)" {
  run env STATUS=success SOURCE=해체 TITLE="teardown" APP="orders" RESOURCE="" \
    IDENT_FROM_APP_OR_RESOURCE=1 sh "$SH"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "orders"; [ "$?" -eq 0 ]
  # the old concat bug glued them; with resource empty the output must not be "orders" + trailing junk
  echo "$output" | grep -qE "orders[^ <]"; [ "$?" -ne 0 ]
}

@test "teardown label fix: resource set, app empty -> shows resource only" {
  run env STATUS=success SOURCE=해체 TITLE="teardown" APP="" RESOURCE="db-foo" \
    IDENT_FROM_APP_OR_RESOURCE=1 sh "$SH"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "db-foo"; [ "$?" -eq 0 ]
}

@test "includes the action link arrow when a url is present" {
  run env STATUS=failure SOURCE=변이 TITLE="mutation" \
    LINK="https://github.com/ukyi/homelab/actions/runs/1" sh "$SH"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "→ https://github.com/ukyi/homelab/actions/runs/1"; [ "$?" -eq 0 ]
}

@test "omits the arrow line when no url" {
  run env STATUS=success SOURCE=배포 TITLE="x" sh "$SH"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "→ "; [ "$?" -ne 0 ]
}

@test "HTML-escapes the link too (query-string & and angle brackets)" {
  run env STATUS=failure SOURCE=변이 TITLE="mutation" \
    LINK="https://x.test/run?a=1&b=2&t=<x>" sh "$SH"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "→ https://x.test/run?a=1&amp;b=2&amp;t=&lt;x&gt;"; [ "$?" -eq 0 ]
  echo "$output" | grep -q "a=1&b=2"; [ "$?" -ne 0 ]   # raw & must NOT survive
}

@test "rejects an unknown status enum" {
  run env STATUS=bogus SOURCE=배포 TITLE="x" sh "$SH"
  [ "$status" -ne 0 ]
}

@test "rejects an unknown source label" {
  run env STATUS=success SOURCE=NotAKoreanLabel TITLE="x" sh "$SH"
  [ "$status" -ne 0 ]
}

@test "optional KST stamp is appended when STAMP=1 (mm/dd hh:mm shape)" {
  run env STATUS=success SOURCE=배포 TITLE="x" STAMP=1 sh "$SH"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qE "[0-1][0-9]/[0-3][0-9] [0-2][0-9]:[0-5][0-9]"; [ "$?" -eq 0 ]
}

@test "caps oversized body at <=4096 chars and appends 생략 marker" {
  big="$(head -c 9000 /dev/zero | tr '\0' 'a')"
  run env STATUS=success SOURCE=감사 TITLE="audit" BODY="$big" sh "$SH"
  [ "$status" -eq 0 ]
  # extract the text= field length is hard in pure sh; assert the marker present and total under cap
  echo "$output" | grep -q "…(생략"; [ "$?" -eq 0 ]
  len="$(printf '%s' "$output" | wc -c | tr -d ' ')"
  [ "$len" -le 4200 ]   # payload incl. chat_id/parse_mode wrapper, body itself <=4096
}

@test "best-effort: non-2xx send logs a warning and still exits 0 (no DRY_RUN)" {
  # point the API at an unroutable host so curl returns non-2xx/empty, action must not fail
  run env -u DRY_RUN STATUS=success SOURCE=배포 TITLE="x" \
    TG_API_BASE="http://127.0.0.1:1/bot" sh "$SH"
  [ "$status" -eq 0 ]
  run cat "$GITHUB_STEP_SUMMARY"
  echo "$output" | grep -qi "telegram"; [ "$?" -eq 0 ]
}
```

**Step 1.2 — run, expect fail**

```bash
bats /Users/ukyi/workspace/homelab/tools/test/telegram-notify.bats
# expect: file-not-found on action.yml/notify.sh -> all tests fail
```

---

### Task 2 — create the composite action + POSIX script (make Task 1 pass)

**Files**
- create `/Users/ukyi/workspace/homelab/.github/actions/telegram-notify/action.yml`
- create `/Users/ukyi/workspace/homelab/.github/actions/telegram-notify/notify.sh`

**Step 2.1 — `action.yml`** (mirror `homelab-token` shape: inline-map inputs, Korean comment header)

```yaml
# telegram-notify composite action — 운영 알림 공통 송신기.
# 메시지 계약(parse_mode=HTML, 고정 필드 순서) + 한국어 상태 어휘(글리프 동반) + HTML 이스케이프 +
# best-effort(비2xx도 step 실패 없이 ::warning:: + STEP_SUMMARY, exit 0) + 4096자 캡.
# ⚠️ client_payload 등 비신뢰 입력은 env로만 전달 — `with:` 텍스트에 ${{ }} 인라인 보간 금지(AGENTS.md).
# 로직은 notify.sh(POSIX sh)에 있다 — bats로 DRY_RUN 단위 검증한다.
name: telegram-notify
description: 운영 Telegram 알림(메시지 계약·HTML 이스케이프·best-effort)
inputs:
  status:      { description: "success|failure|cancelled|skipped|PASS|FAIL|FIRING-critical|FIRING-warning|RESOLVED|drift", required: true }
  source:      { description: "한국어 소스 라벨(알림/배포/해체/감사/…)", required: true }
  title:       { description: "한국어 제목(<b> 안에 들어감)", required: true }
  ident:       { description: "핵심 식별자(소스 라벨 뒤 · 식별자)", required: false, default: "" }
  body:        { description: "추가 본문(key: value 여러 줄 가능). 동적값은 이스케이프됨", required: false, default: "" }
  link:        { description: "액션 링크 URL(run/PR/runbook). 있으면 → 줄 추가", required: false, default: "" }
  stamp:       { description: "1이면 KST 타임스탬프 추가", required: false, default: "" }
  bot-token:   { description: "Telegram bot token (secrets.TELEGRAM_BOT_TOKEN)", required: true }
  chat-id:     { description: "Telegram chat id (secrets.TELEGRAM_CHAT_ID)", required: true }
runs:
  using: composite
  steps:
    - shell: sh
      env:
        STATUS:  ${{ inputs.status }}
        SOURCE:  ${{ inputs.source }}
        TITLE:   ${{ inputs.title }}
        IDENT:   ${{ inputs.ident }}
        BODY:    ${{ inputs.body }}
        LINK:    ${{ inputs.link }}
        STAMP:   ${{ inputs.stamp }}
        TG_TOKEN: ${{ inputs.bot-token }}
        TG_CHAT:  ${{ inputs.chat-id }}
      run: sh "$GITHUB_ACTION_PATH/notify.sh"
```

**Step 2.2 — `notify.sh`** (POSIX; escape via sed; enum via case; cap via awk char count)

```sh
#!/usr/bin/env sh
# 메시지 계약을 조립해 Telegram으로 best-effort 송신한다. DRY_RUN=1이면 text 페이로드를 stdout으로.
# POSIX 전용(bash-ism 금지) — sed/tr/printf만. ⚠️ '&'를 가장 먼저 이스케이프(엔티티 이중 이스케이프 방지).
set -eu

esc() { # HTML 이스케이프 — & 먼저
  printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'
}

# 상태 어휘 (글리프 + 한국어). 입력은 대소문자 무시.
s="$(printf '%s' "${STATUS:-}" | tr 'A-Z' 'a-z')"
case "$s" in
  success|pass)            GLYPH="✅"; WORD="성공" ;;
  failure|fail)            GLYPH="🔴"; WORD="실패" ;;
  firing-critical)         GLYPH="🔴"; WORD="발생" ;;
  firing-warning|drift)    GLYPH="⚠️"; WORD="경고" ;;
  resolved)                GLYPH="🔵"; WORD="해소" ;;
  cancelled)               GLYPH="⚪"; WORD="취소" ;;
  skipped)                 GLYPH="⚪"; WORD="건너뜀" ;;
  *) echo "telegram-notify: unknown status '${STATUS:-}'" >&2; exit 2 ;;
esac

# 소스 라벨 enum 검증
case " 알림 복원드릴 앱생성 DB생성 캐시생성 시크릿갱신 해체 배포 온보딩 IaC IaC수렴 감사 이미지폴링 변이 " in
  *" ${SOURCE:-} "*) : ;;
  *) echo "telegram-notify: unknown source '${SOURCE:-}'" >&2; exit 2 ;;
esac

# teardown 라벨 fix: app/resource 중 비어있지 않은 쪽만 ident로
if [ "${IDENT_FROM_APP_OR_RESOURCE:-}" = "1" ]; then
  if [ -n "${APP:-}" ]; then IDENT="$APP"; else IDENT="${RESOURCE:-}"; fi
fi

TITLE_E="$(esc "${TITLE:-}")"
IDENT_E="$(esc "${IDENT:-}")"
BODY_E="$(esc "${BODY:-}")"
LINK_E="$(esc "${LINK:-}")"   # 링크도 escape — 계약상 "모든 동적 값"(교차검증 Pass2 Finding 4). 쿼리스트링의 &가 HTML parse를 깨지 않게.

# 본문 조립(고정 필드 순서). printf로 개행.
line1="$(printf '%s <b>%s</b> — %s' "$GLYPH" "$TITLE_E" "$WORD")"
if [ -n "${IDENT_E}" ]; then line2="$(printf '%s · %s' "$SOURCE" "$IDENT_E")"; else line2="$SOURCE"; fi
text="$line1
$line2"
[ -n "$BODY_E" ] && text="$text
$BODY_E"
[ -n "${LINK_E:-}" ] && text="$text
→ ${LINK_E}"
[ "${STAMP:-}" = "1" ] && text="$text
$(TZ=Asia/Seoul date '+%m/%d %H:%M')"

# 4096자 캡 (문자 수, 멀티바이트 안전하게 awk로). 초과 시 잘라내고 '…(생략 N건)'.
nchar="$(printf '%s' "$text" | awk '{ n += length($0) } END { print n + NR - 1 }')"
if [ "${nchar:-0}" -gt 4096 ]; then
  keep=4080
  trimmed="$(printf '%s' "$text" | awk -v k="$keep" '
    { for (i=1;i<=length($0);i++){ if (c>=k) exit; printf "%s", substr($0,i,1); c++ }
      if (c<k){ printf "\n"; c++ } }')"
  over=$(( nchar - keep ))
  text="$trimmed
…(생략 ${over}건)"
fi

if [ "${DRY_RUN:-}" = "1" ]; then
  printf 'parse_mode=HTML\nchat_id=%s\ntext=%s\n' "${TG_CHAT:-}" "$text"
  exit 0
fi

# best-effort 송신 — 비2xx도 step 실패시키지 않는다.
api="${TG_API_BASE:-https://api.telegram.org/bot}"
code="$(curl -sS -o /tmp/tg-resp -w '%{http_code}' -X POST "${api}${TG_TOKEN}/sendMessage" \
  --data-urlencode "chat_id=${TG_CHAT}" \
  --data-urlencode "parse_mode=HTML" \
  --data-urlencode "text=${text}" 2>/tmp/tg-err || echo 000)"
case "$code" in
  2*) : ;;
  *)
    msg="telegram-notify: send failed (http=${code}) src=${SOURCE} status=${STATUS}"
    echo "::warning::${msg}"
    [ -n "${GITHUB_STEP_SUMMARY:-}" ] && printf '%s\n' "$msg" >> "$GITHUB_STEP_SUMMARY"
    ;;
esac
exit 0
```

**Step 2.3 — run, expect pass**

```bash
chmod +x /Users/ukyi/workspace/homelab/.github/actions/telegram-notify/notify.sh
bats /Users/ukyi/workspace/homelab/tools/test/telegram-notify.bats
# expect: all green. If the cap test fails, tune `keep`; if KST test fails, ensure TZ is honored on the runner (it is on ubuntu).
```

**Step 2.4 — commit**

```bash
git add .github/actions/telegram-notify/ tools/test/telegram-notify.bats
git commit -m "feat: telegram-notify 공통 액션 추가(메시지 계약·HTML 이스케이프·best-effort·4096 캡)"
```

---

### Task 3 — migrate `_create-app` (representative `always()` step)

**Files**
- edit `/Users/ukyi/workspace/homelab/.github/workflows/_create-app.yml` (lines 125-135)

**Before**

```yaml
      - name: telegram notify
        if: always()
        env:
          TG_TOKEN: ${{ secrets.TELEGRAM_BOT_TOKEN }}
          TG_CHAT: ${{ secrets.TELEGRAM_CHAT_ID }}
          APP_REPO: ${{ inputs.app_repo }}
          STATUS: ${{ job.status }}
        run: |
          curl -fsS -X POST "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" \
            -d chat_id="${TG_CHAT}" \
            -d text="create-app ${STATUS}: ${APP_REPO} — PR을 확인하세요"
```

**After**

```yaml
      - name: telegram notify
        if: always()
        uses: ./.github/actions/telegram-notify
        with:
          status: ${{ job.status }}
          source: 앱생성
          title: 앱 생성
          ident: ${{ inputs.app_repo }}
          body: "PR을 확인하세요"
          link: ${{ github.server_url }}/${{ github.repository }}/actions/runs/${{ github.run_id }}
          bot-token: ${{ secrets.TELEGRAM_BOT_TOKEN }}
          chat-id: ${{ secrets.TELEGRAM_CHAT_ID }}
```

**Run / commit**

```bash
bats /Users/ukyi/workspace/homelab/tools/test/workflow-yaml.bats   # parses clean
git add .github/workflows/_create-app.yml
git commit -m "refactor: _create-app 알림을 telegram-notify 액션으로 이관"
```

---

### Task 4 — migrate `_teardown` (the bug fix)

The old body concatenates `${APP}${RESOURCE}` — only one is ever set (teardown-app vs teardown-resource), so the label silently shows the wrong/empty subject. The action’s `IDENT_FROM_APP_OR_RESOURCE` picks the non-empty one.

**Files**
- edit `/Users/ukyi/workspace/homelab/.github/workflows/_teardown.yml` (lines 73-84)

**Before**

```yaml
      - name: telegram notify
        if: always()
        env:
          TG_TOKEN: ${{ secrets.TELEGRAM_BOT_TOKEN }}
          TG_CHAT: ${{ secrets.TELEGRAM_CHAT_ID }}
          APP: ${{ inputs.app }}
          RESOURCE: ${{ inputs.resource }}
          STATUS: ${{ job.status }}
        run: |
          curl -fsS -X POST "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" \
            -d chat_id="${TG_CHAT}" \
            -d text="teardown ${STATUS}: ${APP}${RESOURCE} — PR을 확인하세요(머지=승인)"
```

**After** (pass APP/RESOURCE via env so the action resolves the non-empty subject; do not pre-concat)

```yaml
      - name: telegram notify
        if: always()
        uses: ./.github/actions/telegram-notify
        env:
          APP: ${{ inputs.app }}
          RESOURCE: ${{ inputs.resource }}
          IDENT_FROM_APP_OR_RESOURCE: "1"
        with:
          status: ${{ job.status }}
          source: 해체
          title: 해체
          body: "PR을 확인하세요(머지=승인)"
          link: ${{ github.server_url }}/${{ github.repository }}/actions/runs/${{ github.run_id }}
          bot-token: ${{ secrets.TELEGRAM_BOT_TOKEN }}
          chat-id: ${{ secrets.TELEGRAM_CHAT_ID }}
```

> Note: `env:` set on a `uses:` step is exported into the composite action’s steps, so `notify.sh` reads `$APP`/`$RESOURCE`/`$IDENT_FROM_APP_OR_RESOURCE`. The teardown-label test (Task 1) already locks this behavior.

**Run / commit**

```bash
bats /Users/ukyi/workspace/homelab/tools/test/workflow-yaml.bats
git add .github/workflows/_teardown.yml
git commit -m "fix: teardown 알림 라벨 — app/resource 빈쪽 연결 버그 수정(액션 이관)"
```

---

### Task 5 — migrate `_audit` (the length cap)

The audit step is the only one with a multi-line `jq` summary that can blow past 4096. Move the summary into `body:` and let the action cap it with `…(생략 N건)`.

**Files**
- edit `/Users/ukyi/workspace/homelab/.github/workflows/_audit.yml` (lines 23-35)

**Before**

```yaml
      - name: telegram report
        if: always()
        env:
          TG_TOKEN: ${{ secrets.TELEGRAM_BOT_TOKEN }}
          TG_CHAT: ${{ secrets.TELEGRAM_CHAT_ID }}
          COUNT: ${{ steps.audit.outputs.count }}
          STATUS: ${{ job.status }}
        run: |
          summary=$(jq -r '.findings[:5][] | "- \(.type): \(.subject)"' /tmp/audit.json 2>/dev/null || true)
          curl -fsS -X POST "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" \
            -d chat_id="${TG_CHAT}" \
            --data-urlencode text="audit ${STATUS}: 드리프트 ${COUNT}건
          ${summary}"
```

**After** (compute body in a prior shell step → output → feed to action; the action escapes + caps)

```yaml
      - name: build audit summary
        id: report
        if: always()
        run: |
          summary="$(jq -r '.findings[:20][] | "- \(.type): \(.subject)"' /tmp/audit.json 2>/dev/null || true)"
          {
            echo "body<<EOF"
            printf '드리프트 건수: %s\n%s\n' "${{ steps.audit.outputs.count }}" "$summary"
            echo "EOF"
          } >> "$GITHUB_OUTPUT"
      - name: telegram report
        if: always()
        uses: ./.github/actions/telegram-notify
        with:
          status: ${{ job.status }}
          source: 감사
          title: 드리프트 감사
          ident: ${{ steps.audit.outputs.count }}건
          body: ${{ steps.report.outputs.body }}
          link: ${{ github.server_url }}/${{ github.repository }}/actions/runs/${{ github.run_id }}
          bot-token: ${{ secrets.TELEGRAM_BOT_TOKEN }}
          chat-id: ${{ secrets.TELEGRAM_CHAT_ID }}
```

**Run / commit**

```bash
bats /Users/ukyi/workspace/homelab/tools/test/workflow-yaml.bats
git add .github/workflows/_audit.yml
git commit -m "refactor: _audit 알림을 telegram-notify로 이관(요약 4096 캡)"
```

---

### Task 6 — migrate `bump.yaml` dispatch step (UNTRUSTED client_payload)

`client_payload.app` / `client_payload.tag` are attacker-controlled. They must reach the action via **env** (not inline `with:` `${{ }}` text) and be validated by regex before use. The action HTML-escapes them at runtime regardless.

**Files**
- edit `/Users/ukyi/workspace/homelab/.github/workflows/bump.yaml` (lines 188-199)

**Before**

```yaml
      - name: telegram notify
        if: always()
        env:
          TG_TOKEN: ${{ secrets.TELEGRAM_BOT_TOKEN }}
          TG_CHAT: ${{ secrets.TELEGRAM_CHAT_ID }}
          APP: ${{ github.event.client_payload.app }}
          TAG: ${{ github.event.client_payload.tag }}
          STATUS: ${{ job.status }}
        run: |
          curl -fsS -X POST "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" \
            -d chat_id="${TG_CHAT}" \
            -d text="deploy write-back ${STATUS}: ${APP} -> ${TAG} (dispatch)"
```

**After** (sanitize in a shell step → emit safe outputs → action consumes them)

```yaml
      - name: sanitize dispatch payload
        id: safe
        if: always()
        env:
          APP: ${{ github.event.client_payload.app }}   # 비신뢰 — env 경유, 인라인 보간 금지
          TAG: ${{ github.event.client_payload.tag }}
        run: |
          # regex 검증 — 통과 못하면 placeholder로 대체(알림은 best-effort)
          case "$APP" in (*[!a-z0-9-]*|"") APP="(invalid)";; esac
          case "$TAG" in (*[!A-Za-z0-9._-]*|"") TAG="(invalid)";; esac
          echo "ident=${APP} -> ${TAG} (dispatch)" >> "$GITHUB_OUTPUT"
      - name: telegram notify
        if: always()
        uses: ./.github/actions/telegram-notify
        with:
          status: ${{ job.status }}
          source: 배포
          title: 이미지 태그 갱신
          ident: ${{ steps.safe.outputs.ident }}
          link: ${{ github.server_url }}/${{ github.repository }}/actions/runs/${{ github.run_id }}
          bot-token: ${{ secrets.TELEGRAM_BOT_TOKEN }}
          chat-id: ${{ secrets.TELEGRAM_CHAT_ID }}
```

> The `case` globs are POSIX; `[!a-z0-9-]` rejects anything outside the app-name charset. Even if the regex were loosened, `notify.sh`’s `esc()` neutralizes `<`/`>`/`&`. Defense in depth, per the AGENTS.md `client_payload` trap.

**Run / commit**

```bash
bats /Users/ukyi/workspace/homelab/tools/test/workflow-yaml.bats
git add .github/workflows/bump.yaml
git commit -m "refactor: bump dispatch 알림 이관 — 비신뢰 client_payload env+regex 정제"
```

---

### Task 7 — migrate `tf-reconcile` (failure-or-drift, drift glyph)

**Files**
- edit `/Users/ukyi/workspace/homelab/.github/workflows/tf-reconcile.yml` (lines 81-91)

**Before**

```yaml
      - name: telegram notify (드리프트 수렴 또는 실패 시에만)
        if: failure() || steps.drift.outputs.drift == 'true'
        env:
          TG_TOKEN: ${{ secrets.TELEGRAM_BOT_TOKEN }}
          TG_CHAT: ${{ secrets.TELEGRAM_CHAT_ID }}
          STATUS: ${{ job.status }}
          DRIFT: ${{ steps.drift.outputs.drift }}
        run: |
          curl -fsS -X POST "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" \
            -d chat_id="${TG_CHAT}" \
            -d text="tf-reconcile ${STATUS}: drift=${DRIFT}"
```

**After** (map drift→`drift` status so the ⚠️/경고 glyph fires even when job.status is success-after-converge)

```yaml
      - name: telegram notify (드리프트 수렴 또는 실패 시에만)
        if: failure() || steps.drift.outputs.drift == 'true'
        uses: ./.github/actions/telegram-notify
        with:
          status: ${{ job.status == 'success' && steps.drift.outputs.drift == 'true' && 'drift' || job.status }}
          source: IaC수렴
          title: IaC 수렴
          ident: "drift=${{ steps.drift.outputs.drift }}"
          link: ${{ github.server_url }}/${{ github.repository }}/actions/runs/${{ github.run_id }}
          bot-token: ${{ secrets.TELEGRAM_BOT_TOKEN }}
          chat-id: ${{ secrets.TELEGRAM_CHAT_ID }}
```

**Run / commit**

```bash
bats /Users/ukyi/workspace/homelab/tools/test/workflow-yaml.bats
git add .github/workflows/tf-reconcile.yml
git commit -m "refactor: tf-reconcile 알림 이관 — 드리프트 수렴은 경고 글리프로"
```

---

### Task 8 — migrate the remaining 8 steps (one commit per file, same pattern)

Each is the identical edit shape as Tasks 3-7: drop `TG_TOKEN/TG_CHAT/curl`, add `uses: ./.github/actions/telegram-notify` with the mapped `with:`. Preserve each step’s existing `if:` and `name:`. Use this mapping table:

| Workflow (lines) | `if:` | `source` | `title` | `status` | `ident` / `body` |
|---|---|---|---|---|---|
| `_create-database.yml` (91-101) | `always()` | `DB생성` | `DB 생성` | `${{ job.status }}` | ident `db=${{ steps.spec.outputs.name }}`; body `핸들 db-<name>-conn / db-<name>-ro-conn (prod)` |
| `_create-cache.yml` (93-103) | `always()` | `캐시생성` | `캐시 생성` | `${{ job.status }}` | ident `${{ steps.spec.outputs.name }}`; body `conn 핸들 cache-<name>-conn (prod)` |
| `_update-secrets.yml` (89-99) | `always()` | `시크릿갱신` | `시크릿 회전` | `${{ job.status }}` | ident `${{ steps.names.outputs.repo }}` |
| `onboard.yaml` (97-108) | `always()` | `온보딩` | `앱 온보딩` | `${{ job.status }}` | ident `${{ steps.scaffold.outputs.app \|\| 'unknown' }} (${{ steps.scaffold.outputs.host \|\| '-' }})`; body `PR을 확인하세요` |
| `iac.yaml` (79-89) | `always()` | `IaC` | `Cloudflare 적용` | `${{ job.status }}` | ident `${{ github.sha }}` |
| `bump.yaml` writeback (112-123) | `always()` | `배포` | `이미지 태그 갱신` | `${{ job.status }}` | ident `apps=[${{ steps.set.outputs.apps }}] -> sha-${{ github.event.workflow_run.head_sha }}` |
| `bump-poll.yml` (114-122) | `failure()` | `이미지폴링` | `이미지 폴링` | `failure` (or `${{ job.status }}`) | link only (already builds `RUN_URL`) |
| `dispatch-mutation.yml` (140-154) | `failure()` | `변이` | `변이 실행` | `failure` | ident `action=${{ github.event.inputs.action }}`; link `RUN_URL` |

For **every** step add `link: ${{ github.server_url }}/${{ github.repository }}/actions/runs/${{ github.run_id }}` (run URL) plus `bot-token`/`chat-id` from secrets. `dispatch-mutation.yml`’s `notify-failure` job step has **no `name:`** today — add `uses:` directly on that step (give it `name: telegram notify` for readability). Korean source labels are non-ASCII so the lint title/source check passes.

> **[BLOCKER — 교차검증]** `dispatch-mutation.yml`의 `notify-failure`는 `validate` 잡과 **분리된 잡**이라 `actions/checkout`이 없다. 로컬 composite action(`uses: ./.github/actions/telegram-notify`)은 레포가 체크아웃돼 있어야 하므로(없으면 `Can't find 'action.yml'` 에러), 이 잡의 `steps:` **맨 앞에 `- uses: actions/checkout@<pinned-sha>`를 추가**한다(레포 규약 = 풀 SHA 핀; 예 `actions/checkout`의 현 핀 SHA를 다른 워크플로에서 복사). 나머지 11스텝은 이미 checkout이 있는 잡에서 실행된다(검증됨: _create-app:43, _create-database:29, _create-cache:28, _update-secrets:42, _teardown:32, _audit:12, bump:47/139, bump-poll:60, onboard:37, iac:24/57, tf-reconcile:48).

> **[Pass3·Pass5 — lean] checkout/bootstrap 실패의 잔여 미통지(의도적 수용).** 로컬 action은 checkout 후에만 resolve되므로, checkout 스텝 자체 실패 또는 토큰 생성 등 checkout 이전 스텝 실패 시 composite notify가 못 나간다. **checkout을 steps[0]으로 강제하지 않는다** — mutation 워크플로(`_create-app`/`_create-database` 등)는 GitHub App 토큰을 checkout *이전*에 생성하므로(token-before-checkout) checkout-first 강제는 그 패턴과 충돌한다(교차검증 Pass5 Finding 2). 이 잔여(드문 SCM/bootstrap 실패)는 **GitHub 네이티브 워크플로 실패 알림(이메일/UI)**이 커버하므로 단일운영자 홈랩에서 수용한다. 인라인 curl fallback·bootstrap 2-checkout은 통합을 약화시키고 표면을 늘려(Pass4 시도 시 secret 물질화·체크아웃 충돌 등 신규 이슈 발생) **v1 범위 밖 → descope**. 정상 경로에선 위 BLOCKER 검증대로 모든 notify 잡에 checkout이 있어 액션이 resolve된다.

**Per-file run + commit** (repeat for each):

```bash
bats /Users/ukyi/workspace/homelab/tools/test/workflow-yaml.bats
git add .github/workflows/<file>
git commit -m "refactor: <file> 알림을 telegram-notify 액션으로 이관"
```

---

### Task 9 — call-site contract gate (yq bats) — 교차검증 Finding 3

Task 10 sweep은 raw curl 제거만 증명하고, 13개 호출처가 **올바른 입력**을 넘기는지는 보지 않는다. `tools/test/telegram-callsites.bats`가 모든 `uses: ./.github/actions/telegram-notify` 사이트를 열거해 계약(개수=13·필수 `with:` 키·링크·secret·`client_payload` 신뢰경계·raw curl 0)을 단언한다.

**Files:** Create `tools/test/telegram-callsites.bats`.

**Step 9.1 — failing test:**
```bash
#!/usr/bin/env bats
# 13개 호출처가 telegram-notify 계약을 지키는지 검사. ⚠️ 중간 단언은 [ ]만(bash 3.2 [[ ]] 침묵통과).
# ⚠️ declare -A 금지(bash 3.2 미지원) — 기대 목록은 here-doc로.
setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"; WF="$ROOT/.github/workflows"
  command -v yq >/dev/null || skip "yq required"
}

@test "exactly the 13 expected workflows notify via the action (enumerated, bump=2)" {
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
tf-reconcile.yml 1
dispatch-mutation.yml 1
EOF
  [ "$total" -eq 13 ]
  ! grep -rq "api.telegram.org" "$WF"   # raw curl 0 — 모든 인라인 curl이 액션으로 이행됨
}

@test "every call site passes required with: keys (status, source, title, bot-token, chat-id)" {
  for f in "$WF"/*.yml "$WF"/*.yaml; do
    [ -e "$f" ] || continue
    miss=$(yq -r '[.jobs[].steps[]? | select(.uses=="./.github/actions/telegram-notify")
      | (["status","source","title","bot-token","chat-id"] - ((.with // {}) | keys)) | .[]] | .[]' "$f" 2>/dev/null)
    [ -z "$miss" ] || { echo "MISSING in $f: $miss"; false; }
  done
}

@test "no call site interpolates client_payload directly into a with: value (trust boundary)" {
  # 비신뢰 client_payload는 env 기반 sanitize step만 거쳐야 — with:에 직접 보간 금지
  for f in "$WF"/*.yml "$WF"/*.yaml; do
    [ -e "$f" ] || continue
    hit=$(yq -r '.jobs[].steps[]? | select(.uses=="./.github/actions/telegram-notify") | (.with // {}) | to_entries[].value' "$f" 2>/dev/null | grep -c 'client_payload' || true)
    [ "${hit:-0}" -eq 0 ] || { echo "client_payload inline in $f"; false; }
  done
}

@test "failure-capable sites carry a link (run URL)" {
  for f in "$WF"/*.yml "$WF"/*.yaml; do
    [ -e "$f" ] || continue
    nolink=$(yq -r '[.jobs[].steps[]? | select(.uses=="./.github/actions/telegram-notify")
      | select((.with.link // "")=="")] | length' "$f" 2>/dev/null)
    [ "${nolink:-0}" -eq 0 ] || { echo "link missing in $f"; false; }
  done
}

@test "every call site title is Korean (Hangul present) — 목표: 한국어 기본 (Pass6 Finding 4)" {
  # source 라벨뿐 아니라 with.title 자체가 한국어여야(영어 제목 회귀 차단).
  for f in "$WF"/*.yml "$WF"/*.yaml; do
    [ -e "$f" ] || continue
    bad=$(yq -r '.jobs[].steps[]? | select(.uses=="./.github/actions/telegram-notify") | (.with.title // "")' "$f" 2>/dev/null \
      | grep -v '^$' | grep -vE '[가-힣]' || true)
    [ -z "$bad" ] || { echo "$f: 비-한국어 title: $bad"; false; }
  done
}
```

**Step 9.2 — make it pass:** Task 3-8 이행이 모든 사이트에 `status/source/title/link/bot-token/chat-id`를 설정하고 `client_payload`(bump dispatch)는 env 기반 sanitize step만 거치게 보장. green까지 반복.

**Step 9.3 — commit:**
```bash
git add tools/test/telegram-callsites.bats
git commit -m "test: telegram-notify 13개 호출처 계약 게이트(개수·with 키·링크·client_payload 경계)"
```

---

### Task 10 — final gate sweep

```bash
# 인라인 telegram curl이 전부 액션으로 이행됐는지 (lean: fallback 없음 → 0이어야)
grep -rn "api.telegram.org" /Users/ukyi/workspace/homelab/.github/workflows/ && echo "LEFTOVER — fix" || echo "clean"
# secret 참조는 13스텝 × (bot-token+chat-id) = 26줄
grep -rn "TELEGRAM_BOT_TOKEN\|TELEGRAM_CHAT_ID" /Users/ukyi/workspace/homelab/.github/workflows/ | wc -l   # expect 26
bats /Users/ukyi/workspace/homelab/tools/test/telegram-notify.bats \
     /Users/ukyi/workspace/homelab/tools/test/telegram-callsites.bats \
     /Users/ukyi/workspace/homelab/tools/test/workflow-yaml.bats
make verify
```

> Do NOT touch `infra/github/secrets.tf` (TF_VAR_telegram_bot_token / telegram_chat_id) — removing them breaks CI notification provisioning. The action keeps consuming `secrets.TELEGRAM_BOT_TOKEN` / `secrets.TELEGRAM_CHAT_ID`.


---

## Alertmanager template rewrite + notifier self-observability + amtool gate

TDD tasks. All edits stay **in place on `prom/alertmanager:v0.27.0`** — no v0.28 upgrade, no topics, no `message_thread_id`, no chat_id migration, **no new secrets**. Single `telegram` receiver, single `chat_id`, `send_resolved: true` preserved. The init `sed` that renders `__CHAT_ID__` stays exactly as-is; the message structure is built with **Go template funcs in the `message:` block**, NOT by the init sed.

> **자기관측 범위(lean — 승인 설계대로):** scrape 애너테이션 + `alertmanager_notifications_failed_total` 메트릭 + `AlertmanagerTelegramFailing` 알림(Telegram 배달) + Watchdog 경계 문서화. **Telegram 전면 장애 시 이 알림 자체도 미도달**하는 한계는 *의도적으로 수용*한다 — 그 경우는 TSDB 메트릭(Grafana)·GitHub 워크플로 실패 알림·pipeline용 off-node dead-man's-switch가 부분 커버하며, 완전 독립 비-Telegram 채널은 단일-운영자 홈랩에 과설계라 **v1 범위 밖**(교차검증 Pass4·Pass5에서 신설 시 secret 물질화·sticky /fail 등 새 표면을 낳음을 확인 → descope).

### Load-bearing facts verified against the pinned image (do not re-litigate)

1. **`amtool check-config` FAILS on the raw ConfigMap** because `chat_id: __CHAT_ID__` (a string placeholder) cannot unmarshal into Alertmanager's `int64` chat_id field:
   ```
   Checking '/cfg/alertmanager.yml'  FAILED: yaml: unmarshal errors:
     line 23: cannot unmarshal !!str `__CHAT_...` into int64
   ```
   The gate (Task 5) MUST first substitute a dummy numeric chat_id (mirroring the init sed) before invoking amtool. With `__CHAT_ID__` → `-1001234567890` it returns `SUCCESS`.

2. **`amtool check-config` does NOT compile/validate the inline `message:` Go template.** A deliberately broken func (`{{ .Status | brokenfunc }}`) still returns `SUCCESS`. Therefore amtool only guards YAML schema + receiver wiring; **the glyph/branch/structure correctness is guarded ONLY by the bats test in Task 5.** Both gates are required and they cover disjoint failure modes.

3. **Escaping func = `reReplaceAll` (Alertmanager-native regex replace).** sprig's `replace`/`html`/`htmlEscape` are NOT registered in Alertmanager's `text/template` FuncMap. `safeHtml` does the OPPOSITE (marks a string as already-safe, i.e. it does NOT escape) and must never wrap untrusted annotation values. Because `parse_mode: HTML` is set, any raw `&`, `<`, `>` in an annotation (e.g. an alert summary containing `up < 0.5` or `A & B`) will break Telegram's HTML parser and the send silently fails. **Every dynamic value MUST be piped through a `reReplaceAll` escaping chain** (`&`→`&amp;` FIRST, then `<`→`&lt;`, then `>`→`&gt;` — ampersand first or you double-escape the entities). This is the explicit escaping approach flagged by the spec.

---

### Task 1 — Failing structural test for the rewritten telegram message template

**Files:** create `tools/test/alertmanager-template.bats`

Write the test FIRST. It asserts the contract structure on the ConfigMap's `message:` block (extracted with yq) — glyph set, both status branches, Korean title source, escaping pipeline, and that `parse_mode: HTML` / single receiver / single chat_id / v0.27 image / `send_resolved: true` are all still present. bats `@test` names in **English**; mid-test assertions use `[ ]` (simple command), NOT `[[ ]]` (bash 3.2 silently passes failing `[[ ]]`).

```bash
#!/usr/bin/env bats
# Alertmanager telegram 메시지 contract 구조 게이트 (in-place v0.27).
# amtool(Task 5)은 message Go-template을 컴파일하지 않는다 — glyph/branch/escape 구조는
# 이 테스트만이 지킨다. v0.27 유지·단일 receiver·단일 chat_id·send_resolved 고정도 함께 검증.
# ⚠️ 중간 단언은 [ ]만 — bash 3.2에서 [[ ]] 실패는 침묵 통과(검증된 버그).

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  AM="$ROOT/platform/victoria-stack/alertmanager.yaml"
  MSG="$(yq '.data["alertmanager.yml"]' "$AM" \
        | yq '.receivers[] | select(.name == "telegram") | .telegram_configs[0].message')"
}

@test "image stays pinned to v0.27.0 (no v0.28 upgrade)" {
  run grep -c 'image: prom/alertmanager:v0.27.0' "$AM"
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
}

@test "exactly one telegram receiver and one chat_id placeholder remain" {
  recv="$(yq '.data["alertmanager.yml"]' "$AM" | yq '[.receivers[] | select(.name=="telegram")] | length')"
  [ "$recv" = "1" ]
  run grep -c 'chat_id: __CHAT_ID__' "$AM"
  [ "$output" = "1" ]
}

@test "telegram config keeps parse_mode HTML and send_resolved true" {
  echo "$MSG" >/dev/null   # MSG must be non-empty
  [ -n "$MSG" ]
  run yq '.data["alertmanager.yml"]' "$AM"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -q 'parse_mode: HTML'
  printf '%s' "$output" | grep -q 'send_resolved: true'
}

@test "message uses an allowed glyph from the lexicon" {
  # allowed: 🔴(발생/실패) 🔵(해소) ⚠️(경고) ✅(성공) ⚪(취소/건너뜀)
  run bash -c "printf '%s' \"$MSG\" | grep -Eo '🔴|🔵|⚠️|✅|⚪' | head -1"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
}

@test "message branches on .Status for firing and resolved" {
  printf '%s' "$MSG" | grep -q 'eq .Status "firing"'
  printf '%s' "$MSG" | grep -q '발생'
  printf '%s' "$MSG" | grep -q '해소'
}

@test "Korean bold title is sourced from CommonLabels.alertname" {
  printf '%s' "$MSG" | grep -q '<b>'
  printf '%s' "$MSG" | grep -q '.CommonLabels.alertname'
}

@test "every dynamic value is HTML-escaped via reReplaceAll (amp first)" {
  # 정규식 escape 체인이 정의돼 있고, safeHtml로 untrusted 값을 감싸지 않는다.
  printf '%s' "$MSG" | grep -q 'reReplaceAll "&" "&amp;"'
  printf '%s' "$MSG" | grep -q 'reReplaceAll "<" "&lt;"'
  printf '%s' "$MSG" | grep -q 'reReplaceAll ">" "&gt;"'
  run bash -c "printf '%s' \"$MSG\" | grep -c 'safeHtml'"
  [ "$output" = "0" ]
}

@test "message ranges over .Alerts annotations" {
  printf '%s' "$MSG" | grep -q 'range .Alerts'
}
```

**Step — run, expect FAIL** (current `message:` has no glyph, no branch, no escaping):
```bash
bats tools/test/alertmanager-template.bats
```

**Step — commit the failing test:**
```bash
git add tools/test/alertmanager-template.bats
git commit -m "test: Alertmanager telegram 메시지 contract 구조 게이트 추가"
```

### Task 2 — Rewrite the telegram receiver `message:` Go-template to the contract

**Files:** edit `platform/victoria-stack/alertmanager.yaml` — replace ONLY the `message: |` block (lines 32–36). Leave `bot_token_file`, `chat_id: __CHAT_ID__`, `api_url`, `parse_mode: HTML`, `send_resolved: true` untouched.

Replace:
```yaml
            message: |
              <b>{{ .Status | toUpper }}</b> {{ .CommonLabels.alertname }}
              {{ range .Alerts }}{{ .Annotations.summary }}
              {{ .Annotations.description }}
              {{ end }}
```
with (contract field order: `{glyph} <b>{title}</b> — {status}` / `{source} · {ident}` / `{key}: {value}` / `→ {link}`):
```yaml
            message: |
              {{- /* HTML escape (parse_mode=HTML): & 먼저, 그다음 < >. safeHtml 금지(역효과). */ -}}
              {{- define "esc" -}}
              {{- . | reReplaceAll "&" "&amp;" | reReplaceAll "<" "&lt;" | reReplaceAll ">" "&gt;" -}}
              {{- end -}}
              {{- /* alertname → 한글 제목 맵(없으면 alertname 원문, escape) */ -}}
              {{- $name := .CommonLabels.alertname -}}
              {{- $title := $name -}}
              {{- if eq $name "Watchdog" }}{{ $title = "알림 파이프라인" }}
              {{- else if eq $name "TargetDown" }}{{ $title = "스크레이프 타겟 다운" }}
              {{- else if eq $name "R2BackupStale" }}{{ $title = "R2 오프사이트 백업 정체" }}
              {{- else if eq $name "WALArchiveStalled" }}{{ $title = "WAL 아카이빙 정체" }}
              {{- else if eq $name "LocalBasebackupStale" }}{{ $title = "로컬 베이스백업 정체" }}
              {{- else if eq $name "CNPGRestoreDrillStale" }}{{ $title = "복원 드릴 정체" }}
              {{- else if eq $name "ArgoCDOutOfSync" }}{{ $title = "ArgoCD 동기화 이탈" }}
              {{- else if eq $name "ImageDigestDrift" }}{{ $title = "이미지 digest 드리프트" }}
              {{- else if eq $name "PodOOMKilled" }}{{ $title = "파드 OOM 종료" }}
              {{- else if eq $name "NodeMemoryHigh" }}{{ $title = "노드 메모리 경고" }}
              {{- else if eq $name "BulkSSDFilling" }}{{ $title = "외장 SSD 포화" }}
              {{- else if eq $name "BulkSSDAlmostFull" }}{{ $title = "외장 SSD 임박" }}
              {{- else if eq $name "StandardSSDFilling" }}{{ $title = "내장 SSD 포화" }}
              {{- end -}}
              {{- /* 미매핑 alertname → escape된 summary를 제목으로(신규 알림도 한국어 — 교차검증 Pass2 Finding 1).
                     summary가 없으면 alertname 원문 유지(escape됨). */ -}}
              {{- if and (eq $title $name) .CommonAnnotations.summary }}{{ $title = .CommonAnnotations.summary }}{{- end -}}
              {{- /* .Status → 한글 + glyph (firing=발생/critical은 🔴, warning은 ⚠️; resolved=해소 🔵) */ -}}
              {{- if eq .Status "resolved" -}}
              🔵 <b>{{ template "esc" $title }}</b> — 해소
              {{- else if eq .CommonLabels.severity "warning" -}}
              ⚠️ <b>{{ template "esc" $title }}</b> — 경고
              {{- else -}}
              🔴 <b>{{ template "esc" $title }}</b> — 발생
              {{- end }}
              알림 · {{ template "esc" $name }}
              {{ range .Alerts -}}
              {{ if .Annotations.summary }}{{ template "esc" .Annotations.summary }}
              {{ end }}{{ if .Annotations.description }}{{ template "esc" .Annotations.description }}
              {{ end }}{{ if .Annotations.runbook_url }}→ {{ template "esc" .Annotations.runbook_url }}
              {{ end }}{{ end }}
```

Notes on the implementation:
- **Source label** is the fixed Korean `알림` (per the lexicon: AM-originated alerts map to `알림`). The composite GH-action renderers in the sibling task own the other source labels (복원드릴/배포/IaC/etc.); the AM template only ever emits cluster alerts, so `알림` is correct and constant.
- **No KST timestamp** here — the spec says the AM template omits the stamp while staying on v0.27 (the `tz`/`date` funcs exist but the contract reserves the stamp for SHELL renderers).
- **`→ {link}` is conditional on `runbook_url`** — included only when an alert annotation actually carries a URL. None of the current rules set `runbook_url`; this is forward-compatible and the structural test only asserts the escaping/branch tokens, not that a link is always emitted by the AM template specifically.
- All four dynamic insertions (`$title`, `$name`, summary, description, link) go through `template "esc"`. There is no inline interpolation of any client-controlled value; AM annotations are the only inputs and they are all escaped.

**Step — run, expect PASS:**
```bash
bats tools/test/alertmanager-template.bats
```

**Step — commit:**
```bash
git add platform/victoria-stack/alertmanager.yaml
git commit -m "feat: Alertmanager telegram 메시지를 glyph+한글 제목 contract 구조로 재작성 (v0.27 유지)"
```

### Task 3 — `prometheus.io/scrape` annotation on the AM pod (notifier self-observability)

**Files:** edit `platform/victoria-stack/alertmanager.yaml` — add pod-template annotations so `vmagent`'s `pod-annotations` job scrapes `alertmanager_notifications_total{integration="telegram"}` / `_failed_total`.

Verified against `platform/victoria-stack/vmagent-scrape-config.yaml`, job `pod-annotations`: it `keep`s on `__meta_kubernetes_pod_annotation_prometheus_io_scrape == "true"`, reads the port from `__meta_kubernetes_pod_annotation_prometheus_io_port` (regex `([^:]+)(?::\d+)?;(\d+)` → `$1:$2`), and path from `prometheus_io_path` (defaults to `/metrics`). Alertmanager exposes `/metrics` on container port `9093` — so we only need `scrape: "true"` + `port: "9093"` (path defaults to `/metrics`, correct for AM).

**First, extend the test** in `tools/test/alertmanager-template.bats` (failing assertion added before impl):
```bash
@test "AM pod is annotated for vmagent scrape on the metrics port" {
  # vmagent pod-annotations job: keep on prometheus.io/scrape==true, port from prometheus.io/port
  ann="$(yq 'select(.kind=="Deployment" and .metadata.name=="alertmanager") | .spec.template.metadata.annotations' "$AM")"
  printf '%s' "$ann" | grep -q 'prometheus.io/scrape: "true"'
  printf '%s' "$ann" | grep -q 'prometheus.io/port: "9093"'
}
```

**Step — run, expect FAIL:**
```bash
bats tools/test/alertmanager-template.bats
```

**Impl** — change the AM Deployment pod template metadata (currently `metadata: { labels: {...} }` with no annotations):
```yaml
  template:
    metadata:
      labels: { app.kubernetes.io/name: alertmanager }
      # vmagent의 pod-annotations job이 /metrics:9093을 스크레이프해
      # alertmanager_notifications_total / _failed_total{integration="telegram"}를 수집한다.
      annotations:
        prometheus.io/scrape: "true"
        prometheus.io/port: "9093"
```

**Step — run, expect PASS:**
```bash
bats tools/test/alertmanager-template.bats
```

**Step — commit:**
```bash
git add platform/victoria-stack/alertmanager.yaml tools/test/alertmanager-template.bats
git commit -m "feat: Alertmanager 파드에 prometheus.io/scrape 추가 — vmagent가 notifier 메트릭 수집"
```

### Task 4 — vmalert rule: alert on Telegram notification failures + document Watchdog boundary

**Files:** edit `platform/victoria-stack/rules/core.yaml` (the `infra` group is the right home — notifier health is core infra; `vmalert-rules-core` is already mounted at `/rules/core` and globbed by `--rule=/rules/core/*.yaml`). Also adds the Watchdog coverage-boundary comment (spec item 4 — done as a rule comment co-located with the new alert, which is where the boundary actually matters).

**First, add a failing rule-presence assertion** to `tools/test/alertmanager-template.bats`:
```bash
@test "core rules alert on telegram notification failures and document Watchdog boundary" {
  CORE="$ROOT/platform/victoria-stack/rules/core.yaml"
  body="$(yq '.data["core.yaml"]' "$CORE")"
  printf '%s' "$body" | grep -q 'alert: AlertmanagerTelegramFailing'
  printf '%s' "$body" | grep -q 'alertmanager_notifications_failed_total{integration="telegram"}'
  printf '%s' "$body" | grep -q 'increase('
  # Watchdog 커버리지 경계가 문서화돼 있어야 한다 (rule 주석 또는 description)
  grep -q '자기 자신의 전송 실패는 감지하지 못한다' "$CORE"
}
```

**Step — run, expect FAIL:**
```bash
bats tools/test/alertmanager-template.bats
```

**Impl** — append to the `infra` group in `core.yaml` (after `PodOOMKilled`), keeping `alert:`/metric/labels English and summary/description Korean per repo convention. The expr uses `increase(...[15m]) > 0` exactly as specified. Note the self-referential failure mode: if Telegram delivery is fully broken, THIS alert also cannot reach Telegram — which is precisely the Watchdog/dead-man's-switch boundary that must be documented.
```yaml
          # Notifier 자기관측 (R8 보강): Telegram 전송이 실패하면 발화.
          # ⚠️ Watchdog 커버리지 경계 — Watchdog는 "vmalert→Alertmanager 평가 파이프라인이
          #    살아있음"만 증명하고(healthchecks.io의 off-node dead-man's-switch가 그 부재를 페이징),
          #    Alertmanager가 Telegram으로 보내는 마지막 홉의 전송 실패는 감지하지 못한다.
          #    이 알림이 (부분) 전송실패는 메운다. ⚠️ 한계(의도적 수용): Telegram이 전면 장애면
          #    이 알림 자체도 미도달(자기참조) — off-node 스위치는 *파이프라인 생존*만 증명하지 Telegram
          #    전송은 증명하지 않는다. 전면 장애의 백스톱은 TSDB의 이 메트릭(Grafana)·GitHub 워크플로
          #    실패 알림이며, 완전 독립 비-Telegram 채널은 단일운영자 홈랩에 과설계라 v1 범위 밖.
          - alert: AlertmanagerTelegramFailing
            expr: increase(alertmanager_notifications_failed_total{integration="telegram"}[15m]) > 0
            for: 0m
            labels: { severity: warning }
            annotations:
              summary: "Alertmanager → Telegram 전송 실패 발생"
              description: "최근 15분간 telegram integration의 notifications_failed_total이 증가했다 — HTML parse 오류(escape 누락)·봇 토큰·chat_id·네트워크를 확인하라. 이 알림 자체도 같은 Telegram 경로를 타므로 전면 장애 시엔 미도달할 수 있다 — 그 경우 신호는 이 메트릭(Grafana 대시보드)·GitHub 워크플로 실패 알림이다(off-node 스위치는 pipeline 생존만 증명)."
```

**Step — run, expect PASS:**
```bash
bats tools/test/alertmanager-template.bats
```

**Step — commit:**
```bash
git add platform/victoria-stack/rules/core.yaml tools/test/alertmanager-template.bats
git commit -m "feat: AlertmanagerTelegramFailing 알림 추가 + Watchdog 커버리지 경계 문서화"
```

> Spec item 4 also permits documenting the boundary in `NOTES.md`. The primary record is the rule comment above (co-located where the gap is closed). If the orchestrator also wants the NOTES.md narrative, append a `## Notifier 자기관측 & Watchdog 경계` section to `platform/victoria-stack/NOTES.md` summarizing the same boundary and citing `AlertmanagerTelegramFailing`; this is optional and additive (no test depends on it).

### Task 5 — Gate: `amtool check-config` on the KSOPS-rendered config + structural assertion

**Files:** add the gate test to `tools/test/alertmanager-template.bats` (or a dedicated `@test`), and wire it so it runs under `bats` / `make verify`.

The gate has three layers covering disjoint failure modes:
- **CI-safe schema half (in `make verify`/bats)** — extract the AM ConfigMap's `alertmanager.yml` **directly from the plaintext manifest** `platform/victoria-stack/alertmanager.yaml` (the `message:` template and the `__CHAT_ID__` placeholder are NOT secret), **substitute a dummy numeric chat_id** (`amtool` parses chat_id as `int64`), then `amtool check-config` from the **pinned v0.27 image**. **Do NOT `kustomize build` the component here** — the base `kustomization.yaml` has a KSOPS `generators: secret-generator.yaml` (`exec: ksops` on `prod/alerting.enc.yaml`) requiring the `ksops` binary + age key, neither present in CI → the build would fail for an environment reason and train people to skip the gate (verified — 교차검증 Finding 1).
- **structural half** — the glyph/branch/escape token assertions from Tasks 1–4 (lint only — amtool does NOT compile the inline `message:` template; actual compilation is proven by **Task 6**).
- **executable render half** — Task 6 (containerized AM render) is the real proof the Go-template compiles and renders the contract.

**Impl** — add to `tools/test/alertmanager-template.bats`:
```bash
@test "amtool check-config (v0.27 image) accepts the AM config (CI-safe, no KSOPS)" {
  command -v docker >/dev/null || skip "docker required for amtool gate"
  command -v yq >/dev/null || skip "yq required"
  tmp="$(mktemp -d)"
  # 평문 ConfigMap에서 alertmanager.yml 직접 추출 — kustomize build(KSOPS exec generator) 미경유.
  # base kustomization은 secret-generator.yaml(ksops exec, prod/alerting.enc.yaml)을 포함하므로
  # kustomize build는 CI에 없는 ksops 바이너리+age 키를 요구해 환경 사유로 실패한다(교차검증 Finding 1).
  # alertmanager.yaml은 멀티-도큐먼트(ConfigMap+Deployment+Service) — ConfigMap만 선택.
  yq 'select(.kind=="ConfigMap" and .metadata.name=="alertmanager-config") | .data["alertmanager.yml"]' \
      "$ROOT/platform/victoria-stack/alertmanager.yaml" > "$tmp/raw.yml"
  [ -s "$tmp/raw.yml" ]
  # init sed를 모사해 placeholder를 더미 숫자 chat_id로 치환 (amtool은 chat_id를 int64로 파싱)
  # init sed 모사: placeholder → 더미 int64 chat_id (amtool은 chat_id를 정수로 파싱).
  sed 's/__CHAT_ID__/-1001234567890/' "$tmp/raw.yml" > "$tmp/alertmanager.yml"
  run docker run --rm -v "$tmp:/cfg" --entrypoint amtool \
      prom/alertmanager:v0.27.0 check-config /cfg/alertmanager.yml
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -q 'SUCCESS'
}
```

> **CI-safe by construction:** reading `alertmanager.yaml` directly avoids the KSOPS generator entirely (no `ksops`/age key). The **full** KSOPS render (`kustomize build --enable-helm --enable-alpha-plugins --enable-exec platform/victoria-stack`) stays a **local/live** verification with explicit prereqs (ksops 바이너리 + `SOPS_AGE_KEY_FILE`) — see the 정리/최종 검증 컴포넌트 — and is NOT part of the CI bats sweep.

**Step — run, expect PASS** (config is valid after Tasks 2–3):
```bash
bats tools/test/alertmanager-template.bats
```

**Step — negative check (manual, do not commit)** — confirm the gate actually bites: temporarily break the receiver (e.g. delete `chat_id`), run the gate, confirm it FAILS, then revert.

**Step — commit:**
```bash
git add tools/test/alertmanager-template.bats
git commit -m "test: amtool check-config(v0.27) + 구조 게이트로 Alertmanager config 검증"
```

### Task 6 — Executable template-render test (containerized AM v0.27 + mock api_url) — 교차검증 Finding 2

**Why:** `amtool check-config`은 inline `message:` Go-template을 **컴파일하지 않고**(검증됨), 구조 lint은 토큰 grep일 뿐이다. 잘못된 `{{ }}`·함수 오용·나쁜 분기가 green으로 통과해 **ArgoCD sync 후 첫 알림 전송 때만** 깨지며 — `AlertmanagerTelegramFailing` 자기관측 알림도 같은 끊긴 경로를 타 장애가 안 보일 수 있다. 이 Task가 템플릿이 실제로 컴파일·렌더되어 계약을 만족함을 **사전(pre-merge)** 증명한다.

**Mechanism:** 핀된 AM 이미지를 렌더된 config로 띄우되 `api_url`을 POST 본문을 캡처하는 로컬 mock으로 지정 → AM v2 API로 firing/resolved fixture 알림 주입 → 캡처된 Telegram `text`가 계약(parse_mode=HTML, 글리프, `<b>한국어 제목</b>`, `&lt;` escape, `→ 링크`)을 만족하는지 단언. 기존 **required `gate` 잡(ci.yaml, ubuntu-24.04-arm, docker 가용)의 스텝**으로 — `make verify`의 skip-가드 bats가 아니다(영구 skip으로 썩는 것 방지). 별도 잡으로 두면 branch protection이 `gate`만 강제해 auto-merge가 안 기다린다(Step 6.4 참조, 교차검증 Pass2 Finding 2).

**Files:**
- Create: `tools/test/alertmanager-render-e2e.sh` (AM 컨테이너 + mock + 주입 + 단언 오케스트레이션)
- Create: `tools/test/mock-telegram.py` — POST body를 **디코드**해 인자 파일에 기록 후 200 반환. ⚠️ AM telegram sender는 `sendMessage`를 form-urlencoded로 보낼 수 있어 raw 본문엔 `<b>`/이모지가 percent-encoded다(교차검증 Pass4 Finding 3). content-type을 보고 `application/x-www-form-urlencoded`면 `urllib.parse.parse_qs`, `application/json`이면 `json.loads`로 파싱해 **디코드된 `text`와 `parse_mode`를 분리 기록**(예: `parse_mode=HTML\ntext=<디코드된 본문>`). 모든 계약 단언은 이 디코드된 `text`에 대해 수행.
- Create: `tools/test/fixtures/alerts-firing.json`, `tools/test/fixtures/alerts-resolved.json`, `tools/test/fixtures/alerts-unmapped.json`
- Modify: `.github/workflows/ci.yaml` — 기존 required `gate` 잡에 e2e 실행 스텝 추가(Step 6.4; 별도 잡 금지)

**Step 6.1 — fixtures.** ⚠️ `/api/v2/alerts`는 **알림 배열**을 기대한다(단일 객체면 400 → `curl -f`가 즉시 실패, 교차검증 Pass3 Finding 3). 세 fixture 모두 `[ ... ]` 배열.

`alerts-firing.json`:
```json
[{ "labels": {"alertname":"PodOOMKilled","severity":"critical","namespace":"app"},
   "annotations": {"summary":"파드가 메모리 한도 초과로 종료됨",
                   "description":"컨테이너 <main>이 OOM — 메모리 상향 검토",
                   "runbook_url":"https://home.example/runbook/oom"},
   "startsAt":"2026-06-15T00:00:00Z" }]
```
`alerts-resolved.json` (send_resolved:true 경로 검증 — `endsAt`을 과거로 둬 AM이 해소로 처리):
```json
[{ "labels": {"alertname":"PodOOMKilled","severity":"critical","namespace":"app"},
   "annotations": {"summary":"파드가 메모리 한도 초과로 종료됨","runbook_url":"https://home.example/runbook/oom"},
   "startsAt":"2026-06-15T00:00:00Z", "endsAt":"2026-06-15T00:01:00Z" }]
```
(escape 테스트: `<main>`은 `&lt;main&gt;`로 도착. AM Task 2 템플릿은 `runbook_url`을 `→ {링크}`로, `.Status` resolved를 🔵 해소로 렌더해야 한다.)

**Step 6.2 — failing 먼저:** `ci.yaml`에 잡을 추가하고 스크립트가 없는 상태에서 push → 잡 FAIL(스크립트 부재) 확인.

**Step 6.3 — 오케스트레이터(sketch, bash):**
```bash
#!/usr/bin/env bash
set -euo pipefail
TMP="$(mktemp -d)"
trap 'docker rm -f am-test >/dev/null 2>&1 || true; kill "${MOCK_PID:-0}" 2>/dev/null || true' EXIT
# 1) CI-safe config 추출(Task 5와 동일) + 더미 chat_id + api_url→mock + group_wait 축소
yq 'select(.kind=="ConfigMap" and .metadata.name=="alertmanager-config") | .data["alertmanager.yml"]' \
   platform/victoria-stack/alertmanager.yaml > "$TMP/am.yml"
sed -i 's/__CHAT_ID__/-1001234567890/' "$TMP/am.yml"
yq -i '(.receivers[]|select(.name=="telegram").telegram_configs[].api_url)="http://127.0.0.1:8089"' "$TMP/am.yml"
yq -i '.route.group_wait="0s" | .route.group_interval="1s" | .route.repeat_interval="1m"' "$TMP/am.yml"
printf '%s' 'dummy-bot-token' > "$TMP/TELEGRAM_BOT_TOKEN"
# 2) mock telegram: POST body 캡처
python3 tools/test/mock-telegram.py "$TMP/capture.txt" 8089 & MOCK_PID=$!
# 3) AM 컨테이너(token 파일 마운트, host 네트워크)
docker run -d --rm --name am-test --network host \
  -v "$TMP/am.yml:/etc/alertmanager/alertmanager.yml:ro" \
  -v "$TMP/TELEGRAM_BOT_TOKEN:/etc/alertmanager/secrets/TELEGRAM_BOT_TOKEN:ro" \
  prom/alertmanager:v0.27.0 --config.file=/etc/alertmanager/alertmanager.yml
# 4) readiness 후 fixture 주입(firing)
until curl -fsS http://127.0.0.1:9093/-/ready >/dev/null 2>&1; do sleep 0.5; done
curl -fsS -X POST http://127.0.0.1:9093/api/v2/alerts -H 'content-type: application/json' \
  --data-binary @tools/test/fixtures/alerts-firing.json
# 5) 캡처 폴링(최대 30s)
for _ in $(seq 60); do [ -s "$TMP/capture.txt" ] && break; sleep 0.5; done
body="$(cat "$TMP/capture.txt")"
# 6) 계약 단언 (실패 시 set -e로 즉시 종료)
grep -q 'parse_mode=HTML'        <<<"$body"
grep -q '<b>파드 OOM 종료</b>'      <<<"$body"   # ⚠️ 제목 자체가 한국어여야(매핑된 제목; Pass6 Finding 3)
grep -qE '<b>[^<]*[가-힣][^<]*</b>' <<<"$body"   # 일반화: bold 제목 안에 한글
grep -q '🔴'                       <<<"$body"   # critical 글리프
grep -q '&lt;main&gt;'            <<<"$body"   # escaping (raw <main> 금지)
grep -q '메모리'                   <<<"$body"   # 한국어 본문
grep -q '→ https://home.example/runbook/oom' <<<"$body"  # 링크
# 6b) 미매핑 alertname(TelegramSmoke)도 summary가 한국어 제목으로 렌더되는지 —
#     사후 라이브 스모크와 동일 경로를 사전 검증(교차검증 Pass2 Finding 1).
: > "$TMP/capture.txt"
curl -fsS -X POST http://127.0.0.1:9093/api/v2/alerts -H 'content-type: application/json' \
  --data-binary @tools/test/fixtures/alerts-unmapped.json
for _ in $(seq 60); do [ -s "$TMP/capture.txt" ] && break; sleep 0.5; done
body2="$(cat "$TMP/capture.txt")"
grep -q '<b>텔레그램 스모크 테스트</b>' <<<"$body2"   # 미매핑 → summary가 escape돼 제목으로
# 6c) resolved 경로(send_resolved:true) — 🔵 해소로 렌더되는지(교차검증 Pass3 Finding 3).
: > "$TMP/capture.txt"
curl -fsS -X POST http://127.0.0.1:9093/api/v2/alerts -H 'content-type: application/json' \
  --data-binary @tools/test/fixtures/alerts-resolved.json
for _ in $(seq 60); do [ -s "$TMP/capture.txt" ] && break; sleep 0.5; done
body3="$(cat "$TMP/capture.txt")"
grep -q '🔵' <<<"$body3"; grep -q '해소' <<<"$body3"
echo "render-e2e OK"
```

`alerts-unmapped.json`(사후 스모크와 동일 fixture — 미매핑 경로 사전 검증):
```json
[{"labels":{"alertname":"TelegramSmoke","severity":"warning"},
  "annotations":{"summary":"텔레그램 스모크 테스트","description":"배포 후 전송 경로 확인용 합성 알림","runbook_url":"https://home.example/runbook/smoke"}}]
```

**Step 6.4 — required `gate` 잡에 스텝 추가 (별도 잡 금지) — 교차검증 Pass2 Finding 2:**
branch protection은 `gate` 컨텍스트만 강제한다(`infra/github/repo.tf:41-43`, 주석: 다른 컨텍스트를 넣으면 모든 PR이 영구 pending). 별도 `telegram-render` 잡을 만들면 auto-merge가 그 잡을 **기다리지 않아** 깨진 Go-template이 그대로 머지된다. 그러므로 e2e를 **기존 `gate` 잡(`.github/workflows/ci.yaml`, `ubuntu-24.04-arm`, docker 가용)의 스텝으로** 추가한다 — Terraform 변경 불필요, 자동으로 required.
```yaml
# .github/workflows/ci.yaml — jobs.gate.steps 끝에 추가 (gate는 이미 checkout된 잡 → 추가 checkout 불요):
      - name: telegram 메시지 렌더 e2e (containerized AM v0.27)
        run: bash tools/test/alertmanager-render-e2e.sh
```
(`prom/alertmanager:v0.27.0`은 멀티아치라 arm64 러너에서 동작. 만약 향후 `gate`에서 docker를 못 쓰게 되면, 그때만 별도 잡 + `repo.tf` 컨텍스트 추가를 검토 — 단 repo.tf 주석의 pending 함정에 유의.)

**Step 6.5 — run, expect PASS → commit:**
```bash
bash tools/test/alertmanager-render-e2e.sh   # expect: "render-e2e OK"
git add tools/test/alertmanager-render-e2e.sh tools/test/mock-telegram.py \
        tools/test/fixtures/alerts-firing.json tools/test/fixtures/alerts-resolved.json \
        tools/test/fixtures/alerts-unmapped.json .github/workflows/ci.yaml
git commit -m "test: 컨테이너화 AM 렌더 e2e — Go-template 컴파일·한국어·escape·링크 사전 검증"
```

> 이 Task로 "amtool/grep이 Go-template 문법을 증명한다"는 주장은 폐기된다 — 문법·렌더 증명은 Task 6이 전담하고, amtool(Task 5)은 스키마/receiver 배선만, 구조 lint은 토큰 존재만 본다.


---

## Rules Korean-ization + Korean-annotation gate

알림 규칙 3종(`core.yaml`, `r4-storage-backup.yaml`, `r6-ci-staleness.yaml`)의 `summary`/`description` annotation을 한국어로 재작성하고, 그 한국어화를 강제하는 bats 게이트를 추가한다.

**불변식 (반드시 지킬 것):**
- `alert:`/`record:` 이름, `expr`, `for`, `labels`(severity 포함)는 **절대 수정 금지** — annotation(`summary`/`description`)만 바꾼다. alertname·metric 이름·식별자(job/instance/namespace/pod/app/name 라벨 키, `restore_drill_last_success_timestamp` 등 지표명)는 **영문 유지**.
- `{{ $labels.* }}` / `{{ $value }}` Go-template 보간은 **그대로 보존**(Alertmanager가 메시지 렌더 시 치환).
- 이 규칙 파일들은 ArgoCD가 싱크하는 GitOps 컴포넌트다. `*.enc.yaml`이 **아니므로** 직접 편집 가능(평문 ConfigMap). 단, 들여쓰기(블록 스칼라 `core.yaml: |` 8칸)와 따옴표 스타일을 그대로 유지해야 vmalert가 파싱한다.
- 이 컴포넌트는 annotation 텍스트와 게이트만 다룬다. Alertmanager `message:` Go-template(`<b>{{ .Status | toUpper }}</b>` 블록)·composite action·워크플로 12곳·restore-drill `notify()`는 **별도 컴포넌트** 소관 — 여기서 건드리지 않는다.

**한국어 재작성 매핑 (alert별, 현재 → 제안):**

| alert (영문 유지) | 현재 summary → 제안 | 현재 description → 제안 |
|---|---|---|
| `TargetDown` | `"Scrape target {{ $labels.job }}/{{ $labels.instance }} down"` → `"스크레이프 타깃 {{ $labels.job }}/{{ $labels.instance }} 다운"` | `"vmagent target has been unreachable for 5m."` → `"vmagent 타깃이 5분간 도달 불가 상태입니다."` |
| `NodeMemoryHigh` | `"VM memory >92%"` → `"VM 메모리 사용률 92% 초과"` | `"Node memory pressure; eviction threshold nears."` → `"노드 메모리 압박 — eviction 임계치에 근접했습니다."` |
| `PodOOMKilled` | `"OOMKill in {{ $labels.namespace }}/{{ $labels.pod }}"` → `"OOMKill 발생: {{ $labels.namespace }}/{{ $labels.pod }}"` | `"Container hit its memory limit — check the ledger budget."` → `"컨테이너가 메모리 limit에 도달했습니다 — 메모리 원장 예산을 확인하세요."` |
| `BulkSSDFilling` | `"External SSD <15% free"` → `"외장 SSD 여유 공간 15% 미만"` | `"bulk-ssd (media + backup staging) is filling; metrics retention byte-cap will NOT save this disk."` → `"bulk-ssd(미디어 + 백업 스테이징)가 차오릅니다 — metrics retention 바이트 상한으로는 이 디스크를 구제할 수 없습니다."` |
| `BulkSSDAlmostFull` | `"External SSD <5% free"` → `"외장 SSD 여유 공간 5% 미만"` | `"bulk-ssd nearly full — local backup staging + media at imminent risk."` → `"bulk-ssd가 거의 가득 찼습니다 — 로컬 백업 스테이징과 미디어가 임박한 위험에 처했습니다."` |
| `StandardSSDFilling` | `"Internal SSD <10% free"` → `"내장 SSD 여유 공간 10% 미만"` | `"standard SC disk low — Postgres PGDATA/WAL at risk."` → `"standard SC 디스크 여유 부족 — Postgres PGDATA/WAL이 위험합니다."` |
| `LocalBasebackupStale` | `"Local base-backup stale (>27h) or missing"` → `"로컬 base-backup이 stale(27시간 초과)이거나 누락됨"` | `"Restore copy 2 (local 1TB SSD) is at risk — unmounted drive or failed CronJob."` → `"복원 사본 2(로컬 1TB SSD)가 위험합니다 — 드라이브 미마운트 또는 CronJob 실패."` |
| `R2BackupStale` | `"R2 offsite backup stale (>27h) or missing"` → `"R2 오프사이트 백업이 stale(27시간 초과)이거나 누락됨"` | `"Offsite copy 3 (Cloudflare R2) has not produced a fresh backup; DR copy is going stale."` → `"오프사이트 사본 3(Cloudflare R2)가 최신 백업을 만들지 못했습니다 — DR 사본이 노후화되고 있습니다."` |
| `WALArchiveStalled` | `"WAL archiving to R2 stalled (RPO at risk)"` → `"R2로의 WAL 아카이빙 정지(RPO 위험)"` | `"Last failed archive is newer than last successful archive; offsite WAL stream is broken and the 5-min RPO is not being met."` → `"마지막 실패 아카이브가 마지막 성공 아카이브보다 최신입니다 — 오프사이트 WAL 스트림이 끊겼고 5분 RPO 목표를 충족하지 못합니다."` |
| `CNPGRestoreDrillStale` | `"CNPG restore drill has not succeeded recently"` → `"CNPG 복원 drill이 최근에 성공하지 못함"` | `"The recurring restore-from-R2 drill (M4) has not pushed a fresh success timestamp; the only verified restore path may be broken (R1)."` → `"반복 R2 복원 drill(M4)이 최신 성공 timestamp를 푸시하지 못했습니다 — 유일하게 검증된 복원 경로가 깨졌을 수 있습니다(R1)."` |
| `ArgoCDOutOfSync` | `"ArgoCD app {{ $labels.name }} OutOfSync >15m"` → `"ArgoCD 앱 {{ $labels.name }} OutOfSync 15분 초과"` | `"Tag write-back webhook or sync may have silently failed; cluster may be running yesterday's image."` → `"태그 write-back webhook 또는 sync가 조용히 실패했을 수 있습니다 — 클러스터가 어제 이미지로 돌고 있을 수 있습니다."` |
| `ImageDigestDrift` | `"Running image for {{ $labels.app }} != latest GHCR digest"` → `"실행 중인 이미지가 최신 GHCR digest와 불일치: {{ $labels.app }}"` | `"Build pushed a new image but the running pod never picked it up (R6 write-back/sync staleness)."` → `"빌드가 새 이미지를 푸시했지만 실행 중인 파드가 반영하지 못했습니다(R6 write-back/sync staleness)."` |
| `Watchdog` | `"Watchdog: alerting pipeline is alive."` → `"Watchdog: 알림 파이프라인 정상 동작 중."` | `"This always-firing alert proves Alertmanager→Telegram and the off-node dead-man's-switch are wired. Its ABSENCE at healthchecks.io is the page."` → `"항상 발화하는 이 알림은 vmalert→Alertmanager→deadmanswitch(webhook)→healthchecks.io 경로의 생존만 증명합니다(healthchecks.io에서 이 알림의 부재가 곧 page). ⚠️ Telegram 전송은 증명하지 않는다 — Watchdog는 deadmanswitch로만 라우팅됨. 마지막 홉 신뢰는 alertmanager_notifications_failed_total{integration=\"telegram\"}와 AlertmanagerTelegramFailing 알림으로 확인."` |

> 비고: `ImageDigestDrift`의 summary는 `!=` 비교 의미를 보존하려고 어순을 한국어 자연어로 바꿨다(접두 라벨 제거 후 콜론으로 식별자 제시). `record: app:image_digest_drift`는 annotation이 없으므로 손대지 않는다.

---

### Task 1 — 한국어 annotation 게이트(failing test)

세 규칙 파일의 모든 `summary`/`description`이 (1) 한국어(비-ASCII)를 포함하고 (2) 비어있지 않은지 강제하는 bats를 추가한다. 작성 시점엔 annotation이 아직 영문이라 **반드시 실패**해야 한다. CI는 `ls tools/test/*.bats`로 글롭하므로 새 파일은 자동 편입된다(`.github/workflows/ci.yaml:42`).

**Files**

- Create `/Users/ukyi/workspace/homelab/tools/test/telegram-alert-korean.bats`:

```bash
#!/usr/bin/env bats
# 알림 규칙 한국어화 게이트 — 3개 규칙 파일의 모든 summary/description이 한국어를
# 포함하는지(텔레그램 메시지가 한국어로 렌더되도록) 강제한다.
# ⚠️ 중간 단언은 [ ]만 사용 — bash 3.2(macOS)에서 [[ ]] 실패는 침묵 통과(검증된 버그).
# 비-ASCII 판정은 LC_ALL=C + 인쇄가능 ASCII 바이트 클래스 '[^ -~]'로 — BSD/GNU grep 양쪽에서
# 동작(grep -P는 macOS 기본 grep에 없다).

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  RULES="$ROOT/platform/victoria-stack/rules"
}

# 규칙 파일의 ConfigMap data 블록(.data["<key>"])에서 모든 annotation 값을 줄 단위로 추출.
# rules 파일은 규칙 YAML을 문자열 스칼라로 담으므로 yq를 2단으로 적용한다.
extract() { # $1=file $2=datakey $3=field(summary|description)
  yq -r ".data[\"$2\"]" "$RULES/$1" | yq -r ".. | select(has(\"$3\")) | .$3"
}

# 값들 중 비-ASCII(한국어)를 포함하지 않는 줄이 하나라도 있으면 그 줄을 출력하고 1.
all_korean() {
  LC_ALL=C grep -vn '[^ -~]' || true   # 한국어 없는 줄만 남긴다(있으면 위반)
}

@test "core.yaml summaries all contain Korean" {
  run bash -c '
    yq -r ".data[\"core.yaml\"]" "'"$RULES"'/core.yaml" \
      | yq -r ".. | select(has(\"summary\")) | .summary" \
      | LC_ALL=C grep -vn "[^ -~]"'
  [ "$status" -ne 0 ]   # 위반 줄이 없어야 한다(grep -v가 아무것도 못 찾아 status=1)
  [ -z "$output" ]
}

@test "core.yaml descriptions all contain Korean" {
  run bash -c '
    yq -r ".data[\"core.yaml\"]" "'"$RULES"'/core.yaml" \
      | yq -r ".. | select(has(\"description\")) | .description" \
      | LC_ALL=C grep -vn "[^ -~]"'
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "r4-storage-backup summaries all contain Korean" {
  run bash -c '
    yq -r ".data[\"r4.yaml\"]" "'"$RULES"'/r4-storage-backup.yaml" \
      | yq -r ".. | select(has(\"summary\")) | .summary" \
      | LC_ALL=C grep -vn "[^ -~]"'
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "r4-storage-backup descriptions all contain Korean" {
  run bash -c '
    yq -r ".data[\"r4.yaml\"]" "'"$RULES"'/r4-storage-backup.yaml" \
      | yq -r ".. | select(has(\"description\")) | .description" \
      | LC_ALL=C grep -vn "[^ -~]"'
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "r6-ci-staleness summaries all contain Korean" {
  run bash -c '
    yq -r ".data[\"r6.yaml\"]" "'"$RULES"'/r6-ci-staleness.yaml" \
      | yq -r ".. | select(has(\"summary\")) | .summary" \
      | LC_ALL=C grep -vn "[^ -~]"'
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "r6-ci-staleness descriptions all contain Korean" {
  run bash -c '
    yq -r ".data[\"r6.yaml\"]" "'"$RULES"'/r6-ci-staleness.yaml" \
      | yq -r ".. | select(has(\"description\")) | .description" \
      | LC_ALL=C grep -vn "[^ -~]"'
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "every rule with annotations has both summary and description (non-empty)" {
  for spec in "core.yaml:core.yaml" "r4.yaml:r4-storage-backup.yaml" "r6.yaml:r6-ci-staleness.yaml"; do
    key="${spec%%:*}"; file="${spec##*:}"
    run bash -c '
      yq -r ".data[\"'"$key"'\"]" "'"$RULES"'/'"$file"'" \
        | yq -r ".. | select(has(\"annotations\")) | .annotations
                 | select((.summary | length == 0) or (.description | length == 0)) | path | join(\".\")"'
    [ "$status" -eq 0 ]
    [ -z "$output" ]   # summary/description 둘 중 하나라도 비면 위반
  done
}

@test "templating placeholders are preserved (no stray un-rendered field names)" {
  # {{ $labels.* }} / {{ $value }} 보간이 남아있어야 하는 4개 알림에서 placeholder가 유지되는지 확인.
  run bash -c '
    yq -r ".data[\"core.yaml\"]" "'"$RULES"'/core.yaml" \
      | yq -r ".. | select(.alert == \"TargetDown\") | .annotations.summary"'
  [ "$status" -eq 0 ]
  case "$output" in *'"{{ $labels.job }}"'*|*'{{ $labels.job }}'*) : ;; *) false ;; esac
  case "$output" in *'{{ $labels.instance }}'*) : ;; *) false ;; esac
}
```

**Step 1 — run (expect FAIL):**

```bash
cd /Users/ukyi/workspace/homelab && bats tools/test/telegram-alert-korean.bats
```

기대: 6개 한국어 단언 테스트가 모두 FAIL(현재 영문이라 `grep -v '[^ -~]'`가 모든 줄을 위반으로 잡아 status=0 → `[ "$status" -ne 0 ]` 실패). placeholder/non-empty 테스트는 PASS일 수 있다.

> 함정: 이 레포의 기존 bats(예: `ci-build.bats`)는 중간 단언에 `[[ ]]`를 쓰지만 그건 bash 3.2에서 침묵 통과하는 검증된 버그다. 이 신규 파일은 **반드시 `[ ]`** 만 쓴다(AGENTS.md). placeholder 테스트에서 `[[ ]]` 패턴 매칭 대신 `case ... esac`를 쓰는 이유도 동일하다.

---

### Task 2 — core.yaml annotation 한국어화

위 매핑표대로 `core.yaml`의 4개 알림(`TargetDown`/`NodeMemoryHigh`/`PodOOMKilled`/`Watchdog`) annotation을 교체한다. expr/for/labels는 그대로.

**Files**

- Edit `/Users/ukyi/workspace/homelab/platform/victoria-stack/rules/core.yaml` — `annotations:` 블록만 교체:

```yaml
          - alert: TargetDown
            expr: up == 0
            for: 5m
            labels: { severity: critical }
            annotations:
              summary: "스크레이프 타깃 {{ $labels.job }}/{{ $labels.instance }} 다운"
              description: "vmagent 타깃이 5분간 도달 불가 상태입니다."
          - alert: NodeMemoryHigh
            expr: (1 - (node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)) > 0.92
            for: 10m
            labels: { severity: warning }
            annotations:
              summary: "VM 메모리 사용률 92% 초과"
              description: "노드 메모리 압박 — eviction 임계치에 근접했습니다."
          - alert: PodOOMKilled
            expr: increase(kube_pod_container_status_restarts_total[15m]) > 0 and on(namespace,pod) kube_pod_container_status_last_terminated_reason{reason="OOMKilled"} == 1
            for: 0m
            labels: { severity: warning }
            annotations:
              summary: "OOMKill 발생: {{ $labels.namespace }}/{{ $labels.pod }}"
              description: "컨테이너가 메모리 limit에 도달했습니다 — 메모리 원장 예산을 확인하세요."
```

그리고 Watchdog 블록:

```yaml
          - alert: Watchdog
            expr: vector(1)
            labels: { severity: none }
            annotations:
              summary: "Watchdog: 알림 파이프라인 정상 동작 중."
              description: "항상 발화하는 이 알림은 vmalert→Alertmanager→deadmanswitch(webhook)→healthchecks.io 경로의 생존만 증명합니다(healthchecks.io에서 이 알림의 부재가 곧 page). ⚠️ Telegram 전송은 증명하지 않는다 — Watchdog는 deadmanswitch로만 라우팅됨."
```

**Step 1 — run (core 테스트만 PASS 확인):**

```bash
cd /Users/ukyi/workspace/homelab && bats tools/test/telegram-alert-korean.bats -f "core.yaml"
```

기대: `core.yaml summaries ...` / `core.yaml descriptions ...` 두 테스트 PASS. (r4/r6는 아직 FAIL — 다음 태스크에서 처리)

---

### Task 3 — r4-storage-backup annotation 한국어화

`r4-storage-backup.yaml`의 7개 알림(`BulkSSDFilling`/`BulkSSDAlmostFull`/`StandardSSDFilling`/`LocalBasebackupStale`/`R2BackupStale`/`WALArchiveStalled`/`CNPGRestoreDrillStale`) annotation을 매핑표대로 교체. expr 블록 스칼라(`|`)와 주석은 그대로 둔다.

**Files**

- Edit `/Users/ukyi/workspace/homelab/platform/victoria-stack/rules/r4-storage-backup.yaml` — 각 `annotations:` 블록만 교체:

```yaml
          - alert: BulkSSDFilling
            ...
            annotations:
              summary: "외장 SSD 여유 공간 15% 미만"
              description: "bulk-ssd(미디어 + 백업 스테이징)가 차오릅니다 — metrics retention 바이트 상한으로는 이 디스크를 구제할 수 없습니다."
          - alert: BulkSSDAlmostFull
            ...
            annotations:
              summary: "외장 SSD 여유 공간 5% 미만"
              description: "bulk-ssd가 거의 가득 찼습니다 — 로컬 백업 스테이징과 미디어가 임박한 위험에 처했습니다."
          - alert: StandardSSDFilling
            ...
            annotations:
              summary: "내장 SSD 여유 공간 10% 미만"
              description: "standard SC 디스크 여유 부족 — Postgres PGDATA/WAL이 위험합니다."
          - alert: LocalBasebackupStale
            ...
            annotations:
              summary: "로컬 base-backup이 stale(27시간 초과)이거나 누락됨"
              description: "복원 사본 2(로컬 1TB SSD)가 위험합니다 — 드라이브 미마운트 또는 CronJob 실패."
          - alert: R2BackupStale
            ...
            annotations:
              summary: "R2 오프사이트 백업이 stale(27시간 초과)이거나 누락됨"
              description: "오프사이트 사본 3(Cloudflare R2)가 최신 백업을 만들지 못했습니다 — DR 사본이 노후화되고 있습니다."
          - alert: WALArchiveStalled
            ...
            annotations:
              summary: "R2로의 WAL 아카이빙 정지(RPO 위험)"
              description: "마지막 실패 아카이브가 마지막 성공 아카이브보다 최신입니다 — 오프사이트 WAL 스트림이 끊겼고 5분 RPO 목표를 충족하지 못합니다."
          - alert: CNPGRestoreDrillStale
            ...
            annotations:
              summary: "CNPG 복원 drill이 최근에 성공하지 못함"
              description: "반복 R2 복원 drill(M4)이 최신 성공 timestamp를 푸시하지 못했습니다 — 유일하게 검증된 복원 경로가 깨졌을 수 있습니다(R1)."
```

> 실제 Edit 시 위 `...` 부분(expr/for/labels)은 원본 그대로 두고 `annotations:` 두 줄씩만 `old_string`/`new_string`으로 정확히 매칭한다. 각 summary 영문 원문이 파일 내 유일하므로 단일 매칭이 안전하다.

**Step 1 — run (r4 테스트 PASS 확인):**

```bash
cd /Users/ukyi/workspace/homelab && bats tools/test/telegram-alert-korean.bats -f "r4-storage-backup"
```

기대: r4 summaries/descriptions 두 테스트 PASS.

---

### Task 4 — r6-ci-staleness annotation 한국어화

`r6-ci-staleness.yaml`의 2개 알림(`ArgoCDOutOfSync`/`ImageDigestDrift`) annotation 교체. `record: app:image_digest_drift`는 annotation이 없으니 건드리지 않는다.

**Files**

- Edit `/Users/ukyi/workspace/homelab/platform/victoria-stack/rules/r6-ci-staleness.yaml`:

```yaml
          - alert: ArgoCDOutOfSync
            expr: argocd_app_info{sync_status="OutOfSync"} == 1
            for: 15m
            labels: { severity: warning }
            annotations:
              summary: "ArgoCD 앱 {{ $labels.name }} OutOfSync 15분 초과"
              description: "태그 write-back webhook 또는 sync가 조용히 실패했을 수 있습니다 — 클러스터가 어제 이미지로 돌고 있을 수 있습니다."
```

```yaml
          - alert: ImageDigestDrift
            expr: app:image_digest_drift == 1
            for: 20m
            labels: { severity: warning }
            annotations:
              summary: "실행 중인 이미지가 최신 GHCR digest와 불일치: {{ $labels.app }}"
              description: "빌드가 새 이미지를 푸시했지만 실행 중인 파드가 반영하지 못했습니다(R6 write-back/sync staleness)."
```

**Step 1 — run (전체 게이트 PASS):**

```bash
cd /Users/ukyi/workspace/homelab && bats tools/test/telegram-alert-korean.bats
```

기대: 전 테스트 PASS(8/8).

**Step 2 — 규칙 파일 YAML 무결성 + KSOPS 미사용이므로 plain kustomize 렌더로 파싱 검증:**

```bash
cd /Users/ukyi/workspace/homelab
# 각 규칙 파일이 여전히 유효한 ConfigMap이고 내부 rules YAML이 파싱되는지 확인
for f in core r4-storage-backup r6-ci-staleness; do
  yq -e '.kind == "ConfigMap"' "platform/victoria-stack/rules/$f.yaml" >/dev/null
  k=$(yq -r '.data | keys | .[0]' "platform/victoria-stack/rules/$f.yaml")
  yq -r ".data[\"$k\"]" "platform/victoria-stack/rules/$f.yaml" | yq -e '.groups | length > 0' >/dev/null
done && echo "rules YAML OK"
# victoria-stack 컴포넌트 전체 렌더(규칙 파일 포함)가 깨지지 않는지
kustomize build --enable-helm --enable-alpha-plugins --enable-exec platform/victoria-stack >/dev/null && echo "kustomize render OK"
```

기대: `rules YAML OK` + `kustomize render OK`. (렌더 경로가 `prod`가 아니면 실제 victoria-stack 디렉토리 구조에 맞춰 조정 — `make chart-test`는 이 컴포넌트와 무관하니 생략 가능.)

---

### Task 5 — commit

annotation 한국어화 + 게이트를 한 커밋으로 묶는다(테스트와 충족 구현을 함께). `/commit` 스킬 사용(직접 git commit 금지 — 사용자 규약).

**Step 1 — 스테이징 후 커밋(스킬 경유):**

```bash
cd /Users/ukyi/workspace/homelab
git add tools/test/telegram-alert-korean.bats \
        platform/victoria-stack/rules/core.yaml \
        platform/victoria-stack/rules/r4-storage-backup.yaml \
        platform/victoria-stack/rules/r6-ci-staleness.yaml
```

커밋 메시지(한국어 conventional, AI 마커 금지):

```
feat: 알림 규칙 annotation 한국어화 + 한국어 강제 게이트 추가

core/r4/r6 규칙의 summary·description을 한국어로 재작성(텔레그램 한국어 알림).
alertname·metric·식별자는 영문, {{ $labels.* }} 보간 보존.
tools/test/telegram-alert-korean.bats가 3개 파일 전 annotation의 한국어 포함을 강제.
```

> 브랜치: 현재 `main`이면 작업 전 `feat/telegram-korean-alerts` 등으로 분기 후 PR-first(AGENTS.md: 모든 main 쓰기는 PR + auto-merge). 단 사용자가 명시 요청 전엔 push/PR 하지 않는다.


---

## restore-drill notify() shared-contract refactor

Refactor `notify()` in `platform/cnpg/prod/restore-drill-script.sh` (lines 21-26, called from `fail()` at line 29 and the PASS branch at line 101) so the drill renders the SHARED message contract instead of the ad-hoc `[restore-drill] $1 $2`. Source label is **복원드릴**; status maps **PASS→성공 ✅**, **FAIL→실패 🔴** (glyph paired with the word). Add a `DRY_RUN` mode that prints the rendered `text` body instead of `curl`ing Telegram, keeps the existing `|| true` swallow, and HTML-escapes every dynamic value (`& < >`). A new isolated bats (`tools/test/restore-drill-notify.bats`) extracts `notify()` out of the embedded script and asserts the DRY_RUN structural invariants for both PASS and FAIL.

**Why extract instead of `source`:** the script runs `set -euo pipefail` and then executes top-level `kubectl exec`/`kubectl apply` commands immediately on load (lines 48+), with a `trap cleanup EXIT`. Sourcing the whole file from bats would fire `kubectl` against no cluster and trigger the EXIT trap. There is no `main` guard today and adding one would churn the whole control-flow body. So the test **carves `notify()` (and the tiny helper it needs) out with `sed` line-range extraction** into a throwaway file, stubs `curl`, sets the required env, and invokes only `notify`. This is the same isolation pattern other tools bats already use for shell snippets.

Runtime context to honor: CronJob runs `command: ["/bin/bash", "/scripts/drill.sh"]` (so `bash` builtins like `${var//}` are fine), the ConfigMap is generated from this exact file via `configMapGenerator` in `platform/cnpg/prod/kustomization.yaml` (`drill.sh=restore-drill-script.sh`), and the image is `pg-tools:16-rclone` (has `curl`, `date`, GNU coreutils → `TZ=Asia/Seoul date` works).

---

### Task 1 — Isolated bats for the DRY_RUN render contract (RED)

Write the failing test first. It extracts `notify()` from the live script, runs it under `DRY_RUN=1`, and asserts the contract for PASS and FAIL. All mid-test assertions use `[ ]` (simple command) — never `[[ ]]` — because the repo runs bats under macOS bash 3.2 where a failing `[[ ]]` is silently swallowed by `set -e` (documented trap). `@test` names are in English.

**Files**

Create `tools/test/restore-drill-notify.bats`:

```bash
#!/usr/bin/env bats
# restore-drill notify() — 공유 메시지 계약 + DRY_RUN 렌더를 격리 검증한다.
# 스크립트 본문은 source 시 즉시 kubectl/ trap EXIT를 실행하므로 notify()만 떼어 테스트한다.

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  SRC="$ROOT/platform/cnpg/prod/restore-drill-script.sh"
  EX="$BATS_TEST_TMPDIR/notify.sh"
  # notify()와 그 헬퍼(hx: HTML-escape)를 BEGIN/END 마커 사이에서 추출한다.
  sed -n '/# >>> notify-block (test-extracted)/,/# <<< notify-block (test-extracted)/p' "$SRC" > "$EX"
  # curl을 호출하면 안 된다(격리). 호출 시 즉시 실패하도록 스텁.
  cat > "$BATS_TEST_TMPDIR/curl" <<'STUB'
#!/usr/bin/env bash
echo "CURL_WAS_CALLED $*" >&2
exit 42
STUB
  chmod +x "$BATS_TEST_TMPDIR/curl"
}

# notify()를 격리 셸에서 호출하는 헬퍼. DRY_RUN=1 → curl 대신 text를 stdout으로.
run_notify() {
  run env PATH="$BATS_TEST_TMPDIR:$PATH" \
    DRY_RUN=1 TELEGRAM_BOT_TOKEN=tok TELEGRAM_CHAT_ID=123 \
    bash -c 'set -euo pipefail; source "$1"; shift; notify "$@"' _ "$EX" "$@"
}

@test "notify extraction yields a sourceable block with a notify function" {
  [ -s "$EX" ]
  run grep -c 'notify()' "$EX"
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
}

@test "DRY_RUN PASS renders glyph+word, source label, and key:value details" {
  run_notify PASS "복구 ${ACTUAL_ROWS:-7}행 (라이브 5행)"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -q '✅'
  printf '%s\n' "$output" | grep -q '성공'
  printf '%s\n' "$output" | grep -q '복원드릴'
  printf '%s\n' "$output" | grep -q '<b>'
}

@test "DRY_RUN FAIL renders the failure glyph and word" {
  run_notify FAIL "라이브 row count를 읽지 못함"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -q '🔴'
  printf '%s\n' "$output" | grep -q '실패'
  printf '%s\n' "$output" | grep -q '복원드릴'
}

@test "DRY_RUN never invokes curl (stub would print CURL_WAS_CALLED)" {
  run_notify PASS "x"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qv 'CURL_WAS_CALLED' || true
  run bash -c 'printf "%s" "$1" | grep -c CURL_WAS_CALLED || true' _ "$output"
  [ "$output" = "0" ]
}

@test "notify HTML-escapes dynamic values (< > & become entities, no raw <script)" {
  run_notify FAIL 'tbl <script> a&b >x'
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -q '&lt;script&gt;'
  printf '%s\n' "$output" | grep -q 'a&amp;b'
  run bash -c 'printf "%s" "$1" | grep -c "<script>" || true' _ "$output"
  [ "$output" = "0" ]
}

@test "notify keeps parse_mode=HTML semantics (bold title tag present)" {
  run_notify PASS "복구 7행"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -q '<b>'
  printf '%s\n' "$output" | grep -q '</b>'
}
```

**Step — run, expect RED**

```bash
bats tools/test/restore-drill-notify.bats
```

Expect failures: the `sed` markers don't exist yet, `notify()` still emits the old `[restore-drill] $1 $2` format, there is no `DRY_RUN` branch, and no HTML-escape helper.

---

### Task 2 — Refactor `notify()` to the shared contract + DRY_RUN + HTML-escape (GREEN)

Replace the old `notify()` (current lines 21-26) with a contract renderer wrapped in the test-extraction markers. The block must be **self-contained** so the `sed`-carved file sources cleanly: it declares the `hx` HTML-escape helper and `notify` and nothing else (no top-level `kubectl`). Keep `set -euo pipefail` happy — `hx` is pure bash parameter expansion, no externals.

**Files**

In `platform/cnpg/prod/restore-drill-script.sh`, replace:

```bash
notify() { # $1=emoji-status $2=text
  curl -fsS -X POST "$TG" \
    --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
    --data-urlencode "text=[restore-drill] $1 $2" \
    --data-urlencode "parse_mode=HTML" >/dev/null || true
}
```

with:

```bash
# >>> notify-block (test-extracted)
# HTML-escape: parse_mode=HTML에서 동적 값의 & < > 를 엔티티로. & 를 먼저 치환해야 한다
# (이미 만든 &lt; 의 &를 다시 이스케이프하지 않도록). 외부 명령 없이 bash 파라미터 확장만 사용.
hx() { local s=${1//&/&amp;}; s=${s//</&lt;}; s=${s//>/&gt;}; printf '%s' "$s"; }

# 공유 메시지 계약(parse_mode=HTML, 고정 필드 순서):
#   {glyph} <b>{제목}</b> — {상태}
#   복원드릴 · {핵심 식별자}
#   {key}: {value}
#   → {링크}            (URL이 있을 때만)
# $1=PASS|FAIL  $2=상태 상세 텍스트(동적, 이스케이프 대상)
notify() {
  local outcome=$1 detail=$2 glyph word
  case "$outcome" in
    PASS) glyph='✅'; word='성공' ;;
    *)    glyph='🔴'; word='실패' ;;   # FAIL 및 기타 → 실패 (fail-closed)
  esac
  local stamp; stamp="$(TZ=Asia/Seoul date '+%m/%d %H:%M' 2>/dev/null || true)"
  # 동적 값은 전부 이스케이프. 정적 한국어 라벨/태그는 그대로(계약 구조).
  local text
  text="${glyph} <b>복원 드릴</b> — ${word}
복원드릴 · pg-restore-drill
결과: $(hx "$detail")"
  [ -n "$stamp" ] && text="${text}
시각: ${stamp} KST"

  if [ "${DRY_RUN:-0}" = "1" ]; then
    printf '%s\n' "$text"
    return 0
  fi
  curl -fsS -X POST "$TG" \
    --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
    --data-urlencode "text=${text}" \
    --data-urlencode "parse_mode=HTML" >/dev/null || true
}
# <<< notify-block (test-extracted)
```

Note the call sites stay source-compatible: `fail()` calls `notify "🔴 FAIL" "$1"` and the PASS branch calls `notify "🟢 PASS" "..."`. The new signature is `$1=PASS|FAIL`, so update both call sites in the same edit.

In the same file, change `fail()` (currently line 28-31):

```bash
fail() {
  notify "🔴 FAIL" "$1"
  exit 1
}
```

to:

```bash
fail() {
  notify FAIL "$1"
  exit 1
}
```

and change the PASS call (currently line 101):

```bash
  notify "🟢 PASS" "recovered ${ACTUAL_ROWS} rows (live ${EXPECTED_ROWS}) from R2"
```

to:

```bash
  notify PASS "복구 ${ACTUAL_ROWS}행 (라이브 ${EXPECTED_ROWS}행) — R2"
```

**Step — run, expect GREEN**

```bash
bats tools/test/restore-drill-notify.bats
```

**Step — guard against shellcheck regressions and the embedded-render test**

The existing suite `platform/cnpg/prod/test_restore_drill.bats` runs `shellcheck "$sh"` and greps for `api.telegram.org`/`sendMessage`. Both still hold (curl line retained). Run:

```bash
shellcheck platform/cnpg/prod/restore-drill-script.sh
bats platform/cnpg/prod/test_restore_drill.bats
```

If shellcheck flags `hx`'s local-assign-then-use, it is benign here (no command substitution on the `local` line); leave as written. Verify the ConfigMap still renders the updated script:

```bash
export SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt
kustomize build --enable-helm --enable-alpha-plugins --enable-exec platform/cnpg/prod \
  | yq 'select(.kind=="ConfigMap" and .metadata.name=="restore-drill-script") | .data."drill.sh"' \
  | grep -q 'notify-block (test-extracted)'
```

**Step — commit**

```bash
git add platform/cnpg/prod/restore-drill-script.sh tools/test/restore-drill-notify.bats
git commit  # /commit 스킬 사용
```
Korean conventional message, e.g. `refactor: restore-drill notify를 공유 메시지 계약으로 전환 (DRY_RUN·HTML escape)`.

---

### Task 3 — Wire the new bats into the existing drill suite assertions (GREEN, optional hardening)

Extend `platform/cnpg/prod/test_restore_drill.bats` so the source-of-truth file is asserted to carry the contract (catches anyone reverting the render without running the isolated suite). Keep names English, assertions `[ ]`.

**Files**

Append to `platform/cnpg/prod/test_restore_drill.bats`:

```bash
@test "drill notify renders the shared contract (Korean source label + parse_mode HTML)" {
  grep -q '복원드릴' "$sh"          # 소스 라벨
  grep -q 'parse_mode=HTML' "$sh"   # HTML 모드 유지
  grep -q 'notify-block (test-extracted)' "$sh" # 격리 테스트 추출 마커
}
@test "drill notify supports DRY_RUN (print instead of curl) and HTML-escapes" {
  grep -q 'DRY_RUN' "$sh"
  grep -q 'hx()' "$sh"
}
```

**Step — run, expect GREEN**

```bash
bats platform/cnpg/prod/test_restore_drill.bats tools/test/restore-drill-notify.bats
```

**Step — commit**

```bash
git add platform/cnpg/prod/test_restore_drill.bats
git commit  # /commit 스킬: test: restore-drill notify 계약 회귀 가드 추가
```



---

## Cleanup + Final Verification

Two jobs: (1) defuse the `.env.secrets.example` double-entry footgun with comments + a derivation hint (KEEP the `TF_VAR_telegram_*` pair — it provisions the GH Actions secret via `infra/github/secrets.tf`); (2) document the final integration gate (`make verify` green, KSOPS full render of victoria-stack, manual post-merge smoke). **v1 scope: no topics, no `message_thread_id`, no v0.27->v0.28, no chat_id migration, no new secrets** (Task 4b 독립 채널은 descope됨 — 자기관측은 메트릭+Telegram 알림+한계 명문화로).

Confirmed wiring (do not change the contract):
- `.env.secrets.example:48-49` — `TF_VAR_telegram_bot_token` / `TF_VAR_telegram_chat_id` (read by terraform `infra/github`).
- `infra/github/secrets.tf:6-15` — consumes `var.telegram_bot_token` / `var.telegram_chat_id` (declared `infra/github/variables.tf:17,21`) into GH Actions secrets `TELEGRAM_BOT_TOKEN` / `TELEGRAM_CHAT_ID`. **Removing the TF_VAR pair breaks CI notifications.**
- `.env.secrets.example:61-63` — `TELEGRAM_BOT_TOKEN` / `TELEGRAM_CHAT_ID` (read by `scripts/seed-secrets.sh:9-10`, sealed into k8s SOPS secrets at `scripts/seed-secrets.sh:112-113,128-129`).

The footgun: two name pairs must hold the **same** value but are listed independently, so a future operator updates one and not the other — CI Telegram and in-cluster Alertmanager Telegram then point at different bots/chats.

### Task 1 — Lock the `.env.secrets.example` double-entry with a comment gate + derivation hint

Add a guard test FIRST (greenfield — no test references these vars today), then edit the template so the two pairs are explicitly cross-linked and the second pair is derived from the first.

**Files**
- `tools/test/env-secrets-telegram.bats` (new) — structural lint on the committed template.
- `.env.secrets.example` (edit comments + add derivation hint; KEEP all four `export` lines).

**Step 1 — write the failing test.** Create `tools/test/env-secrets-telegram.bats`. bats `@test` names in ENGLISH; mid-test assertions use `[ ]` (simple command), never `[[ ]]` (bash 3.2 silently passes failing `[[ ]]`).

```bash
#!/usr/bin/env bats
# .env.secrets.example의 Telegram 이중 기재가 "같은 값"임을 명시하는지 검증.
# TF_VAR 쌍은 CI 알림(infra/github/secrets.tf)을 공급하므로 삭제 금지 — 존재까지 강제한다.

EXAMPLE="${BATS_TEST_DIRNAME}/../../.env.secrets.example"

@test "TF_VAR telegram pair is still present (provisions GH Actions secret)" {
  run grep -qE '^export TF_VAR_telegram_bot_token=' "$EXAMPLE"
  [ "$status" -eq 0 ]
  run grep -qE '^export TF_VAR_telegram_chat_id=' "$EXAMPLE"
  [ "$status" -eq 0 ]
}

@test "seed-secrets telegram pair is still present (seeds k8s SOPS secret)" {
  run grep -qE '^export TELEGRAM_BOT_TOKEN=' "$EXAMPLE"
  [ "$status" -eq 0 ]
  run grep -qE '^export TELEGRAM_CHAT_ID=' "$EXAMPLE"
  [ "$status" -eq 0 ]
}

@test "the two pairs are documented as the SAME value (footgun guard)" {
  # 두 쌍이 동일 값이어야 함을 알리는 핵심 키워드가 주석에 있어야 한다.
  run grep -q '동일한 값' "$EXAMPLE"
  [ "$status" -eq 0 ]
  run grep -q 'infra/github/secrets.tf' "$EXAMPLE"
  [ "$status" -eq 0 ]
  run grep -q 'seed-secrets.sh' "$EXAMPLE"
  [ "$status" -eq 0 ]
}

@test "the seed pair shows a derive-from-TF_VAR hint (default expansion)" {
  # ⑦ 블록은 ⑤에서 파생되는 기본값(파라미터 확장)을 제시해야 한다.
  run grep -qF '${TF_VAR_telegram_bot_token}' "$EXAMPLE"
  [ "$status" -eq 0 ]
  run grep -qF '${TF_VAR_telegram_chat_id}' "$EXAMPLE"
  [ "$status" -eq 0 ]
}
```

**Step 2 — run, expect FAIL.**

```bash
bats tools/test/env-secrets-telegram.bats
# expect: the last two @tests fail (no '동일한 값' comment, no derive hint yet)
```

**Step 3 — minimal impl.** Edit `.env.secrets.example`. Replace the `⑤` block comment (lines 44-49) so it names the downstream consumer and the cross-link:

```bash
# ── ⑤ Telegram 봇 토큰 + chat_id (CI 알림용 — infra/github/secrets.tf가 소비) ──────
# 이 TF_VAR 쌍은 terraform(infra/github)이 GitHub Actions secret
#   TELEGRAM_BOT_TOKEN / TELEGRAM_CHAT_ID 로 올린다 (워크플로 알림이 이걸 읽음).
#   ⚠️ 절대 삭제 금지 — 지우면 CI Telegram 알림이 죽는다.
# ⑦(seed-secrets.sh가 읽는 동명 쌍)과 반드시 *동일한 값*이어야 한다.
#   같은 봇/같은 chat을 CI(Actions)와 클러스터(Alertmanager) 양쪽이 써야 하므로.
# 토큰: Telegram에서 @BotFather → /newbot → 토큰 복사
# chat_id: 만든 봇에게 아무 메시지 전송 후
#   https://api.telegram.org/bot<토큰>/getUpdates 에서 "chat":{"id":숫자} 복사
export TF_VAR_telegram_bot_token=""
export TF_VAR_telegram_chat_id=""
```

Then replace the `⑦` block (lines 61-63) so the seed pair derives from ⑤ by default (parameter expansion — one edit point, no drift), while still allowing an explicit override:

```bash
# ── ⑦ Telegram (seed-secrets.sh가 이 이름을 읽어 k8s SOPS 시크릿으로 봉인) ─────────
# ⑤와 *동일한 값*. 단일 출처를 위해 기본은 ⑤에서 파생시킨다(아래 확장).
# 다른 봇/chat을 쓸 특별한 이유가 없으면 이 두 줄을 그대로 두면 된다.
# (source 순서상 ⑤가 위에서 먼저 export되므로 확장이 채워진다.)
export TELEGRAM_BOT_TOKEN="${TF_VAR_telegram_bot_token}"
export TELEGRAM_CHAT_ID="${TF_VAR_telegram_chat_id}"
```

Note: this preserves the existing usage flow (`set -a; source .env.secrets; set +a`) — because `set -a` exports and ⑤ precedes ⑦ in file order, the `${TF_VAR_telegram_*}` expansions resolve at source time. `seed-secrets.sh:9-10` still sees populated `TELEGRAM_BOT_TOKEN`/`TELEGRAM_CHAT_ID`, and the `:?` guards still fire if ⑤ was left blank.

**Step 4 — run, expect PASS.**

```bash
bats tools/test/env-secrets-telegram.bats
# expect: 4/4 ok
```

**Step 5 — commit.** Korean conventional, no AI markers (use the `/commit` skill per repo convention).

```
docs: .env.secrets.example Telegram 이중 기재 동일성 명시 + 파생 기본값
```

### Task 2 — Wire the new gate into `make verify` is NOT needed; keep it in the dedicated bats sweep

`make verify` (Makefile:23-27) runs `tests/sops-roundtrip.bats` only; `tools/test/*.bats` run via the broader `bats tools/test/ infra/k3s-bootstrap/test/` sweep (per AGENTS.md core commands). The new `env-secrets-telegram.bats` lives under `tools/test/` so it is picked up by that sweep and by CI's bats job — no Makefile edit required. **Do not** add it to the `make verify` recipe (that target is scoped to skeleton + ledger + sops roundtrip).

If a directory-level run is used, confirm the new file is collected:

```bash
bats tools/test/   # expect: existing suites + env-secrets-telegram (4 ok) all green
```

### Task 3 — Final integration verification (plan content — DO NOT run now; this is the post-merge gate)

This task documents the acceptance gate for the whole Telegram-message-contract feature. It is the last thing to run after all upstream components (composite action, Alertmanager template, rules Korean, restore-drill notify) are merged. Author it as a checklist in the plan; execution is manual/CI, not part of authoring.

**3a — Repo gates green (CI + local).** Run from repo root:

```bash
make verify        # skeleton + 원장(conftest) + sops 라운드트립
bats tools/test/   # includes env-secrets-telegram.bats + the notify-lint gate from the composite-action component
make chart-test    # 공유 차트 렌더(영향 없음 확인 — Telegram 변경은 차트 밖)
```

Expect all green. The notify-structure lint (owned by the composite-action component) must assert, for every migrated site: `parse_mode=HTML` present, glyph in the allowed set (✅ 🔴 ⚠️ 🔵 ⚪), Korean (non-ASCII) title present, action link present. This component depends on that gate existing but does not author it.

**3b — KSOPS full render of victoria-stack succeeds.** The Alertmanager ConfigMap message template (`platform/victoria-stack/alertmanager.yaml`) and rules Korean annotations (`platform/victoria-stack/rules/core.yaml`, `r4-storage-backup.yaml`, `r6-ci-staleness.yaml`) must still render with secrets injected:

```bash
export SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt
kustomize build --enable-helm --enable-alpha-plugins --enable-exec \
  platform/victoria-stack | grep -c "parse_mode"
# expect: render exits 0; Alertmanager config block contains the HTML template (no Go-template syntax error)
```

Sanity-grep the rendered output for the contract markers (Korean title bytes, glyph) and confirm `image: prom/alertmanager:v0.27.0` is unchanged (no accidental v0.28 bump).

**3c — Documented manual post-merge Telegram smoke (run ONCE after ArgoCD syncs the new Alertmanager config).** This is operator-run against the live cluster, not CI. Per AGENTS.md, verification is via the failed-notification counter, NOT logs (the bot token lives in the init-rendered `alertmanager.yml` `bot_token_file`, not main-container env).

```bash
export KUBECONFIG=$PWD/infra/k3s-bootstrap/kubeconfig
# ⚠️ VM 컴포넌트(vmalert/vmsingle)·일부 prom 이미지는 distroless(wget/sh 없음 — AGENTS.md). 파드 내 exec
#    금지 → operator 호스트에서 `kubectl port-forward` + curl로 질의한다(교차검증 Pass6 Finding 2).
#    (executor: svc 이름/포트는 platform/victoria-stack/{vmalert,vmsingle}.yaml·alertmanager.yaml에서 확인)
cleanup_pf() { kill ${PF_VMA:-0} ${PF_AM:-0} ${PF_VM:-0} 2>/dev/null || true; }
trap cleanup_pf EXIT

# 0) 새 ConfigMap/규칙 반영: ConfigMap 변경은 자동 재시작 없음 → AM·vmalert 재시작.
kubectl -n observability rollout restart deploy/alertmanager deploy/vmalert
kubectl -n observability rollout status  deploy/alertmanager --timeout=120s
kubectl -n observability rollout status  deploy/vmalert      --timeout=120s

# 1) vmalert가 변경 규칙(한국어 annotation + AlertmanagerTelegramFailing)을 로드했는지 — 스모크는 AM에
#    직접 주입해 vmalert를 우회하므로 별도 확인(교차검증 Pass4 Finding 2). port-forward + curl.
kubectl -n observability port-forward svc/vmalert 8880:8880 >/dev/null 2>&1 & PF_VMA=$!
sleep 2
curl -fsS 'http://127.0.0.1:8880/api/v1/rules' > /tmp/rules.json     # AGENTS.md: groups는 400, rules OK
grep -q 'AlertmanagerTelegramFailing' /tmp/rules.json               # 신규 규칙 로드
! grep -oE '"lastError":"[^"]+"' /tmp/rules.json | grep -qv '"lastError":""'   # 규칙 파싱 에러 0
grep -q '정체\|포화\|초과\|불일치\|드리프트' /tmp/rules.json          # 한국어화 표본

# 2) 테스트 알림 1건 주입 — port-forward한 Alertmanager v2 API로(배열 페이로드, 한국어 annotation+runbook_url).
kubectl -n observability port-forward svc/alertmanager 9093:9093 >/dev/null 2>&1 & PF_AM=$!
sleep 2
curl -fsS -X POST http://127.0.0.1:9093/api/v2/alerts -H 'content-type: application/json' \
  --data-binary '[{"labels":{"alertname":"TelegramSmoke","severity":"warning"},
    "annotations":{"summary":"텔레그램 스모크 테스트","description":"배포 후 전송 경로 확인용 합성 알림","runbook_url":"https://home.example/runbook/smoke"}}]'
#   비2xx면 -f + set -e로 즉시 실패. 매핑 안 된 alertname도 summary가 한국어 제목으로, runbook_url이 → 링크로.

# 3) 텔레그램 수신 채널에서 메시지 1건 도착 확인(글리프 + <b>한글 제목</b> + → 링크).

# 4) 권위 검증(AGENTS.md): (a) AM 로컬 실패카운터 == 0, (b) vmsingle에 시계열 존재(=vmagent가
#    scrape 애너테이션 단 AM 파드를 실제 수집 중임을 증명 — 교차검증 Pass5 Finding 3).
curl -fsS 'http://127.0.0.1:9093/metrics' \
  | awk '/^alertmanager_notifications_failed_total\{.*integration="telegram".*\}/{print $2}' \
  | { read -r v; [ "${v:-0}" = "0" ]; } || { echo "telegram 실패 카운터 != 0"; exit 1; }
kubectl -n observability port-forward svc/vmsingle 8428:8428 >/dev/null 2>&1 & PF_VM=$!
sleep 2
curl -fsS 'http://127.0.0.1:8428/api/v1/query?query=alertmanager_notifications_total%7Bintegration%3D%22telegram%22%7D' \
  | grep -q '"result":\[{' || { echo "vmsingle에 AM telegram 시계열 없음 — scrape 애너테이션/vmagent 경로 점검"; exit 1; }
# (성공 카운터 alertmanager_notifications_total{integration="telegram"}는 스모크 1건만큼 증가했어야)
```

Acceptance: the injected `TelegramSmoke` 메시지가 계약 형식(`{glyph} <b>{한글 제목}</b> — {한글 상태}` … `→ {runbook_url}`)으로 도착하고 — 제목/본문은 한국어, `→` 링크는 주입한 `runbook_url`(`https://home.example/runbook/smoke`) — `alertmanager_notifications_failed_total{integration="telegram"} == 0`. 제목이 한국어가 아니거나 링크가 빠지면 AM Task 2 템플릿 결함이다(Task 6 렌더 e2e가 이미 사전 차단했어야 함). 결과는 로컬 전용 런북 `docs/runbooks/observability-verify.md`에 기록. 이후 합성 `TelegramSmoke` 알림을 resolve/expire.

**No commit** for 3a-3c — verification only. If 3b reveals a Go-template syntax error or 3c shows a nonzero failed counter, that is a defect in the Alertmanager-template component, not this one; fix there and re-run this gate.

---

## 실행 핸드오프

본 계획은 PR-first 단일 저위험 PR(브랜치 `feat/telegram-notifications`)로 실행한다. 컴포넌트 순서대로
TDD(실패 테스트 → 구현 → 통과 → 커밋)로 진행하고, 마지막에 `make verify` + KSOPS 풀 렌더 green을 확인한다.

실행 방식 2택(코드 작성 시작 시 선택):
1. **Subagent-Driven (현 세션)** — Task별 신선 subagent 디스패치 + Task 사이 코드 리뷰. (`superpowers:subagent-driven-development`)
2. **별도 세션** — 새 세션에서 `superpowers:executing-plans`로 체크포인트 배치 실행.

---

## Adversarial review dispositions (감사 추적)

> 사후 감사 기록(bookkeeping) — 승인 후 추가되었고 재리뷰 대상 아님. codex 적대 리뷰는 **계획**에 대해 6 pass 수행(모두 `ok:true`·`planInDiff:true`·codex 정상). 설계 단계의 다관점 비평(별도)으로 토픽 분리·v0.28 업그레이드·chat_id 마이그레이션은 plan 작성 전 이미 descope됨.

**Pass 1 — verdict: needs-attention (4건 전부 Accept):**
- KSOPS 렌더 게이트 CI-break → 평문 ConfigMap 직접 추출(KSOPS 미경유)로 CI-safe화.
- AM `message:` Go-template 미컴파일 → 컨테이너화 AM 렌더 e2e(Task 6) 신설.
- 12개 호출처 계약 게이트 부재 → `telegram-callsites.bats` 신설.
- 사후 스모크 셀렉터/계약 오류 → `app.kubernetes.io/name`·fixture·`|| true` 제거.

**Pass 2 — verdict: needs-attention (4건 전부 Accept):**
- 미매핑 alertname이 스모크 통과 불가 → 템플릿 fallback을 escape된 `.CommonAnnotations.summary`로.
- render-e2e "required"가 미강제 → 별도 잡 대신 required `gate` 잡 스텝으로.
- Watchdog annotation 거짓 Telegram 주장(매핑표) → dead-man 경로만 명시로 수정.
- composite action이 LINK 미escape → `LINK_E` + bats 케이스.

**Pass 3 — verdict: needs-attention (3건 전부 Accept):**
- checkout 이전 실패 미통지 → checkout 보장 명시(이후 Pass5에서 token-before-checkout 충돌 확인 → lean 조정).
- 호출처 개수 12가 아니라 13(bump.yaml 2) → 13·26 + 열거 게이트.
- e2e fixture가 v2 배열 아님 → 배열화 + 200 단언 + resolved 커버리지.

**Pass 4 — verdict: needs-attention (4건 Accept; #1·#4는 이후 descope):**
- Telegram-실패 알림 자기참조 → (full-resolution Task 4b 독립 채널 시도 → **Pass5 후 descope**).
- 스모크가 vmalert 우회 → vmalert `/api/v1/rules` 로드 검증 추가.
- render-e2e가 form 본문 미디코드 → `mock-telegram.py` content-type 디코드.
- checkout-실패 회귀 → (인라인 fallback 시도 → **Pass5 후 descope**).

**Pass 5 — verdict: needs-attention (4건 Accept; #1·#2·#4 descope-resolve, #3 적용):**
- 신규 secret 미물질화 → AM CrashLoop / checkout-first가 token-before-checkout과 충돌 / failsafe 복구 경로 없음 → **모두 Task 4b·인라인 fallback의 부작용**. 사용자 결정으로 lean 복귀(Task 4b·fallback·checkout-first 제거, 한계 명문화).
- 자기관측 검증이 잘못된 경로 → vmsingle 질의 + 값 단언으로 정밀화(적용).
- **메타: Pass4 "완전 해결" 추가분이 Pass5에서 신규 이슈 3건 유발 = 과설계 스파이럴. 승인 설계 비목표("no new secrets")까지 위반 → descope로 승인 설계 복귀.**

**Pass 6 — verdict: needs-attention (4건 전부 Accept, lean 상태 검증):**
- Watchdog 규칙 YAML 스니펫(매핑표와 별개)에 거짓 Telegram 주장 잔존 → 수정.
- 라이브 스모크가 distroless vmalert에서 `wget` exec → `kubectl port-forward` + curl로 전면 재작성.
- render-e2e가 한국어 **제목**을 미증명 + 맵에 영어 제목(`Pod OOMKill`·`ArgoCD OutOfSync`) → 제목 한국어화 + `<b>` 안 한글 단언.
- GH 호출처 영어 제목(`Cloudflare 적용`·`이미지 폴링`·`변이 실행`·`IaC 수렴` 등) → 한국어화 + 호출처 게이트에 제목 한글 단언.

**최종 상태 메모:** Pass 6 verdict는 `needs-attention`이었고 4건은 **Pass 6 이후** 반영됨(사용자가 "4건 반영 + 추가 리뷰 없이 finalize" 선택 — 기계적·핵심 목표 직결 수정). 즉 커밋된 계획은 Pass 6 verdict가 가리키던 결함을 모두 해소한 상태다. Rejected 0건(전 pass의 모든 plan-finding이 근거 충분). 설계 비평에서 기각된 2건(TF_VAR 제거=CI 파손이라 유지 / 정기-토픽 self-DoS=이미 failure-gated)은 plan에 반영하지 않음.
