#!/usr/bin/env bash
# 자격 인벤토리 드리프트 로컬 가드 — 런북 `token-inventory.md` §A 표 ↔ `policy/credential-expiry.json`.
#
# 병(실측 2026-08-21): 원장에는 `github-tf-ci-pat`(⑮)·`r2-terraform-state`(⑯)가 PR #511/#517로
# 들어갔는데, 런북 §A 표는 **3건인 채로 남아 있었다.** 두 행이 통째로 빠져 있었고 아무도 못 잡았다 —
# 런북이 gitignored라 CI 게이트의 도메인 밖이고, `check-credential-expiry.sh`는 원장 **안**만 본다
# (그 파일 헤더가 이미 그 한계를 고백해 두었다). 즉 **자격증명 인벤토리가 두 곳에 있는데 어느 쪽도
# 다른 쪽을 대조하지 않는 상태**였다. 자격은 조용히 사라지면 안 되는 종류의 자산이다.
#
# ⇒ 런북은 owner 머신에만 있으므로 이 가드도 **로컬 전용**이다. 부재는 실패가 아니라 **SKIP 신호**
#   (exit 4 + `SKIP:` 마커 — CONTRIBUTING 규약). exit 0은 "실제로 대조했고 정합"이라는 뜻이고,
#   부재로 건너뛴 것과 **절대 같은 종료코드를 쓰지 않는다.** 선례: `scripts/verify-runbook-index.sh`.
#
# 검사 방향 3가지(전부 fail-closed):
#   ① §A 표의 `원장 name` → 원장에 실재  (표에 있는데 원장에 없다 = 원장이 자격을 잃어버렸다)
#   ② 원장 name → §A 표에 실재            (원장에 있는데 표에 없다 = 2026-08-21에 실제로 난 사고)
#   ③ §현재 원장 상태의 "N건 등재" 수치 == 원장 항목 수
#      ⚠️ 이 레포는 손 관리 수치를 금지한다. 그런데 런북은 사람이 읽는 문서라 그 수치가 있는 편이
#         낫다 — 그러면 **기계가 대조**하게 만드는 것이 답이다(수치를 지우는 것이 아니라).
# bash 3.2 호환(mapfile 금지). shellcheck 클린. ⚠️ 정렬은 전부 `LC_ALL=C`(#514).
set -euo pipefail
# 프롤로그(LC_ALL=C·ROOT·scan-floor)는 guard_init(scripts/lib/guard.sh)이 소유한다.
# shellcheck source=scripts/lib/guard.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/guard.sh"
guard_init verify-credential-inventory
# 바닥값 오버라이드는 공용 어휘 `--floor <도메인>=<n>`뿐이다(kernel-followups 03 — 구 env 폐지).
# (이관 전 --floor는 위치 인자라 런북 경로로 오인돼 SKIP이 났다 — 리뷰 실측. 커널이 먼저 걷는다.)
take_floors "verify-credential-inventory:ledger verify-credential-inventory:runbook" "$@" || exit $?
set -- "${REST_ARGV[@]+"${REST_ARGV[@]}"}"
cd "$ROOT"

RB="${1:-$ROOT/docs/runbooks/token-inventory.md}"
LEDGER="${2:-$ROOT/policy/credential-expiry.json}"

# skip 방출(마커+exit 4 원자)은 guard_skip(scripts/lib/guard.sh)이 소유한다 — 짝 규약은 그 구현 줄이 진다.
if [ ! -f "$RB" ]; then guard_skip verify-credential-inventory "${RB#"$ROOT/"} 부재(gitignored 로컬 전용) — 인벤토리 대조를 하지 못했다"; fi
[ -f "$LEDGER" ] || {
  echo "FAIL: verify-credential-inventory: 원장 ${LEDGER#"$ROOT/"} 부재 — 대조 대상이 없다." >&2
  exit 1
}

# ── 원장 name 슬러그(첫 공백 앞) ────────────────────────────────────────────────────────
# 원장의 name은 `<슬러그> (<괄호 설명>)` 형태다. 표가 참조하는 것은 그 슬러그다.
# ⚠️ jq를 쓴다 — 종전에는 python heredoc이었는데 CONTRIBUTING.md 「새 코드 배치 규칙」이
#    셸 heredoc의 제3 언어 내장을 명시적으로 금지한다(typecheck·lint 사각). 이 블록은 순수 JSON
#    순회라 규칙이 셸에 배정한 jq 필터가 정확한 자리다. 2026-09-01 이관 — 산출물 동일 검증.
led_names="$(jq -r 'if type != "array" then ("원장이 배열이 아니다" | halt_error(1)) else .[] | ((.name // "") | tostring | split(" ")[0]) end' "$LEDGER")" \
  || { echo "FAIL: verify-credential-inventory: 원장 파싱 실패 — 판정 불가는 '통과'가 아니다." >&2; exit 1; }
led_sorted="$(printf '%s\n' "$led_names" | grep -c . >/dev/null && printf '%s\n' "$led_names" | LC_ALL=C sort -u)"
led_n="$(scan_count "$led_names")"

# ── 런북 §A 표의 `원장 name` 열(2열) ────────────────────────────────────────────────────
# 헤더 `| # | 원장 name |`로 표를 특정한다(같은 문서의 §B 표는 헤더가 달라 섞이지 않는다).
# ⚠️ 열을 **앞에서**(`$3`) 센다 — traps-f-4(a96d7dd)의 「임베디드 `|`가 열을 미는」 클래스와
#    달리, 이 열 앞에는 `#`(원 안 숫자) 열 하나뿐이다. 계약: **`#` 열에 리터럴 `|`를 넣지 않는다**
#    (원 안 숫자 유니코드 기호뿐이라 원리적으로 불가능 — 뒤 열(발급처·스코프·보관 위치 등)이
#    아무리 길고 `|`를 담아도 대상 열 **뒤**라 이 추출에 영향이 없다). 앞선 열이 위험해지면
#    (예: `#` 열에 자유 텍스트가 들어오면) 뒤에서 세는 형태로 바꿀 것.
rb_names="$(awk -F'|' '
  /^\| # \| 원장 name \|/ { intab=1; next }
  intab && /^\|---/ { next }
  intab && !/^\|/    { intab=0 }
  intab { gsub(/^[ \t`]+|[ \t`]+$/, "", $3); if ($3 != "") print $3 }
' "$RB")"
rb_sorted="$(printf '%s\n' "$rb_names" | LC_ALL=C sort -u)"
rb_n="$(scan_count "$rb_names")"

# 열거 붕괴 방어 — 어느 쪽이든 0건이면 아래 대조가 vacuous하게 통과한다.
scan_floor verify-credential-inventory:ledger "$led_n" "$(floor_of verify-credential-inventory:ledger 3)" || exit 1
scan_floor verify-credential-inventory:runbook "$rb_n" "$(floor_of verify-credential-inventory:runbook 3)" || exit 1

fail=0
# ① 표 → 원장
while IFS= read -r n; do
  [ -n "$n" ] || continue
  grep -Fqx -- "$n" <<<"$led_sorted" || {
    echo "FAIL: 런북 §A 표에 있으나 원장에 없다: ${n} — 원장이 자격을 잃어버렸거나 이름이 갈렸다."
    fail=1
  }
done <<EOF
$rb_sorted
EOF
# ② 원장 → 표  (2026-08-21에 실제로 난 사고의 방향이다)
while IFS= read -r n; do
  [ -n "$n" ] || continue
  grep -Fqx -- "$n" <<<"$rb_sorted" || {
    echo "FAIL: 원장에 있으나 런북 §A 표에 없다: ${n} — 원장에 행을 더한 PR이 표를 같이 갱신하지 않았다."
    fail=1
  }
done <<EOF
$led_sorted
EOF

# ③ "N건 등재" 수치 ↔ 원장 항목 수
declared="$(grep -oE '\*\*[0-9]+건\*\* 등재' "$RB" | head -1 | grep -oE '[0-9]+' || true)"
if [ -n "$declared" ]; then
  [ "$declared" -eq "$led_n" ] || {
    echo "FAIL: 런북이 '${declared}건 등재'라 적었는데 원장은 ${led_n}건이다 — 아무도 대조하지 않는 손 관리 수치가 드리프트했다."
    fail=1
  }
else
  echo "FAIL: 런북 §현재 원장 상태에서 '**N건** 등재' 수치를 찾지 못했다 — 형식이 바뀌었다면 이 가드도 함께 고쳐라(찾지 못한 것을 정합으로 읽지 않는다)."
  fail=1
fi

[ "$fail" -eq 0 ] || { echo "verify-credential-inventory: 인벤토리 드리프트 발견" >&2; exit 1; }
echo "verify-credential-inventory: 런북 §A ↔ 원장 양방향 정합 + 수치 일치 OK (${led_n}건)"
