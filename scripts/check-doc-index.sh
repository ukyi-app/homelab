#!/usr/bin/env bash
# 디렉토리 인덱스 드리프트 가드 — 두 레인.
#
#   [1] **등재** — scripts/·tools/·.github/workflows/ 의 각 산출물이 해당 README에 문자열로 등재됐는지
#       검사(가드 없는 인덱스 드리프트 소멸). check-skeleton.sh(디렉토리 지도)·verify-runbook-index.sh
#       (런북 인덱스)와 동일 불변식.
#   [2] **스코프** — scripts/README.md의 **가드 bullet**이 계산 가능한 사실을 주장하지 않는지 검사.
#       병(2026-08-29 실측): 가드의 실행 경로는 tools/check-guard-authority.ts가 venue에서 계산하는데,
#       README는 그 계산을 손으로 베낀 사본을 들고 있었다. 사본은 드리프트했다 — 「CI 게이트」 절 26개
#       항목 중 12곳이 틀렸고(11곳은 비권위 mirror를 권위처럼, sops-guard.sh는 정반대 방향으로),
#       4곳은 한 글자도 적지 않았다. 나머지 두 절에도 mirror 주장이 6곳 더 있었다.
#
# ⚠️ **스코프는 가드 bullet뿐이다.** 권위 계산의 도메인은 repo-walk.ts의 `guards` 스코프
#    (`check-*`/`verify-*` 접두 · `-guard`/`-check` 접미)이고, bootstrap.sh·dr-drill.sh·teardown.sh
#    같은 비-가드 스크립트는 **그 밖**이다 — 그것들의 실행 경로를 계산하는 것이 레포에 없으므로
#    README가 SSOT이고, 지우면 정보 손실이 0이 아니다(리뷰 실측: 삭제된 문장의 절반이 이 부류였다).
#    여기 있는 이름 모양 판정은 그 스코프의 사본이므로 **게이트가 권위 도구와 등식으로 대조한다**
#    (tests/gates/test_check-doc-index.bats — 손 사본을 남기되 대조되지 않게 두지는 않는다).
# ⚠️ 판정 단위는 **bullet**이지 절이 아니다. 「## CI 게이트」 절 스코프 hard-zero는 절 이름을 바꾸기만
#    하면 통째로 우회되고, 그때 red는 나지 않는다 — 무증인 초록이야말로 이 가드가 닫는 병소 형태다.
#    그래서 `- **` bullet 전건 + **bullet 밖 산문**까지 본다(헤더·절 사이 텍스트에도 출구를 두지
#    않는다). 절 제목은 추출 단위가 아니라 부류 라벨일 뿐이다.
# ⚠️ **판정 선은 두 어휘의 합집합이다.** 옛 판정은 서술어 리터럴 6개였고, base README 자신의 표기
#    8곳이 그 밖이었다(「이 **공통** 호출」·「가 게이트」·「가 픽스처+실-레포로 가드」 — 리뷰가 실측:
#    손으로 지운 문장을 되돌려도 초록이었다). 서술어는 무한히 바꿔 쓸 수 있으므로 그쪽만 닫는 것은
#    말바꾸기 경주다. 그래서 **닫힌 쪽을 문다**:
#      · VENUE — 실행 경로 주장은 **venue를 지목하지 않고는 성립하지 않는다**. venue 종류는
#        check-guard-authority가 소유하는 닫힌 집합이다(ci.yaml gate 스텝 · gate 수집 bats ·
#        스케줄 워크플로 · make 타깃 · bun run 별칭). 이쪽이 주력이다.
#      · REL — venue 이름 없이 서는 주장(「배선 없음」·「직접 실행」·「진입점은」)을 받는 보조 어휘.
#    **합집합이지 접속사 조건이 아니다** — 둘 중 하나만 걸려도 red다(접속사로 묶으면 레인이 vacuous
#    해지는 자리를 형제 가드 check-host-ports가 이미 실측했다).
#    매칭은 ERE가 아니라 awk index() **리터럴**이다 — leftmost-longest 사고와 셸→awk 이스케이프
#    4층 드리프트를 원천 배제한다(형제 가드들이 반복해 밟은 자리).
# ⚠️ [2]는 **부재 단언**이라 양성 대조 없이는 조용히 무증인이 된다. 두 겹으로 막는다:
#      ① 추출 바닥값(scan_floor) — bullet 0건은 "위반 0"이 아니라 열거 붕괴다.
#      ② **비-가드 bullet이 상시 양성 대조다** — 그것들은 실행 경로를 적는 것이 계약이므로 두 어휘가
#         실제로 무는 문장을 상시 담고 있다. 어휘가 깨지면 그 히트 수가 무너져 red가 된다. 즉
#         "검출기가 죽은 채로 위반 0"이 나올 수 없다. (개별 리터럴 하나하나의 부하는 게이트 bats가
#         진다 — 라이브 대조는 어휘 **단위**까지만 증인이다.)
# 순수 파일/문자열 검사(CI-safe). bash 3.2 안전(glob 루프, 배열 미사용).
set -euo pipefail
# 프롤로그(LC_ALL=C·ROOT·scan-floor)는 guard_init(scripts/lib/guard.sh)이 소유한다.
# shellcheck source=scripts/lib/guard.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/guard.sh"
guard_init check-doc-index
cd "$ROOT"
BT='`'   # 백틱 리터럴(명령치환 회피)
rc=0

# ── 레인 [2]의 레지스트리 상수 ────────────────────────────────────────────────────────────────
# 면제 상한 — 형제 처방을 그대로 가져온다(scripts/check-bats-accounting.sh의 BATS_EXCLUDE_MAX ·
# tests/.ci-exclude). ① 면제 bullet은 마커와 함께 **왜 계산이 못 보는지**를 적어야 하고 ② 건수에
# 상한이 있다. 오늘 실측 **0** — 스코프가 가드 bullet으로 좁혀지면서 옛 면제 3건(호스트 systemd가
# 실행자인 스크립트들)이 전부 비-가드로 판명돼 면제 자체가 필요 없어졌다. 늘리려면 같은 PR에서 이
# 숫자를 올려야 하고, 그건 리뷰에 보인다.
# ⚠️ 래칫이 아니라 **상한**이다. 0은 "면제 기계가 죽었다"가 아니라 "정당한 면제가 아직 없다"이고,
#    기계 자체는 게이트 bats의 픽스처가 매번 밟는다.
README_EXEMPT_MAX=0
# 추출 바닥값. 기본 모드는 실측(2026-08-29 = 42)에 여유를 둔 값 — 바닥값은 래칫이 아니므로
# 정당한 삭제를 red로 만들지 않을 만큼 낮게, 정규식이 깨진 붕괴는 반드시 잡을 만큼 높게 잡는다.
# 픽스처 모드는 1: 픽스처가 아무리 작아도 **0건은 언제나 붕괴**다(그 자리가 vacuous green의 입구다).
README_BULLET_FLOOR=35
README_FIXTURE_FLOOR=1
# 양성 대조 바닥값 — 비-가드 bullet 중 각 어휘가 실제로 무는 건수. 실측(2026-08-29): VENUE 10 ·
# REL 16(비-가드 bullet 18건 기준). 어휘 리터럴이 깨지거나 비-가드 문장이 통째로 지워지면 여기서
# 죽는다. 바닥값은 래칫이 아니므로 실측의 절반 언저리에 둔다 — 정당한 축소는 통과시키고, 어휘
# 붕괴(→ 0)는 반드시 잡는다.
README_WITNESS_VENUE_FLOOR=5
README_WITNESS_REL_FLOOR=8

# ── 인자 ──────────────────────────────────────────────────────────────────────────────────────
# `--readme <파일>`은 레인 [2]만 보는 픽스처 모드다(형제: check-bats-accounting `--lint-excludes`).
# ⚠️ 그 외 인자는 exit 2 — 맨 인자로 레인을 끄는 off-switch를 두지 않는다.
README_FILE="scripts/README.md"
BULLET_FLOOR="$README_BULLET_FLOOR"
SCOPE_ONLY=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --readme)
      README_FILE="${2-}"
      if [ -z "$README_FILE" ]; then
        echo "--readme <파일>이 필요하다" >&2
        exit 2
      fi
      BULLET_FLOOR="$README_FIXTURE_FLOOR"
      SCOPE_ONLY=1
      shift 2 ;;
    *)
      echo "사용법: check-doc-index.sh [--readme <파일>]" >&2
      exit 2 ;;
  esac
done

# ── 레인 [1] 등재 ─────────────────────────────────────────────────────────────────────────────
if [ "$SCOPE_ONLY" -eq 0 ]; then
  # scripts/*.sh ↔ scripts/README.md (백틱 감싼 파일명 — README 규약)
  for f in scripts/*.sh; do
    b="$(basename "$f")"
    grep -Fq "${BT}${b}${BT}" scripts/README.md || { echo "FAIL: scripts/README.md 미등재: $b"; rc=1; }
  done

  # tools/*.ts·*.mts ↔ tools/README.md (스키마 .json은 표로 별도 문서화 → 제외)
  for f in tools/*.ts tools/*.mts; do
    [ -e "$f" ] || continue
    b="$(basename "$f")"
    grep -Fq "${BT}${b}${BT}" tools/README.md || { echo "FAIL: tools/README.md 미등재: $b"; rc=1; }
  done

  # .github/workflows/*.yaml ↔ workflows README (친화명 표기라 basename 존재검사)
  # ⚠️ 거친 검사: prose 언급도 통과(build은 'build 완료'에 이미 등장). 제로-언급 신규 워크플로 차단이 목적.
  for f in .github/workflows/*.yaml; do
    b="$(basename "$f" .yaml)"
    grep -Fq "$b" .github/workflows/README.md || { echo "FAIL: workflows README 미등재: ${b}.yaml"; rc=1; }
  done
fi

# ── 레인 [2] scripts/README.md 스코프 계약 ────────────────────────────────────────────────────
# 검출기는 detect_run(guard.sh) 경유 — rc 포착 · 읽기 프리체크 · READFILES 열거수 대조까지 커널이
# 진다(`findings="$(awk … || true)"`가 검출기 사망을 "0곳 OK"로 바꾸던 fail-open의 봉쇄).
# shellcheck disable=SC2016  # awk 프로그램이다 — `$0`는 셸이 아니라 awk가 해소한다(단일 인용 의도).
README_DETECT='
FNR == 1 { nfiles++ }
function starts(s, p) { return substr(s, 1, length(p)) == p }
function ends(s, p)   { return length(s) >= length(p) && substr(s, length(s) - length(p) + 1) == p }
function base(s,   i) { while ((i = index(s, "/")) > 0) s = substr(s, i + 1); return s }
# 가드 이름 모양 — SSOT는 tools/lib/repo-walk.ts의 `guards` 스코프이고, 이 사본은 게이트 bats가
# 권위 도구의 리포트와 등식으로 대조한다(사본을 두되 대조되지 않게 두지 않는다).
function isguard(n) {
  n = base(n)
  if (ends(n, ".sh")) return (starts(n, "check-") || starts(n, "verify-") || ends(n, "-guard.sh") || ends(n, "-check.sh"))
  if (ends(n, ".ts")) return (starts(n, "check-") || starts(n, "verify-"))
  return 0
}
function hits(text, A, n,   i) { for (i = 1; i <= n; i++) if (index(text, A[i]) > 0) return 1; return 0 }
function flushb(   hv, hr, ex, name) {
  if (cur == "") return
  name = cur; gsub(/`/, "", name)
  hv = hits(buf, VEN, nv)
  hr = hits(buf, REL, nr)
  ex = (index(buf, MARK) > 0)
  if (isguard(name) == 0) {
    # 비-가드 = 스코프 밖이자 **양성 대조**. 계산원이 없으므로 실행 경로는 이 bullet이 소유한다.
    nng++
    if (hv == 1) wv++
    if (hr == 1) wr++
    if (ex == 1)
      printf "FAIL\t%d\t%s\t면제가 필요 없다 — 가드가 아니라서 실행 경로를 여기 적는 것이 계약이다\n", bl, cur
    cur = ""; buf = ""; return
  }
  ngb++
  if (ex == 1) {
    nex++
    if (index(buf, WHY) == 0)
      printf "FAIL\t%d\t%s\t면제에 사유가 없다 — 「%s」로 시작하는 설명을 같은 bullet에 적어라\n", bl, cur, WHY
    if (hv == 0 && hr == 0)
      printf "FAIL\t%d\t%s\t죽은 면제 — 면제할 주장이 bullet에 없다(상한만 잡아먹는다)\n", bl, cur
  } else if (hv == 1 || hr == 1) {
    printf "FAIL\t%d\t%s\t계산 가능한 실행 경로 주장 — 지우거나 면제로 등재하라\n", bl, cur
  }
  cur = ""; buf = ""
}
BEGIN {
  # VENUE — 계산이 소유하는 venue 종류. 주장은 이 이름들을 지목하지 않고는 성립하지 않는다.
  # bats는 `tests/` 접두까지 요구한다: 접두 없는 `test_*.bats`는 가드가 **검사 대상**으로 말하는
  # 도메인 어휘라(check-bats-accounting) venue 지목과 구별해야 한다.
  VEN[1] = "make "; VEN[2] = "ci.yaml"; VEN[3] = "bun run "
  VEN[4] = "tests/gates/test_"; VEN[5] = "tests/test_"; nv = 5
  # REL — venue 이름 없이 서는 관계 주장. 도메인 산문과 겹치는 맨 명사(「가드」·「게이트」·「배선」·
  # 「호출자」)는 넣지 않는다 — 주어 표지를 붙인 술어형만 쓴다(실측: 맨 「가드」는 현 README에서
  # 14줄, 맨 「배선」은 check-app-deploy의 「봉인 배선」을 오탐한다).
  REL[1] = "가 호출"; REL[2] = "이 호출"; REL[3] = "호출 아님"; REL[4] = "가 부른"; REL[5] = "이 부른"
  REL[6] = "배선됨"; REL[7] = "배선 아님"; REL[8] = "배선 없"; REL[9] = "배선되어"
  REL[10] = "진입점"; REL[11] = "실행자"; REL[12] = "밟는"; REL[13] = "직접 실행"
  REL[14] = "가 게이트"; REL[15] = "이 게이트"; REL[16] = "가 가드"; REL[17] = "이 가드"
  REL[18] = "중계"; REL[19] = "source한"; nr = 19
  MARK = "[계산-밖]"; WHY = "왜 계산이 못 보는가"
  nb = 0; nex = 0; ngb = 0; nng = 0; wv = 0; wr = 0
  cur = ""; buf = ""; prose = ""; nfiles = 0
}
/^- \*\*/ { flushb(); nb++; cur = $0; sub(/^- \*\*/, "", cur); sub(/\*\*.*/, "", cur); buf = $0; bl = FNR; next }
/^## /    { flushb(); prose = prose "\n" $0; next }
          { if (cur == "") prose = prose "\n" $0; else buf = buf "\n" $0 }
END {
  flushb()
  # bullet 밖 산문은 스크립트에 붙지 않으므로 가드/비-가드로 갈 수 없다 — 두 어휘 전건 hard-zero다.
  for (i = 1; i <= nv; i++)
    if (index(prose, VEN[i]) > 0) {
      printf "FAIL\t0\t(bullet 밖 산문)\tvenue 지목 「%s」 — 면제는 bullet 단위라 헤더·절 사이엔 출구가 없다\n", VEN[i]
      break
    }
  for (i = 1; i <= nr; i++)
    if (index(prose, REL[i]) > 0) {
      printf "FAIL\t0\t(bullet 밖 산문)\t관계 주장 「%s」 — 면제는 bullet 단위라 헤더·절 사이엔 출구가 없다\n", REL[i]
      break
    }
  printf "BULLETS\t%d\n", nb
  printf "EXEMPT\t%d\n", nex
  printf "GUARDB\t%d\n", ngb
  printf "NONGUARDB\t%d\n", nng
  printf "WVENUE\t%d\n", wv
  printf "WREL\t%d\n", wr
  printf "READFILES=%d\n", nfiles > "/dev/stderr"
}
'

findings="$(detect_run check-doc-index:readme "$README_DETECT" "$README_FILE")"
field() { printf '%s\n' "$findings" | awk -F'\t' -v K="$1" '$1 == K { print $2 }'; }
bullets="$(field BULLETS)"
exempt="$(field EXEMPT)"
guardb="$(field GUARDB)"
wvenue="$(field WVENUE)"
wrel="$(field WREL)"
# 검출기가 끝까지 돌지 않았으면 "위반 0"이 아니다 — 판정 불가는 통과가 아니다.
for n in "$bullets" "$exempt" "$guardb" "$wvenue" "$wrel"; do
  case "$n" in ''|*[!0-9]*) echo "FAIL: ${README_FILE}: 검출기가 집계를 보고하지 않았다."; exit 1;; esac
done

viol="$(printf '%s\n' "$findings" | awk -F'\t' -v F="$README_FILE" \
        '$1 == "FAIL" { printf "  %s:%s  %s — %s\n", F, $2, $3, $4 }')"
if [ -n "$viol" ]; then
  echo "FAIL: ${README_FILE}: 스코프 계약 위반 — 가드의 실행 경로는 tools/check-guard-authority.ts가 계산한다:"
  printf '%s\n' "$viol"
  echo "  확인: bun tools/check-guard-authority.ts --json"
  rc=1
fi

if [ "$exempt" -gt "$README_EXEMPT_MAX" ]; then
  echo "FAIL: ${README_FILE}: 면제 ${exempt}건 > 상한 ${README_EXEMPT_MAX} — 면제는 부채다."
  echo "  정당한 면제라면 이 상한(scripts/check-doc-index.sh의 README_EXEMPT_MAX)을 같은 PR에서 올려라."
  rc=1
fi

# 바닥값·마커는 **검출 뒤**다 — 마커는 "열거·판정을 실제로 마쳤다"는 뜻이라, 붕괴한 실행이 내면
# 소비자가 정반대로 읽는다(check-floor-vocab 레인 P가 이 순서를 정적으로 강제한다).
scan_floor check-doc-index:readme-bullets "$bullets" "$BULLET_FLOOR" || rc=1

# 양성 대조 — 실 README에서만 잰다(픽스처는 이 분포를 가질 이유가 없다). 두 어휘가 비-가드 bullet을
# 실제로 물고 있어야 "가드 bullet 위반 0"이 의미를 갖는다.
if [ "$SCOPE_ONLY" -eq 0 ]; then
  scan_floor check-doc-index:witness-venue "$wvenue" "$README_WITNESS_VENUE_FLOOR" || rc=1
  scan_floor check-doc-index:witness-rel   "$wrel"   "$README_WITNESS_REL_FLOOR"   || rc=1
fi

if [ "$rc" -eq 0 ]; then
  if [ "$SCOPE_ONLY" -eq 0 ]; then
    echo "check-doc-index: scripts·tools·workflows 인덱스 정합 OK · README 스코프 OK (bullet ${bullets}건 / 가드 ${guardb}건, 면제 ${exempt}건)"
  else
    echo "check-doc-index: ${README_FILE} 스코프 OK (bullet ${bullets}건 / 가드 ${guardb}건, 면제 ${exempt}건)"
  fi
fi
exit "$rc"
