#!/usr/bin/env bats
# verify-traps.sh — 함정 원장 3종의 **4방향** 드리프트 가드.
#   ① 원장의 guard 경로가 실재하는가(삭제/리네임 드리프트 — KD-4)
#   ② traps-detail.md의 '> 가드:' 주석이 원장에 추적되는가(SSOT → 원장)
#   ③ 원장의 각 행이 SSOT의 '> 가드:' 줄에 대응하는가(원장 → SSOT). ①②는 이 갭을 원리적으로 못 본다.
#   ④ SSOT 섹션 헤드라인 ↔ AGENTS.md 한줄 인덱스의 **완전 일치**(개수 등식 포함).
# ⚠️ **argc 규약: 0(실 트리) 또는 3(원장·SSOT·인덱스 트리플).** 부분 지정은 exit 2다 — 일부만
#    픽스처로 바꾸면 남은 하나가 실 트리라 그 방향이 의도하지 않은 이유로 판정되고, 유일한 회피가
#    "그 방향을 argc로 끄기"인데 그것이 이 가드가 닫은 fail-open 그 자체다(가드 헤더가 논증한다).
#    ⇒ 아래 픽스처 레인은 전부 트리플을 넘긴다. 인덱스 픽스처는 그 레인의 SSOT 헤드라인과 짝이 맞아야
#    한다 — 안 맞으면 방향 ④가 먼저 물어 레인이 의도한 방향이 아닌 이유로 red가 된다.
# ⚠️ 중간 단언은 [ ]만 — bash 3.2 [[ ]] 침묵 통과.

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"; cd "$ROOT" || exit 1
  TMP="$(mktemp -d)"
}
teardown() { rm -rf "$TMP"; }

# 픽스처 인덱스 — 인자로 받은 헤드라인들을 AGENTS.md의 절 형식으로 적는다. 방향 ④가 SSOT 픽스처와
# 짝을 이뤄야 하므로, 각 레인은 자기 detail의 '### ' 줄과 **같은 텍스트**를 여기 넘긴다.
_mkindex() {
  out="$1"; shift
  { echo '## 라이브에서 검증된 함정'; for h in "$@"; do echo "- $h"; done; echo '## 다음 절'; } > "$out"
}

@test "verify-traps passes — ledger guards exist + SSOT guard annotations tracked (reverse tie)" {
  run bash scripts/verify-traps.sh
  [ "$status" -eq 0 ]
  echo "$output" | grep -Fq "실재 + SSOT"   # 3방향 전부 통과
}

@test "direction 3 flags a ledger row that claims enforcement with no SSOT narrative behind it" {
  # ★ 실측 2026-08-21 도입 시점에 원장 9행이 이 상태였다 — SSOT에도 AGENTS 인덱스에도 없이
  #   `gate` enforced를 주장했다. ①은 파일 실재만, ②는 반대 방향만 보므로 둘 다 침묵한다.
  printf '| 함정 | where | guard |\n|---|---|---|\n| 서사 없는 함정 | gate | `scripts/verify-traps.sh` |\n' > "$TMP/orphan.md"
  # ⚠️ 픽스처 detail에는 '> 가드:'를 두지 않는다 — 두면 방향 ②(SSOT→원장)가 먼저 물어 이 레인이
  #   **의도한 방향이 아닌 이유로** 판정된다(레인이 초록/빨강이어도 무엇을 쟀는지 알 수 없다).
  printf '### 다른 함정\n- 본문\n' > "$TMP/detail.md"
  _mkindex "$TMP/index.md" '다른 함정'
  run bash scripts/verify-traps.sh "$TMP/orphan.md" "$TMP/detail.md" "$TMP/index.md"
  [ "$status" -ne 0 ]
  echo "$output" | grep -Fq "SSOT(traps-detail.md)에 대응"
}

@test "direction 3 accepts an explicitly declared exemption, and only in the where column" {
  # 면제는 **사유 마커**여야 한다 — 하드코딩 파일 목록이면 새 행이 그 목록 밖에서 태어난다.
  printf '| 함정 | where | guard |\n|---|---|---|\n| 불변식 가드 | gate · SSOT없음(불변식) | `scripts/verify-traps.sh` |\n' > "$TMP/ok.md"
  # ⚠️ 픽스처 detail에는 '> 가드:'를 두지 않는다 — 두면 방향 ②(SSOT→원장)가 먼저 물어 이 레인이
  #   **의도한 방향이 아닌 이유로** 판정된다(레인이 초록/빨강이어도 무엇을 쟀는지 알 수 없다).
  printf '### 다른 함정\n- 본문\n' > "$TMP/detail.md"
  _mkindex "$TMP/index.md" '다른 함정'
  run bash scripts/verify-traps.sh "$TMP/ok.md" "$TMP/detail.md" "$TMP/index.md"
  [ "$status" -eq 0 ]
  # 음성 대조 — 마커를 guard 열에 적으면 면제되지 않는다(엉뚱한 열에 적어 통과하는 것을 막는다).
  printf '| 함정 | where | guard |\n|---|---|---|\n| 잘못된 위치 | gate | `scripts/verify-traps.sh` SSOT없음(불변식) |\n' > "$TMP/wrong.md"
  run bash scripts/verify-traps.sh "$TMP/wrong.md" "$TMP/detail.md" "$TMP/index.md"
  [ "$status" -ne 0 ]
}

@test "an SSOT with no guard annotations at all does not kill the script silently" {
  # ★ 예전엔 `> 가드:` 0건이면 pipefail 아래 할당이 실패해 set -e가 **메시지 0줄에 rc=1**로 죽였다.
  #   판정 불가가 아니라 **무엇이 틀렸는지 말하지 않는 실패**라 진단이 통째로 사라진다.
  printf '| 함정 | where | guard |\n|---|---|---|\n| 면제된 행 | gate · SSOT없음(불변식) | `scripts/verify-traps.sh` |\n' > "$TMP/led.md"
  printf '### 서사만 있는 함정\n- 가드 주석이 없다\n' > "$TMP/noguard.md"
  _mkindex "$TMP/index.md" '서사만 있는 함정'
  run bash scripts/verify-traps.sh "$TMP/led.md" "$TMP/noguard.md" "$TMP/index.md"
  [ "$status" -eq 0 ]
  echo "$output" | grep -Fq "실재 + SSOT"
}

@test "the live ledger declares every exemption with a reason, and none is silently blank" {
  # 원장에서 면제 마커를 쓴 행은 두 사유 중 하나여야 한다 — `SSOT없음`만 적고 사유를 비우면
  # "왜 면제인가"가 사라져 다음 사람이 근거 없이 복제한다.
  bad="$(grep -oE 'SSOT없음\([^)]*\)' docs/traps.md | LC_ALL=C sort -u | grep -vE '^SSOT없음\((불변식|승격대상)\)$' || true)"
  [ -z "$bad" ]
  # 그리고 실제로 쓰이고 있는지(마커가 죽은 문법이 되면 위 레인들이 vacuous해진다).
  [ "$(grep -c 'SSOT없음(' docs/traps.md)" -ge 1 ]
}

@test "a row whose guard column is prose-only (no executable extension) is flagged unless marked" {
  # ★ 예전엔 guards가 비면(guard 열이 .md 등 실행 가능 확장자가 아니면) 그 행이 n_rows에도 안
  #   잡히고 조용히 건너뛰어졌다(2026-09-03 실측: 단일 `.md`-only 행 픽스처 — SSOT 대응
  #   '> 가드:'가 아예 없어도 rc=0). 이제 명시 면제(`가드없음(산문SSOT)`) 없이는 FAIL이다.
  printf '| 함정 | where | guard |\n|---|---|---|\n| 산문 SSOT 함정 | gate | `docs/memory-ledger.md` |\n' > "$TMP/prose.md"
  printf '### 다른 함정\n- 본문\n' > "$TMP/detail.md"
  _mkindex "$TMP/index.md" '다른 함정'
  run bash scripts/verify-traps.sh "$TMP/prose.md" "$TMP/detail.md" "$TMP/index.md"
  [ "$status" -ne 0 ]
  echo "$output" | grep -Fq "실행 가능한 가드"
  printf '| 함정 | where | guard |\n|---|---|---|\n| 산문 SSOT 함정 | gate · 가드없음(산문SSOT) | `docs/memory-ledger.md` |\n' > "$TMP/prose-ok.md"
  run bash scripts/verify-traps.sh "$TMP/prose-ok.md" "$TMP/detail.md" "$TMP/index.md"
  [ "$status" -eq 0 ]
}

@test "direction 2 flags an SSOT guard annotation absent from the ledger (reverse-tie regression)" {
  # guard-decision-b-3 — line 69의 SSOT→원장 역추적(grep -Fq -- "$p" "$LEDGER")을 무력화해도(뮤테이션:
  # true로 교체) 기존 7개 @test 전건이 초록이었다 — 이 픽스처는 방향②만 겨냥한다(DETAIL의 '> 가드:'
  # 경로가 LEDGER 어디에도 없으면 드리프트).
  printf '| 함정 | where | guard |\n|---|---|---|\n' > "$TMP/led.md"
  printf '### 다른 함정\n> 가드: `scripts/does-not-appear-in-ledger.sh`\n- 본문\n' > "$TMP/detail.md"
  _mkindex "$TMP/index.md" '다른 함정'
  run bash scripts/verify-traps.sh "$TMP/led.md" "$TMP/detail.md" "$TMP/index.md"
  [ "$status" -ne 0 ]
  echo "$output" | grep -Fq "SSOT(traps-detail.md) 가드가 원장에 부재"
}

@test "direction 4 flags an AGENTS index line that appends a tail to the SSOT headline" {
  # guard-decision-b-3 — line 162/169의 완전일치(grep -Fqx)가 부분일치(grep -Fq)로 완화돼도 기존
  # 7개 @test 전건이 초록이었다 — 꼬리 덧붙임은 개수 등식(n_index==n_heads)으로도 안 잡힌다
  # (2026-08-29 실사고: 107=107인데 4건이 이 상태).
  printf '| 함정 | where | guard |\n|---|---|---|\n' > "$TMP/led.md"
  printf '### 헤드라인 테스트\n- 본문\n' > "$TMP/detail.md"
  _mkindex "$TMP/index.md" '헤드라인 테스트 (부가설명)'
  run bash scripts/verify-traps.sh "$TMP/led.md" "$TMP/detail.md" "$TMP/index.md"
  [ "$status" -ne 0 ]
  echo "$output" | grep -Fq "완전 일치 아님"
}

@test "verify-traps flags a ledger guard path that does not exist" {
  printf '| 함정 | status | guard |\n|---|---|---|\n| x | gate-enforced | `tools/tests/nonexistent-guard.bats` |\n' > "$TMP/bad.md"
  printf '### 아무 함정\n- 본문\n' > "$TMP/detail.md"
  _mkindex "$TMP/index.md" '아무 함정'
  run bash scripts/verify-traps.sh "$TMP/bad.md" "$TMP/detail.md" "$TMP/index.md"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "nonexistent-guard"
}
