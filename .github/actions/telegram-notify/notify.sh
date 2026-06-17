#!/usr/bin/env sh
# 메시지 계약을 조립해 Telegram으로 best-effort 송신한다. DRY_RUN=1이면 text 페이로드를 stdout으로.
# POSIX 전용(bash-ism 금지) — sed/tr/printf만. ⚠️ '&'를 가장 먼저 이스케이프(엔티티 이중 이스케이프 방지).
set -eu

esc() { # HTML 이스케이프 — & 먼저
  printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'
}

# 상태 어휘 (글리프 + 한국어). 입력은 대소문자 무시.
s="$(printf '%s' "${STATUS:-}" | tr '[:upper:]' '[:lower:]')"
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

# 소스 라벨 enum 검증 — 멤버십 테스트(상수 haystack, 패턴에 변수): case subject가 상수인 게 의도.
# shellcheck disable=SC2194
case " 알림 복원드릴 앱생성 DB생성 캐시생성 시크릿갱신 해체 배포 온보딩 IaC IaC수렴 IaC드리프트 감사 이미지폴링 변이 " in
  *" ${SOURCE:-} "*) : ;;
  *) echo "telegram-notify: unknown source '${SOURCE:-}'" >&2; exit 2 ;;
esac

# teardown 라벨: app/resource 중 비어있지 않은 쪽만 ident로
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
