#!/usr/bin/env bats
# 모든 호출처가 telegram-notify 계약을 지키는지 검사(건수는 아래 EXPECTED here-doc이 유일한 SSOT —
# 헤더에 숫자를 박으면 그 자체가 낡은 주장이 된다. 실제로 '15개'로 굳어 있던 것을 걷어냈다). ⚠️ 중간 단언은 [ ]만(bash 3.2 [[ ]] 침묵통과).
# ⚠️ declare -A 금지(bash 3.2 미지원) — 기대 목록은 here-doc로.
# ⚠️ @test 이름은 영어만(한글이면 bats 파싱 깨짐 — 검증된 버그, AGENTS.md).
setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"; WF="$ROOT/.github/workflows"
  command -v yq >/dev/null || skip "yq required"
}

# ⚠️ 테스트 이름에 건수를 박지 않는다 — 이름이 곧 낡은 주장이 된다(이 이름은 실제로 bump=1·
# tf-reconcile=3으로 굳어 있었고 그 사이 둘 다 바뀌었다). 권위는 아래 here-doc 하나다.
@test "exactly the expected workflows notify via the action (self-deriving sum)" {
  # ⚠️ codex restale3 F1: 합계는 here-doc 줄의 self-deriving sum(절대값 prebake 금지) — 새 콜사이트(P6 pr-sweeper·
  # P8 build.yaml)는 EXPECTED here-doc 줄만 더하면 된다(머지 순서 의존 절대값 무수정).
  # B6a: 4 변이 디스패처(create-app/update-secrets/create-database/create-cache)는 notify를
  # .github/actions/mutation-notify composite로 위임(→내부에서 telegram-notify) → 직접 카운트 0.
  # 위임 자체는 test_mutation-dispatch.bats가 검증(composite uses + job.status 직접참조 금지).
  # bump-poll=3: bump 루프(poll job) + **인가 회수(reconcile job)** + **준비상태 회계(accounting job)**.
  # 회수는 독립 job이라 자기 실패를 스스로 알려야 한다 — poll의 알림에 얹으면 그 job의 성공에 묶인다
  # (그리고 회수 실패는 "낡은 auto-merge 인가가 살아남았다"는 **보안** 사실이라 조용하면 안 된다).
  # 회계 job의 알림이 **별도**인 이유는 더 근본적이다(G-09): 감시 대상 job이 skip되면 그 안의 알림 스텝은
  # `if: always()`여도 실행되지 않는다 — 게이트 밖 job만이 그 침묵을 알릴 수 있다.
  # tf-reconcile=4(수렴 + github/tailscale 드리프트 + 회계) · renovate=1(회계 전용 — 이 워크플로의 첫 알림).
  # iac는 회계가 있어도 0→1이 아니다: PR 컨텍스트라 red 체크 자체가 사람이 보는 신호이고 매 PR 알림은 소음이다.
  EXPECTED="$(cat <<'EOF'
_create-app.yaml 1
_create-database.yaml 1
_create-cache.yaml 1
_update-secrets.yaml 1
_teardown-app.yaml 1
create-app.yaml 0
update-secrets.yaml 0
create-database.yaml 0
create-cache.yaml 0
audit.yaml 1
bump.yaml 1
bump-poll.yaml 3
iac.yaml 1
tf-reconcile.yaml 4
dns-drift.yaml 1
renovate.yaml 1
contract-drift.yaml 1
pr-sweeper.yaml 1
build.yaml 1
credential-expiry.yaml 1
EOF
)"
  total=0
  while read -r wf n; do
    [ -n "$wf" ] || continue
    got=$(grep -c "uses: ./.github/actions/telegram-notify" "$WF/$wf" 2>/dev/null || true)
    [ "${got:-0}" -eq "$n" ] || { echo "$wf: want $n got ${got:-0}"; false; }
    total=$(( total + ${got:-0} ))
  done <<EOF
$EXPECTED
EOF
  expected=$(printf '%s\n' "$EXPECTED" | awk '{ s += $2 } END { print s }')
  [ "$total" -eq "$expected" ]
  ! grep -rq "api.telegram.org" "$WF"   # raw curl 0 — 모든 인라인 curl이 액션으로 이행됨
}

@test "yq selector sees every grep-visible call site (positive control, self-deriving)" {
  # 열거 붕괴 → vacuous green 차단. 아래 @test들은 yq 셀렉터 결과를 **부정 카운트로만** 판정해
  # '위반 0'과 '아무것도 안 봤다'가 같은 초록이 된다(실측: 빈 출력 yq 셰임에서 5/5 ok).
  # 더 중요한 건 **부분 실명**이다 — @test 1의 grep은 substring, 아래 yq는 `==`라 한 콜사이트만
  # `telegram-notify/`(후행 슬래시)로 드리프트하면 grep은 세고 yq는 못 봐서 그 스텝의 계약 4건이
  # 조용히 0건 평가된다(client_payload 신뢰 경계 포함). 실측: 그 상태로 run-bats 전량 rc=0이었다.
  # yq 매치 수 == grep 리터럴 수 교차검증이 그 다리를 잇는다.
  # ⚠️ 2>/dev/null·|| true 금지 — yq 하드 실패는 set -e로 여기서 죽어야 한다.
  # ⚠️ 절대값 prebake 금지(@test 1과 같은 규율) — 양쪽 다 self-deriving.
  yqn=0; gn=0
  for f in "$WF"/*.yml "$WF"/*.yaml; do
    [ -e "$f" ] || continue
    n=$(yq -r '[.jobs[].steps[]? | select(.uses=="./.github/actions/telegram-notify")] | length' "$f")
    yqn=$(( yqn + ${n:-0} ))
    g=$(grep -c "uses: ./.github/actions/telegram-notify" "$f" || true)
    gn=$(( gn + ${g:-0} ))
  done
  [ "$yqn" -gt 0 ]
  [ "$yqn" -eq "$gn" ] || { echo "yq 매치 $yqn != grep 리터럴 $gn — 셀렉터가 콜사이트를 놓쳤다(아래 계약이 0건 평가된다)"; false; }
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

@test "every call site title is Korean (non-ASCII present, blocks english-title regression)" {
  # source 라벨뿐 아니라 with.title 자체가 한국어여야(영어 제목 회귀 차단).
  # 비-ASCII 판정은 LC_ALL=C + 인쇄가능 ASCII 클래스로(BSD/GNU 양쪽 동작 — [가-힣]는 로케일 의존).
  for f in "$WF"/*.yml "$WF"/*.yaml; do
    [ -e "$f" ] || continue
    bad=$(yq -r '.jobs[].steps[]? | select(.uses=="./.github/actions/telegram-notify") | (.with.title // "")' "$f" 2>/dev/null \
      | grep -v '^$' | LC_ALL=C grep -vE '[^ -~]' || true)
    [ -z "$bad" ] || { echo "$f: 비-한국어(순수 ASCII) title: $bad"; false; }
  done
}
