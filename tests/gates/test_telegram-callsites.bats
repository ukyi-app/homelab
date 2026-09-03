#!/usr/bin/env bats
# 모든 호출처가 telegram-notify 계약을 지키는지 검사(건수는 아래 EXPECTED here-doc이 유일한 SSOT —
# 헤더에 숫자를 박으면 그 자체가 낡은 주장이 된다. 실제로 '15개'로 굳어 있던 것을 걷어냈다). ⚠️ 중간 단언은 [ ]만(bash 3.2 [[ ]] 침묵통과).
# ⚠️ declare -A 금지(bash 3.2 미지원) — 기대 목록은 here-doc로.
# ⚠️ @test 이름은 영어만(한글이면 bats 파싱 깨짐 — 검증된 버그, AGENTS.md).
setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"; WF="$ROOT/.github/workflows"
  command -v yq >/dev/null || skip "yq required"
}

# 콜사이트 **건수 SSOT** — @test 1의 대조표이자 아래 계약 레인의 열거 붕괴 바닥값이다.
# 두 @test가 각자 표를 들면 그 자체가 두 번째 손 관리 수치가 된다 — 한 함수가 소유한다.
# ⚠️ 새 콜사이트는 이 here-doc에 줄만 더한다(절대값 prebake 금지 — 합계는 소비처가 파생한다).
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
expected_callsites() {
  cat <<'EOF'
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
}

# ⚠️ 테스트 이름에 건수를 박지 않는다 — 이름이 곧 낡은 주장이 된다(이 이름은 실제로 bump=1·
# tf-reconcile=3으로 굳어 있었고 그 사이 둘 다 바뀌었다). 권위는 expected_callsites 하나다.
@test "exactly the expected workflows notify via the action (self-deriving sum)" {
  EXPECTED="$(expected_callsites)"
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

@test "every call site satisfies the action required inputs and carries an if: guard (roster derived)" {
  # 콜사이트별 **계약** 레인 — 건수 SSOT(@test 1)는 "몇 개인가"만 말한다. 여기서 두 축을 진다.
  # ⚠️ 필수 키 로스터를 손으로 적지 않는다 — action.yml의 `required: true`에서 파생한다.
  #    손 목록이던 시절: action.yml에 새 `required: true` 입력을 넣어도 20 콜사이트 전부가 그 키를
  #    빠뜨린 채 7/7 초록이었다(실측).
  # ⚠️ `if:` 축은 아예 무증인이었다 — audit.yaml 콜사이트의 `if:` 한 줄을 지워도 7/7 초록(실측).
  #    그 한 줄이 "드리프트/실패 시에만"이라는 알림 정책 전부를 진다(지우면 매 실행 알림 = 소음).
  # ⚠️ 2>/dev/null·|| true 금지 — yq 하드 실패는 대입 자리에서 set -e로 죽어야 한다(@test 2와 같은 규율).
  ACT="$ROOT/.github/actions/telegram-notify/action.yml"
  [ -f "$ACT" ]
  req="$(yq -r '.inputs | to_entries[] | select(.value.required == true) | .key' "$ACT")"
  nreq=$(printf '%s\n' "$req" | awk 'NF { n++ } END { print n+0 }')
  # 로스터 바닥값(양성 대조) — action.yml이 리네임되거나 `required` 표기가 바뀌면 아래 차집합이
  # 빈 배열이 되어 전 콜사이트가 무조건 통과한다. 5 = status·source·title·bot-token·chat-id.
  [ "$nreq" -ge 5 ]
  reqjson="[$(printf '%s\n' "$req" | awk 'NF { printf "%s\"%s\"", (n++ ? "," : ""), $0 } END { printf "\n" }')]"

  total=0
  for f in "$WF"/*.yml "$WF"/*.yaml; do
    [ -e "$f" ] || continue
    n=$(yq -r '[.jobs[].steps[]? | select(.uses=="./.github/actions/telegram-notify")] | length' "$f")
    total=$(( total + n ))
    miss=$(REQ_JSON="$reqjson" yq -r '[.jobs[].steps[]?
      | select(.uses=="./.github/actions/telegram-notify")
      | (.name // "(unnamed)") as $nm
      | ((env(REQ_JSON)) - ((.with // {}) | keys)) | .[] | $nm + " -> " + .] | .[]' "$f")
    [ -z "$miss" ] || { echo "$f: 필수 with 키 부재 — $miss"; false; }
    noif=$(yq -r '[.jobs[].steps[]?
      | select(.uses=="./.github/actions/telegram-notify")
      | select((.if // "") == "")] | length' "$f")
    [ "$noif" -eq 0 ] || { echo "$f: if: 없는 telegram-notify 콜사이트 ${noif}건 — 알림 조건이 사라졌다"; false; }
  done
  # 열거 붕괴 바닥값 — 셀렉터가 부패하면 위 루프는 0건 평가하고 부정 카운트만으로는 rc에 안 보인다.
  # 건수 SSOT와 **같은 수**를 요구한다(@test 2가 잇는 grep↔yq 다리와 독립한, 표↔yq 다리).
  expected=$(expected_callsites | awk '{ s += $2 } END { print s+0 }')
  [ "$expected" -gt 0 ]
  [ "$total" -eq "$expected" ] || { echo "yq 열거 $total != 건수 SSOT $expected — 콜사이트 계약이 그만큼 미평가"; false; }
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

@test "outcome-driven status expressions guard on success, not on failure (skipped upstream is not drift)" {
  # 상류 스텝(checkout·setup-bun 등)이 죽으면 그 뒤 검사 스텝은 outcome=**skipped**이고 outputs는 ''이다.
  # `outcome == 'failure' && 'failure' || …`처럼 **부정 가드**로 쓰면 첫 분기가 거짓이라 `'' != '0'`이
  # 참이 되어 실행 실패가 'drift'(⚠️ 경고)로 오라벨된다 — 원인이 러너/의존성인데 드리프트로 귀속된다.
  # 긍정 가드(`outcome == 'success' && … || 'failure'`)만이 success 아닌 모든 결과를 failure로 접는다.
  # 선례: contract-drift.yaml(b11b 적대리뷰). audit·dns-drift·회계 3종이 뒤늦게 여기에 합류했다.
  n=0; bad=""
  for f in "$WF"/*.yml "$WF"/*.yaml; do
    [ -e "$f" ] || continue
    # ⚠️ 2>/dev/null·|| true 금지 — yq 하드 실패는 대입 자리에서 set -e로 죽어야 한다(위 @test와 같은 규율).
    sts="$(yq -r '.jobs[].steps[]? | select(.uses=="./.github/actions/telegram-notify") | (.with.status // "")' "$f")"
    while read -r st; do
      [ -n "$st" ] || continue
      grep -qF '.outcome' <<<"$st" || continue      # outcome을 참조하지 않는 콜사이트는 분모 밖
      n=$(( n + 1 ))
      grep -qF "outcome == 'success'" <<<"$st" || bad="$bad
  $(basename "$f"): 긍정 가드 없음 — $st"
      if grep -qE "outcome == 'failure'[[:space:]]*&&[[:space:]]*'failure'" <<<"$st"; then
        bad="$bad
  $(basename "$f"): 옛 부정 가드 — $st"
      fi
    done <<EOF
$sts
EOF
  done
  [ -z "$bad" ] || { echo "$bad"; false; }
  # 양성 대조 — outcome을 참조하는 콜사이트가 실재해야 한다. 셀렉터가 부패하거나 `.with.status`가
  # 리네임되면 위 루프는 0회 돌고 부정 카운트(bad 빈 문자열)만으로는 그것이 rc에 안 보인다.
  # 6 = audit · dns-drift · contract-drift · bump-poll/renovate/tf-reconcile 회계(콜사이트가 소유한 바닥값).
  [ "$n" -ge 6 ]
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
