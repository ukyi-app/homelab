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
