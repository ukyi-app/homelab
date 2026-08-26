#!/usr/bin/env bash
# docs/traps.md enforcement 원장 드리프트 가드 — 원장이 '강제됐다'며 가리키는 guard 파일
# (백틱으로 감싼, 가드 확장자로 끝나는 경로)이 실재하는지 검사. 가드 파일이 삭제/리네임됐는데
# 원장이 enforced로 남아있는 거짓 안심을 차단(KD-4). doc-only 함정(guard 경로 없음)은 대상 아님.
# 인자로 원장 경로를 덮어쓸 수 있다(테스트용). 순수 파일 존재 검사 — 라이브 무관.
set -euo pipefail
# 프롤로그(LC_ALL=C·ROOT·scan-floor)는 guard_init(scripts/lib/guard.sh)이 소유한다.
# shellcheck source=scripts/lib/guard.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/guard.sh"
guard_init verify-traps
cd "$ROOT"

LEDGER="${1:-docs/traps.md}"
[ -f "$LEDGER" ] || { echo "verify-traps: $LEDGER 없음" >&2; exit 1; }

fail=0
# shellcheck disable=SC2016  # 백틱은 의도된 리터럴 매칭(명령 치환 아님)
paths="$(grep -oE '`[^`]+`' "$LEDGER" | tr -d '`' | grep -E '\.(bats|sh|ts|rego|mjs|ya?ml|json)$' | LC_ALL=C sort -u)"
while IFS= read -r p; do
  [ -n "$p" ] || continue
  [ -e "$p" ] || { echo "FAIL: 원장이 가리키는 가드 부재: $p"; fail=1; }
done <<< "$paths"

# 역방향 guard-path-tie(D3): traps-detail.md의 '> 가드:' 주석 경로가 원장(traps.md)에도 등장하는지.
# 위는 원장→가드파일 존재검사, 이건 SSOT(traps-detail.md) 가드주석→원장 추적 검사 — SSOT가 enforced라 단
# 가드를 원장이 안 따라가는 드리프트 차단. ★'> 가드:' 줄의 백틱 경로만 — 본문 prose 백틱(scripts/verify-traps.sh
# 등)은 비대상(F6: 원장 prose 경로를 SSOT에 요구하던 overbroad tie 회피).
DETAIL="${2:-docs/traps-detail.md}"
if [ -f "$DETAIL" ]; then
  # shellcheck disable=SC2016  # 백틱은 리터럴 매칭
  # ⚠️ `|| detail_guards=""`가 **필요하다** — `> 가드:` 줄이 0건이면 첫 grep이 rc=1이고 `set -o pipefail`
  #    아래에서 `set -e`가 **할당 단계에서** 스크립트를 죽인다. 그러면 아래 두 방향이 아예 실행되지
  #    않고 verify-traps가 **메시지 0줄에 rc=1**로 끝난다(무엇이 틀렸는지 알 수 없다).
  detail_guards="$(grep -E '^> 가드:' "$DETAIL" | grep -oE '`[^`]+`' | tr -d '`' | grep -E '\.(bats|sh|ts|rego|mjs|ya?ml|json)$' | LC_ALL=C sort -u)" || detail_guards=""
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    grep -Fq -- "$p" "$LEDGER" || { echo "FAIL: SSOT(traps-detail.md) 가드가 원장에 부재(드리프트): $p"; fail=1; }
  done <<< "$detail_guards"
fi

# 세 번째 방향(원장 행 → SSOT 섹션): 원장의 각 행이 가리키는 가드가 traps-detail.md의 어느
# `> 가드:` 줄에도 없으면, 그 행은 **SSOT에 서사가 없는 함정을 enforced로 주장**하는 것이다.
# 원장 머리말이 스스로 "traps-detail.md가 단일 SSOT이고 이 원장은 **그중** 강제된 것만 추적한다"고
# 선언하므로, 그 주장이 참이 아니면 원장이 거짓말을 한다.
# ⚠️ 위 두 방향은 이 갭을 **원리적으로 못 본다**: ①은 파일 실재만, ②는 SSOT→원장 방향만 본다.
#    실측 2026-08-21 도입 시점에 9행이 이 상태였다(SSOT에도 AGENTS 인덱스에도 없음).
# 면제는 `where` 열에 **사유와 함께 명시**한다 — 목록이 아니라 마커라 새 행에도 같은 규칙이 적용된다:
#   `SSOT없음(불변식)`   = 함정 서사가 아니라 불변식·규약을 지키는 가드다(SSOT에 들어갈 대상이 아니다)
#   `SSOT없음(승격대상)` = 함정인데 traps-detail 서사가 아직 없다(부채를 침묵시키지 않고 계상한다)
if [ -f "$DETAIL" ]; then
  while IFS= read -r row; do
    case "$row" in '|'*) : ;; *) continue ;; esac
    case "$row" in *'|---'*) continue ;; esac
    where="$(printf '%s' "$row" | awk -F'|' '{print $3}')"
    # shellcheck disable=SC2016  # 백틱은 의도된 리터럴 매칭(명령 치환 아님)
    guards="$(printf '%s' "$row" | awk -F'|' '{print $4}' | grep -oE '`[^`]+`' | tr -d '`' | grep -E '\.(bats|sh|ts|rego|mjs|ya?ml|json)$' || true)"
    [ -n "$guards" ] || continue
    case "$where" in *'SSOT없음('*) continue ;; esac
    hit=0
    while IFS= read -r g; do
      [ -n "$g" ] || continue
      printf '%s\n' "$detail_guards" | grep -Fqx -- "$g" && { hit=1; break; }
    done <<EOF
$guards
EOF
    if [ "$hit" -eq 0 ]; then
      title="$(printf '%s' "$row" | awk -F'|' '{print $2}' | cut -c1-72)"
      echo "FAIL: 원장 행이 SSOT(traps-detail.md)에 대응 '> 가드:' 없이 enforced를 주장한다: ${title}"
      echo "      → traps-detail.md에 섹션을 쓰고 '> 가드:'를 달거나, where 열에 SSOT없음(불변식)/SSOT없음(승격대상)을 사유로 명시하라."
      fail=1
    fi
  done < "$LEDGER"
fi

if [ "$fail" -ne 0 ]; then echo "verify-traps: 가드 드리프트 발견" >&2; exit 1; fi
echo "verify-traps: 원장 guard 실재 + SSOT↔원장 양방향 일치 OK"
