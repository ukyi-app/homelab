#!/usr/bin/env bats
# 15개 호출처가 telegram-notify 계약을 지키는지 검사. ⚠️ 중간 단언은 [ ]만(bash 3.2 [[ ]] 침묵통과).
# ⚠️ declare -A 금지(bash 3.2 미지원) — 기대 목록은 here-doc로.
# ⚠️ @test 이름은 영어만(한글이면 bats 파싱 깨짐 — 검증된 버그, AGENTS.md).
setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"; WF="$ROOT/.github/workflows"
  command -v yq >/dev/null || skip "yq required"
}

@test "exactly the expected workflows notify via the action (self-deriving sum, bump=1, tf-reconcile=3)" {
  # ⚠️ codex restale3 F1: 합계는 here-doc 줄의 self-deriving sum(절대값 prebake 금지) — 새 콜사이트(P6 pr-sweeper·
  # P8 build.yaml)는 EXPECTED here-doc 줄만 더하면 된다(머지 순서 의존 절대값 무수정).
  # B6a: 4 변이 디스패처(create-app/update-secrets/create-database/create-cache)는 notify를
  # .github/actions/mutation-notify composite로 위임(→내부에서 telegram-notify) → 직접 카운트 0.
  # 위임 자체는 test_mutation-dispatch.bats가 검증(composite uses + job.status 직접참조 금지).
  EXPECTED="$(cat <<'EOF'
_create-app.yaml 1
_create-database.yaml 1
_create-cache.yaml 1
_update-secrets.yaml 1
create-app.yaml 0
update-secrets.yaml 0
create-database.yaml 0
create-cache.yaml 0
audit.yaml 1
bump.yaml 1
bump-poll.yaml 1
iac.yaml 1
tf-reconcile.yaml 3
dns-drift.yaml 1
pr-sweeper.yaml 1
build.yaml 1
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
